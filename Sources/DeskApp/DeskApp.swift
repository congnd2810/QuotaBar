import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct DeskApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    }

    var body: some Scene {
        // The UI lives in AppKit status items and windows; SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var store = UsageStore(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store)
    private lazy var sessionsWindow = SessionsWindowController(store: store)
    private var claudeItem: StatusItemController?
    private var antigravityItem: StatusItemController?
    /// Codex, Command Code and Cursor.
    private var otherItems: [StatusItemController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, even when launched via `swift run` without the bundle's LSUIElement.
        NSApp.setActivationPolicy(.accessory)

        let store = store, settings = settings
        let openSettings: () -> Void = { [weak self] in self?.settingsWindow.show() }
        let openSessions: () -> Void = { [weak self] in self?.sessionsWindow.show() }
        // Created right-to-left: the first item ends up rightmost in the menu bar.
        otherItems = [
            StatusItemController(
                label: { MenuBarLabel.image(for: [store.cursorWidget], style: settings.menuBarStyle) },
                isVisible: { settings.showCursor }
            ) {
                ProviderPopover(provider: .cursor, store: store, openSettings: openSettings, openSessions: openSessions)
            },
            StatusItemController(
                label: { MenuBarLabel.image(for: [store.commandCodeWidget], style: settings.menuBarStyle) },
                isVisible: { settings.showCommandCode }
            ) {
                ProviderPopover(provider: .commandCode, store: store, openSettings: openSettings, openSessions: openSessions)
            },
            StatusItemController(
                label: { MenuBarLabel.image(for: [store.codexWidget], style: settings.menuBarStyle) },
                isVisible: { settings.showCodex }
            ) {
                ProviderPopover(provider: .codex, store: store, openSettings: openSettings, openSessions: openSessions)
            },
        ]
        antigravityItem = StatusItemController(
            label: { MenuBarLabel.image(for: store.antigravityWidgets, style: settings.menuBarStyle) },
            isVisible: { settings.showAntigravity }
        ) {
            AntigravityPopover(store: store, openSettings: openSettings)
        }
        claudeItem = StatusItemController(
            label: { MenuBarLabel.image(for: [store.claudeWidget], style: settings.menuBarStyle) },
            isVisible: { settings.showClaude }
        ) {
            ClaudePopover(store: store, openSettings: openSettings, openSessions: openSessions)
        }
        updateShortcuts()
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    /// ⌃⌥⌘C Claude · ⌃⌥⌘A Antigravity · ⌃⌥⌘S Sessions. Re-registered when the setting changes.
    private func updateShortcuts() {
        HotKeyCenter.shared.unregisterAll()
        let enabled = withObservationTracking {
            settings.globalShortcuts
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateShortcuts() }
        }
        guard enabled else { return }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_C) { [weak self] in self?.claudeItem?.togglePopover() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_A) { [weak self] in self?.antigravityItem?.togglePopover() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_S) { [weak self] in self?.sessionsWindow.show() }
    }
}
