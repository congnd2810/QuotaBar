# DeskApp

A lightweight, native macOS menu bar app inspired by [Stats](https://github.com/exelban/stats) for tracking AI coding assistant rate limits, quotas, and API-equivalent costs in real time.

## Features

- **Claude Plan Limits (Pro / Max)**: Tracks percentage used across 5-hour and 7-day rolling windows (including separate Opus and Sonnet limits when applicable) along with exact reset times.
- **Antigravity (`agy`) Quotas**: Tracks 5-hour and weekly rate limits across both quota pools side by side in the menu bar:
  - `AG GEMINI` — Google Gemini models (Gemini Pro, Gemini Flash)
  - `AG CLAUDE·GPT` — Third-party models (Claude Opus, Claude Sonnet, GPT-OSS)
- **Command Code**: Monthly credits, 5-hour and weekly windows, plan name and renewal/expiry date, from the same `api.commandcode.ai` endpoints its `/usage` command calls (API key from `~/.commandcode/auth.json`).
- **Codex**: 5-hour and weekly limits from the latest `rate_limits` snapshot in `~/.codex/sessions` logs (Codex only writes these when signed in with a ChatGPT plan). Windows whose reset time has passed show 0%.
- **Cursor** *(not yet verified against a live account)*: Plan usage via `cursor.com/api/usage-summary`, authenticated with the Cursor app's own sign-in token (`state.vscdb`, read-only).
- **OpenCode** *(not yet verified against a live install)*: No plan limits exist locally; its sessions and estimated costs come from `~/.local/share/opencode/opencode.db`.
- Codex, Command Code and Cursor menu bar items are shown by default only when the tool is detected on the Mac; toggle each in Settings → Providers.
- **Claude Code API-Equivalent Cost**: Scans local Claude Code JSONL logs to calculate API-equivalent spend (Today / 7 days / 30 days) with a 14-day stacked bar chart broken down by model.
- **Rolling 7-Day Limit History**: Records limit usage on every refresh to `~/Library/Application Support/DeskApp/limit-history.json` (retaining today + the previous 6 calendar days) and plots step-line charts in each provider's popover.
- **Sessions Browser (`⌃⌥⌘S`)**: Lists top-level sessions from the last 30 days across **Claude Code** (with titles and subagent-inclusive costs), **Antigravity CLI (`agy`)** (with step counts from `conversation_summaries.db` opened in `immutable=1` read-only mode), **Codex** (thread names from `session_index.jsonl`), **Command Code** (titles and recorded costs) and **OpenCode**. Filter by project or tool, double-click to resume in Terminal (`claude --resume` / `agy --conversation` / `codex resume` / `commandcode --resume` / `opencode --session`), or copy the resume command for iTerm and other terminals.
- **Menu Bar Styles**: Choose between **Text**, **Bar**, or **Ring** gauges. Each provider lives in its own menu bar item and can be toggled independently (hidden providers are not polled).
- **Automatic OAuth Token Refresh**: Optionally refreshes expired Claude Code OAuth tokens using the same endpoint as Claude Code and writes the rotated token pair back to the Keychain so your CLI session stays signed in.
- **CSV Export**: Export `daily-cost.csv`, `sessions.csv`, and `limit-history.csv` from Settings.

## Requirements

- **macOS 14.0 (Sonoma)** or later
- **Xcode 16+** / **Swift 6.0+** (for building from source)
- **Claude Code (`claude`)**: Signed in so the `Claude Code-credentials` item exists in your macOS Keychain
- **Antigravity CLI (`agy`)** *(optional)*: Installed at `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, or `/usr/local/bin/agy`

## Quick Start

```sh
# Run directly during development
swift run DeskApp

# Run the unit test suite
swift test

# Build and package the release app bundle (build/DeskApp.app)
./scripts/build-app.sh
open build/DeskApp.app
```

To open the project in Xcode:

```sh
open Package.swift
```

To regenerate the app icon (`Resources/AppIcon.icns`):

```sh
swift scripts/generate-icon.swift
```

## Keyboard Shortcuts

Global shortcuts can be toggled in **Settings → General**:

| Shortcut | Action |
|---|---|
| `⌃⌥⌘C` | Toggle Claude popover |
| `⌃⌥⌘A` | Toggle Antigravity popover |
| `⌃⌥⌘S` | Open Sessions window |

## How It Works & Data Sources

All data is read locally or fetched directly using your existing CLI credentials—no third-party servers or telemetry are involved.

| Data | Source | Notes |
|---|---|---|
| **Claude Plan Limits** | `GET https://api.anthropic.com/api/oauth/usage` using the OAuth token from Keychain (`Claude Code-credentials`) | Undocumented internal endpoint used by `claude /usage`; subject to change |
| **Claude Token Refresh** | `POST https://platform.claude.com/v1/oauth/token` | Refresh tokens rotate on use; the new token pair is written back to Keychain via `/usr/bin/security` so `claude` is never logged out |
| **Antigravity Quotas** | `agy -p /usage --output-format json` | Local slash command; consumes zero quota |
| **Claude Code Cost & Sessions** | `~/.claude/projects/**/*.jsonl` (plus `$CLAUDE_CONFIG_DIR` and `~/.config/claude`) | Incremental tail reader over the last 30 days; cached in `~/Library/Application Support/DeskApp/claude-code-usage.json` |
| **Antigravity Sessions** | `~/.gemini/antigravity-cli/conversation_summaries.db` | Opened with `mode=ro&immutable=1` so DeskApp never creates lock or journal files next to `agy`'s database |

### Notes on Cost Calculation

- **API-Equivalent Estimate**: Costs shown for Claude Code are calculated from token counts using Anthropic's public API rate card (`ModelPricing.swift`), **not** your subscription billing amount.
- **Deduplication**: Streaming JSONL entries are deduplicated by `message.id` + `requestId`, keeping the final entry for each message.
- **Unpriced Models**: Any model not yet listed in `ModelPricing.swift` still has its tokens scanned and is surfaced under *"No price for: …"* in the popover.

## Project Structure

```text
Sources/
  DeskAppCore/                          # Core library (no UI dependencies, unit-tested)
    Models.swift                        # Shared limit/window models and ISO-8601 parser
    ProcessRunner.swift                 # Async subprocess runner with timeout & SIGTERM/SIGKILL handling
    LimitHistory.swift                  # Rolling 7-day limit usage store
    CSVExporter.swift                   # CSV serializer for costs, sessions, and limit history
    Claude/
      ClaudeCredentialStore.swift       # Reads/writes Claude Code Keychain credentials
      ClaudeLimitsFetcher.swift         # Fetches 5h/7d plan limits and refreshes OAuth tokens
      ClaudeCodeUsageScanner.swift      # Incremental JSONL log scanner and session aggregator
      ModelPricing.swift                # Anthropic API token pricing table
      ResumeCommand.swift               # Shell-safe resume command builder
    Antigravity/
      AntigravityQuotaFetcher.swift     # Parses `agy -p /usage --output-format json`
      AgySessionReader.swift            # Read-only SQLite reader for agy conversation summaries
  DeskApp/                              # macOS menu bar executable (AppKit + SwiftUI + Swift Charts)
    DeskApp.swift                       # App entry point, status items, and global hotkeys
    StatusItemController.swift          # NSStatusItem + transient NSPopover management
    MenuBarLabel.swift                  # Template image renderer for text, bar, and ring widgets
    UsageStore.swift                    # Observable state store and polling loop
    Views.swift                         # Claude & Antigravity popovers and Swift Charts views
    SessionsView.swift                  # Project & session browser window
    SettingsView.swift                  # Settings & About window
    AppSettings.swift                   # UserDefaults-backed preferences & Launch at Login
    HotKeyCenter.swift                  # Carbon global hotkey registration
Tests/
  DeskAppCoreTests/                     # Swift Testing unit tests
scripts/
  build-app.sh                          # Builds release binary and packages build/DeskApp.app
  generate-icon.swift                   # Renders Resources/AppIcon.icns via SwiftUI
```

## License

Released under the [MIT License](LICENSE).
