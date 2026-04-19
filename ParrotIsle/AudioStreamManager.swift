import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Translation

// MARK: - Data Model
struct SubtitleSnapshot: Sendable {
    let stableLines: [String]
    let pendingText: String
    
    var displayText: String {
        let parts = (stableLines + [pendingText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Audio Stream Manager
actor AudioStreamManager: NSObject {
    // MARK: Constants
    private let sampleRate = 16_000
    
    private var translationSession: TranslationSession?
    private var activeTranslationTask: Task<Void, Never>?

    // MARK: Sherpa State (Đã sửa theo đúng class trong SherpaOnnx.swift)
    private var recognizer: SherpaOnnxRecognizer?
    
    // MARK: Capture State
    private var scStream: SCStream?
    private var streamBridge: StreamBridge?
    private var isCapturing = false

    private var committedText: String = ""
    private var liveText: String = ""

    // Callbacks
    var onSubtitleSnapshot: (@MainActor @Sendable (SubtitleSnapshot) -> Void)?
    var onModelReady: (@MainActor @Sendable () -> Void)?
    var onStatusChanged: (@MainActor @Sendable (String) -> Void)?

    func setCallbacks(
        onModelReady: (@MainActor @Sendable () -> Void)?,
        onStatusChanged: (@MainActor @Sendable (String) -> Void)?,
        onSubtitleSnapshot: (@MainActor @Sendable (SubtitleSnapshot) -> Void)?
    ) {
        self.onModelReady = onModelReady
        self.onStatusChanged = onStatusChanged
        self.onSubtitleSnapshot = onSubtitleSnapshot
    }

    private nonisolated let defaults = UserDefaults.standard

    override init() {
        super.init()
    }

    func setTranslationSession(_ session: TranslationSession) {
        self.translationSession = session
    }

    // MARK: - Setup & Model Management
    
    func prepareModel() async {
        if isCapturing { stopCapture() }
        
        await sendStatus("Khởi tạo Sherpa-onnx model...")
        
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDirectory = appSupportURL.appendingPathComponent("ParrotIsle/sherpa", isDirectory: true)
        
        let encoderPath = modelsDirectory.appendingPathComponent("encoder.onnx").path
        let decoderPath = modelsDirectory.appendingPathComponent("decoder.onnx").path
        let joinerPath = modelsDirectory.appendingPathComponent("joiner.onnx").path
        let tokensPath = modelsDirectory.appendingPathComponent("tokens.txt").path
        
        guard FileManager.default.fileExists(atPath: encoderPath) else {
            print("Lỗi: Không tìm thấy file model ONNX trong \(modelsDirectory.path)")
            await sendStatus("Lỗi: Không tìm thấy file model ONNX trong \(modelsDirectory.path)")
            return
        }
        
        // SỬ DỤNG HELPER FUNCTIONS CỦA SHERPAONNX.SWIFT
        let featConfig = await sherpaOnnxFeatureConfig(
            sampleRate: sampleRate,
            featureDim: 80
        )
        
        let transducerConfig = await sherpaOnnxOnlineTransducerModelConfig(
            encoder: encoderPath,
            decoder: decoderPath,
            joiner: joinerPath
        )
        
        let modelConfig = await sherpaOnnxOnlineModelConfig(
            tokens: tokensPath,
            transducer: transducerConfig,
            numThreads: 4,
            debug: 0
        )
        
        var config = await sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: 1.2,
            rule2MinTrailingSilence: 0.8,
            rule3MinUtteranceLength: 20.0
        )
        
        // Khởi tạo (Stream đã được bọc ngầm bên trong class này)
        self.recognizer = await SherpaOnnxRecognizer(config: &config)
        
        if self.recognizer == nil {
            await sendStatus("Lỗi: Không thể khởi tạo Sherpa-onnx.")
        } else {
            await sendStatus("Sẵn sàng!")
            let cb = onModelReady
            await MainActor.run { cb?() }
        }
    }
    
    // MARK: - Capture Control
    func startCapture() async -> Bool {
        guard recognizer != nil else {
            await sendStatus("Model chưa sẵn sàng.")
            return false
        }
        guard !isCapturing else { return true }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let streamConfig = SCStreamConfiguration()
            
            // Cấu hình chuẩn cho Audio
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = sampleRate
            streamConfig.channelCount = 1
            streamConfig.queueDepth = 5

            let bridge = await StreamBridge(manager: self)
            self.streamBridge = bridge
            let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: bridge)
            
            // Hứng luồng Audio (Luồng chính cần xử lý)
            try newStream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            
            // Hứng luồng Video (Chỉ để chặn cái log spam Dropping frame của Apple, hứng xong vứt luôn)
            try newStream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: .global(qos: .background))
            
            try await newStream.startCapture()

            scStream = newStream
            resetState()
            isCapturing = true
            await sendStatus("Đang nghe âm thanh hệ thống...")
            return true
        } catch {
            await sendStatus("Lỗi capture: \(error.localizedDescription)")
            return false
        }
    }

    func stopCapture() {
        let s = scStream
        scStream = nil
        streamBridge = nil
        isCapturing = false
        resetState()
        Task.detached { try? await s?.stopCapture() }
    }

    private func resetState() {
        committedText = ""
        liveText = ""
        recognizer?.reset() // Wrapper tự xử lý reset stream bên trong
    }

    // MARK: - Core Realtime Processing
    func ingestSamples(_ samples: [Float]) {
        guard isCapturing, let recognizer = recognizer else { return }

        // Gọi thẳng từ recognizer (Nó đã giữ stream bên trong)
        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)

        while recognizer.isReady() {
            recognizer.decode()
        }

        let partialText = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let changed = partialText != liveText
        if changed {
            liveText = partialText
            pushSnapshot()
        }

        // Kiểm tra dứt câu
        if recognizer.isEndpoint() {
            if !liveText.isEmpty {
                let separator = committedText.isEmpty ? "" : " "
                let combined = committedText + separator + liveText
                let words = combined.split(separator: " ").map { String($0) }
                
                var tempLines: [String] = []
                var tLine = ""
                for w in words {
                    if tLine.isEmpty { tLine = w }
                    else if tLine.count + 1 + w.count <= 40 { tLine += " " + w }
                    else { tempLines.append(tLine); tLine = w }
                }
                if !tLine.isEmpty { tempLines.append(tLine) }
                
                if tempLines.count > 4 {
                    committedText = tempLines.suffix(4).joined(separator: " ")
                } else {
                    committedText = combined
                }
            }
            liveText = ""
            pushSnapshot()
            recognizer.reset() // Bắt đầu câu mới
        }
    }

    private func pushSnapshot() {
        let rawCommitted = committedText
        let rawLive = liveText
        
        activeTranslationTask?.cancel()
        activeTranslationTask = Task {
            let fullRawText = [rawCommitted, rawLive]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            
            if fullRawText.isEmpty { return }
            
            let sourceId = defaults.string(forKey: "sourceLanguage") ?? "en"
            let targetId = defaults.string(forKey: "targetLanguage") ?? "none"
            var translatedText = fullRawText
            
            if targetId != "none", sourceId != targetId, let session = await self.translationSession {
                do {
                    let response = try await session.translations(from: [TranslationSession.Request(sourceText: fullRawText)])
                    translatedText = response.first?.targetText ?? fullRawText
                } catch {
                    print("Translation error: \(error)")
                }
            }
            
            if Task.isCancelled { return }
            
            let words = translatedText.split(separator: " ").map { String($0) }
            var lines: [String] = []
            var currentLine = ""
            for word in words {
                if currentLine.isEmpty { currentLine = word }
                else if currentLine.count + 1 + word.count <= 45 { currentLine += " " + word }
                else { lines.append(currentLine); currentLine = word }
            }
            if !currentLine.isEmpty { lines.append(currentLine) }
            
            let displayLines = Array(lines.suffix(2))
            let snapshot = SubtitleSnapshot(stableLines: displayLines, pendingText: "")
            
            let cb = onSubtitleSnapshot
            await MainActor.run { cb?(snapshot) }
        }
    }

    private func sendStatus(_ msg: String) async {
        let cb = onStatusChanged
        await MainActor.run { cb?(msg) }
    }
}

private final class StreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var manager: AudioStreamManager?

    init(manager: AudioStreamManager) {
        self.manager = manager
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let samples = extractFloatSamples(from: sampleBuffer),
              !samples.isEmpty,
              let mgr = manager else { return }

        Task { await mgr.ingestSamples(samples) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let mgr = manager else { return }
        Task {
            await mgr.stopCapture()
            let cb = await mgr.onStatusChanged
            await MainActor.run { cb?("Capture stopped: \(error.localizedDescription)") }
        }
    }

    private nonisolated func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }

        let asbd = asbdPtr.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInt   = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var result: [Float] = []
        result.reserveCapacity(Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)

        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let data = buf.mData else { continue }
            if isFloat {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                result.append(contentsOf: UnsafeBufferPointer(start: data.bindMemory(to: Float.self, capacity: count), count: count))
            } else if isInt {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
                let ptr = data.bindMemory(to: Int16.self, capacity: count)
                result.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count).map { Float($0) / Float(Int16.max) })
            }
        }
        return result
    }
}

