import AppKit
import SwiftUI

/// Provider identity for the UI: display name and logo. Logos are taken at runtime from the
/// provider's own app or extension installed on this Mac (nothing brand-related is bundled);
/// when none is found an SF Symbol stands in.
enum ProviderBrand: CaseIterable {
    case claude, antigravity, codex, commandCode, cursor, openCode

    var name: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        case .commandCode: "Command Code"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .claude: "sparkle"
        case .antigravity: "arrow.up.circle"
        case .codex: "circle.hexagongrid"
        case .commandCode: "command"
        case .cursor: "cursorarrow"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        }
    }

    @MainActor private static var cache: [ProviderBrand: NSImage?] = [:]

    @MainActor var logo: NSImage? {
        if let cached = Self.cache[self] { return cached }
        let image = loadLogo()
        Self.cache[self] = image
        return image
    }

    private func loadLogo() -> NSImage? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        func appIcon(_ bundleID: String, _ path: String) -> NSImage? {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
                ?? (fm.fileExists(atPath: path) ? path : nil)
            return url.map { NSWorkspace.shared.icon(forFile: $0) }
        }
        switch self {
        case .claude:
            return appIcon("com.anthropic.claudefordesktop", "/Applications/Claude.app")
        case .antigravity:
            return appIcon("com.google.antigravity", "/Applications/Antigravity.app")
        case .cursor:
            return appIcon("com.todesktop.230313mzl4w4u92", "/Applications/Cursor.app")
        case .codex:
            // The OpenAI extension for VS Code-based editors ships the Codex "blossom" mark.
            for editor in [".vscode", ".cursor", ".antigravity", ".windsurf"] {
                let dir = "\(home)/\(editor)/extensions"
                let extensions = (try? fm.contentsOfDirectory(atPath: dir))?
                    .filter { $0.hasPrefix("openai.chatgpt-") }.sorted().reversed() ?? []
                for ext in extensions {
                    if let image = NSImage(contentsOfFile: "\(dir)/\(ext)/resources/blossom.dark.png") { return image }
                }
            }
            return nil
        case .commandCode:
            return Self.commandCodeIcon()
        case .openCode:
            return nil
        }
    }

    /// Command Code's npm package bundles its VS Code extension; the icon is extracted from that
    /// `.vsix` (a zip) once and cached.
    private static func commandCodeIcon() -> NSImage? {
        let fm = FileManager.default
        let cached = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskApp/icons/commandcode.png")
        if let image = NSImage(contentsOf: cached) { return image }

        let home = fm.homeDirectoryForCurrentUser.path
        var packageDirs = ["/opt/homebrew/lib/node_modules/command-code", "/usr/local/lib/node_modules/command-code"]
        let nvm = "\(home)/.nvm/versions/node"
        for version in (try? fm.contentsOfDirectory(atPath: nvm)) ?? [] {
            packageDirs.append("\(nvm)/\(version)/lib/node_modules/command-code")
        }
        guard let vsix = packageDirs.lazy.map({ "\($0)/vsix/commandcode-vscode.vsix" }).first(where: fm.fileExists(atPath:))
        else { return nil }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", vsix, "extension/icon.png"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = FileHandle.nullDevice
        guard (try? unzip.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, let image = NSImage(data: data) else { return nil }
        try? fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cached)
        return image
    }
}

/// Logo + name, used as a section/popover header.
struct ProviderLabel: View {
    let brand: ProviderBrand
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            ProviderLogo(brand: brand, size: size)
            Text(brand.name)
        }
    }
}

struct ProviderLogo: View {
    let brand: ProviderBrand
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let logo = brand.logo {
                Image(nsImage: logo).resizable().interpolation(.high)
            } else {
                Image(systemName: brand.fallbackSymbol).resizable().scaledToFit().padding(size * 0.12)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
