import Foundation
import PDFKit
import UniformTypeIdentifiers

/// 交给 Rust `parse_statement` 的来源。`content` 对 eml 是原始字节的 base64，其余为 UTF-8 文本。
public struct StatementSourcePayload: Sendable {
    public enum Kind: String, Sendable {
        case eml
        case html
        case pdfText = "pdf_text"
    }

    public let kind: Kind
    public let content: String

    public init(kind: Kind, content: String) {
        self.kind = kind
        self.content = content
    }
}

public enum StatementImportError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case unreadable
    case passwordRequired
    case wrongPassword
    case noText

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            return "不支持的账单文件「\(name)」，请选择 .eml、.html 或 PDF。"
        case .unreadable:
            return "无法读取所选账单文件。"
        case .passwordRequired:
            return "该 PDF 已加密，请输入密码。"
        case .wrongPassword:
            return "PDF 密码不正确。"
        case .noText:
            return "PDF 中没有可提取的文字，请改用邮件文件导入。"
        }
    }
}

public enum StatementImportService {
    public static let emailType = UTType("com.apple.mail.email") ?? UTType(filenameExtension: "eml") ?? .data
    public static let supportedTypes: [UTType] = [emailType, .html, .pdf]

    /// 读取账单文件。加密 PDF 未提供密码时抛出 `.passwordRequired`；密码不保存也不写日志。
    public static func load(from url: URL, password: String? = nil) throws -> StatementSourcePayload {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        switch url.pathExtension.lowercased() {
        case "eml":
            let data = try readData(url)
            return StatementSourcePayload(kind: .eml, content: data.base64EncodedString())
        case "html", "htm":
            let data = try readData(url)
            guard let html = String(data: data, encoding: .utf8) else { throw StatementImportError.unreadable }
            return StatementSourcePayload(kind: .html, content: html)
        case "pdf":
            return StatementSourcePayload(kind: .pdfText, content: try pdfText(url, password: password))
        default:
            throw StatementImportError.unsupportedFile(url.lastPathComponent)
        }
    }

    private static func readData(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StatementImportError.unreadable
        }
    }

    private static func pdfText(_ url: URL, password: String?) throws -> String {
        guard let document = PDFDocument(url: url) else { throw StatementImportError.unreadable }
        if document.isLocked {
            guard let password else { throw StatementImportError.passwordRequired }
            guard document.unlock(withPassword: password) else { throw StatementImportError.wrongPassword }
        }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pages.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StatementImportError.noText
        }
        return text
    }
}

/// iOS 分享扩展写入、主 App 读取的账单收件箱（App Group 容器内）。
/// 扩展侧有一份独立的写入实现，目录名与 App Group 必须与这里保持一致。
public enum StatementInbox {
    public static let appGroupIdentifier = "group.com.shendongchun.BillLensApple"
    static let directoryName = "StatementInbox"

    /// 只有 iOS 有分享扩展。macOS 不访问 group 容器：未声明 App Group 时
    /// macOS 15 会为此弹出「访问其他 App 的数据」授权框。
    public static var directory: URL? {
        #if os(iOS)
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(directoryName, isDirectory: true)
        #else
        nil
        #endif
    }

    /// 最早写入的一个账单文件；忽略扩展写入中的临时文件。
    public static func oldestFile() -> URL? {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        return files
            .filter { !$0.lastPathComponent.hasSuffix(".partial") }
            .min { creationDate($0) < creationDate($1) }
    }

    public static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.log("statement.inbox.remove_failed", error.localizedDescription)
        }
    }

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
