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
            Button("Reset Size") { delegate.windows?.resetSize() }
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
        // Nothing to set up any more, so Settings only opens when macOS hasn't been asked for permission to drive
        // Spotify yet — the one thing a new install still needs from the user.
        if SpotifyAutomation.permission() == .notAsked { windows?.showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) { windows?.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
