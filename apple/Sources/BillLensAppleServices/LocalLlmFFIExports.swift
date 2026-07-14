import Darwin
import Foundation

@_cdecl("billlens_swift_local_llm_run")
public func billlens_swift_local_llm_run(
    _ request: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let request, let requestJSON = String(validatingCString: request) else {
        return strdup(
            #"{"schema_version":1,"status":"error","code":"invalid_runtime_response","message":"本地模型请求不是有效 UTF-8。"}"#
        )
    }
    return strdup(LocalLlmRuntime.shared.run(requestJSON: requestJSON))
}

@_cdecl("billlens_swift_local_llm_cancel")
public func billlens_swift_local_llm_cancel() {
    LocalLlmRuntime.shared.cancel()
}

@_cdecl("billlens_swift_local_llm_unload")
public func billlens_swift_local_llm_unload() {
    LocalLlmRuntime.shared.unload()
}

@_cdecl("billlens_swift_local_llm_free_string")
public func billlens_swift_local_llm_free_string(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}
