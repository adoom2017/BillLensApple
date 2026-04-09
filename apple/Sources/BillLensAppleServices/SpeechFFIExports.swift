import Darwin
import Foundation

/// C exports invoked by Rust through the registered backend function pointers.
/// These run on a Rust FFI thread (NOT the main thread), so they can safely
/// `DispatchQueue.main.sync` into the @MainActor SpeechCaptureService.

@_cdecl("billlens_swift_stt_start")
public func billlens_swift_stt_start() -> Int32 {
    var code: Int32 = 0
    DispatchQueue.main.sync {
        do {
            try MainActor.assumeIsolated {
                try SpeechCaptureService.shared.start()
            }
        } catch {
            code = -1
        }
    }
    return code
}

@_cdecl("billlens_swift_stt_stop")
public func billlens_swift_stt_stop() -> UnsafeMutablePointer<CChar>? {
    var transcript: String = ""
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            transcript = (try? SpeechCaptureService.shared.stop()) ?? ""
        }
    }
    return strdup(transcript)
}

@_cdecl("billlens_swift_stt_cancel")
public func billlens_swift_stt_cancel() {
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            SpeechCaptureService.shared.cancel()
        }
    }
}

@_cdecl("billlens_swift_stt_free_string")
public func billlens_swift_stt_free_string(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
