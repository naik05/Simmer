import Foundation

/// How the MagSafe LED is driven.
public enum LEDMode: String, Codable, Sendable, CaseIterable {
    /// Leave the LED to macOS.
    case system
    /// Green while holding at the limit, orange while charging, off while discharging,
    /// blinking while heat protection pauses charging.
    case status
    /// Always off.
    case off
}

/// User-tunable parameters of the charge state machine.
public struct EngineConfig: Codable, Sendable, Equatable {
    public static let limitRange = 20...100
    public static let bufferRange = 0...30

    /// Maximum charge in percent.
    public var limit = 80
    /// Sailing buffer: after reaching the limit, charging resumes only once the battery
    /// dropped this many percent below it. `0` disables sailing.
    public var sailingBuffer = 5
    public var heatProtectionEnabled = true
    public var heatThresholdC = 35.0
    /// Charging resumes once the battery cooled this far below the threshold.
    public var heatHysteresisC = 2.0
    public var ledMode = LEDMode.system
    public var calibrationLowPercent = 15
    public var calibrationRestDuration: TimeInterval = 3600

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EngineConfig()
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? defaults.limit
        sailingBuffer = try values.decodeIfPresent(Int.self, forKey: .sailingBuffer) ?? defaults.sailingBuffer
        heatProtectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled)
            ?? defaults.heatProtectionEnabled
        heatThresholdC = try values.decodeIfPresent(Double.self, forKey: .heatThresholdC) ?? defaults.heatThresholdC
        heatHysteresisC = try values.decodeIfPresent(Double.self, forKey: .heatHysteresisC) ?? defaults.heatHysteresisC
        ledMode = (try? values.decodeIfPresent(LEDMode.self, forKey: .ledMode)) ?? defaults.ledMode
        calibrationLowPercent = try values.decodeIfPresent(Int.self, forKey: .calibrationLowPercent)
            ?? defaults.calibrationLowPercent
        calibrationRestDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .calibrationRestDuration)
            ?? defaults.calibrationRestDuration
        self = sanitized()
    }

    /// The limit clamped to the supported range.
    public var effectiveLimit: Int { min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound) }

    /// Charge level at or below which charging resumes.
    public var resumeLevel: Int {
        let buffer = min(max(sailingBuffer, Self.bufferRange.lowerBound), Self.bufferRange.upperBound)
        return max(effectiveLimit - buffer, 10)
    }

    public var holdBand: ChargeBand { ChargeBand(upper: effectiveLimit, lower: resumeLevel) }

    public func sanitized() -> EngineConfig {
        var copy = self
        copy.limit = effectiveLimit
        copy.sailingBuffer = min(max(sailingBuffer, Self.bufferRange.lowerBound), Self.bufferRange.upperBound)
        copy.heatThresholdC = min(max(heatThresholdC, 25), 50)
        copy.heatHysteresisC = min(max(heatHysteresisC, 0.5), 10)
        copy.calibrationLowPercent = min(max(calibrationLowPercent, 5), 50)
        copy.calibrationRestDuration = max(calibrationRestDuration, 0)
        return copy
    }
}

public enum CalibrationPhase: String, Codable, Sendable, CaseIterable {
    case chargeToFull
    case dischargeToLow
    case rest
    case rechargeToLimit

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum EngineMode: Codable, Sendable, Equatable {
    /// Charge limiter with sailing.
    case normal
    /// Drain the battery down to the limit although the adapter is attached.
    case discharge
    /// Charge to 100 % once, then return to `normal`.
    case topUp
    case calibration(CalibrationPhase)
}

/// The engine's persistent state. Codable so a calibration survives an app relaunch.
public struct EngineState: Codable, Sendable, Equatable {
    public var mode = EngineMode.normal
    /// Sailing: the limit was reached and the battery has not yet fallen to the resume level.
    public var isHolding = false
    /// The limit that was in effect when holding began; raising the limit ends the hold.
    public var holdLimit: Int?
    public var isHeatPaused = false
    public var restStartedAt: Date?
    public var calibrationStartPercent: Int?

    public init() {}
}

/// What the battery is doing right now, for display.
public enum ChargeActivity: String, Codable, Sendable {
    case onBattery
    case charging
    case full
    /// At or sailing below the limit; the Mac runs from the adapter.
    case holding
    case discharging
    case heatPaused
    case resting
    /// Limiter disabled – macOS manages charging.
    case unmanaged
}

public enum EngineEvent: Sendable, Equatable {
    case limitReached(Int)
    case topUpFinished
    case dischargeFinished
    case heatPauseBegan(Double)
    case heatPauseEnded
    case calibrationPhaseChanged(CalibrationPhase)
    case calibrationFinished
}

public struct EngineOutput: Sendable, Equatable {
    public var command: ChargeCommand
    public var activity: ChargeActivity
    public var events: [EngineEvent]
}

/// Pure charge state machine. Feed it a battery snapshot on every tick and apply the
/// command it returns. No I/O, no clocks – everything is passed in, so it is fully testable.
public struct ChargeEngine: Sendable, Equatable {
    public var state: EngineState

    public init(state: EngineState = EngineState()) {
        self.state = state
    }

    // MARK: User actions

    public mutating func startDischarge() {
        state.mode = .discharge
    }

    public mutating func startTopUp() {
        state.mode = .topUp
    }

    public mutating func startCalibration(currentPercent: Int) {
        state.mode = .calibration(.chargeToFull)
        state.calibrationStartPercent = currentPercent
        state.restStartedAt = nil
    }

    /// Ends discharge, top-up or calibration and returns to the limiter.
    public mutating func returnToNormal() {
        state.mode = .normal
        state.isHolding = false
        state.holdLimit = nil
        state.restStartedAt = nil
        state.calibrationStartPercent = nil
    }

    // MARK: Tick

    public mutating func tick(snapshot: BatterySnapshot, config: EngineConfig, now: Date) -> EngineOutput {
        let config = config.sanitized()
        let percent = snapshot.percent
        let limit = config.effectiveLimit
        let isFull = percent >= 100 || snapshot.isFullyCharged
        var events: [EngineEvent] = []

        updateHeatPause(snapshot: snapshot, config: config, events: &events)

        // Resolve mode transitions first; each iteration either settles or advances the mode.
        var wantsCharge = false
        var adapterConnected = true
        var hold = config.holdBand
        var activity = ChargeActivity.holding

        resolve: for _ in 0..<6 {
            switch state.mode {
            case .normal:
                if state.isHolding, let held = state.holdLimit, limit > held {
                    // The user raised the limit: charge up to the new one right away.
                    state.isHolding = false
                }
                if !snapshot.isPluggedIn {
                    // Re-plugging below the limit should top the battery back up to it.
                    state.isHolding = percent >= limit
                } else if percent >= limit {
                    if !state.isHolding { events.append(.limitReached(limit)) }
                    state.isHolding = true
                } else if percent <= config.resumeLevel {
                    state.isHolding = false
                }
                state.holdLimit = state.isHolding ? limit : nil
                wantsCharge = !state.isHolding
                hold = config.holdBand
                activity = !snapshot.isPluggedIn ? .onBattery : (wantsCharge ? .charging : .holding)
                break resolve

            case .discharge:
                if percent <= limit {
                    finishToHolding()
                    events.append(.dischargeFinished)
                    continue
                }
                wantsCharge = false
                adapterConnected = false
                hold = config.holdBand
                activity = .discharging
                break resolve

            case .topUp:
                if isFull {
                    finishToHolding()
                    events.append(.topUpFinished)
                    continue
                }
                wantsCharge = true
                hold = ChargeBand(upper: 100, lower: 100)
                activity = snapshot.isPluggedIn ? .charging : .onBattery
                break resolve

            case .calibration(.chargeToFull):
                if isFull {
                    advanceCalibration(to: .dischargeToLow, events: &events)
                    continue
                }
                wantsCharge = true
                hold = ChargeBand(upper: 100, lower: 100)
                activity = snapshot.isPluggedIn ? .charging : .onBattery
                break resolve

            case .calibration(.dischargeToLow):
                if percent <= config.calibrationLowPercent {
                    state.restStartedAt = now
                    advanceCalibration(to: .rest, events: &events)
                    continue
                }
                wantsCharge = false
                adapterConnected = false
                hold = ChargeBand(upper: config.calibrationLowPercent, lower: 10)
                activity = .discharging
                break resolve

            case .calibration(.rest):
                let started = state.restStartedAt ?? now
                state.restStartedAt = started
                if now.timeIntervalSince(started) >= config.calibrationRestDuration {
                    advanceCalibration(to: .rechargeToLimit, events: &events)
                    continue
                }
                wantsCharge = false
                hold = ChargeBand(upper: percent, lower: 10)
                activity = .resting
                break resolve

            case .calibration(.rechargeToLimit):
                if percent >= limit {
                    finishToHolding()
                    events.append(.calibrationFinished)
                    continue
                }
                wantsCharge = true
                hold = config.holdBand
                activity = snapshot.isPluggedIn ? .charging : .onBattery
                break resolve
            }
        }

        // Heat protection overrides any wish to charge; it never touches the adapter.
        var chargingAllowed = wantsCharge
        if state.isHeatPaused, wantsCharge {
            chargingAllowed = false
            hold = ChargeBand(upper: percent, lower: 10)
            if snapshot.isPluggedIn { activity = .heatPaused }
        }
        if activity == .charging, isFull { activity = .full }

        let command = ChargeCommand(
            chargingAllowed: chargingAllowed,
            adapterConnected: adapterConnected,
            led: led(for: activity, mode: config.ledMode),
            hold: hold
        )
        return EngineOutput(command: command, activity: activity, events: events)
    }

    // MARK: Calibration progress

    /// Overall calibration progress in 0…1, or `nil` when no calibration is running.
    public func calibrationProgress(snapshot: BatterySnapshot, config: EngineConfig, now: Date) -> Double? {
        guard case .calibration(let phase) = state.mode else { return nil }
        let config = config.sanitized()
        let percent = Double(snapshot.percent)
        let low = Double(config.calibrationLowPercent)
        func fraction(_ done: Double, of total: Double) -> Double {
            total <= 0 ? 1 : min(max(done / total, 0), 1)
        }
        let within: Double
        switch phase {
        case .chargeToFull:
            let start = Double(state.calibrationStartPercent ?? snapshot.percent)
            within = fraction(percent - start, of: 100 - start)
        case .dischargeToLow:
            within = fraction(100 - percent, of: 100 - low)
        case .rest:
            let elapsed = state.restStartedAt.map { now.timeIntervalSince($0) } ?? 0
            within = fraction(elapsed, of: config.calibrationRestDuration)
        case .rechargeToLimit:
            within = fraction(percent - low, of: Double(config.effectiveLimit) - low)
        }
        return (Double(phase.index) + within) / Double(CalibrationPhase.allCases.count)
    }

    // MARK: Internals

    private mutating func updateHeatPause(snapshot: BatterySnapshot, config: EngineConfig, events: inout [EngineEvent]) {
        guard config.heatProtectionEnabled, let temperature = snapshot.temperatureC else {
            if state.isHeatPaused {
                state.isHeatPaused = false
                events.append(.heatPauseEnded)
            }
            return
        }
        if !state.isHeatPaused, temperature >= config.heatThresholdC {
            state.isHeatPaused = true
            events.append(.heatPauseBegan(temperature))
        } else if state.isHeatPaused, temperature <= config.heatThresholdC - config.heatHysteresisC {
            state.isHeatPaused = false
            events.append(.heatPauseEnded)
        }
    }

    private mutating func finishToHolding() {
        state.mode = .normal
        state.isHolding = true
        state.holdLimit = nil
        state.restStartedAt = nil
        state.calibrationStartPercent = nil
    }

    private mutating func advanceCalibration(to phase: CalibrationPhase, events: inout [EngineEvent]) {
        state.mode = .calibration(phase)
        events.append(.calibrationPhaseChanged(phase))
    }

    private func led(for activity: ChargeActivity, mode: LEDMode) -> LEDState {
        switch mode {
        case .system: .system
        case .off: .off
        case .status:
            switch activity {
            case .charging: .orange
            case .holding, .full, .resting: .green
            case .discharging, .onBattery: .off
            case .heatPaused: .blinkSlow
            case .unmanaged: .system
            }
        }
    }
}
