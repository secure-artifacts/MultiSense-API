import Foundation
import FluidAudio
import AVFoundation

/// 单槽异步信号量：把 ASR 推理串行化。
///
/// 为什么需要它：`TranscriptionService` 是 actor，但 actor 只保证「同步代码段」互斥。
/// `await asr.transcribe(...)` 是挂起点——挂起期间 actor 会放行下一个排队请求（actor 重入），
/// 导致多路推理并发压在非线程安全的 `AsrManager` 上，触发 CoreML/ANE 原生内存崩溃（SIGSEGV）。
/// 信号量的 `await acquire()` 让重入请求挂起排队，跨挂起点持续生效，正是 actor 缺失的语义。
///
/// 标准库无 `AsyncSemaphore`，且 `DispatchSemaphore` 会阻塞线程、不适合 async 上下文，故自实现。
actor AsyncSemaphore {
    /// 可用令牌数。
    private var available: Int
    /// 等待队列：令牌耗尽时排队的请求。带 id 以便取消时精确移除。
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    init(value: Int = 1) {
        self.available = value
    }

    /// 获取令牌。有空闲则立即返回；否则挂起排队。
    /// 挂起期间若任务被取消（如 Vapor 客户端断连取消请求 Task），
    /// 会把自己移出等待队列并抛 `CancellationError`，避免令牌泄漏导致永久占槽。
    func acquire() async throws {
        // 进入时已取消则直接抛出，不占令牌。
        try Task.checkCancellation()

        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiters.append((id, cont))
            }
        } onCancel: {
            // onCancel 在任意上下文调用，跳回 actor 移除并以 CancellationError 唤醒。
            Task { await self.cancelWaiter(id) }
        }
    }

    /// 释放令牌：若有等待者，直接把令牌移交队首（available 保持不变）；否则归还令牌。
    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.cont.resume()
        } else {
            available += 1
        }
    }

    /// 取消处理：把指定等待者移出队列并以 CancellationError 唤醒。
    /// 若该 id 已被 release 唤醒并移除，则无操作（避免重复 resume）。
    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: idx)
        w.cont.resume(throwing: CancellationError())
    }
}

actor TranscriptionService {
    private var asr: AsrManager?
    // 记录模型是否已加载完毕
    private var isInitialized = false
    // 一次性初始化任务缓存：并发首请求共享同一次初始化，失败后清空以允许重试。
    private var initTask: Task<Void, Error>?
    // 推理串行门控：保证任意时刻最多一路 asr.transcribe，消除 actor 重入导致的并发推理。
    private let inferenceGate = AsyncSemaphore(value: 1)

    // 供外部查询模型加载状态。仅在初始化完整成功后才为 true（GET / 健康检查依赖此语义）。
    func getIsInitialized() -> Bool {
        return isInitialized
    }

    // 只有在第一次调用转录或明确要求下载时才执行。
    // 并发安全：并发首请求共享同一个 initTask，模型只初始化一次；
    // 若初始化失败，在 actor 同步上下文清空缓存，使后续请求触发全新重试。
    func initializeIfNeeded() async throws {
        if isInitialized { return }

        // 已有进行中的初始化任务则复用（并发首请求只初始化一次）。
        if let task = initTask {
            try await task.value
            return
        }

        // 首个请求创建并缓存初始化任务。Task 闭包继承本 actor 隔离，在 actor 上执行。
        let task = Task { try await self.performInitialize() }
        initTask = task
        do {
            try await task.value
            // 成功后清空引用：isInitialized 快路径已接管，无需再持有已完成的 Task
            // （该 Task 捕获 self，留存会形成保留环）。
            initTask = nil
        } catch {
            // await 恢复后回到 actor 同步上下文，此处清空缓存允许重试。
            initTask = nil
            throw error
        }
    }

    // 实际的下载 + 加载逻辑。actor 隔离，安全修改 asr / isInitialized。
    private func performInitialize() async throws {
        // 下载模型
        AppLogger.shared.breadcrumb("ASR: downloadAndLoad(v3) 开始")
        let models = try await AsrModels.downloadAndLoad(version: .v3)

        // 使用默认配置初始化 ASR 管理器
        let config = ASRConfig.default
        let manager = AsrManager(config: config)

        // 加载模型（CoreML 编译/加载，可能 native crash）
        AppLogger.shared.breadcrumb("ASR: AsrManager.initialize 开始")
        try await manager.initialize(models: models)

        // 只在完整成功后才发布 asr 与 isInitialized。
        asr = manager
        isInitialized = true
        AppLogger.shared.breadcrumb("ASR: 初始化完成")
    }

    // 音频转换文字
    func transcribe(fileURL: URL) async throws -> String {
        try await initializeIfNeeded()
        guard let asr = asr else { throw NSError(domain: "ASR", code: 500) }

        // 音频预处理（不占推理令牌，可与其它请求的预处理并行）
        AppLogger.shared.breadcrumb("ASR: resampleAudioFile 开始")
        let samples = try AudioConverter().resampleAudioFile(fileURL)

        // 串行门控：在重采样之后、推理之前获取令牌，保证任意时刻只有一路推理。
        // 成功与抛错（含取消）路径都释放令牌，避免占槽导致后续请求永久阻塞。
        try await inferenceGate.acquire()
        do {
            AppLogger.shared.breadcrumb("ASR: transcribe 推理开始 | samples=\(samples.count)")
            let result = try await asr.transcribe(samples, source: .system)
            AppLogger.shared.breadcrumb("ASR: transcribe 推理完成")
            await inferenceGate.release()
            return result.text
        } catch {
            await inferenceGate.release()
            throw error
        }
    }
}
