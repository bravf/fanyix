import Foundation

/// 一个原生客户端持有一个 Agent 子进程；切换后端、取消和异常时释放。
@MainActor
public final class NativeAgent {
    private var wire: JSONLineProcess?
    private var backend: Backend?
    private var overridePath = ""
    private var modelFingerprint = ""
    private var instructionsFingerprint: Data?
    private var claudeModels: [[String: Any]] = []
    private var codexThread: String?
    private var piSessionStarted = false
    private var operation: UUID?
    private let launchOverride: AgentLaunch?
    private let workspaceDirectory: URL
    public private(set) var executablePath: String?
    public var processIdentifier: Int32? { wire?.processIdentifier }
    var pendingCount: Int { wire?.pendingCount ?? 0 }
    public init(launchOverride: AgentLaunch? = nil, workspaceDirectory: URL = AgentWorkspace.directory) {
        self.launchOverride = launchOverride; self.workspaceDirectory = workspaceDirectory
    }

    public func translate(_ source: String, configuration: Configuration) async throws -> String {
        let prompt = try TranslationPrompt.make(source)
        return try await perform(configuration: configuration) { wire in
            wire.discardEvents()
            let output: String
            switch configuration.backend {
            case .codex: output = try await self.codex(prompt, model: configuration.selectedModel, wire: wire)
            case .claude: output = try await self.claude(prompt, wire: wire)
            case .pi: output = try await self.pi(prompt, model: configuration.selectedModel, wire: wire)
            }
            try Task.checkCancellation()
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.message("Agent 返回空译文，原文已保留。") }
            guard output.utf8.count <= 128_000 else { throw TranslationError.message("Agent 译文过长，原文已保留。") }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func listModels(configuration: Configuration) async throws -> [AgentModel] {
        var catalog = configuration
        catalog.models = [:]
        return try await perform(configuration: catalog) { wire in
            let rows: [[String: Any]]
            switch catalog.backend {
            case .codex:
                var all: [[String: Any]] = []; var cursor: String?; var seen = Set<String>()
                repeat {
                    var params: [String: Any] = ["limit": 100, "includeHidden": false]
                    if let cursor { params["cursor"] = cursor }
                    let page = try await wire.request("model/list", params)
                    all += page["data"] as? [[String: Any]] ?? []
                    cursor = page["nextCursor"] as? String
                    if let cursor, !seen.insert(cursor).inserted { throw TranslationError.message("Agent 模型列表分页异常。") }
                    guard seen.count < 100 else { throw TranslationError.message("模型列表过大。") }
                } while cursor != nil
                rows = all
            case .claude: rows = self.claudeModels
            case .pi:
                let response = try await wire.request("get_available_models", pi: true)
                rows = response["models"] as? [[String: Any]] ?? []
            }
            return AgentModel.decode(rows, backend: catalog.backend)
        }
    }

    private func perform<T>(configuration: Configuration, action: (JSONLineProcess) async throws -> T) async throws -> T {
        guard operation == nil else { throw TranslationError.message("正在翻译，请等待当前任务结束。") }
        try Task.checkCancellation()
        let id = UUID()
        operation = id
        let seconds = configuration.timeout.isFinite ? min(max(configuration.timeout, 0.1), 300) : 75
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.operation == id else { return }
            self.wire?.close(TranslationError.message("翻译超时，已终止 Agent，下次调用会自动重连。"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer { timeout.cancel(); operation = nil }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await connect(configuration)
                try Task.checkCancellation()
                guard let wire else { throw TranslationError.message("Agent 尚未启动。") }
                return try await action(wire)
            } catch {
                wire?.close(error)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.operation == id else { return }
                self.wire?.close(CancellationError())
            }
        })
    }

    private func connect(_ configuration: Configuration) async throws {
        let path = configuration.executablePaths[configuration.backend.rawValue] ?? ""
        let instructions = try AgentWorkspace.prepare(directory: workspaceDirectory)
        if let wire, !wire.closed, backend == configuration.backend, overridePath == path, modelFingerprint == configuration.selectedModel, instructionsFingerprint == instructions { return }
        close()
        var launch = try launchOverride ?? AgentLaunch.resolve(configuration.backend, override: path, workspaceDirectory: workspaceDirectory)
        if launchOverride == nil, configuration.backend == .claude, !configuration.selectedModel.isEmpty {
            launch = AgentLaunch(executable: launch.executable, arguments: launch.arguments + ["--model", configuration.selectedModel], environment: launch.environment)
        }
        let connected = try JSONLineProcess(launch: launch, directory: workspaceDirectory)
        wire = connected; backend = configuration.backend; overridePath = path; executablePath = launch.executable.path
        modelFingerprint = configuration.selectedModel
        instructionsFingerprint = instructions
        if configuration.backend == .codex {
            _ = try await connected.request("initialize", ["clientInfo": ["name": "shurufa", "title": "FanyiX", "version": "0.5.1"]])
            try connected.send(["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: String]])
        } else if configuration.backend == .pi {
            _ = try await connected.request("get_state", pi: true)
        } else {
            let response = try await connected.controlRequest(["subtype": "initialize", "hooks": [:] as [String: String]])
            claudeModels = response["models"] as? [[String: Any]] ?? []
        }
    }

    private func codex(_ prompt: String, model: String, wire: JSONLineProcess) async throws -> String {
        if codexThread == nil {
            var params: [String: Any] = ["cwd": workspaceDirectory.path, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true, "config": ["mcp_servers": [:] as [String: String], "web_search": "disabled"]]
            if !model.isEmpty { params["model"] = model }
            let result = try await wire.request("thread/start", params)
            guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else { throw TranslationError.message("Codex 没有返回 thread id。") }
            codexThread = thread
        }
        guard let thread = codexThread else { throw TranslationError.message("Codex 翻译会话尚未创建。") }
        var turnParams: [String: Any] = ["threadId": thread, "input": [["type": "text", "text": prompt, "text_elements": [] as [String]]], "approvalPolicy": "never"]
        if !model.isEmpty { turnParams["model"] = model }
        let started = try await wire.request("turn/start", turnParams)
        guard let turnID = (started["turn"] as? [String: Any])?["id"] as? String else { throw TranslationError.message("Codex 没有返回 turn id。") }
        var messages: [String: [String: Any]] = [:]
        var order: [String] = []
        func collect(_ item: [String: Any]) {
            guard item["type"] as? String == "agentMessage", let id = item["id"] as? String else { return }
            if messages[id] == nil { order.append(id) }; messages[id] = item
        }
        while true {
            let event = try await wire.nextEvent()
            let params = event["params"] as? [String: Any] ?? [:]
            guard params["threadId"] as? String == thread else { continue }
            if let eventTurn = params["turnId"] as? String, eventTurn != turnID { continue }
            if event["method"] as? String == "item/completed", let item = params["item"] as? [String: Any] { collect(item) }
            if event["method"] as? String == "turn/completed" {
                let turn = params["turn"] as? [String: Any] ?? [:]
                guard turn["id"] as? String == turnID else { continue }
                guard turn["status"] as? String == "completed" else { throw TranslationError.message((turn["error"] as? [String: Any])?["message"] as? String ?? "Codex 翻译失败或被中断。") }
                for item in turn["items"] as? [[String: Any]] ?? [] { collect(item) }
                let all = order.compactMap { messages[$0] }
                let final = all.filter { $0["phase"] as? String == "final_answer" }
                let output = (final.isEmpty ? all : final).compactMap { $0["text"] as? String }.joined(separator: "\n")
                return output
            }
        }
    }

    private func claude(_ prompt: String, wire: JSONLineProcess) async throws -> String {
        try wire.send(["type": "user", "message": ["role": "user", "content": prompt], "parent_tool_use_id": NSNull()])
        while true {
            let event = try await wire.nextEvent()
            guard event["type"] as? String == "result" else { continue }
            guard event["is_error"] as? Bool != true, event["subtype"] as? String == "success" else {
                throw TranslationError.message((event["errors"] as? [String])?.joined(separator: "；") ?? "Claude 翻译失败。")
            }
            return event["result"] as? String ?? ""
        }
    }

    private func pi(_ prompt: String, model: String, wire: JSONLineProcess) async throws -> String {
        if !piSessionStarted {
            let reset = try await wire.request("new_session", pi: true)
            guard reset["cancelled"] as? Bool != true else { throw TranslationError.message("Pi 未能创建翻译会话。") }
            if !model.isEmpty {
                guard let slash = model.firstIndex(of: "/"), slash != model.startIndex, model.index(after: slash) != model.endIndex else { throw TranslationError.message("Pi 模型 ID 需要使用 provider/model 格式。") }
                _ = try await wire.request("set_model", ["provider": String(model[..<slash]), "modelId": String(model[model.index(after: slash)...])], pi: true)
            }
            piSessionStarted = true
        }
        let ack = try await wire.request("prompt", ["message": prompt], pi: true)
        guard ack["disposition"] as? String != "handled", ack["agentInvoked"] as? Bool != false else { throw TranslationError.message("Pi 未执行翻译。") }
        var last: [String: Any] = [:]
        while true {
            let event = try await wire.nextEvent()
            if event["type"] as? String == "message_end", let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" { last = message }
            if event["type"] as? String == "agent_settled" {
                guard !["error", "aborted"].contains(last["stopReason"] as? String ?? "") else { throw TranslationError.message(last["errorMessage"] as? String ?? "Pi 翻译失败。") }
                return (last["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            }
        }
    }

    public func close() { wire?.close(); wire = nil; backend = nil; executablePath = nil; claudeModels = []; modelFingerprint = ""; instructionsFingerprint = nil; codexThread = nil; piSessionStarted = false }
}
