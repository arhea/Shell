import XCTest
@testable import Shell

final class RuntimeDetectionTests: XCTestCase {
    private func finder(_ files: [String: String]) -> (String) -> String? { { files[$0] } }

    func testNearestMarkerWinsWalkingUp() {
        let files = [
            "/h/proj/package.json": #"{"name":"x","engines":{"node":">=20"}}"#,
            "/h/proj/api/go.mod": "module x\n\ngo 1.23.2\n",
            "/h/.python-version": "3.12.4\n",
        ]
        let api = RuntimeDetection.findMarker(from: "/h/proj/api/internal", stop: "/h", read: finder(files))
        XCTAssertEqual(api, RuntimeMarker(kind: .go, declared: "1.23.2", directory: "/h/proj/api"))
        let web = RuntimeDetection.findMarker(from: "/h/proj/web", stop: "/h", read: finder(files))
        XCTAssertEqual(web, RuntimeMarker(kind: .node, declared: ">=20", directory: "/h/proj"))
        XCTAssertEqual(RuntimeDetection.findMarker(from: "/h/other", stop: "/h", read: finder(files))?.kind, .python)
        XCTAssertNil(RuntimeDetection.findMarker(from: "/elsewhere/x", stop: "/h", read: finder(files)))
    }

    func testStopsAtTheStopDirectory() {
        let files = ["/h/.nvmrc": "22"]
        XCTAssertNil(RuntimeDetection.findMarker(from: "/h/a/b", stop: "/h/a", read: finder(files)))
        XCTAssertNotNil(RuntimeDetection.findMarker(from: "/h/a/b", stop: "/h", read: finder(files)))
    }

    func testNodeMarkersBeatOthersInTheSameFolder() {
        let files = ["/p/.nvmrc": "# pinned\nv22.9.0\n", "/p/go.mod": "go 1.22", "/p/package.json": "{}"]
        XCTAssertEqual(RuntimeDetection.findMarker(from: "/p", stop: "/", read: finder(files)),
                       RuntimeMarker(kind: .node, declared: "v22.9.0", directory: "/p"))
    }

    func testParsing() {
        XCTAssertEqual(RuntimeDetection.firstToken("  \n# comment\nlts/iron  extra\n"), "lts/iron")
        XCTAssertNil(RuntimeDetection.firstToken("\n"))
        XCTAssertNil(RuntimeDetection.packageEngine(#"{"name":"x"}"#))
        XCTAssertNil(RuntimeDetection.packageEngine("not json"))
        XCTAssertEqual(RuntimeDetection.goVersion("module a\ngo 1.21\ntoolchain go1.22.1"), "1.21")
        XCTAssertEqual(RuntimeDetection.shortVersion("v22.9.0\n"), "22.9")
        XCTAssertEqual(RuntimeDetection.shortVersion("3.12.4"), "3.12")
        XCTAssertEqual(RuntimeDetection.shortVersion("20"), "20")
        XCTAssertNil(RuntimeDetection.shortVersion(">=20"))
        XCTAssertNil(RuntimeDetection.shortVersion("lts/iron"))
    }

    func testLabelPrefersTheResolvedVersion() {
        let node = RuntimeMarker(kind: .node, declared: "lts/iron", directory: "/p")
        XCTAssertEqual(RuntimeDetection.label(for: node, resolved: "v22.9.0"), "node 22.9")
        XCTAssertEqual(RuntimeDetection.label(for: node, resolved: nil), "node")
        let py = RuntimeMarker(kind: .python, declared: "3.12.4", directory: "/p")
        XCTAssertEqual(RuntimeDetection.label(for: py, resolved: nil), "python 3.12")
        XCTAssertEqual(RuntimeDetection.label(for: RuntimeMarker(kind: .go, declared: "1.23.2", directory: "/p"), resolved: nil), "go 1.23")
    }

    @MainActor
    func testDetectorReadsRealFilesAndCaches() async throws {
        let dir = try makeTemporaryDirectory()
        try "3.11.9\n".write(to: dir.appendingPathComponent(".python-version"), atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let label = await RuntimeDetector.shared.label(for: sub.path, environment: [:])
        XCTAssertEqual(label, "python 3.11")
        XCTAssertEqual(RuntimeDetector.shared.cachedLabel(for: sub.path), .some("python 3.11"))
    }
}
