import Foundation

public enum Backend: String, Codable, CaseIterable {
    case codex, claude, pi
    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .pi: return "Pi"
        }
    }
}

public enum ReplacementStyle: String, Codable, CaseIterable {
    case translationOnly, sourceThenTranslation, translationThenSource

    public var title: String {
        switch self {
        case .translationOnly: return "仅译文"
        case .sourceThenTranslation: return "原文 [译文]"
        case .translationThenSource: return "译文 [原文]"
        }
    }

    public func replacement(source: String, translation: String) -> String {
        guard source != translation else { return source }
        switch self {
        case .translationOnly: return translation
        case .sourceThenTranslation: return source + " [" + translation + "]"
        case .translationThenSource: return translation + " [" + source + "]"
        }
    }
}

public struct Configuration: Codable {
    public var backend: Backend = .codex
    public var timeout: Double = 75
    public var shortcut: Int = 0
    public var replacementStyle: ReplacementStyle = .translationOnly
    public var notes: Bool = false
    public var executablePaths: [String: String] = [:]
    public var models: [String: String] = [:]
    public var selectedModel: String { models[backend.rawValue] ?? "" }
    public init() {}

    private enum CodingKeys: String, CodingKey { case backend, timeout, shortcut, replacementStyle, notes, executablePaths, models }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decodeIfPresent(Backend.self, forKey: .backend) ?? .codex
        timeout = try values.decodeIfPresent(Double.self, forKey: .timeout) ?? 75
        shortcut = try values.decodeIfPresent(Int.self, forKey: .shortcut) ?? 0
        replacementStyle = try values.decodeIfPresent(ReplacementStyle.self, forKey: .replacementStyle) ?? .translationOnly
        notes = try values.decodeIfPresent(Bool.self, forKey: .notes) ?? false
        executablePaths = try values.decodeIfPresent([String: String].self, forKey: .executablePaths) ?? [:]
        models = try values.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shurufa", isDirectory: true)
    }
    public static var file: URL { directory.appendingPathComponent("settings.json") }
    public static func load() -> Configuration {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(Configuration.self, from: data) else { return Configuration() }
        return value
    }
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file, options: .atomic)
    }
}

public enum TranslationError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public enum TranslationPrompt {
    private struct NotesRequest: Encodable { let text: String; let notes: Bool }

    public static func make(_ text: String, notes: Bool = false) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.message("请先选中需要翻译的文字。")
        }
        guard text.utf8.count <= 32_000 else {
            throw TranslationError.message("选中文字太长，请分段翻译（每次不超过 32 KB）。")
        }
        // 默认仍是纯 JSON 字符串，保持既有规则与行为；开启注释时才改用带 notes 的对象。
        let data: Data
        if notes { data = try JSONEncoder().encode(NotesRequest(text: text, notes: true)) }
        else { data = try JSONEncoder().encode(text) }
        return String(decoding: data, as: UTF8.self)
    }
}
