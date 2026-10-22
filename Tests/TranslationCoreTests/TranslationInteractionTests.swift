import XCTest
@testable import TranslationCore

final class TranslationInteractionTests: XCTestCase {
    func testWeChatAlwaysCopiesInsteadOfTrustingStaleInputSelection() {
        for source: String? in [nil, "", "旧输入框选区"] {
            XCTAssertTrue(SelectionCapturePolicy.needsFreshCopy(wechat: true, selectedText: source))
            for length: Int? in [nil, 0, 5] {
                XCTAssertFalse(SelectionCapturePolicy.emptyRangeOpensHistory(wechat: true, editableTarget: true, rangeLength: length, selectedText: source))
            }
        }
        XCTAssertFalse(SelectionCapturePolicy.needsFreshCopy(wechat: false, selectedText: "网页文字"))
        XCTAssertTrue(SelectionCapturePolicy.needsFreshCopy(wechat: false, selectedText: nil))
        XCTAssertTrue(SelectionCapturePolicy.needsFreshCopy(wechat: false, selectedText: ""))
    }

    func testOnlyKnownEmptyEditableRangesSkipCopy() {
        XCTAssertTrue(SelectionCapturePolicy.emptyRangeOpensHistory(wechat: false, editableTarget: true, rangeLength: 0, selectedText: ""))
        XCTAssertFalse(SelectionCapturePolicy.emptyRangeOpensHistory(wechat: false, editableTarget: false, rangeLength: 0, selectedText: nil))
        XCTAssertFalse(SelectionCapturePolicy.emptyRangeOpensHistory(wechat: false, editableTarget: true, rangeLength: nil, selectedText: nil))
        XCTAssertFalse(SelectionCapturePolicy.emptyRangeOpensHistory(wechat: false, editableTarget: true, rangeLength: 0, selectedText: "页面选区"))
        XCTAssertFalse(SelectionCapturePolicy.emptyRangeOpensHistory(wechat: false, editableTarget: true, rangeLength: 2, selectedText: "你好"))
    }

    func testReadOnlyClassificationKeepsWeChatChatHistoryAwayFromPaste() {
        for cut: Bool? in [false, nil] {
            // 微信的 AX 焦点即使仍指向输入框，也不能覆盖聊天记录选区。
            XCTAssertTrue(SelectionCapturePolicy.isReadOnly(wechat: true, editableRole: true, writableText: true, cutEnabled: cut))
        }
        XCTAssertFalse(SelectionCapturePolicy.isReadOnly(wechat: true, editableRole: false, writableText: false, cutEnabled: true))
        XCTAssertTrue(SelectionCapturePolicy.isReadOnly(wechat: false, editableRole: false, writableText: false, cutEnabled: nil))
        XCTAssertFalse(SelectionCapturePolicy.isReadOnly(wechat: false, editableRole: true, writableText: false, cutEnabled: nil))
        XCTAssertFalse(SelectionCapturePolicy.isReadOnly(wechat: false, editableRole: false, writableText: true, cutEnabled: nil))
    }

    func testEmptySelectionOpensHistoryAndNonemptySelectionStillTranslates() {
        for text: String? in [nil, "", " ", "\n\t\r", "　", "\u{00A0}"] {
            XCTAssertTrue(SelectionShortcut.opensHistory(selectedText: text))
        }
        for text in ["你好", "Hello", "  hello\n", "0", "🌏", "[ ]"] {
            XCTAssertFalse(SelectionShortcut.opensHistory(selectedText: text))
        }
    }

    func testClipboardCompatibilityRequiresTargetIdleInputAndFreshMatchingCopy() {
        func matches(target: Bool = true, idle: Bool = true, source: String = "🌏 你好", copy: String? = "🌏 你好") -> Bool {
            ClipboardSelectionIntegrity.matches(sameTarget: target, inputUnchanged: idle, source: source, copiedSelection: copy)
        }
        XCTAssertTrue(matches())
        XCTAssertFalse(matches(target: false))
        XCTAssertFalse(matches(idle: false)) // 即使改回相同内容，也不能恢复资格。
        XCTAssertFalse(matches(copy: nil))
        XCTAssertFalse(matches(copy: "你好"))
        XCTAssertFalse(matches(copy: "🌏 你好 ")) // 不裁剪选区，不容许位置外多字。
        XCTAssertFalse(matches(source: "  ", copy: "  "))
    }
    func testSelectionChangePermanentlyDisablesReplacementForRequest() {
        var state = TranslationInteraction()
        let id = state.begin()
        XCTAssertTrue(state.canReplace(id))
        XCTAssertTrue(state.invalidate(id))
        XCTAssertFalse(state.canReplace(id))
        XCTAssertFalse(state.invalidate(id))
        XCTAssertTrue(state.owns(id)) // 仍可保留已完成的译文。
    }
    func testLateResultAndOldCleanupCannotAffectNewRequest() {
        var state = TranslationInteraction()
        let old = state.begin()
        let current = state.begin()
        XCTAssertFalse(state.owns(old))
        XCTAssertFalse(state.invalidate(old))
        XCTAssertFalse(state.finish(old))
        XCTAssertTrue(state.canReplace(current))
        XCTAssertTrue(state.finish(current))
        XCTAssertNil(state.requestID)
        XCTAssertFalse(state.canReplace(current))
    }
    func testTargetRangeAndContentMustAllMatch() {
        let range = NSRange(location: 2, length: 2)
        func check(target: Bool = true, range current: NSRange? = NSRange(location: 2, length: 2), text: String? = "甲乙你好", selected: String? = "你好") -> SelectionIntegrity {
            SelectionIntegrity.evaluate(sameTarget: target, originalRange: range, currentRange: current, originalText: "甲乙你好", currentText: text, source: "你好", selectedText: selected)
        }
        XCTAssertEqual(check(), .matches)
        XCTAssertEqual(check(target: false), .changed)
        XCTAssertEqual(check(range: NSRange(location: 0, length: 2)), .changed)
        XCTAssertEqual(check(range: NSRange(location: 2, length: 0)), .changed)
        XCTAssertEqual(check(text: "丙乙你好"), .changed)
        XCTAssertEqual(check(selected: "再见"), .changed)
        XCTAssertEqual(check(range: nil), .unverifiable)
        XCTAssertEqual(check(text: nil), .unverifiable)
    }
    func testMissingSelectedTextCanBeVerifiedAgainstUTF16FullText() {
        let text = "🌏你好"
        XCTAssertEqual(SelectionIntegrity.evaluate(sameTarget: true, originalRange: NSRange(location: 2, length: 2), currentRange: NSRange(location: 2, length: 2),
                                                  originalText: text, currentText: text, source: "你好", selectedText: nil), .matches)
        XCTAssertEqual(SelectionIntegrity.evaluate(sameTarget: true, originalRange: NSRange(location: 20, length: 2), currentRange: NSRange(location: 20, length: 2),
                                                  originalText: text, currentText: text, source: "你好", selectedText: nil), .unverifiable)
    }
    func testRangeAloneAndTextAloneNeverAuthorizeReplacement() {
        let range = NSRange(location: 0, length: 2)
        XCTAssertEqual(SelectionIntegrity.evaluate(sameTarget: true, originalRange: range, currentRange: range, originalText: nil, currentText: nil, source: "你好", selectedText: nil), .unverifiable)
        XCTAssertEqual(SelectionIntegrity.evaluate(sameTarget: true, originalRange: nil, currentRange: nil, originalText: nil, currentText: nil, source: "你好", selectedText: "你好"), .unverifiable)
    }
    func testReplacementMustMatchActualTextRatherThanSetterSuccess() {
        func check(_ text: String?) -> ReplacementVerification {
            ReplacementVerification.evaluate(originalText: "真冷呀", range: NSRange(location: 0, length: 3),
                source: "真冷呀", translation: "It's so cold.", currentText: text)
        }
        XCTAssertEqual(check("真冷呀"), .unchanged)
        XCTAssertEqual(check("It's so cold."), .confirmed)
        XCTAssertEqual(check("真冷呀！"), .changed)
        XCTAssertEqual(check(nil), .unverifiable)
    }
    func testReplacementVerifiesFullTextAndUTF16Selection() {
        func check(_ text: String) -> ReplacementVerification {
            ReplacementVerification.evaluate(originalText: "🌏真冷呀，再见", range: NSRange(location: 2, length: 3),
                source: "真冷呀", translation: "It's so cold.", currentText: text)
        }
        XCTAssertEqual(check("🌏It's so cold.，再见"), .confirmed)
        XCTAssertEqual(check("It's so cold."), .changed)
        XCTAssertEqual(check("🌏真冷呀，再见"), .unchanged)
        XCTAssertEqual(check("🌏It's so cold.，再见！"), .changed)
    }
    func testMissingOrInvalidOriginalTextNeverConfirmsReplacement() {
        func check(text: String? = "真冷呀", range: NSRange? = NSRange(location: 0, length: 3), source: String = "真冷呀") -> ReplacementVerification {
            ReplacementVerification.evaluate(originalText: text, range: range, source: source, translation: "Cold", currentText: "Cold")
        }
        XCTAssertEqual(check(text: nil), .unverifiable)
        XCTAssertEqual(check(range: nil), .unverifiable)
        XCTAssertEqual(check(range: NSRange(location: 20, length: 3)), .unverifiable)
        XCTAssertEqual(check(range: NSRange(location: 0, length: 0)), .unverifiable)
        XCTAssertEqual(check(source: "你好"), .unverifiable)
    }
}
