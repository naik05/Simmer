import Foundation
import SimmerCore
import UserNotifications

/// Turns engine events into user notifications.
@MainActor
final class EventNotifier {
    private let model: SimmerModel
    private let presenter = ForegroundPresenter()

    init(model: SimmerModel) {
        self.model = model
    }

    /// Lets notifications appear even while the popover or Settings window is frontmost.
    func activate() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    func handle(_ event: EngineEvent) {
        guard model.settings.notificationsEnabled else { return }
        let message = Self.message(for: event, settings: model.settings)
        Task { await NotificationPoster.post(title: message.title, body: message.body) }
    }

    static func message(for event: EngineEvent, settings: SimmerSettings) -> (title: String, body: String) {
        let limit = Format.percent(settings.engine.effectiveLimit)
        switch event {
        case .limitReached(let percent):
            return ("Charge limit reached", "The battery is at \(Format.percent(percent)). Your Mac now runs on the adapter.")
        case .topUpFinished:
            return ("Top Up finished", "The battery is full. Simmer returns to your \(limit) limit.")
        case .dischargeFinished:
            return ("Discharge finished", "The battery is down to \(limit). The adapter is connected again.")
        case .heatPauseBegan(let celsius):
            let temperature = Format.temperature(celsius: celsius, unit: settings.temperatureUnit)
            return ("Charging paused", "The battery is at \(temperature). Charging resumes once it has cooled down.")
        case .heatPauseEnded:
            return ("Charging resumed", "The battery has cooled down.")
        case .calibrationPhaseChanged(let phase):
            let title = "Calibration – phase \(phase.index + 1) of \(CalibrationPhase.allCases.count)"
            return (title, phase.title(config: settings.engine))
        case .calibrationFinished:
            return ("Calibration finished", "Simmer is back to holding your \(limit) limit.")
        }
    }
}

enum NotificationPoster {
    /// Asks for permission the first time it is needed. Returns whether posting is allowed.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    static func post(title: String, body: String) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
