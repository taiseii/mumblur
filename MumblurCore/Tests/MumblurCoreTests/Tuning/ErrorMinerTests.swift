// MumblurCore/Tests/MumblurCoreTests/Tuning/ErrorMinerTests.swift
import XCTest
@testable import MumblurCore

final class ErrorMinerTests: XCTestCase {
    func testProducedToExpectedDirection() {
        let miner = ErrorMiner()
        let pairs = miner.mineSubstitutions(samples: [
            .init(groundTruth: "Questable rocks",      raw: "questionable rocks"),
            .init(groundTruth: "I love Questable",     raw: "I love questionable"),
        ])
        XCTAssertTrue(pairs.contains { $0.produced == "questionable" && $0.expected == "questable" })
    }
    func testIgnoresPunctuationCasing_viaNormalizer() {
        let miner = ErrorMiner()
        let pairs = miner.mineSubstitutions(samples: [
            .init(groundTruth: "WhisperKit!", raw: "whisper kit"),
        ])
        XCTAssertFalse(pairs.contains { $0.produced == "whisperkit" })
    }
}
