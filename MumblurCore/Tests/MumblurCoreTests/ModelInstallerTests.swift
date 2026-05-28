import XCTest
@testable import MumblurCore

final class ModelInstallerTests: XCTestCase {
    func testInstalledVariants_scansRepoDir() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = WhisperKitModels.defaultRepo
        let repoDir = WhisperKitInstaller.repoDir(downloadBase: base, repo: repo)
        for variant in ["openai_whisper-tiny", "openai_whisper-large-v3-turbo"] {
            try fm.createDirectory(at: repoDir.appendingPathComponent(variant),
                                   withIntermediateDirectories: true)
        }
        // A stray file (not a directory) must be ignored.
        try Data().write(to: repoDir.appendingPathComponent("README.md"))

        let installer = WhisperKitInstaller()
        let found = installer.installedVariants(downloadBase: base, repo: repo)
        XCTAssertEqual(found, ["openai_whisper-tiny", "openai_whisper-large-v3-turbo"])

        try? fm.removeItem(at: base)
    }

    func testInstalledVariants_missingDirIsEmpty() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let found = WhisperKitInstaller().installedVariants(downloadBase: base,
                                                            repo: WhisperKitModels.defaultRepo)
        XCTAssertTrue(found.isEmpty)
    }

    func testRepoDir_layout() {
        let base = URL(fileURLWithPath: "/tmp/store/models-root")
        let dir = WhisperKitInstaller.repoDir(downloadBase: base, repo: "argmaxinc/whisperkit-coreml")
        XCTAssertEqual(dir.path, "/tmp/store/models-root/models/argmaxinc/whisperkit-coreml")
    }
}
