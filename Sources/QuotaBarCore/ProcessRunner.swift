import Foundation

public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
    }

    public enum RunError: LocalizedError {
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut(let command): "\(command) took too long and was stopped."
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var timedOut = false

        func append(_ data: Data, toStdout: Bool) {
            lock.withLock {
                if toStdout { stdout.append(data) } else { stderr.append(data) }
            }
        }

        func markTimedOut() { lock.withLock { timedOut = true } }

        func snapshot() -> (stdout: Data, stderr: Data, timedOut: Bool) {
            lock.withLock { (stdout, stderr, timedOut) }
        }
    }

    /// Runs an executable and collects its output. Sends SIGTERM after `timeout` seconds and SIGKILL
    /// if it is still alive a few seconds later.
    ///
    /// Completion is driven by process exit, not by EOF on the pipes: CLIs like `agy` spawn helpers
    /// (MCP servers) that inherit stdout and can keep the pipe open after the parent is gone.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        var environment = ProcessInfo.processInfo.environment
        // GUI apps start with a minimal PATH; CLIs may spawn helpers that need the usual dirs.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let collector = Collector()
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        outPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, toStdout: true) }
        errPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, toStdout: false) }

        let name = URL(fileURLWithPath: executable).lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                // Give the readability handlers a moment to deliver what is already buffered.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let result = collector.snapshot()
                    if result.timedOut {
                        continuation.resume(throwing: RunError.timedOut(name))
                    } else {
                        continuation.resume(returning: Output(status: process.terminationStatus, stdout: result.stdout, stderr: result.stderr))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            if let stdin {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }
}
