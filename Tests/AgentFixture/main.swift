import Foundation

let mode = CommandLine.arguments.dropFirst().first ?? "codex"
var thread = 0
var turn = 0
var selectedModel = ""
func emit(_ value: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: value)
    data.append(10)
    // 故意拆开 UTF-8 字节，验证跨 chunk 解码不丢字。
    let split = max(1, data.count / 2)
    try! FileHandle.standardOutput.write(contentsOf: data.prefix(split))
    try! FileHandle.standardOutput.write(contentsOf: data.dropFirst(split))
}
func reply(_ request: [String: Any], _ value: [String: Any] = [:]) {
    guard let id = request["id"] else { return }
    emit(mode == "pi" ? ["type": "response", "id": id, "success": true, "data": value] : ["id": id, "result": value])
}
while let line = readLine() {
    guard let data = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let method = request["method"] as? String ?? ""
    let type = request["type"] as? String ?? ""
    let params = request["params"] as? [String: Any] ?? [:]
    if type == "control_request", request["request"] is [String: Any], let id = request["request_id"] as? String {
        let models: [[String: Any]] = [["value": "fixture-small", "displayName": "Small", "description": "Fixture model"]]
        emit(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": ["models": models]]])
        continue
    }
    if method == "model/list" {
        if params["cursor"] == nil { reply(request, ["data": [["id": "internal-small", "model": "fixture-small", "displayName": "Small"]], "nextCursor": "page-2"]) }
        else { reply(request, ["data": [["id": "internal-large", "model": "fixture-large", "displayName": "Large"]]]) }
        continue
    }
    if type == "get_available_models" { reply(request, ["models": [["id": "fixture-small", "provider": "fixture", "name": "Small"]]]); continue }
    if type == "set_model" { selectedModel = (request["provider"] as? String ?? "") + "/" + (request["modelId"] as? String ?? ""); reply(request); continue }
    if type == "new_session" { thread += 1; turn = 0; reply(request); continue }
    if method == "initialize" || method == "thread/unsubscribe" || type == "get_state" { reply(request); continue }
    if method == "thread/start" {
        guard params["baseInstructions"] == nil, let cwd = params["cwd"] as? String, FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md").path) else { exit(4) }
        selectedModel = params["model"] as? String ?? ""; thread += 1; reply(request, ["thread": ["id": "thread-" + String(thread)]]); continue
    }
    if method == "turn/start" || type == "user" || type == "prompt" {
        if mode == "claude", thread == 0 { thread = 1 }
        turn += 1
        let turnID = "turn-" + String(turn)
        let input = params["input"] as? [[String: Any]]
        let prompt = (input?.first?["text"] as? String) ?? (request["message"] as? String) ?? ((request["message"] as? [String: Any])?["content"] as? String) ?? ""
        if prompt.contains("__BAD_JSON__") { print("invalid-json"); fflush(stdout); continue }
        if prompt.contains("__EXIT__") { exit(3) }
        if prompt.contains("__HANG__") { reply(request, mode == "codex" ? ["turn": ["id": turnID]] : [:]); continue }
        let text = prompt.contains("__EMPTY__") ? "" : prompt.contains("__MODEL__") ? selectedModel : prompt.contains("__SESSION__") ? String(thread) + "|" + String(turn) : "I might be a little late today. 🌏"
        if mode == "codex" {
            let id = params["threadId"] as? String ?? ""
            if turn > 1 {
                emit(["method": "item/completed", "params": ["threadId": id, "turnId": "old-turn", "item": ["id": "stale", "type": "agentMessage", "phase": "final_answer", "text": "STALE"]]])
                emit(["method": "turn/completed", "params": ["threadId": id, "turn": ["id": "old-turn", "status": "completed", "items": []]]])
            }
            emit(["method": "item/completed", "params": ["threadId": id, "turnId": turnID, "item": ["id": "commentary", "type": "agentMessage", "phase": "commentary", "text": "Thinking..."]]])
            emit(["method": "item/completed", "params": ["threadId": id, "turnId": turnID, "item": ["id": "final", "type": "agentMessage", "phase": "final_answer", "text": text]]])
            emit(["method": "turn/completed", "params": ["threadId": id, "turn": ["id": turnID, "status": "completed", "items": []]]])
            // 故意让最终事件先于 turn/start 响应，测试事件缓冲。
            reply(request, ["turn": ["id": turnID]])
        } else if mode == "claude" { emit(["type": "result", "subtype": "success", "result": text]) }
        else {
            emit(["type": "message_end", "message": ["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": text]]]])
            emit(["type": "agent_end"])
            reply(request)
            emit(["type": "agent_settled"])
        }
    }
}
