import XCTest
@testable import TranslationCore

final class ReplacementStyleTests: XCTestCase {
    func testDefaultAndBothBilingualOrders() {
        XCTAssertEqual(ReplacementStyle.translationOnly.replacement(source: "今天真冷", translation: "It's really cold today."), "It's really cold today.")
        XCTAssertEqual(ReplacementStyle.sourceThenTranslation.replacement(source: "今天真冷", translation: "It's really cold today."), "今天真冷 [It's really cold today.]")
        XCTAssertEqual(ReplacementStyle.translationThenSource.replacement(source: "今天真冷", translation: "It's really cold today."), "It's really cold today. [今天真冷]")
        XCTAssertEqual(ReplacementStyle.sourceThenTranslation.replacement(source: "Thank you!", translation: "谢谢！"), "Thank you! [谢谢！]")
        XCTAssertEqual(ReplacementStyle.translationThenSource.replacement(source: "Thank you!", translation: "谢谢！"), "谢谢！ [Thank you!]")
    }
    func testFormattingPreservesWhitespaceEmojiBracketsAndNewlines() {
        let source = " 🌏[你好]\n再见！ "
        let translation = "🌏[Hello]\nGoodbye!"
        XCTAssertEqual(ReplacementStyle.sourceThenTranslation.replacement(source: source, translation: translation), source + " [" + translation + "]")
        XCTAssertEqual(ReplacementStyle.translationThenSource.replacement(source: source, translation: translation), translation + " [" + source + "]")
        for style in ReplacementStyle.allCases { XCTAssertEqual(style.replacement(source: "123 [abc]", translation: "123 [abc]"), "123 [abc]") }
    }
    func testPartialSelectionVerifiesTheCompleteComposedReplacement() {
        let source = "真冷呀"
        let original = "🌏真冷呀，再见"
        let range = NSRange(location: 2, length: 3)
        for style in ReplacementStyle.allCases {
            let formatted = style.replacement(source: source, translation: "It's cold.")
            XCTAssertEqual(ReplacementVerification.evaluate(originalText: original, range: range, source: source, translation: formatted, currentText: "🌏" + formatted + "，再见"), .confirmed)
            XCTAssertEqual(ReplacementVerification.evaluate(originalText: original, range: range, source: source, translation: formatted, currentText: original), .unchanged)
        }
    }
    func testOldSettingsDefaultToTranslationOnlyAndStylesRoundTrip() throws {
        let old = Data(#"{"backend":"pi","models":{"pi":"provider/model"}}"#.utf8)
        let migrated = try JSONDecoder().decode(Configuration.self, from: old)
        XCTAssertEqual(migrated.replacementStyle, .translationOnly)
        XCTAssertEqual(migrated.selectedModel, "provider/model")
        for style in ReplacementStyle.allCases {
            var config = migrated; config.replacementStyle = style
            let captured = config
            config.replacementStyle = style == .translationOnly ? .sourceThenTranslation : .translationOnly
            XCTAssertEqual(captured.replacementStyle, style)
            let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(captured))
            XCTAssertEqual(decoded.replacementStyle, style)
            XCTAssertEqual(decoded.selectedModel, migrated.selectedModel)
        }
    }
}
