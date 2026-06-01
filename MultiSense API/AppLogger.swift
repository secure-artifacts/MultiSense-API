import Foundation
import os

/// 应用级文件日志器。
///
/// 目标：把"崩溃前发生了什么"持久化到磁盘，配合系统崩溃报告 (.ips) 定位偶发崩溃。
/// - 线程安全：所有写入走串行队列，可从 Vapor 的任意线程调用。
/// - 双通道：同时写本地文件 + os.Logger（Console.app 可见）。
/// - 自动轮转：单文件超过上限后归档为 .1，避免无限增长。
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    /// 日志级别。
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case crash = "CRASH"
    }

    /// 日志根目录：~/Library/Logs/MultiSense API/
    let logDirectory: URL
    /// 崩溃报告归档目录：~/Library/Logs/MultiSense API/crashes/
    let crashesDirectory: URL
    /// 主日志文件路径。
    private let logFileURL: URL
    /// 单个日志文件大小上限（5 MB），超过则轮转。
    private let maxLogFileSize: UInt64 = 5 * 1024 * 1024

    /// 串行队列，保证写入顺序与线程安全。
    private let queue = DispatchQueue(label: "com.Raz1ner.MultiSense-API.logger")
    /// 系统统一日志，便于在 Console.app 实时查看。
    private let osLog = os.Logger(subsystem: "com.Raz1ner.MultiSense-API", category: "app")

    private let dateFormatter: DateFormatter

    private init() {
        let logsBase = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/MultiSense API")
            // 极端兜底：拿不到 Library 目录时退回临时目录，保证仍能写日志
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MultiSense API Logs")

        logDirectory = logsBase
        crashesDirectory = logsBase.appendingPathComponent("crashes")
        logFileURL = logsBase.appendingPathComponent("app.log")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: crashesDirectory, withIntermediateDirectories: true)
    }

    /// 写入一条日志。
    func log(_ level: Level, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"

        // os.Logger 实时通道
        switch level {
        case .debug: osLog.debug("\(message, privacy: .public)")
        case .info: osLog.info("\(message, privacy: .public)")
        case .warn: osLog.warning("\(message, privacy: .public)")
        case .error, .crash: osLog.error("\(message, privacy: .public)")
        }

        // 文件通道（异步串行写）
        queue.async { [weak self] in
            self?.appendToFile(line)
        }
    }

    /// 记录"面包屑"——崩溃前的关键动作轨迹。
    func breadcrumb(_ message: String) {
        log(.info, "🍞 \(message)")
    }

    /// 记录一个捕获到的错误（含完整描述）。
    func error(_ context: String, _ error: Error) {
        let nsError = error as NSError
        let detail = """
        \(context) | \(error.localizedDescription) \
        | domain=\(nsError.domain) code=\(nsError.code) \
        | userInfo=\(nsError.userInfo)
        """
        log(.error, detail)
    }

    /// 记录崩溃信息（由崩溃处理器调用，尽量同步落盘）。
    func logCrashSync(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [CRASH] \(message)\n"
        queue.sync {
            appendToFile(line)
        }
    }

    // MARK: - 文件写入

    private func appendToFile(_ line: String) {
        rotateIfNeeded()
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            try? data.write(to: logFileURL)
            return
        }
        // 追加写
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// 超过大小上限时轮转：app.log -> app.log.1（覆盖旧归档）。
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogFileSize else { return }

        let archived = logDirectory.appendingPathComponent("app.log.1")
        try? fm.removeItem(at: archived)
        try? fm.moveItem(at: logFileURL, to: archived)
    }
}
