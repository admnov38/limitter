import XCTest
@testable import LimitterCore

final class CodexConnectionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func executable(at url: URL, permissions: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func testNestedDesktopCLIIsFoundWithFinderPath() throws {
        for app in ["Codex.app", "ChatGPT.app"] {
            for userInstall in [false, true] {
                let home = try fixture()
                let systemApps = home.appendingPathComponent("SystemApplications")
                let userApps = home.appendingPathComponent("Applications")
                let binary = (userInstall ? userApps : systemApps).appendingPathComponent(app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                try executable(at: binary)
                XCTAssertEqual(CodexConnection.executable(home: home, applicationDirectories: [systemApps, userApps], path: "/usr/bin:/bin:/usr/sbin:/sbin"), binary)
            }
        }
    }

    func testLegacyDesktopAndWrapperLayoutsRemainSupported() throws {
        for app in ["Codex.app", "ChatGPT.app"] {
            for relativePath in ["codex", "codex-cli/bin/codex"] {
                let home = try fixture(), apps = home.appendingPathComponent("Applications")
                let binary = apps.appendingPathComponent(app + "/Contents/Resources/" + relativePath)
                try executable(at: binary)
                XCTAssertEqual(CodexConnection.executable(home: home, applicationDirectories: [apps], path: ""), binary)
            }
        }
    }

    func testUnusableNestedCLIIsSkippedAndBundlePrecedesPath() throws {
        let home = try fixture(), apps = home.appendingPathComponent("Applications")
        let resources = apps.appendingPathComponent("ChatGPT.app/Contents/Resources")
        try executable(at: resources.appendingPathComponent("codex-cli/CodexCLI.app/Contents/MacOS/codex"), permissions: 0o644)
        let wrapper = resources.appendingPathComponent("codex-cli/bin/codex")
        try executable(at: wrapper)
        let path = home.appendingPathComponent("bin")
        try executable(at: path.appendingPathComponent("codex"))
        XCTAssertEqual(CodexConnection.executable(home: home, applicationDirectories: [apps], path: path.path), wrapper)
    }
}
