import Foundation
import notify

/// macOS's own charge limit ("manual charge limit", enforced by powerd / PowerUIAgent).
///
/// On macOS 27 the firmware gates the SMC charging keys even for root, but the system
/// limit can still be steered: at the limit the Mac runs from the adapter and the battery
/// idles – a real bypass, which also holds during sleep. Above the limit macOS drains the
/// battery down to it.
public protocol NativeLimitControlling: Sendable {
    /// Sets the system charge limit to `percent` (1…99).
    func setLimit(_ percent: Int) throws
    /// Turns the system limit off so the battery charges to 100 %.
    func disable() throws
    /// Puts back whatever was configured before Simmer first touched the setting.
    /// A no-op when Simmer never changed it.
    func restoreOriginal() throws
}

public enum NativeLimitError: Error, Equatable, CustomStringConvertible {
    case notRoot
    case outOfRange(Int)
    case preferencesNotSaved
    case notificationFailed

    public var description: String {
        switch self {
        case .notRoot: "The macOS charge limit can only be changed by the root helper"
        case .outOfRange(let value): "The macOS charge limit must be 1…99 %, got \(value)"
        case .preferencesNotSaved: "Could not save the macOS charge limit"
        case .notificationFailed: "Could not notify PowerUIAgent of the new charge limit"
        }
    }
}

/// Where the limit's settings live. Abstracted so the logic is testable without root.
public protocol NativeLimitStore: Sendable {
    func value(for key: String) -> Int?
    func set(_ value: Int?, for key: String)
    /// Persists pending changes and tells the system agent to reload them.
    func commit() throws
}

/// Steers the system charge limit through PowerUIAgent's preferences.
///
/// The agent runs as root and reads `MCLFeatureState` / `mclLimitValue` from root's
/// `com.apple.smartcharging.topoffprotection` domain when it receives the
/// `com.apple.smartcharging.defaultschanged` notification. The System Settings slider
/// only offers 80…100 %; the preference accepts any target. (Mechanism as used by the
/// open-source tool `batt`, verified against the macOS 27 preference schema only.)
public final class NativeChargeLimit: NativeLimitControlling, @unchecked Sendable {
    public static let featureKey = "MCLFeatureState"
    public static let limitKey = "mclLimitValue"

    /// Only the OS generation whose preference schema is known.
    public static var isSupportedOnThisSystem: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
            && FileManager.default.fileExists(atPath: "/usr/libexec/PowerUIAgent")
    }

    private struct Original: Codable, Equatable {
        var feature: Int?
        var limit: Int?
    }

    private let store: any NativeLimitStore
    private let backupURL: URL
    private let lock = NSLock()
    private var lastWritten: (feature: Int, limit: Int?)?

    public init(
        store: any NativeLimitStore = PowerUIPreferences(),
        backupURL: URL = URL(fileURLWithPath: "/Library/Application Support/Simmer/native-limit-original.json")
    ) {
        self.store = store
        self.backupURL = backupURL
    }

    public func setLimit(_ percent: Int) throws {
        guard (1...99).contains(percent) else { throw NativeLimitError.outOfRange(percent) }
        try lock.withLock {
            if let lastWritten, lastWritten.feature == 1, lastWritten.limit == percent { return }
            backUpOriginalIfNeeded()
            store.set(1, for: Self.featureKey)
            store.set(percent, for: Self.limitKey)
            try store.commit()
            lastWritten = (1, percent)
        }
    }

    public func disable() throws {
        try lock.withLock {
            if let lastWritten, lastWritten.feature == 0 { return }
            backUpOriginalIfNeeded()
            store.set(0, for: Self.featureKey)
            try store.commit()
            lastWritten = (0, nil)
        }
    }

    public func restoreOriginal() throws {
        try lock.withLock {
            lastWritten = nil
            guard let data = try? Data(contentsOf: backupURL),
                  let original = try? JSONDecoder().decode(Original.self, from: data)
            else { return }
            store.set(original.feature, for: Self.featureKey)
            store.set(original.limit, for: Self.limitKey)
            try store.commit()
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    /// Remembers the user's own setting once, before the first change, so a crash or
    /// restart of the helper can still put it back.
    private func backUpOriginalIfNeeded() {
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        let original = Original(feature: store.value(for: Self.featureKey), limit: store.value(for: Self.limitKey))
        guard let data = try? JSONEncoder().encode(original) else { return }
        try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: backupURL, options: .atomic)
    }
}

/// The real preference domain of the root PowerUIAgent. Only meaningful when running as root.
public struct PowerUIPreferences: NativeLimitStore {
    private static var domain: CFString { "com.apple.smartcharging.topoffprotection" as CFString }
    private static let notification = "com.apple.smartcharging.defaultschanged"

    public init() {}

    public func value(for key: String) -> Int? {
        CFPreferencesSynchronize(Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = CFPreferencesCopyValue(key as CFString, Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.intValue
    }

    public func set(_ value: Int?, for key: String) {
        CFPreferencesSetValue(
            key as CFString, value.map { NSNumber(value: $0) }, Self.domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
    }

    public func commit() throws {
        guard geteuid() == 0 else { throw NativeLimitError.notRoot }
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NativeLimitError.preferencesNotSaved
        }
        guard notify_post(Self.notification) == UInt32(NOTIFY_STATUS_OK) else {
            throw NativeLimitError.notificationFailed
        }
    }
}
