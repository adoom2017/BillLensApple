import Foundation

public actor AppLogger {
    public static let shared = AppLogger()

    private let fileURL: URL

    private init() {
        let supportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = (supportURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("BillLensApple", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("billlens.log")
    }

    public func log(_ stage: String, _ message: String) {
        let line = "\(timestamp()) [SWIFT] [\(stage)] \(message)"
        print(line)
        append(line)
    }

    public nonisolated static func log(_ stage: String, _ message: String) {
        Task {
            await AppLogger.shared.log(stage, message)
        }
    }

    public nonisolated static var defaultLogFilePath: String {
        let supportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = (supportURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("BillLensApple", isDirectory: true)
        return directory.appendingPathComponent("billlens.log").path
    }

    private func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: data)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print("failed to append log file: \(error.localizedDescription)")
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: .now)
    }
}
