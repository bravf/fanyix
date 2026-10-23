import Foundation

/// 一条语言点注释；type 与 term、explain 一起由 Agent 以 JSON 返回。
public struct TranslationNote: Codable, Equatable, Identifiable {
    public var term: String
    public var kind: String
    public var explain: String

    public var id: String { term + "\u{1F}" + kind + "\u{1F}" + explain }

    /// 注释只针对英文语言点；含中文词或没有英文字母的条目不展示。
    public var isEnglish: Bool {
        term.range(of: "[A-Za-z]", options: .regularExpression) != nil
            && term.range(of: "\\p{Han}", options: .regularExpression) == nil
    }

    public init(term: String, kind: String = "", explain: String) {
        self.term = term; self.kind = kind; self.explain = explain
    }

    private enum CodingKeys: String, CodingKey { case term, kind = "type", explain }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        term = (try values.decodeIfPresent(String.self, forKey: .term) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        kind = (try values.decodeIfPresent(String.self, forKey: .kind) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        explain = (try values.decodeIfPresent(String.self, forKey: .explain) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TranslationResult: Equatable {
    public var translation: String
    public var notes: [TranslationNote]
    public init(translation: String, notes: [TranslationNote] = []) {
        self.translation = translation; self.notes = notes
    }
}

/// 解析 Agent 输出。注释关闭时输出仍是纯译文；格式异常时整段按译文处理，不影响替换。
public enum TranslationResponse {
    public static let maximumNotes = 20

    public static func parse(_ output: String) -> TranslationResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TranslationResult(translation: "") }
        if let payload = object(from: trimmed),
           let translation = (payload["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            return TranslationResult(translation: translation, notes: notes(from: payload["notes"]))
        }
        return TranslationResult(translation: trimmed)
    }

    private static func object(from output: String) -> [String: Any]? {
        var candidate = output
        if candidate.hasPrefix("```") {
            if let newline = candidate.firstIndex(of: "\n") {
                candidate = String(candidate[candidate.index(after: newline)...])
            }
            if let fence = candidate.range(of: "```", options: .backwards) {
                candidate = String(candidate[..<fence.lowerBound])
            }
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard candidate.hasPrefix("{"), candidate.hasSuffix("}"),
              let data = candidate.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func notes(from raw: Any?) -> [TranslationNote] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.prefix(maximumNotes).compactMap { row in
            let term = (row["term"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = (row["type"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let explain = (row["explain"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = TranslationNote(term: term, kind: kind, explain: explain)
            guard !explain.isEmpty, note.isEnglish else { return nil }
            return seen.insert(note.id).inserted ? note : nil
        }
    }
}
