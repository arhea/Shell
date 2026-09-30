import XCTest
@testable import Shell

final class ClaudeModelNameTests: XCTestCase {
    private func option(_ value: String, _ name: String, _ description: String) -> ClaudeModelOption {
        ClaudeModelOption(value: value, displayName: name, description: description, effortLevels: [], supportsAutoMode: true)
    }

    /// The list Claude Code 2.1 returns from `initialize`.
    func testLabelsShowRealModelsAndVersions() {
        let def = option("default", "Default (recommended)", "Opus 5 with 1M context · Best for everyday, complex tasks")
        XCTAssertEqual(def.label, "Opus 5 (1M)")
        XCTAssertEqual(def.detail, "Default · Best for everyday, complex tasks")

        let fable = option("claude-fable-5-1[1m]", "Fable", "Fable 5.1 · Most capable for your hardest and longest-running tasks")
        XCTAssertEqual(fable.label, "Fable 5.1")
        XCTAssertEqual(fable.detail, "Most capable for your hardest and longest-running tasks")

        XCTAssertEqual(option("sonnet", "Sonnet", "Sonnet 5 · Efficient for routine tasks").label, "Sonnet 5")
        XCTAssertEqual(option("haiku", "Haiku", "Haiku 4.5 · Fastest for quick answers").label, "Haiku 4.5")
    }

    func testFallsBackToTheModelID() {
        XCTAssertEqual(option("claude-fable-5-1[1m]", "Fable", "Most capable").label, "Fable 5.1 (1M)")
        XCTAssertEqual(option("sonnet", "Sonnet", "Efficient").label, "Sonnet")
        XCTAssertEqual(ClaudeModelName.format("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeModelName.format("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ClaudeModelName.format("claude-opus-5[1m]"), "Opus 5 (1M)")
    }
}
