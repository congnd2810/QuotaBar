import Foundation

/// Shell commands that reopen a coding-agent session. Both CLIs resolve sessions relative to the
/// working directory, so the command starts in the session's project folder.
public enum ResumeCommand {
    /// `cd <project> && claude --resume <id>`
    public static func claude(sessionID: String, projectPath: String) -> String {
        "cd \(shellQuote(projectPath)) && claude --resume \(shellQuote(sessionID))"
    }

    /// `cd <project> && agy --conversation <id>`
    public static func agy(conversationID: String, projectPath: String) -> String {
        "cd \(shellQuote(projectPath)) && agy --conversation \(shellQuote(conversationID))"
    }

    /// `cd <project> && codex resume <id>`
    public static func codex(sessionID: String, projectPath: String) -> String {
        "cd \(shellQuote(projectPath)) && codex resume \(shellQuote(sessionID))"
    }

    /// `cd <project> && commandcode --resume <id>`
    public static func commandCode(sessionID: String, projectPath: String) -> String {
        "cd \(shellQuote(projectPath)) && commandcode --resume \(shellQuote(sessionID))"
    }

    /// `cd <project> && opencode --session <id>`
    public static func openCode(sessionID: String, projectPath: String) -> String {
        "cd \(shellQuote(projectPath)) && opencode --session \(shellQuote(sessionID))"
    }

    /// Contents of a `.command` file Terminal can open. Runs in an interactive login shell so the
    /// user's PATH (where `claude`/`agy` live) is set up as in a normal terminal tab.
    public static func script(_ command: String) -> String {
        "#!/bin/zsh -il\n\(command)\n"
    }

    /// Single-quotes a string for POSIX shells: `it's` -> `'it'\''s'`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
