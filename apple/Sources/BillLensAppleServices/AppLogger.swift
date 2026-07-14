import Foundation

public actor AppLogger {
    public static let shared = AppLogger()

    private let fileURL: URL

    private init() {
        do {
            fileURL = try Self.resolveLogFileURL()
        } catch {
            preconditionFailure("初始化日志目录失败：\(error.localizedDescription)")
        }
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
        do {
            return try resolveLogFileURL().path
        } catch {
            preconditionFailure("解析日志文件路径失败：\(error.localizedDescription)")
        }
    }

    private nonisolated static func resolveLogFileURL() throws -> URL {
        let supportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportURL
            .appendingPathComponent("BillLensApple", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("billlens.log")
    }

    private func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            precondition(
                FileManager.default.createFile(atPath: fileURL.path, contents: data),
                "创建日志文件失败：\(fileURL.path)"
            )
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            preconditionFailure("写入日志文件失败：\(error.localizedDescription)")
        }
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func timestamp() -> String {
        Self.tsFormatter.string(from: .now)
    }
}
