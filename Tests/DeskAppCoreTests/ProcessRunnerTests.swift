import Foundation
import Testing
@testable import DeskAppCore

struct ProcessRunnerTests {
    @Test func returnsWhenParentExitsEvenIfChildKeepsPipeOpen() async throws {
        let start = Date()
        // The background `sleep` inherits stdout, so EOF would not arrive for 30 s.
        let output = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & echo hi"], timeout: 10)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "hi\n")
        #expect(output.status == 0)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func killsProcessThatIgnoresSigterm() async throws {
        let start = Date()
        await #expect(throws: ProcessRunner.RunError.self) {
            try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; while true; do sleep 1; done"], timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func passesStdin() async throws {
        let output = try await ProcessRunner.run("/bin/cat", [], stdin: Data("abc".utf8))
        #expect(output.stdout == Data("abc".utf8))
    }
}
