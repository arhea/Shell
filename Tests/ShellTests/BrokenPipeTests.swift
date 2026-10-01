import XCTest
@testable import Shell

/// Writing to a child that already exited must fail, not end the app:
/// SIGPIPE's default action quits silently, with no crash report.
final class BrokenPipeTests: XCTestCase {
    func testWritingToAnExitedChildThrowsInsteadOfKillingTheApp() throws {
        // The test host's app delegate installs the handler at launch; if it
        // didn't, this write would end the test run.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        p.waitUntilExit()
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data("hello\n".utf8)))
    }

    func testChildrenStillGetTheDefaultSIGPIPE() throws {
        // A caught signal resets on exec; an ignored one would be inherited
        // and change how `yes | head` behaves in every shell.
        AppDelegate.installBrokenPipeHandler()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "yes | head -n1 >/dev/null; echo ${PIPESTATUS[0]}"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let status = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(status, "141", "yes should be killed by SIGPIPE (128 + 13)")
    }
}
