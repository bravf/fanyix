import Foundation
import Darwin

/// Process + Pipe 直连 JSONL，所有协议状态在 MainActor 串行更新。
@MainActor
final class JSONLineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var events: [[String: Any]] = []
    private var eventWaiter: CheckedContinuation<[String: Any], Error>?
    private(set) var closed = false
    private var closedError: Error = TranslationError.message("Agent 已断开。")
    var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }
    var pendingCount: Int { pending.count + (eventWaiter == nil ? 0 : 1) }

    init(launch: AgentLaunch, directory: URL) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // 同一管道按读取顺序入队；独立 Task 的调度顺序并不保证 FIFO。
            DispatchQueue.main.async { [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { [weak self] in self?.close(TranslationError.message("Agent 进程退出，状态码 " + String(status) + "。")) }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            closed = true
            throw TranslationError.message("无法启动 Agent：" + error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        if data.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            close(TranslationError.message("Agent 输出流已关闭。"))
            return
        }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            guard line.count <= 4_000_000, let object = try? JSONSerialization.jsonObject(with: line), let message = object as? [String: Any] else {
                close(TranslationError.message("Agent 返回无效或过大的 JSONL 消息。")); return
            }
            route(message)
            if closed { return }
        }
        if buffer.count > 4_000_000 { close(TranslationError.message("Agent 消息超过限制。")) }
    }

    private func route(_ message: [String: Any]) {
        if message["type"] as? String == "control_request", let id = message["request_id"] {
            try? send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Translation has no interactive tools."]])
            return
        }
        if message["type"] as? String == "control_response", let response = message["response"] as? [String: Any], let id = response["request_id"] as? String {
            guard let waiter = pending.removeValue(forKey: id) else { return }
            if response["subtype"] as? String == "error" { waiter.resume(throwing: TranslationError.message(response["error"] as? String ?? "Claude 控制请求失败。")) }
            else { waiter.resume(returning: response["response"] as? [String: Any] ?? [:]) }
            return
        }
        if let id = message["id"], let method = message["method"] as? String {
            _ = method
            try? send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Translation has no interactive tools."]])
            return
        }
        let key = (message["id"] as? String) ?? (message["id"] as? NSNumber)?.stringValue
        if let key, let waiter = pending.removeValue(forKey: key) {
            if let error = message["error"], !(error is NSNull) {
                let detail = (error as? String) ?? (error as? [String: Any])?["message"] as? String ?? "Agent 请求失败。"
                waiter.resume(throwing: TranslationError.message(detail))
            } else if message["success"] as? Bool == false { waiter.resume(throwing: TranslationError.message("Agent 请求失败。")) }
            else { waiter.resume(returning: (message["result"] as? [String: Any]) ?? (message["data"] as? [String: Any]) ?? [:]) }
        } else if let waiter = eventWaiter {
            eventWaiter = nil; waiter.resume(returning: message)
        } else {
            if events.count >= 4096 { close(TranslationError.message("Agent 事件过多。")) }
            else { events.append(message) }
        }
    }

    func send(_ message: [String: Any]) throws {
        guard !closed, process.isRunning else { throw closedError }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { close(error); throw error }
    }

    func request(_ method: String, _ params: [String: Any] = [:], pi: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            guard !closed else { continuation.resume(throwing: closedError); return }
            pending[id] = continuation
            var message: [String: Any] = pi ? params : ["jsonrpc": "2.0", "method": method, "params": params]
            if pi { message["type"] = method }
            message["id"] = id
            do { try send(message) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    func nextEvent() async throws -> [String: Any] {
        try Task.checkCancellation()
        if !events.isEmpty { return events.removeFirst() }
        guard !closed else { throw closedError }
        return try await withCheckedThrowingContinuation { continuation in eventWaiter = continuation }
    }

    func controlRequest(_ request: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            guard !closed else { continuation.resume(throwing: closedError); return }
            pending[id] = continuation
            do { try send(["type": "control_request", "request_id": id, "request": request]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    func discardEvents() { events.removeAll(keepingCapacity: true) }

    func close(_ error: Error = TranslationError.message("Agent 连接已关闭。")) {
        guard !closed else { return }
        closed = true; closedError = error
        output.fileHandleForReading.readabilityHandler = nil
        for waiter in pending.values { waiter.resume(throwing: error) }
        pending.removeAll()
        eventWaiter?.resume(throwing: error); eventWaiter = nil
        events.removeAll(); buffer.removeAll()
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            let pid = process.processIdentifier
            // 仅在已确认独立进程组时清理该组，否则只终止本应用持有的子进程。
            let ownGroup = getpgid(pid) == pid
            if ownGroup { kill(-pid, SIGTERM) } else { process.terminate() }
            let child = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard child.isRunning else { return }
                if ownGroup { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
    }
}
