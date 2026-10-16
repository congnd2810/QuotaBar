import DeskAppCore
import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let refreshChoices = [1, 2, 5, 10, 15, 30]

    private enum Key {
        static let refreshMinutes = "refreshMinutes"
        static let showClaude = "showClaude"
        static let showAntigravity = "showAntigravity"
        static let showCodex = "showCodex"
        static let showCommandCode = "showCommandCode"
        static let showCursor = "showCursor"
        static let autoRefreshClaudeToken = "autoRefreshClaudeToken"
        static let menuBarStyle = "menuBarStyle"
        static let globalShortcuts = "globalShortcuts"
    }

    private let defaults = UserDefaults.standard

    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refreshMinutes) }
    }
    var showClaude: Bool {
        didSet { defaults.set(showClaude, forKey: Key.showClaude) }
    }
    var showAntigravity: Bool {
        didSet { defaults.set(showAntigravity, forKey: Key.showAntigravity) }
    }
    var showCodex: Bool {
        didSet { defaults.set(showCodex, forKey: Key.showCodex) }
    }
    var showCommandCode: Bool {
        didSet { defaults.set(showCommandCode, forKey: Key.showCommandCode) }
    }
    var showCursor: Bool {
        didSet { defaults.set(showCursor, forKey: Key.showCursor) }
    }

    /// Number of menu bar items currently shown; the last one cannot be hidden.
    var visibleItemCount: Int {
        [showClaude, showAntigravity, showCodex, showCommandCode, showCursor].filter { $0 }.count
    }
    var autoRefreshClaudeToken: Bool {
        didSet { defaults.set(autoRefreshClaudeToken, forKey: Key.autoRefreshClaudeToken) }
    }
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) }
    }
    var globalShortcuts: Bool {
        didSet { defaults.set(globalShortcuts, forKey: Key.globalShortcuts) }
    }

    private(set) var launchAtLoginError: String?

    init() {
        defaults.register(defaults: [
            Key.refreshMinutes: 5,
            Key.showClaude: true,
            Key.showAntigravity: true,
            // Newer providers start visible only when found on this Mac.
            Key.showCodex: CodexReader.isInstalled,
            Key.showCommandCode: CommandCodeFetcher.isInstalled,
            Key.showCursor: CursorFetcher.isSignedIn,
            Key.autoRefreshClaudeToken: true,
            Key.globalShortcuts: true,
        ])
        refreshMinutes = defaults.integer(forKey: Key.refreshMinutes)
        showClaude = defaults.bool(forKey: Key.showClaude)
        showAntigravity = defaults.bool(forKey: Key.showAntigravity)
        showCodex = defaults.bool(forKey: Key.showCodex)
        showCommandCode = defaults.bool(forKey: Key.showCommandCode)
        showCursor = defaults.bool(forKey: Key.showCursor)
        autoRefreshClaudeToken = defaults.bool(forKey: Key.autoRefreshClaudeToken)
        menuBarStyle = defaults.string(forKey: Key.menuBarStyle).flatMap(MenuBarStyle.init(rawValue:)) ?? .text
        globalShortcuts = defaults.bool(forKey: Key.globalShortcuts)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }
}
