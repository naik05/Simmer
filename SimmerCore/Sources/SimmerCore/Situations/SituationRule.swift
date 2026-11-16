import Foundation

/// What Simmer can tell about where the Mac is being used, without asking for any
/// permission: the power adapter and whether an external display is attached.
public struct Situation: Sendable, Equatable {
    /// Rated power of the attached adapter in watts, `nil` when on battery.
    public var adapterWatts: Int?
    public var externalDisplayCount: Int

    public init(adapterWatts: Int? = nil, externalDisplayCount: Int = 0) {
        self.adapterWatts = adapterWatts
        self.externalDisplayCount = externalDisplayCount
    }
}

public enum SituationCondition: Codable, Sendable, Equatable, Hashable {
    /// A power adapter with exactly this rated wattage is attached.
    case adapter(watts: Int)
    /// At least one external display is attached (at the desk).
    case externalDisplay
    /// Plugged in with no external display (charging on the go).
    case pluggedInWithoutDisplay

    public func matches(_ situation: Situation) -> Bool {
        switch self {
        case .adapter(let watts): situation.adapterWatts == watts
        case .externalDisplay: situation.externalDisplayCount > 0
        case .pluggedInWithoutDisplay: situation.adapterWatts != nil && situation.externalDisplayCount == 0
        }
    }
}

/// "In this situation, use this charge limit instead of the normal one."
public struct SituationRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var isEnabled: Bool
    public var condition: SituationCondition
    public var limit: Int

    public init(id: UUID = UUID(), isEnabled: Bool = true, condition: SituationCondition, limit: Int = 80) {
        self.id = id
        self.isEnabled = isEnabled
        self.condition = condition
        self.limit = limit
    }

    /// The limit clamped to the supported range.
    public var effectiveLimit: Int {
        min(max(limit, EngineConfig.limitRange.lowerBound), EngineConfig.limitRange.upperBound)
    }
}

extension Array where Element == SituationRule {
    /// The first enabled rule that matches; order is priority.
    public func active(in situation: Situation) -> SituationRule? {
        first { $0.isEnabled && $0.condition.matches(situation) }
    }
}
