import Foundation
import AVFoundation
import Speech

public enum SpeechCaptureError: LocalizedError {
    case recognizerUnavailable
    case notAuthorized
    case engineAlreadyRunning
    case missingRecognitionRequest
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "语音识别当前不可用。"
        case .notAuthorized:
            return "没有获得麦克风或语音识别权限。"
        case .engineAlreadyRunning:
            return "录音已经在进行中。"
        case .missingRecognitionRequest:
            return "语音识别请求尚未初始化。"
        case .noTranscript:
            return "未识别到语音内容。"
        }
    }
}

@MainActor
public final class SpeechCaptureService: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var liveTranscript = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    public override init() {
        super.init()
    }

    public func start() async throws {
        guard !isRecording else {
            throw SpeechCaptureError.engineAlreadyRunning
        }
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechCaptureError.recognizerUnavailable
        }

        let speechAuthorized = await requestSpeechAuthorization()
        let micAuthorized = await requestMicrophoneAuthorization()
        guard speechAuthorized && micAuthorized else {
            throw SpeechCaptureError.notAuthorized
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        liveTranscript = ""
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let text = result?.bestTranscription.formattedString {
                    self?.liveTranscript = text
                }
                if error != nil || result?.isFinal == true {
                    self?.stopInternally()
                }
            }
        }
    }

    public func stop() async throws -> String {
        guard isRecording else {
            let trimmed = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw SpeechCaptureError.noTranscript
            }
            return trimmed
        }

        recognitionRequest?.endAudio()
        stopInternally()
        try await Task.sleep(for: .milliseconds(300))
        let trimmed = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw SpeechCaptureError.noTranscript
        }
        return trimmed
    }

    private func stopInternally() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

