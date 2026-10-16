import AppKit
import QuotaBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store: UsageStore

    var body: some View {
        TabView {
            GeneralSettings(settings: settings, store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettings(settings: settings)
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 440)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let store: UsageStore
    @State private var exportMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                Picker("Menu bar style", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        HStack {
                            Image(nsImage: MenuBarLabel.image(
                                for: [MenuBarWidget(caption: "CLAUDE", fraction: 0.36)], style: style
                            ))
                            Text(style.title)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Global shortcuts", isOn: $settings.globalShortcuts)
                Text("⌃⌥⌘C Claude · ⌃⌥⌘A Antigravity · ⌃⌥⌘S Sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Export data as CSV")
                    Spacer()
                    Button("Export…") { export() }
                }
                Text("Daily cost per model, sessions, and the 7-day limit history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            var files = ["limit-history.csv": CSVExporter.limitHistory(store.history)]
            if let cost = store.cost {
                files["daily-cost.csv"] = CSVExporter.dailyCost(cost)
                files["sessions.csv"] = CSVExporter.sessions(cost)
            }
            for (name, contents) in files {
                try contents.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            exportMessage = nil
            NSWorkspace.shared.activateFileViewerSelecting(files.keys.map { folder.appendingPathComponent($0) })
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

private struct ProviderSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                // Keep at least one item, otherwise the app becomes unreachable.
                Toggle("Show in menu bar", isOn: $settings.showClaude)
                    .disabled(isLastVisible(settings.showClaude))
                Toggle("Refresh sign-in token automatically", isOn: $settings.autoRefreshClaudeToken)
                Text("When the token expires, QuotaBar refreshes it the same way Claude Code does and writes the new token back to Claude Code's Keychain item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                ProviderLabel(brand: .claude)
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showAntigravity)
                    .disabled(isLastVisible(settings.showAntigravity))
                LabeledContent("agy CLI") {
                    if let path = AntigravityQuotaFetcher.locateCLI() {
                        Text(verbatim: path).textSelection(.enabled)
                    } else {
                        Text("Not found").foregroundStyle(.orange)
                    }
                }
            } header: {
                ProviderLabel(brand: .antigravity)
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showCodex)
                    .disabled(isLastVisible(settings.showCodex))
                Text("Plan limits are read from the latest Codex session logs (written only when signed in with a ChatGPT plan).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                detected(CodexReader.isInstalled)
            } header: {
                ProviderLabel(brand: .codex)
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showCommandCode)
                    .disabled(isLastVisible(settings.showCommandCode))
                detected(CommandCodeFetcher.isInstalled)
            } header: {
                ProviderLabel(brand: .commandCode)
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showCursor)
                    .disabled(isLastVisible(settings.showCursor))
                Text("Uses the sign-in of the Cursor app. Not verified against a live account yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                detected(CursorFetcher.isSignedIn, missing: "Not signed in")
            } header: {
                ProviderLabel(brand: .cursor)
            }
            Section {
                Text("OpenCode keeps no plan limits locally; its sessions appear in the Sessions window. Not verified against a live install yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                detected(OpenCodeReader.isInstalled)
            } header: {
                ProviderLabel(brand: .openCode)
            }
        }
        .formStyle(.grouped)
    }

    private func isLastVisible(_ isOn: Bool) -> Bool {
        isOn && settings.visibleItemCount == 1
    }

    private func detected(_ found: Bool, missing: String = "Not found") -> some View {
        LabeledContent("Status") {
            Text(found ? "Detected" : missing).foregroundStyle(found ? Color.secondary : Color.orange)
        }
    }
}

private struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: "QuotaBar").font(.title2.weight(.semibold))
            Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            Text("Plan limits, costs and sessions of your AI coding tools, right in the menu bar: Claude, Antigravity, Codex, Command Code, Cursor and OpenCode.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .padding(.horizontal, 40)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MenuBarStyle {
    var title: String {
        switch self {
        case .text: "Text"
        case .bar: "Bar"
        case .ring: "Ring"
        }
    }
}

/// Hosts SettingsView in a regular window; the app has no SwiftUI window scenes.
@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let store: UsageStore
    private var window: NSWindow?

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, store: store)))
            window.title = "QuotaBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
