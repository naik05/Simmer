import AppKit
import Observation

public enum HelperConnection: Sendable, Equatable {
    case connecting
    case connected(version: String)
    /// SMC writes are simulated in-process.
    case dryRun
    case unavailable(String)

    public var isUsable: Bool {
        switch self {
        case .connected, .dryRun: true
        case .connecting, .unavailable: false
        }
    }
}

/// The app's single source of truth: owns settings, polls telemetry, runs the charge
/// engine and schedules, and pushes the resulting commands to the helper.
///
/// UI code reads the observable properties and calls the action methods; it never talks
/// to the helper or the SMC directly.
@MainActor
@Observable
public final class SimmerModel {
    public static let shared = SimmerModel()

    // MARK: Observable state

    public var settings: SimmerSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            settingsChanged(from: oldValue)
        }
    }

    public private(set) var snapshot: BatterySnapshot?
    public private(set) var engineState: EngineState
    public private(set) var activity = ChargeActivity.unmanaged
    public private(set) var connection = HelperConnection.connecting
    public private(set) var capabilities = HardwareCapabilities.unsupported
    /// Most recent failure talking to the helper, for display.
    public private(set) var lastError: String?
    /// 0…1 while a calibration runs, otherwise `nil`.
    public private(set) var calibrationProgress: Double?
    /// The command most recently accepted by the helper.
    public private(set) var appliedCommand: ChargeCommand?
    /// `true` when the installed helper is a different version than this app expects.
    public var helperNeedsUpdate: Bool {
        if case .connected(let version) = connection { return version != HelperCore.version }
        return false
    }

    /// Human-readable record of simulated SMC writes (dry-run mode), newest last.
    public private(set) var dryRunLog: [String] = []

    /// Called on the main actor for every engine event (limit reached, top-up finished, …).
    @ObservationIgnored public var onEvent: ((EngineEvent) -> Void)?

    // MARK: Dependencies

    public typealias ControllerFactory = @MainActor (_ dryRun: Bool, _ onWrite: @escaping @Sendable (DryRunSMC.Write) -> Void)
        -> any ChargeControlling

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let readSnapshot: @MainActor () -> BatterySnapshot?
    @ObservationIgnored private let makeController: ControllerFactory
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var controller: (any ChargeControlling)?
    @ObservationIgnored private var engine: ChargeEngine
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var isTicking = false
    @ObservationIgnored private var needsTick = false
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var lastSentAt = Date.distantPast
    @ObservationIgnored private var lastConnectAttempt = Date.distantPast
    @ObservationIgnored private var lastScheduleCheck = Date()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    public init(
        store: SettingsStore = SettingsStore(),
        tickInterval: Duration = .seconds(5),
        readSnapshot: (@MainActor () -> BatterySnapshot?)? = nil,
        makeController: ControllerFactory? = nil
    ) {
        self.store = store
        self.tickInterval = tickInterval
        settings = store.loadSettings()
        let state = store.loadEngineState()
        engine = ChargeEngine(state: state)
        engineState = state

        if let readSnapshot {
            self.readSnapshot = readSnapshot
        } else {
            let reader = BatteryReader(smc: try? AppleSMC())
            self.readSnapshot = { reader.read() }
        }
        self.makeController = makeController ?? { dryRun, onWrite in
            if dryRun { DryRunChargeController(onWrite: onWrite) } else { XPCChargeController() }
        }
    }

    // MARK: Lifecycle

    /// Starts polling. Safe to call more than once.
    public func start() {
        guard loopTask == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: self.tickInterval)
            }
        }
    }

    /// Call from `applicationWillTerminate`. Dropping the connection lets the helper apply
    /// the fail-safe policy (reset to stock unless the user chose to keep the state).
    public func prepareForTermination() {
        loopTask?.cancel()
        loopTask = nil
        controller?.disconnect()
        controller = nil
    }

    /// Re-establishes the helper connection, e.g. right after installing the helper.
    public func reconnect() async {
        controller?.disconnect()
        controller = nil
        connection = .connecting
        appliedCommand = nil
        await connect()
        await tick()
    }

    // MARK: Actions

    public func setLimit(_ percent: Int) {
        settings.engine.limit = min(max(percent, EngineConfig.limitRange.lowerBound), EngineConfig.limitRange.upperBound)
    }

    /// Drains the battery down to the limit while staying plugged in.
    public func startDischarge() {
        guard capabilities.canDischarge else { return }
        mutateEngine { $0.startDischarge() }
    }

    /// Charges to 100 % once, then returns to the configured limit.
    public func startTopUp() {
        mutateEngine { $0.startTopUp() }
    }

    public func startCalibration() {
        guard capabilities.canDischarge, let percent = snapshot?.percent else { return }
        mutateEngine { $0.startCalibration(currentPercent: percent) }
    }

    /// Cancels discharge, top-up or calibration.
    public func returnToNormal() {
        mutateEngine { $0.returnToNormal() }
    }

    public func perform(_ action: ScheduleAction) {
        switch action {
        case .topUp: startTopUp()
        case .setLimit(let percent): setLimit(percent)
        case .startDischarge: startDischarge()
        case .returnToNormal: returnToNormal()
        case .startCalibration: startCalibration()
        }
    }

    public func clearDryRunLog() {
        dryRunLog.removeAll()
    }

    /// Runs one control cycle now instead of waiting for the next poll.
    public func refresh() {
        Task { await tick() }
    }

    // MARK: Control loop

    func tick(now: Date = Date()) async {
        guard !isTicking else {
            needsTick = true
            return
        }
        isTicking = true
        defer {
            isTicking = false
            if needsTick {
                needsTick = false
                refresh()
            }
        }

        if !connection.isUsable, now.timeIntervalSince(lastConnectAttempt) >= 10 {
            await connect(now: now)
        }

        snapshot = readSnapshot()
        // While Simmer itself disconnected the adapter, the system reports "unplugged".
        // Keep treating the Mac as plugged in, or the engine would flap.
        if adapterIsDisconnectedBySimmer, snapshot?.isPluggedIn == false {
            snapshot?.isPluggedIn = true
        }
        guard let snapshot else {
            activity = .unmanaged
            return
        }

        runSchedules(now: now)

        var command = ChargeCommand.stock
        if settings.isLimiterEnabled {
            let output = engine.tick(snapshot: snapshot, config: settings.engine, now: now)
            activity = output.activity
            command = isSleeping ? sleepCommand(from: output.command) : output.command
            output.events.forEach { onEvent?($0) }
        } else {
            activity = .unmanaged
        }
        publishEngineState()
        calibrationProgress = engine.calibrationProgress(snapshot: snapshot, config: settings.engine, now: now)
        await send(command, now: now)
    }

    private func connect(now: Date = Date()) async {
        lastConnectAttempt = now
        let controller = controller ?? makeController(settings.dryRun) { [weak self] write in
            Task { @MainActor in self?.recordDryRunWrite(write) }
        }
        self.controller = controller
        do {
            let handshake = try await controller.handshake()
            try await controller.configure(settings.failSafePolicy)
            capabilities = handshake.capabilities
            connection = handshake.isDryRun ? .dryRun : .connected(version: handshake.version)
            lastError = nil
        } catch {
            connection = .unavailable(String(describing: error))
        }
    }

    private func send(_ command: ChargeCommand, now: Date) async {
        guard connection.isUsable, let controller else { return }
        // Resend unchanged commands periodically: they double as the helper's heartbeat.
        guard command != appliedCommand || now.timeIntervalSince(lastSentAt) >= 30 else { return }
        do {
            try await controller.apply(command)
            appliedCommand = command
            lastSentAt = now
            lastError = nil
        } catch let error as HelperError {
            lastError = error.description
            if case .connection = error {
                connection = .unavailable(error.description)
                appliedCommand = nil
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func runSchedules(now: Date) {
        let due = Scheduler.dueRules(settings.schedules, after: lastScheduleCheck, upTo: now)
        lastScheduleCheck = now
        for rule in due { perform(rule.action) }
    }

    private func mutateEngine(_ body: (inout ChargeEngine) -> Void) {
        body(&engine)
        publishEngineState()
        refresh()
    }

    private func publishEngineState() {
        guard engine.state != engineState else { return }
        engineState = engine.state
        store.save(engine.state)
    }

    private func settingsChanged(from old: SimmerSettings) {
        if settings.dryRun != old.dryRun {
            Task { await reconnect() }
            return
        }
        if settings.failSafePolicy != old.failSafePolicy, connection.isUsable, let controller {
            let policy = settings.failSafePolicy
            Task { try? await controller.configure(policy) }
        }
        refresh()
    }

    private func recordDryRunWrite(_ write: DryRunSMC.Write) {
        let time = Date().formatted(date: .omitted, time: .standard)
        dryRunLog.append("\(time)  \(write.key) ← \(write.hex)")
        if dryRunLog.count > 200 { dryRunLog.removeFirst(dryRunLog.count - 200) }
    }

    private var adapterIsDisconnectedBySimmer: Bool {
        guard let applied = appliedCommand else { return false }
        return !applied.adapterConnected || (capabilities.holdsByDischarging && !applied.chargingAllowed)
    }

    // MARK: Sleep

    /// While asleep nobody watches the battery, so never sleep in a forced discharge, and
    /// (if enabled) hand the limit to the firmware / inhibit charging in limiter mode.
    private func sleepCommand(from command: ChargeCommand) -> ChargeCommand {
        var command = command
        command.adapterConnected = true
        // Holding by running from the battery must not continue unattended during sleep.
        if capabilities.holdsByDischarging {
            command.chargingAllowed = true
            return command
        }
        // macOS keeps enforcing its own limit while asleep; nothing to change.
        if capabilities.limitEnforcedBySystem { return command }
        if settings.stopChargingBeforeSleep, engine.state.mode == .normal {
            command.chargingAllowed = false
            command.hold = settings.engine.holdBand
        }
        return command
    }

    private func systemWillSleep() {
        isSleeping = true
        refresh()
    }

    private func systemDidWake() {
        isSleeping = false
        appliedCommand = nil
        lastScheduleCheck = max(lastScheduleCheck, Date().addingTimeInterval(-15 * 60))
        refresh()
    }
}
