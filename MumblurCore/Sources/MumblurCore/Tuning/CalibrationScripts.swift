// MumblurCore/Sources/MumblurCore/Tuning/CalibrationScripts.swift
import Foundation
import CryptoKit

public struct CalibrationScript: Sendable, Identifiable {
    public enum Role: String, Sendable { case mining, eval }
    public struct Sentence: Sendable {
        public let text: String
        public let role: Role
    }
    public let id: String
    public let name: String
    public let language: String?
    public let sentences: [Sentence]

    public var hash: String {
        let joined = sentences.map(\.text).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum CalibrationScripts {
    public static let englishBaseline = CalibrationScript(
        id: "en-baseline-v1", name: "English baseline", language: "en",
        sentences: [
            .init(text: "Mumblur transcribes audio locally.", role: .mining),
            .init(text: "I use WhisperKit on Apple Silicon.", role: .mining),
            .init(text: "Questable is the company name.", role: .mining),
            .init(text: "Open the settings to add vocabulary.", role: .mining),
            .init(text: "The right option key starts recording.", role: .mining),
            .init(text: "Calibration uses a held-out evaluation set.", role: .eval),
            .init(text: "WhisperKit prompts can bias decoding output.", role: .eval),
            .init(text: "Replacement rules run after transcription.", role: .eval),
            .init(text: "I love using Questable every day.", role: .eval),
            .init(text: "The model loads in the background while you dictate.", role: .eval),
        ])

    public static let all: [CalibrationScript] = [englishBaseline]
    public static func byID(_ id: String) -> CalibrationScript? { all.first { $0.id == id } }
}
