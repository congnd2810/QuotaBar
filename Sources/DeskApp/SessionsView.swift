import AppKit
import DeskAppCore
import SwiftUI

/// A session of one of the supported coding agents, as shown in the Sessions window.
struct SessionRow: Identifiable {
    enum Tool: String, CaseIterable, Identifiable {
        case claudeCode, agy, codex, commandCode, openCode
        var id: String { rawValue }
        var name: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .agy: "agy"
            case .codex: "Codex"
            case .commandCode: "Command Code"
            case .openCode: "OpenCode"
            }
        }
        var color: Color {
            switch self {
            case .claudeCode: .orange
            case .agy: .blue
            case .codex: .green
            case .commandCode: .purple
            case .openCode: .gray
            }
        }
    }

    let id: String
    let tool: Tool
    let title: String?
    let projectPath: String
    let lastActivity: Date
    /// nil when the tool reports no per-session cost (agy, Codex).
    let cost: Double?
    /// Main model, or step/token count when no model is known.
    let detail: String
    let resumeCommand: String

    var projectName: String { (projectPath as NSString).lastPathComponent }

    init(_ session: SessionSummary) {
        id = session.id
        tool = .claudeCode
        title = session.title
        projectPath = session.projectPath
        lastActivity = session.lastActivity
        cost = session.cost
        detail = session.models.first?.replacingOccurrences(of: "claude-", with: "") ?? "–"
        resumeCommand = ResumeCommand.claude(sessionID: session.id, projectPath: session.projectPath)
    }

    init(_ session: AgySession) {
        id = session.id
        tool = .agy
        title = session.title
        projectPath = session.projectPath
        lastActivity = session.lastActivity
        cost = nil
        detail = "\(session.stepCount) steps"
        resumeCommand = ResumeCommand.agy(conversationID: session.id, projectPath: session.projectPath)
    }

    init(_ session: CodexSession) {
        id = session.id
        tool = .codex
        title = session.title
        projectPath = session.projectPath
        lastActivity = session.lastActivity
        cost = nil
        detail = session.model ?? "\(session.totalTokens.formatted(.number.notation(.compactName))) tokens"
        resumeCommand = ResumeCommand.codex(sessionID: session.id, projectPath: session.projectPath)
    }

    init(_ session: CommandCodeSession) {
        id = session.id
        tool = .commandCode
        title = session.title
        projectPath = session.projectPath
        lastActivity = session.lastActivity
        cost = session.cost
        detail = session.model.map { ($0 as NSString).lastPathComponent } ?? "–"
        resumeCommand = ResumeCommand.commandCode(sessionID: session.id, projectPath: session.projectPath)
    }

    init(_ session: OpenCodeSession) {
        id = session.id
        tool = .openCode
        title = session.title
        projectPath = session.projectPath
        lastActivity = session.lastActivity
        cost = session.cost
        detail = session.model ?? "–"
        resumeCommand = ResumeCommand.openCode(sessionID: session.id, projectPath: session.projectPath)
    }
}

/// Sessions of the last 30 days from all supported coding agents, grouped by project, with actions to resume them.
struct SessionsView: View {
    let store: UsageStore

    @State private var selectedProject: String?
    @State private var selectedRows = Set<SessionRow.ID>()
    @State private var toolFilter: SessionRow.Tool?
    @State private var searchText = ""
    @State private var launchError: String?

    private static let allProjects = "\u{0}all"

    private var rows: [SessionRow] {
        let claude = (store.cost?.sessions ?? []).map(SessionRow.init)
        let agy = store.agySessions.map(SessionRow.init)
        let codex = store.codexSessions.map(SessionRow.init)
        let commandCode = store.commandCodeSessions.map(SessionRow.init)
        let openCode = store.openCodeSessions.map(SessionRow.init)
        return (claude + agy + codex + commandCode + openCode)
            .filter { toolFilter == nil || $0.tool == toolFilter }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// `cost` is nil when no session in the project reports one (agy only).
    private var projects: [(path: String, name: String, cost: Double?, count: Int)] {
        Dictionary(grouping: rows, by: \.projectPath)
            .map { path, rows in
                (path, (path as NSString).lastPathComponent, Self.totalCost(rows), rows.count)
            }
            .sorted { ($0.cost ?? -1, $0.count) > ($1.cost ?? -1, $1.count) }
    }

    private static func totalCost(_ rows: [SessionRow]) -> Double? {
        let costs = rows.compactMap(\.cost)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private var visibleRows: [SessionRow] {
        rows.filter { row in
            (selectedProject == nil || selectedProject == Self.allProjects || row.projectPath == selectedProject)
                && (searchText.isEmpty
                    || (row.title ?? "").localizedCaseInsensitiveContains(searchText)
                    || row.id.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProject) {
                ProjectRow(name: "All projects", detail: nil,
                           cost: Self.totalCost(rows), count: rows.count)
                    .tag(Self.allProjects)
                Section("Projects") {
                    ForEach(projects, id: \.path) { project in
                        ProjectRow(name: project.name, detail: project.path, cost: project.cost, count: project.count)
                            .tag(project.path)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            sessionTable
        }
        .toolbar {
            Picker("Tool", selection: $toolFilter) {
                Text("All").tag(SessionRow.Tool?.none)
                ForEach(SessionRow.Tool.allCases) { tool in
                    Text(verbatim: tool.name).tag(SessionRow.Tool?.some(tool))
                }
            }
            .pickerStyle(.menu)
        }
        .searchable(text: $searchText, prompt: Text("Search sessions"))
        .navigationTitle("Sessions")
        .frame(minWidth: 860, minHeight: 460)
        .onAppear { if selectedProject == nil { selectedProject = Self.allProjects } }
        .alert("Could not open the session", isPresented: .init(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    @ViewBuilder
    private var sessionTable: some View {
        if store.cost == nil && store.agySessions.isEmpty {
            ProgressView("Scanning Claude Code logs…")
        } else {
            Table(visibleRows, selection: $selectedRows) {
                TableColumn("Session") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title ?? "Untitled session")
                            .lineLimit(1)
                        Text(verbatim: "\(row.projectName) · \(row.id.prefix(8))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(row.title ?? row.id)
                }
                .width(min: 200, ideal: 260)
                TableColumn("Tool") { row in
                    Text(verbatim: row.tool.name)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(row.tool.color.opacity(0.2), in: Capsule())
                }
                .width(min: 76, ideal: 84)
                TableColumn("Last active") { row in
                    Text(row.lastActivity, format: .relative(presentation: .named))
                }
                .width(min: 84, ideal: 92)
                TableColumn("Model / steps") { row in
                    Text(verbatim: row.detail)
                }
                .width(min: 70, ideal: 84)
                TableColumn("Cost") { row in
                    if let cost = row.cost {
                        Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                            .monospacedDigit()
                    } else {
                        Text(verbatim: "—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 86, ideal: 96)
                TableColumn("") { row in
                    Button("Resume") { resume(row) }
                }
                .width(70)
            }
            .contextMenu(forSelectionType: SessionRow.ID.self) { ids in
                if let row = row(for: ids) {
                    Button("Resume in Terminal") { resume(row) }
                    Button("Copy resume command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.resumeCommand, forType: .string)
                    }
                    Button("Show project in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.projectPath)])
                    }
                }
            } primaryAction: { ids in
                // Double-click resumes.
                if let row = row(for: ids) { resume(row) }
            }
        }
    }

    private func row(for ids: Set<SessionRow.ID>) -> SessionRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    private func resume(_ row: SessionRow) {
        do {
            try SessionLauncher.resume(row)
        } catch {
            launchError = error.localizedDescription
        }
    }
}

private struct ProjectRow: View {
    let name: String
    let detail: String?
    let cost: Double?
    let count: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).lineLimit(1)
                if let detail {
                    Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let cost {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .monospacedDigit()
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
                Text("\(count) sessions").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Opens the resume command in Terminal through a `.command` file, which Terminal runs on open —
/// no Automation permission needed. (iTerm does not run `.command` files; other terminals can use
/// "Copy resume command".)
enum SessionLauncher {
    enum LaunchError: LocalizedError {
        case projectMissing(String)

        var errorDescription: String? {
            switch self {
            case .projectMissing(let path): "The project folder no longer exists: \(path)"
            }
        }
    }

    @MainActor
    static func resume(_ row: SessionRow) throws {
        guard FileManager.default.fileExists(atPath: row.projectPath) else {
            throw LaunchError.projectMissing(row.projectPath)
        }
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskApp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("resume-\(row.id).command")
        try ResumeCommand.script(row.resumeCommand).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

@MainActor
final class SessionsWindowController {
    private let store: UsageStore
    private var window: NSWindow?

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SessionsView(store: store)))
            window.title = "Sessions"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1000, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SessionsWindow")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
