import Foundation
import SimmerCore

/// Wires the pieces of the daemon together: SMC access, the shared ``HelperCore``, the XPC
/// listener, the watchdog timer and signal handling.
enum HelperDaemon {
    /// Seconds between watchdog checks (the timeout itself is `HelperCore.watchdogTimeout`).
    private static let watchdogInterval = 15

    static func run(arguments: [String]) -> Never {
        let isDryRun = arguments.dropFirst().contains("--dry-run")
        let log = HelperLog(mirrorToStderr: isDryRun || isatty(STDERR_FILENO) != 0)
        log.notice("SimmerHelper \(HelperCore.version) starting (pid \(getpid()), uid \(getuid()))"
            + (isDryRun ? " – DRY RUN, no hardware is touched" : ""))

        for argument in arguments.dropFirst() where argument != "--dry-run" {
            log.error("ignoring unknown argument '\(argument)'")
        }

        // MARK: Hardware

        let smc: any SMCInterface
        if isDryRun {
            smc = DryRunSMC.hostDefault { write in
                log.info("dry-run SMC write \(write.key) = \(write.hex)")
            }
        } else {
            do {
                smc = try AppleSMC()
            } catch {
                log.error("cannot open AppleSMC: \(error)")
                exit(EXIT_FAILURE)
            }
            if getuid() != 0 {
                log.error("not running as root – SMC writes will be rejected")
            }
        }

        // macOS 27 gates the SMC charging keys; there the system's own charge limit is used.
        let nativeLimit: (any NativeLimitControlling)? =
            !isDryRun && NativeChargeLimit.isSupportedOnThisSystem ? NativeChargeLimit() : nil
        let batteryReader = BatteryReader(smc: nil)
        let hardware = ChargeHardware(smc: smc, nativeLimit: nativeLimit) { batteryReader.read()?.percent }
        let core = HelperCore(hardware: hardware, isDryRun: isDryRun)
        let capabilities = hardware.capabilities
        log.info("capabilities: charging=\(capabilities.charging.rawValue) adapter=\(capabilities.adapter.rawValue) "
            + "hardwareLimit=\(capabilities.hardwareLimit.rawValue) led=\(capabilities.hasMagSafeLED)")

        // A helper that crashed or was restarted must never leave charging blocked or the
        // adapter disconnected: start from stock behaviour, the app re-applies its state.
        core.failSafeReset()
        log.info("start-up fail-safe reset done")

        // MARK: Signals

        // SIG_IGN keeps the default action (immediate termination) from running; the
        // dispatch sources still observe the signals.
        let signalQueue = DispatchQueue(label: "com.simmer.helper.signals")
        let signalSources = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler {
                log.notice("received signal \(number); restoring stock charging and exiting")
                core.failSafeReset()
                exit(EXIT_SUCCESS)
            }
            source.resume()
            return source
        }

        // MARK: Watchdog

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.simmer.helper.watchdog"))
        watchdog.schedule(
            deadline: .now() + .seconds(watchdogInterval), repeating: .seconds(watchdogInterval),
            leeway: .seconds(1)
        )
        watchdog.setEventHandler {
            if core.checkWatchdog() {
                log.notice("watchdog: client silent for more than \(Int(HelperCore.watchdogTimeout)) s, fail-safe applied")
            }
        }
        watchdog.resume()

        // MARK: XPC

        let requirement = ClientValidation.requirement()
        if let team = requirement.teamID {
            log.info("clients must be \(SimmerIdentifiers.appBundleID) signed by team \(team)")
        } else {
            log.notice("helper is ad-hoc signed or unsigned: clients are validated by identifier only")
        }

        let delegate = ListenerDelegate(core: core, log: log, requirement: requirement.text)
        // Outside launchd (e.g. started by hand) the mach service cannot be checked in. XPC
        // then just never delivers a connection; the daemon keeps running, which is what
        // the `--dry-run` smoke test relies on.
        let listener = NSXPCListener(machServiceName: SimmerIdentifiers.helperService)
        listener.delegate = delegate
        listener.resume()
        log.info("listening on mach service \(SimmerIdentifiers.helperService)")

        // Keeps the listener (whose delegate is weak), its delegate and the dispatch
        // sources alive for the lifetime of the process.
        withExtendedLifetime((listener, delegate, signalSources, watchdog)) {
            dispatchMain()
        }
    }
}
