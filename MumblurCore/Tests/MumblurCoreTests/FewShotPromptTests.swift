import XCTest
@testable import MumblurCore

final class FewShotPromptTests: XCTestCase {
    func testAugment_noExamples_returnsBaseUnchanged() {
        let base = "Fix punctuation and capitalization."
        XCTAssertEqual(FewShotPrompt.augment(base: base, examples: []), base)
    }

    func testAugment_withExamples_keepsBaseAndIncludesRawAndCorrected() {
        let base = "Fix punctuation."
        let out = FewShotPrompt.augment(base: base, examples: [
            FewShotExample(raw: "helo wrld", corrected: "Hello, world."),
        ])
        XCTAssertTrue(out.hasPrefix(base))         // base instruction preserved up front
        XCTAssertTrue(out.contains("helo wrld"))   // the user's raw transcription
        XCTAssertTrue(out.contains("Hello, world.")) // their intended correction
    }
}
