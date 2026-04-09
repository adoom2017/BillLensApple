import Foundation
import AVFoundation
import Speech

public enum SpeechCaptureError: LocalizedError {
    case recognizerUnavailable
    case notAuthorized
    case engineAlreadyRunning
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "语音识别当前不可用。"
        case .notAuthorized:
            return "没有获得麦克风或语音识别权限。"
        case .engineAlreadyRunning:
            return "录音已经在进行中。"
        case .noTranscript:
            return "未识别到语音内容。"
        }
    }
}

// ---------------------------------------------------------------------------
// Non-isolated audio engine wrapper.
// AVAudioEngine's realtime tap callbacks run on audio threads. If the engine
// lives inside a @MainActor class, Swift 6 strict concurrency propagates the
// actor isolation to internal AVFAudio callbacks and traps. Keeping audio ops
// in a plain (non-isolated) class avoids this entirely.
// ---------------------------------------------------------------------------
private final class AudioCaptureEngine: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var latestTranscript = ""
    private let finishSemaphore = DispatchSemaphore(value: 0)

    func start(onPartial: @escaping @Sendable (String) -> Void,
               onFinish: @escaping @Sendable () -> Void) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechCaptureError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        latestTranscript = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString {
                self?.latestTranscript = text
                onPartial(text)
            }
            if error != nil || result?.isFinal == true {
                self?.finishSemaphore.signal()
                self?.teardown()
                onFinish()
            }
        }
    }

    func stop() -> String {
        // Tell recognizer no more audio; let it process the remaining buffer.
        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // Wait up to 1.5s for the recognizer to deliver the final result.
        _ = finishSemaphore.wait(timeout: .now() + 1.5)
        // Clean up whatever is left.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        return latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        teardown()
        latestTranscript = ""
    }

    private func teardown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }
}

// ---------------------------------------------------------------------------
// Public @MainActor service — thin shell around AudioCaptureEngine.
// Owns @Published state for SwiftUI and delegates audio work to the
// non-isolated engine above.
// ---------------------------------------------------------------------------
@MainActor
public final class SpeechCaptureService: NSObject, ObservableObject {
    public static let shared = SpeechCaptureService()

    @Published public private(set) var isRecording = false
    @Published public private(set) var liveTranscript = ""

    private let engine = AudioCaptureEngine()
    private var permissionsGranted = false

    public override init() {
        super.init()
    }

    /// Request mic + speech permissions once at app launch.
    public nonisolated func bootstrapPermissions() async {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let mic = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        await MainActor.run {
            self.permissionsGranted = speech && mic
        }
    }

    public func start() throws {
        guard !isRecording else {
            throw SpeechCaptureError.engineAlreadyRunning
        }
        guard permissionsGranted else {
            throw SpeechCaptureError.notAuthorized
        }

        try engine.start(
            onPartial: { [weak self] text in
                Task { @MainActor in
                    self?.liveTranscript = text
                }
            },
            onFinish: { [weak self] in
                Task { @MainActor in
                    self?.isRecording = false
                }
            }
        )
        liveTranscript = ""
        isRecording = true
    }

    public func stop() throws -> String {
        guard isRecording else {
            let trimmed = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw SpeechCaptureError.noTranscript }
            return trimmed
        }

        isRecording = false
        let transcript = engine.stop()
        liveTranscript = transcript
        if transcript.isEmpty { throw SpeechCaptureError.noTranscript }
        return transcript
    }

    public func cancel() {
        engine.cancel()
        isRecording = false
        liveTranscript = ""
    }
}
