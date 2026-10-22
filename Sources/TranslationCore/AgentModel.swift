import Foundation

public struct AgentModel: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String = "") { self.id = id; self.name = name; self.detail = detail }

    static func decode(_ rows: [[String: Any]], backend: Backend) -> [AgentModel] {
        var seen = Set<String>()
        return rows.compactMap { row in
            let raw = (row["model"] as? String) ?? (row["value"] as? String) ?? (row["id"] as? String) ?? ""
            guard !raw.isEmpty else { return nil }
            let provider = row["provider"] as? String ?? ""
            let id = backend == .pi && !provider.isEmpty ? provider + "/" + raw : raw
            guard seen.insert(id).inserted else { return nil }
            let name = (row["displayName"] as? String) ?? (row["name"] as? String) ?? raw
            return AgentModel(id: id, name: backend == .pi && !provider.isEmpty ? name + " · " + provider : name, detail: row["description"] as? String ?? "")
        }
    }
}
