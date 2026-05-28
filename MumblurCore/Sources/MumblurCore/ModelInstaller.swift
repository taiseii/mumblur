// MumblurCore/Sources/MumblurCore/ModelInstaller.swift
import Foundation
import WhisperKit

public enum WhisperKitModels {
    public static let defaultRepo = "argmaxinc/whisperkit-coreml"
}

/// Mockable seam over WhisperKit's model download so the App can show progress
/// and detect what's on disk without importing WhisperKit or hitting the network
/// in tests.
public protocol ModelInstalling: Sendable {
    /// Downloads `variant` from `repo` into `downloadBase`, reporting fractional
    /// progress in 0...1. Returns the local model folder.
    func download(variant: String, repo: String, downloadBase: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    /// Variants already present on disk under `downloadBase` for `repo`.
    func installedVariants(downloadBase: URL, repo: String) -> Set<String>
}

public struct WhisperKitInstaller: ModelInstalling {
    public init() {}

    public func download(variant: String, repo: String, downloadBase: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(
            variant: variant, downloadBase: downloadBase, from: repo,
            progressCallback: { p in progress(p.fractionCompleted) })
    }

    public func installedVariants(downloadBase: URL, repo: String) -> Set<String> {
        let dir = Self.repoDir(downloadBase: downloadBase, repo: repo)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return [] }
        return Set(entries
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).isDirectory) == true }
            .map { $0.lastPathComponent })
    }

    /// swift-transformers Hub on-disk layout: `<downloadBase>/models/<repo>/<variant>/`.
    /// Centralized so a layout change only needs fixing here.
    public static func repoDir(downloadBase: URL, repo: String) -> URL {
        repo.split(separator: "/").reduce(downloadBase.appendingPathComponent("models")) {
            $0.appendingPathComponent(String($1))
        }
    }
}
