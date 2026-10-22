import Foundation

/// 每次快捷键对应独立请求。失效不可恢复，旧结果不能影响新请求。
public struct TranslationInteraction {
    public private(set) var requestID: UUID?
    public private(set) var replacementAllowed = false
    public init() {}
    @discardableResult public mutating func begin() -> UUID {
        let id = UUID(); requestID = id; replacementAllowed = true; return id
    }
    public func owns(_ id: UUID) -> Bool { requestID == id }
    public func canReplace(_ id: UUID) -> Bool { owns(id) && replacementAllowed }
    @discardableResult public mutating func invalidate(_ id: UUID) -> Bool {
        guard owns(id), replacementAllowed else { return false }
        replacementAllowed = false; return true
    }
    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard owns(id) else { return false }
        requestID = nil; replacementAllowed = false; return true
    }
}

public enum SelectionIntegrity: Equatable {
    case matches, changed, unverifiable

    public static func evaluate(sameTarget: Bool, originalRange: NSRange?, currentRange: NSRange?,
                                originalText: String?, currentText: String?, source: String, selectedText: String?) -> Self {
        guard sameTarget else { return .changed }
        if let originalText {
            guard let currentText else { return .unverifiable }
            if originalText != currentText { return .changed }
        }
        guard let originalRange, let currentRange else { return .unverifiable }
        guard originalRange == currentRange, originalRange.length > 0 else { return .changed }
        if let selectedText { return selectedText == source ? .matches : .changed }
        if let currentText {
            let text = currentText as NSString
            guard currentRange.location >= 0, currentRange.length <= text.length, currentRange.location <= text.length - currentRange.length else { return .unverifiable }
            return text.substring(with: currentRange) == source ? .matches : .changed
        }
        return .unverifiable
    }
}

/// 写入 API 返回成功并不能证明输入框已改变；必须核对实际内容。
public enum ReplacementVerification: Equatable {
    case confirmed, unchanged, changed, unverifiable

    public static func evaluate(originalText: String?, range: NSRange?, source: String, translation: String, currentText: String?) -> Self {
        guard let originalText, let range, let currentText, range.location >= 0, range.length > 0,
              range.length <= (originalText as NSString).length, range.location <= (originalText as NSString).length - range.length,
              let selection = Range(range, in: originalText),
              String(originalText[selection]) == source else { return .unverifiable }
        let expected = originalText.replacingCharacters(in: selection, with: translation)
        if currentText == expected { return .confirmed }
        return currentText == originalText ? .unchanged : .changed
    }
}

/// 自绘输入框无法读取范围时，目标身份、无操作记录与本次重新复制必须同时成立。
public enum ClipboardSelectionIntegrity {
    public static func matches(sameTarget: Bool, inputUnchanged: Bool, source: String, copiedSelection: String?) -> Bool {
        sameTarget && inputUnchanged && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && copiedSelection == source
    }
}

/// 「无选区」是打开历史的正常快捷键分支，不是翻译错误。
public enum SelectionCaptureError: LocalizedError {
    case noSelection
    public var errorDescription: String? { "当前没有可翻译的选中文字。" }
}

public enum SelectionShortcut {
    public static func opensHistory(selectedText: String?) -> Bool {
        selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

/// 微信焦点常停留在输入框，不能用零长度 AX 范围否定聊天记录里的选区。
public enum SelectionCapturePolicy {
    public static func needsFreshCopy(wechat: Bool, selectedText: String?) -> Bool {
        wechat || selectedText == nil || selectedText?.isEmpty == true
    }
    public static func emptyRangeOpensHistory(wechat: Bool, editableTarget: Bool, rangeLength: Int?, selectedText: String?) -> Bool {
        !wechat && editableTarget && rangeLength == 0 && SelectionShortcut.opensHistory(selectedText: selectedText)
    }
    public static func isReadOnly(wechat: Bool, editableRole: Bool, writableText: Bool, cutEnabled: Bool?) -> Bool {
        if wechat { return cutEnabled != true }
        return !editableRole && !writableText
    }
}
