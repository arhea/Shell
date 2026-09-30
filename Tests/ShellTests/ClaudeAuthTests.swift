import XCTest
@testable import Shell

final class ClaudeAuthTests: XCTestCase {
    func testStatusFromAuthStatusJSON() {
        let loggedIn = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}"#
        let loggedOut = #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#
        XCTAssertEqual(ClaudeAuth.parseStatus(Data(loggedIn.utf8)), .loggedIn)
        XCTAssertEqual(ClaudeAuth.parseStatus(Data(loggedOut.utf8)), .loggedOut)
    }

    func testThirdPartyProvidersAndUnreadableOutputAreUnknown() {
        let bedrock = #"{"loggedIn": false, "authMethod": "none", "apiProvider": "bedrock"}"#
        XCTAssertEqual(ClaudeAuth.parseStatus(Data(bedrock.utf8)), .unknown)
        XCTAssertEqual(ClaudeAuth.parseStatus(Data("Not logged in. Run claude auth login to authenticate.".utf8)), .unknown)
        XCTAssertEqual(ClaudeAuth.parseStatus(Data()), .unknown)
    }

    func testRecognisesLoginErrors() {
        XCTAssertTrue(ClaudeAuth.isLoginError("Not logged in · Please run /login"))
        XCTAssertTrue(ClaudeAuth.isLoginError("OAuth token has expired · Please run /login"))
        XCTAssertFalse(ClaudeAuth.isLoginError("API Error: 529 Overloaded"))
        XCTAssertFalse(ClaudeAuth.isLoginError("Run the login tests"))
    }

    func testRecognisesTheSyntheticAuthFailureMessage() {
        let flagged: [String: Any] = ["type": "assistant", "error": "authentication_failed",
                                      "message": ["model": "<synthetic>", "content": [["type": "text", "text": "Not logged in · Please run /login"]]]]
        XCTAssertTrue(ClaudeAuth.isAuthFailure(flagged))
        // Older CLIs without the error field.
        var unflagged = flagged
        unflagged["error"] = nil
        XCTAssertTrue(ClaudeAuth.isAuthFailure(unflagged))
        // Claude itself talking about /login isn't a failure.
        let reply: [String: Any] = ["type": "assistant",
                                    "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": "Please run /login first"]]]]
        XCTAssertFalse(ClaudeAuth.isAuthFailure(reply))
    }

    func testFindsTheSignInURLInsideAnOSC8Link() {
        let url = "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz"
        let output = "Opening browser to sign in…\nIf the browser didn't open, visit: \u{1B}]8;;\(url)\u{07}\(url)\u{1B}]8;;\u{07}\nPaste code here if prompted > "
        XCTAssertEqual(ClaudeAuth.loginURL(in: output)?.absoluteString, url)
        XCTAssertNil(ClaudeAuth.loginURL(in: "Opening browser to sign in…"))
    }

    func testFailureMessageDropsTheCodePrompt() {
        let output = "Opening browser to sign in…\n\u{1B}[31mPaste code here if prompted > Login failed: Request failed with status code 400\u{1B}[0m\n"
        XCTAssertEqual(ClaudeAuth.failureMessage(in: output), "Login failed: Request failed with status code 400")
        XCTAssertNil(ClaudeAuth.failureMessage(in: "\n  \n"))
    }

    func testRestartDropsConversationSelection() {
        let id = "7bcc953c-5abd-4120-82da-148001c196cb"
        XCTAssertEqual(ClaudeCodeSession.withoutSessionSelection(["-c", "--add-dir", "../a", "--resume", id, "--fork-session", "--session-id", id, "--verbose"]),
                       ["--add-dir", "../a", "--verbose"])
    }
}

@MainActor
final class ClaudeSessionLoginTests: XCTestCase {
    private func session() -> ClaudeCodeSession {
        ClaudeCodeSession(request: ClaudeLaunchRequest(directory: NSTemporaryDirectory(), binary: "/usr/bin/false",
                                                       arguments: ClaudeArguments(), environment: [:]))
    }

    func testSignedOutTurnShowsSignInInsteadOfAnError() {
        let claude = session()
        claude.handle(["type": "assistant", "error": "authentication_failed", "parent_tool_use_id": NSNull(),
                       "message": ["id": "m1", "model": "<synthetic>", "content": [["type": "text", "text": "Not logged in · Please run /login"]]]])
        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"])
        XCTAssertNotNil(claude.login)
        XCTAssertEqual(claude.login?.expired, false)
        XCTAssertFalse(claude.canSend)
        XCTAssertTrue(claude.items.isEmpty, "no assistant text or error for the failed turn")
    }

    func testOtherErrorsStayInTheTranscript() {
        let claude = session()
        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "API Error: 529 Overloaded"])
        XCTAssertNil(claude.login)
        XCTAssertEqual(claude.items.last?.kind, .error)
    }
}
