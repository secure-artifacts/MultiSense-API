import Foundation
import FluidAudio
import AVFoundation

actor TranscriptionService {
    private var asr: AsrManager?
    // 记录模型是否已加载完毕
    private var isInitialized = false
    
    // 供外部查询模型加载状态
    func getIsInitialized() -> Bool {
        return isInitialized
    }

    // 只有在第一次调用转录或明确要求下载时才执行
    func initializeIfNeeded() async throws {
        if isInitialized { return }

        // 下载模型
        AppLogger.shared.breadcrumb("ASR: downloadAndLoad(v3) 开始")
        let models = try await AsrModels.downloadAndLoad(version: .v3)

        // 使用默认配置初始化 ASR 管理器
        let config = ASRConfig.default
        asr = AsrManager(config: config)

        // 加载模型（CoreML 编译/加载，可能 native crash）
        AppLogger.shared.breadcrumb("ASR: AsrManager.initialize 开始")
        try await asr?.initialize(models: models)

        isInitialized = true
        AppLogger.shared.breadcrumb("ASR: 初始化完成")
    }

    // 音频转换文字
    func transcribe(fileURL: URL) async throws -> String {
        try await initializeIfNeeded()
        guard let asr = asr else { throw NSError(domain: "ASR", code: 500) }
        
        // 音频预处理
        AppLogger.shared.breadcrumb("ASR: resampleAudioFile 开始")
        let samples = try AudioConverter().resampleAudioFile(fileURL)

        // 开始转录（CoreML/ANE 推理，偶发崩溃高发区）
        AppLogger.shared.breadcrumb("ASR: transcribe 推理开始 | samples=\(samples.count)")
        let result = try await asr.transcribe(samples, source: .system)
        AppLogger.shared.breadcrumb("ASR: transcribe 推理完成")

        return result.text
    }
}
