import SwiftUI
import AppKit

@main
struct SquiddApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Squidd", image: "Squidd-SI") {
            Button("Show / Hide Player") { delegate.windows?.toggleCard() }
            Button("Settings…") { delegate.windows?.showSettings() }
                .keyboardShortcut(",")
            Button("Reset Position") { delegate.windows?.resetPosition() }
            Divider()
            Button("Quit Squidd") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: WindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows = WindowCoordinator(store: AppStore())
        windows?.show()
        Task {
            var permissions: [Automation.Permission?] = []
            for app in MusicApp.allCases { permissions.append(await Automation.permission(for: app)) }
            if !permissions.contains(.granted) && permissions.contains(.notAsked) { windows?.showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { windows?.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
