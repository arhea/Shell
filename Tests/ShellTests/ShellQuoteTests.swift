import XCTest
@testable import Shell

final class ShellQuoteTests: XCTestCase {
    func testQuotesAnythingUnsafe() {
        XCTAssertEqual(ShellQuote.quote("src/App.swift"), "src/App.swift")
        XCTAssertEqual(ShellQuote.quote(""), "''")
        XCTAssertEqual(ShellQuote.quote("My File.txt"), "'My File.txt'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote("a\nb"), "'a\nb'")
        XCTAssertEqual(ShellQuote.quote("tab\there"), "'tab\there'")
        XCTAssertEqual(ShellQuote.quote("$(rm -rf ~)"), "'$(rm -rf ~)'")
        XCTAssertEqual(ShellQuote.quote("naïve"), "'naïve'")
    }

    func testPathsKeepTilde() {
        XCTAssertEqual(ShellQuote.path("/Users/me/My Repo", home: "/Users/me"), "~/'My Repo'")
        XCTAssertEqual(ShellQuote.path("/opt/x", home: "/Users/me"), "/opt/x")
    }
}
