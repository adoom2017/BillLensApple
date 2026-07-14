import Darwin
import Foundation
import llama

private struct LocalLlmRuntimeRequest: Decodable {
    let schemaVersion: UInt32
    let modelId: String
    let systemPrompt: String
    let userText: String
    let grammar: String
    let contextTokens: UInt32
    let maxOutputTokens: UInt32
    let deadlineMs: UInt64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelId = "model_id"
        case systemPrompt = "system_prompt"
        case userText = "user_text"
        case grammar
        case contextTokens = "context_tokens"
        case maxOutputTokens = "max_output_tokens"
        case deadlineMs = "deadline_ms"
    }
}

private struct LocalLlmRuntimeResponse: Encodable {
    let schemaVersion: UInt32
    let status: String
    let modelId: String?
    let content: String?
    let elapsedMs: UInt64?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case modelId = "model_id"
        case content
        case elapsedMs = "elapsed_ms"
        case code
        case message
    }

    static func success(modelId: String, content: String, elapsedMs: UInt64) -> Self {
        Self(
            schemaVersion: 1,
            status: "success",
            modelId: modelId,
            content: content,
            elapsedMs: elapsedMs,
            code: nil,
            message: nil
        )
    }

    static func failure(code: String, message: String) -> Self {
        Self(
            schemaVersion: 1,
            status: "error",
            modelId: nil,
            content: nil,
            elapsedMs: nil,
            code: code,
            message: message
        )
    }
}

private struct LocalLlmRuntimeFailure: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

public final class LocalLlmRuntime: @unchecked Sendable {
    public static let shared = LocalLlmRuntime()

    private let queue = DispatchQueue(label: "BillLensApple.LocalLlmRuntime", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancellationReason: String?
    private var cancellationEpoch: UInt64 = 0
    private var unloadPending = false
    private var applicationIsBackgrounded = false
    private var session: LlamaSession?

    private init() {}

    public func run(requestJSON: String) -> String {
        do {
            let rawRequest: Any
            do {
                rawRequest = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8))
            } catch {
                throw LocalLlmRuntimeFailure(
                    code: "invalid_runtime_request",
                    message: "本地模型请求不是有效 JSON：\(error.localizedDescription)"
                )
            }
            guard let requestObject = rawRequest as? [String: Any] else {
                throw LocalLlmRuntimeFailure(
                    code: "invalid_runtime_request",
                    message: "本地模型请求必须是 JSON 对象。"
                )
            }
            let expectedKeys: Set<String> = [
                "schema_version", "model_id", "system_prompt", "user_text", "grammar",
                "context_tokens", "max_output_tokens", "deadline_ms"
            ]
            guard Set(requestObject.keys) == expectedKeys else {
                throw LocalLlmRuntimeFailure(
                    code: "invalid_runtime_request",
                    message: "本地模型请求字段与运行时协议不一致。"
                )
            }
            let request: LocalLlmRuntimeRequest
            do {
                request = try JSONDecoder().decode(
                    LocalLlmRuntimeRequest.self,
                    from: Data(requestJSON.utf8)
                )
            } catch {
                throw LocalLlmRuntimeFailure(
                    code: "invalid_runtime_request",
                    message: "本地模型请求不符合运行时协议：\(error.localizedDescription)"
                )
            }
            guard request.schemaVersion == 1 else {
                throw LocalLlmRuntimeFailure(
                    code: "invalid_runtime_request",
                    message: "不支持的本地模型请求版本：\(request.schemaVersion)"
                )
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let requestEpoch = currentCancellationEpoch()
            let content = try queue.sync {
                if let reason = beginRequest(expectedEpoch: requestEpoch) {
                    throw LocalLlmRuntimeFailure(
                        code: reason,
                        message: "本地推理请求在执行前已被终止：\(reason)"
                    )
                }
                let selected = try LocalModelManager.resolvedSelectedModel()
                guard selected.0.modelId == request.modelId else {
                    throw LocalLlmRuntimeFailure(
                        code: "model_not_installed",
                        message: "请求模型与当前选择的已安装模型不一致。"
                    )
                }
                guard request.contextTokens == selected.0.contextTokens,
                      request.maxOutputTokens == selected.0.maxOutputTokens else {
                    throw LocalLlmRuntimeFailure(
                        code: "invalid_runtime_response",
                        message: "请求的上下文参数与模型清单不一致。"
                    )
                }
                let availableMemory = try LocalModelManager.availableMemory()
                guard availableMemory >= selected.0.minimumAvailableMemory else {
                    throw LocalLlmRuntimeFailure(
                        code: "out_of_memory",
                        message: "加载模型前可用内存不足：需要 \(selected.0.minimumAvailableMemory)，当前 \(availableMemory)。"
                    )
                }
                if session?.modelId != request.modelId {
                    session = nil
                    session = try LlamaSession(
                        modelId: request.modelId,
                        modelURL: selected.1,
                        contextTokens: request.contextTokens
                    )
                    AppLogger.log("local_llm.load", "model_id=\(request.modelId)")
                }
                guard let session else {
                    throw LocalLlmRuntimeFailure(
                        code: "load_failed",
                        message: "本地模型会话没有成功创建。"
                    )
                }
                return try session.generate(
                    systemPrompt: request.systemPrompt,
                    userText: request.userText,
                    grammar: request.grammar,
                    maxOutputTokens: request.maxOutputTokens,
                    deadlineMs: request.deadlineMs,
                    cancellationReason: {
                        self.cancellationReason(since: requestEpoch)
                    }
                )
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            AppLogger.log(
                "local_llm.run",
                "model_id=\(request.modelId) elapsed_ms=\(elapsed)"
            )
            return encode(.success(modelId: request.modelId, content: content, elapsedMs: elapsed))
        } catch let failure as LocalLlmRuntimeFailure {
            return encode(.failure(code: failure.code, message: failure.message))
        } catch let error as LocalModelManagerError {
            let code: String
            switch error {
            case .modelNotInstalled:
                code = "model_not_installed"
            case .insufficientMemory:
                code = "out_of_memory"
            default:
                code = "load_failed"
            }
            return encode(.failure(code: code, message: error.localizedDescription))
        } catch {
            return encode(.failure(code: "inference_failed", message: error.localizedDescription))
        }
    }

    public func cancel(reason: String = "cancelled") {
        precondition(
            ["cancelled", "app_backgrounded", "memory_pressure"].contains(reason),
            "不支持的本地推理取消原因：\(reason)"
        )
        cancellationLock.lock()
        cancellationEpoch &+= 1
        cancellationReason = reason
        cancellationLock.unlock()
    }

    public func unload(reason: String = "cancelled") {
        precondition(
            ["cancelled", "app_backgrounded", "memory_pressure"].contains(reason),
            "不支持的本地推理卸载原因：\(reason)"
        )
        cancellationLock.lock()
        cancellationEpoch &+= 1
        cancellationReason = reason
        unloadPending = true
        cancellationLock.unlock()
        queue.sync {
            session = nil
        }
        AppLogger.log("local_llm.unload", "reason=\(reason)")
        cancellationLock.lock()
        unloadPending = false
        cancellationLock.unlock()
    }

    public func suspendForBackground() {
        cancellationLock.lock()
        applicationIsBackgrounded = true
        cancellationLock.unlock()
        unload(reason: "app_backgrounded")
    }

    public func resumeAfterBackground() {
        cancellationLock.lock()
        applicationIsBackgrounded = false
        cancellationEpoch &+= 1
        cancellationReason = "app_backgrounded"
        cancellationLock.unlock()
        AppLogger.log("local_llm.resume", "reason=app_active")
    }

    private func currentCancellationEpoch() -> UInt64 {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationEpoch
    }

    private func beginRequest(expectedEpoch: UInt64) -> String? {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        if applicationIsBackgrounded {
            return "app_backgrounded"
        }
        guard !unloadPending, cancellationEpoch == expectedEpoch else {
            guard let cancellationReason else {
                preconditionFailure("取消 epoch 已变化，但取消原因缺失。")
            }
            return cancellationReason
        }
        return nil
    }

    private func cancellationReason(since requestEpoch: UInt64) -> String? {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        if applicationIsBackgrounded {
            return "app_backgrounded"
        }
        return cancellationEpoch == requestEpoch ? nil : cancellationReason
    }

    private func encode(_ response: LocalLlmRuntimeResponse) -> String {
        do {
            let data = try JSONEncoder().encode(response)
            guard let text = String(data: data, encoding: .utf8) else {
                preconditionFailure("本地模型响应编码后不是 UTF-8。")
            }
            return text
        } catch {
            preconditionFailure("编码本地模型响应失败：\(error.localizedDescription)")
        }
    }
}

private final class LlamaSession {
    let modelId: String
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch

    init(modelId: String, modelURL: URL, contextTokens: UInt32) throws {
        self.modelId = modelId
        llama_backend_init()

        var modelParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
        #else
        modelParameters.n_gpu_layers = Int32.max
        #endif
        guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParameters) else {
            llama_backend_free()
            throw LocalLlmRuntimeFailure(code: "load_failed", message: "无法加载 GGUF 模型文件。")
        }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = contextTokens
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)
        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LocalLlmRuntimeFailure(code: "load_failed", message: "无法创建 llama.cpp 上下文。")
        }
        context = loadedContext
        let allocatedBatch = llama_batch_init(Int32(contextTokens), 0, 1)
        guard allocatedBatch.token != nil,
              allocatedBatch.pos != nil,
              allocatedBatch.n_seq_id != nil,
              allocatedBatch.seq_id != nil,
              allocatedBatch.logits != nil else {
            llama_batch_free(allocatedBatch)
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LocalLlmRuntimeFailure(
                code: "out_of_memory",
                message: "无法分配 llama.cpp 推理批次内存。"
            )
        }
        batch = allocatedBatch
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    func generate(
        systemPrompt: String,
        userText: String,
        grammar: String,
        maxOutputTokens: UInt32,
        deadlineMs: UInt64,
        cancellationReason: () -> String?
    ) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        let prompt = try applyChatTemplate(systemPrompt: systemPrompt, userText: userText)
        let promptTokens = try tokenize(prompt)
        let contextCapacity = Int(llama_n_ctx(context))
        guard promptTokens.count + Int(maxOutputTokens) <= contextCapacity else {
            throw LocalLlmRuntimeFailure(
                code: "inference_failed",
                message: "提示词和最大输出超过模型上下文长度。"
            )
        }
        resetBatch()
        for (index, token) in promptTokens.enumerated() {
            addToken(token, position: Int32(index), logits: index == promptTokens.count - 1)
        }
        guard llama_decode(context, batch) == 0 else {
            throw LocalLlmRuntimeFailure(code: "inference_failed", message: "本地模型提示词解码失败。")
        }

        let samplerParameters = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParameters) else {
            throw LocalLlmRuntimeFailure(code: "inference_failed", message: "无法创建本地模型采样器。")
        }
        defer { llama_sampler_free(sampler) }
        let grammarSampler = grammar.withCString {
            llama_sampler_init_grammar(vocab, $0, "root")
        }
        guard let grammarSampler else {
            throw LocalLlmRuntimeFailure(code: "inference_failed", message: "无法创建 JSON grammar 采样器。")
        }
        llama_sampler_chain_add(sampler, grammarSampler)
        guard let greedySampler = llama_sampler_init_greedy() else {
            throw LocalLlmRuntimeFailure(code: "inference_failed", message: "无法创建贪心采样器。")
        }
        llama_sampler_chain_add(sampler, greedySampler)

        let start = DispatchTime.now().uptimeNanoseconds
        var position = Int32(promptTokens.count)
        var utf8Buffer: [CChar] = []
        var output = ""
        for _ in 0..<maxOutputTokens {
            if let reason = cancellationReason() {
                throw LocalLlmRuntimeFailure(code: reason, message: "本地推理已被终止：\(reason)")
            }
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if elapsedMs >= deadlineMs {
                throw LocalLlmRuntimeFailure(code: "timeout", message: "本地推理超过 \(deadlineMs) 毫秒。")
            }

            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) {
                if !utf8Buffer.isEmpty {
                    guard let tail = strictUTF8(utf8Buffer) else {
                        throw LocalLlmRuntimeFailure(
                            code: "invalid_runtime_response",
                            message: "本地模型输出包含无效 UTF-8。"
                        )
                    }
                    output += tail
                }
                guard !output.isEmpty else {
                    throw LocalLlmRuntimeFailure(
                        code: "invalid_runtime_response",
                        message: "本地模型没有生成内容。"
                    )
                }
                return output
            }
            utf8Buffer.append(contentsOf: try tokenPiece(token))
            if let text = strictUTF8(utf8Buffer) {
                output += text
                utf8Buffer.removeAll(keepingCapacity: true)
            }

            resetBatch()
            addToken(token, position: position, logits: true)
            guard llama_decode(context, batch) == 0 else {
                throw LocalLlmRuntimeFailure(code: "inference_failed", message: "本地模型 token 解码失败。")
            }
            position += 1
        }
        throw LocalLlmRuntimeFailure(
            code: "invalid_runtime_response",
            message: "本地模型达到最大输出 token，未正常结束 JSON。"
        )
    }

    private func applyChatTemplate(systemPrompt: String, userText: String) throws -> String {
        guard let template = llama_model_chat_template(model, nil) else {
            throw LocalLlmRuntimeFailure(
                code: "unsupported_chat_template",
                message: "GGUF 模型不包含可用的 chat template。"
            )
        }
        return try "system".withCString { systemRole in
            try "user".withCString { userRole in
                try systemPrompt.withCString { systemContent in
                    try userText.withCString { userContent in
                        let messages = [
                            llama_chat_message(role: systemRole, content: systemContent),
                            llama_chat_message(role: userRole, content: userContent)
                        ]
                        let required = messages.withUnsafeBufferPointer { buffer in
                            llama_chat_apply_template(
                                template,
                                buffer.baseAddress,
                                buffer.count,
                                true,
                                nil,
                                0
                            )
                        }
                        guard required > 0 else {
                            throw LocalLlmRuntimeFailure(
                                code: "unsupported_chat_template",
                                message: "模型 chat template 计算输出长度失败。"
                            )
                        }
                        var output = [CChar](repeating: 0, count: Int(required) + 1)
                        let written = messages.withUnsafeBufferPointer { buffer in
                            output.withUnsafeMutableBufferPointer { outputBuffer in
                                llama_chat_apply_template(
                                    template,
                                    buffer.baseAddress,
                                    buffer.count,
                                    true,
                                    outputBuffer.baseAddress,
                                    Int32(outputBuffer.count)
                                )
                            }
                        }
                        guard written >= 0, written <= required else {
                            throw LocalLlmRuntimeFailure(
                                code: "unsupported_chat_template",
                                message: "模型 chat template 输出失败。"
                            )
                        }
                        guard let prompt = strictUTF8(Array(output.prefix(Int(written)))) else {
                            throw LocalLlmRuntimeFailure(
                                code: "unsupported_chat_template",
                                message: "模型 chat template 输出不是有效 UTF-8。"
                            )
                        }
                        return prompt
                    }
                }
            }
        }
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let capacity = text.utf8.count + 2
        var tokens = [llama_token](repeating: 0, count: capacity)
        let count = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_tokenize(
                vocab,
                text,
                Int32(text.utf8.count),
                buffer.baseAddress,
                Int32(buffer.count),
                true,
                true
            )
        }
        guard count >= 0 else {
            throw LocalLlmRuntimeFailure(code: "inference_failed", message: "本地模型分词失败。")
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenPiece(_ token: llama_token) throws -> [CChar] {
        var buffer = [CChar](repeating: 0, count: 32)
        var count = buffer.withUnsafeMutableBufferPointer { pointer in
            llama_token_to_piece(vocab, token, pointer.baseAddress, Int32(pointer.count), 0, false)
        }
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = buffer.withUnsafeMutableBufferPointer { pointer in
                llama_token_to_piece(vocab, token, pointer.baseAddress, Int32(pointer.count), 0, false)
            }
        }
        guard count >= 0 else {
            throw LocalLlmRuntimeFailure(code: "invalid_runtime_response", message: "无法读取模型 token。")
        }
        return Array(buffer.prefix(Int(count)))
    }

    private func resetBatch() {
        batch.n_tokens = 0
    }

    private func addToken(_ token: llama_token, position: Int32, logits: Bool) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func strictUTF8(_ characters: [CChar]) -> String? {
        String(
            bytes: characters.map { UInt8(bitPattern: $0) },
            encoding: .utf8
        )
    }
}
