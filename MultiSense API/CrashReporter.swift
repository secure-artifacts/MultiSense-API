import Foundation
import Darwin
import AppKit

// MARK: - C 层信号处理（async-signal-safe）

/// 崩溃专用日志文件描述符。信号处理函数里只能用它做 write(2)，
/// 不能调用任何会分配内存 / 非可重入的 API（含大多数 Foundation/Swift 运行时）。
private var crashLogFD: Int32 = -1

/// 向崩溃文件写入一段静态字符串字面量。
/// 字符串字面量位于静态存储区，withCString 不触发堆分配，可在信号上下文使用。
@inline(__always)
private func writeRawString(_ s: StaticString) {
    guard crashLogFD >= 0 else { return }
    s.withUTF8Buffer { buf in
        _ = write(crashLogFD, buf.baseAddress, buf.count)
    }
}

/// 把整数转成十进制写入（不分配堆，手工转字符）。
@inline(__always)
private func writeRawInt(_ value: Int32) {
    guard crashLogFD >= 0 else { return }
    var v = value
    var negative = false
    if v < 0 { negative = true; v = -v }
    var digits = [UInt8](repeating: 0, count: 12)
    var idx = digits.count
    if v == 0 {
        idx -= 1
        digits[idx] = UInt8(ascii: "0")
    } else {
        while v > 0 {
            idx -= 1
            digits[idx] = UInt8(ascii: "0") + UInt8(v % 10)
            v /= 10
        }
    }
    if negative {
        idx -= 1
        digits[idx] = UInt8(ascii: "-")
    }
    digits.withUnsafeBufferPointer { buf in
        _ = write(crashLogFD, buf.baseAddress! + idx, buf.count - idx)
    }
}

/// 致命信号处理函数。@convention(c) + 无捕获，符合 signal() 要求。
private func fatalSignalHandler(_ signal: Int32) {
    writeRawString("\n========== FATAL SIGNAL ==========\n")
    writeRawString("signal=")
    writeRawInt(signal)
    writeRawString("\nbacktrace:\n")

    // 抓取调用栈并直接写入 fd（backtrace_symbols_fd 不分配堆，适合信号上下文）
    var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let frameCount = callstack.withUnsafeMutableBufferPointer { ptr -> Int32 in
        backtrace(ptr.baseAddress, 128)
    }
    if crashLogFD >= 0 {
        callstack.withUnsafeMutableBufferPointer { ptr in
            backtrace_symbols_fd(ptr.baseAddress, frameCount, crashLogFD)
        }
    }
    writeRawString("==================================\n")
    fsync(crashLogFD)

    // 恢复默认处理并重新抛出，让系统照常生成 .ips（双保险，下次启动归档）
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

// MARK: - 崩溃报告器

/// 负责安装崩溃捕获、归档系统崩溃报告、导出诊断包。
final class CrashReporter: @unchecked Sendable {
    static let shared = CrashReporter()

    /// 进程内崩溃栈的实时文件（信号处理函数直接写这里）。
    private let liveCrashFileURL: URL
    /// 应用 bundle 进程名（用于匹配系统 .ips 报告）。
    private let processNamePrefix = "MultiSense API"

    private init() {
        liveCrashFileURL = AppLogger.shared.crashesDirectory
            .appendingPathComponent("inprocess-crash.log")
    }

    /// 安装所有崩溃捕获钩子。应在 App 启动最早期调用。
    func install() {
        openLiveCrashFile()
        installSignalHandlers()
        installUncaughtExceptionHandler()
        AppLogger.shared.log(.info, "CrashReporter installed (signal + NSException handlers)")
    }

    /// 打开崩溃专用 fd（O_APPEND，信号处理函数复用）。
    private func openLiveCrashFile() {
        liveCrashFileURL.path.withCString { path in
            crashLogFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
    }

    /// 注册致命信号。
    private func installSignalHandlers() {
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE]
        for sig in signals {
            Darwin.signal(sig, fatalSignalHandler)
        }
    }

    /// 注册未捕获的 Objective-C 异常处理器。
    private func installUncaughtExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            let message = """
            NSException: \(exception.name.rawValue)
            reason: \(exception.reason ?? "(none)")
            userInfo: \(exception.userInfo ?? [:])
            callStack:
            \(symbols)
            """
            // 异常上下文相对宽松，可用 Foundation 同步落盘
            AppLogger.shared.logCrashSync(message)
        }
    }

    // MARK: - 上次会话崩溃检测

    /// 启动时检查上次进程内崩溃记录；若非空，归档并在主日志标记。
    func processPreviousCrash() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: liveCrashFileURL.path),
              let size = attrs[.size] as? UInt64, size > 0 else { return }

        // 归档为带时间戳的文件
        let stamp = Self.timestampString()
        let archived = AppLogger.shared.crashesDirectory
            .appendingPathComponent("crash-\(stamp).log")
        try? fm.copyItem(at: liveCrashFileURL, to: archived)
        // 清空实时文件
        try? "".data(using: .utf8)?.write(to: liveCrashFileURL)

        AppLogger.shared.log(.crash, "⚠️ 检测到上次会话发生进程内崩溃，已归档：\(archived.lastPathComponent)")
    }

    // MARK: - 系统崩溃报告 (.ips) 归档

    /// 把系统生成的 MultiSense .ips 崩溃报告拷贝进本应用日志目录，确保最详细的栈被本地留存。
    func collectSystemDiagnosticReports() {
        let fm = FileManager.default
        let candidates = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        ]

        var copied = 0
        for dir in candidates {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in entries {
                let name = file.lastPathComponent
                // 匹配本应用的崩溃报告（.ips / .crash）
                guard name.hasPrefix(processNamePrefix),
                      name.hasSuffix(".ips") || name.hasSuffix(".crash") else { continue }

                let dest = AppLogger.shared.crashesDirectory.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) { continue }
                if (try? fm.copyItem(at: file, to: dest)) != nil {
                    copied += 1
                    AppLogger.shared.log(.crash, "📋 已归档系统崩溃报告：\(name)")
                }
            }
        }
        if copied > 0 {
            AppLogger.shared.log(.info, "本次共归档 \(copied) 份系统崩溃报告")
        }
    }

    // MARK: - 导出诊断包

    /// 把整个日志目录打包成 zip 放到桌面，并在 Finder 中选中。返回 zip 路径。
    @discardableResult
    func exportDiagnostics() -> URL? {
        // 导出前先抓一次最新的系统报告
        collectSystemDiagnosticReports()

        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let zipURL = desktop.appendingPathComponent("MultiSense-API-诊断-\(Self.timestampString()).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.path, AppLogger.shared.logDirectory.lastPathComponent]
        process.currentDirectoryURL = AppLogger.shared.logDirectory.deletingLastPathComponent()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                AppLogger.shared.log(.warn, "导出诊断包失败，zip 退出码 \(process.terminationStatus)")
                return nil
            }
            AppLogger.shared.log(.info, "诊断包已导出：\(zipURL.path)")
            NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            return zipURL
        } catch {
            AppLogger.shared.error("导出诊断包异常", error)
            return nil
        }
    }

    // MARK: - 工具

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
