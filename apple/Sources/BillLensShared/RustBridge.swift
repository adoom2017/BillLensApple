import Foundation
import CBillLensRustBridge

public enum RustBridgeError: LocalizedError {
    case missingData
    case invalidResponse
    case engineError(String)

    public var errorDescription: String? {
        switch self {
        case .missingData:
            return "Rust 引擎没有返回数据。"
        case .invalidResponse:
            return "Rust 引擎返回了无效响应。"
        case .engineError(let message):
            return message
        }
    }
}

public struct SttStopResponse: Decodable, Sendable {
    public let sessionId: String
    public let transcript: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcript
    }
}

public struct SttStartResponse: Decodable, Sendable {
    public let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

public struct EmptyResponse: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}

public struct RustBridge: Sendable {
    public init() {}

    /// Register Swift STT C functions with the Rust core. Call once at app launch.
    public static func registerSttBackend() {
        billlens_register_stt_backend(
            billlens_swift_stt_start,
            billlens_swift_stt_stop,
            billlens_swift_stt_cancel,
            billlens_swift_stt_free_string
        )
    }

    public func send<Response: Decodable>(_ payload: [String: Any]) throws -> Response {
        let jsonString = try encodePayload(payload)
        let responseString = try executeEncoded(jsonString)
        return try decodeEnvelope(responseString)
    }

    @MainActor
    public func sendAsync<Response: Decodable>(_ payload: [String: Any]) async throws -> Response {
        let jsonString = try encodePayload(payload)
        let responseString = try await Task.detached(priority: .userInitiated) {
            try executeEncoded(jsonString)
        }.value
        return try decodeEnvelope(responseString)
    }

    private func encodePayload(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw RustBridgeError.invalidResponse
        }
        return jsonString
    }
}

private func executeEncoded(_ jsonString: String) throws -> String {
    let resultPointer = jsonString.withCString { cString in
        billlens_handle_request(cString)
    }
    guard let resultPointer else {
        throw RustBridgeError.invalidResponse
    }

    defer { billlens_free_string(resultPointer) }

    let responseString = String(cString: resultPointer)
    return responseString
}

private func decodeEnvelope<Response: Decodable>(_ responseString: String) throws -> Response {
    let decoder = JSONDecoder()
    guard let responseData = responseString.data(using: .utf8) else {
        throw RustBridgeError.invalidResponse
    }
    let envelope = try decoder.decode(EngineEnvelope<Response>.self, from: responseData)
    if envelope.ok, let data = envelope.data {
        return data
    }
    throw RustBridgeError.engineError(envelope.error ?? "Rust 引擎执行失败。")
}
