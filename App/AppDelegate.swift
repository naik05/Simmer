import AppKit
import SimmerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifier = EventNotifier(model: .shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = SimmerModel.shared
        notifier.activate()
        model.onEvent = { [notifier] event in notifier.handle(event) }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SimmerModel.shared.prepareForTermination()
    }
}
