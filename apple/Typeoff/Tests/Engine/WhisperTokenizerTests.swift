import XCTest
@testable import Typeoff

final class WhisperTokenizerTests: XCTestCase {

    func testSpecialTokenValues() {
        XCTAssertEqual(WhisperTokenizer.sot, 50258)
        XCTAssertEqual(WhisperTokenizer.eot, 50257)
        XCTAssertEqual(WhisperTokenizer.transcribe, 50359)
        XCTAssertEqual(WhisperTokenizer.noTimestamps, 50363)
    }

    func testInitialTokensEnglish() {
        let tokenizer = WhisperTokenizer()
        let tokens = tokenizer.initialTokens(language: "en")

        XCTAssertEqual(tokens[0], WhisperTokenizer.sot, "First token should be SOT")
        XCTAssertEqual(tokens[1], 50259, "Second should be English language token")
        XCTAssertEqual(tokens[2], WhisperTokenizer.transcribe, "Third should be transcribe task")
        XCTAssertEqual(tokens[3], WhisperTokenizer.noTimestamps, "Fourth should be no timestamps")
    }

    func testInitialTokensNoLanguage() {
        let tokenizer = WhisperTokenizer()
        let tokens = tokenizer.initialTokens(language: nil)

        XCTAssertEqual(tokens.count, 3, "Without language: SOT + transcribe + noTimestamps")
        XCTAssertEqual(tokens[0], WhisperTokenizer.sot)
    }

    func testDecodeSkipsSpecialTokens() {
        let tokenizer = WhisperTokenizer()
        tokenizer.load()

        // Special tokens (>= EOT) should be skipped
        let result = tokenizer.decode([WhisperTokenizer.sot, WhisperTokenizer.eot])
        XCTAssertEqual(result, "", "Special tokens should produce empty string")
    }

    func testDecodeEmptyArray() {
        let tokenizer = WhisperTokenizer()
        tokenizer.load()

        let result = tokenizer.decode([])
        XCTAssertEqual(result, "")
    }

    func testLanguageTokenLookup() {
        XCTAssertEqual(WhisperTokenizer.languages["en"], 50259)
        XCTAssertEqual(WhisperTokenizer.languages["zh"], 50260)
        XCTAssertEqual(WhisperTokenizer.languages["es"], 50262)
        XCTAssertNil(WhisperTokenizer.languages["xx"])
    }
}
