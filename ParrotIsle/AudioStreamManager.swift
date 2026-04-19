import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - Audio Stream Manager
final class AudioStreamManager: NSObject, @unchecked Sendable {
    private let sampleRate = 16_000
    private let sherpaQueue = DispatchQueue(label: "com.parrotisle.sherpa", qos: .userInitiated)
    
    private var isDecodingRunning = false
    private var recognizer: SherpaOnnxRecognizer?
    private var scStream: SCStream?
    private var streamBridge: StreamBridge?
    private var isCapturing = false

    private var committedText: String = ""
    private var liveText: String = ""

    // Callbacks
    var onTranscriptionUpdate: (@MainActor @Sendable (String) -> Void)?
    var onModelReady: (@MainActor @Sendable () -> Void)?
    var onStatusChanged: (@MainActor @Sendable (String) -> Void)?

    override init() { super.init() }

    func setCallbacks(
        onModelReady: (@MainActor @Sendable () -> Void)?,
        onStatusChanged: (@MainActor @Sendable (String) -> Void)?,
        onTranscriptionUpdate: (@MainActor @Sendable (String) -> Void)?
    ) {
        self.onModelReady = onModelReady
        self.onStatusChanged = onStatusChanged
        self.onTranscriptionUpdate = onTranscriptionUpdate
    }

    // MARK: - Setup & Capture
    func prepareModel() async {
        if isCapturing { stopCapture() }
        await sendStatus("Initializing model...")
        
        guard let encoderPath = Bundle.main.path(forResource: "encoder", ofType: "onnx"),
              let decoderPath = Bundle.main.path(forResource: "decoder", ofType: "onnx"),
              let joinerPath  = Bundle.main.path(forResource: "joiner", ofType: "onnx"),
              let tokensPath  = Bundle.main.path(forResource: "tokens", ofType: "txt")
        else {
            await sendStatus("Error: Model files not found.")
            return
        }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let featConfig = sherpaOnnxFeatureConfig(sampleRate: self.sampleRate, featureDim: 80)
            let transducerConfig = sherpaOnnxOnlineTransducerModelConfig(encoder: encoderPath, decoder: decoderPath, joiner: joinerPath)
            let modelConfig = sherpaOnnxOnlineModelConfig(tokens: tokensPath, transducer: transducerConfig, numThreads: 4, debug: 0)
            
            var config = sherpaOnnxOnlineRecognizerConfig(
                featConfig: featConfig,
                modelConfig: modelConfig,
                enableEndpoint: true,
                rule1MinTrailingSilence: 1.2,
                rule2MinTrailingSilence: 0.8,
                rule3MinUtteranceLength: 20.0
            )
            
            let newRecognizer = SherpaOnnxRecognizer(config: &config)
            
            self.sherpaQueue.async {
                self.recognizer = newRecognizer
                Task {
                    await self.sendStatus("Ready!")
                    await MainActor.run { self.onModelReady?() }
                }
            }
        }
    }
    
    func startCapture() async -> Bool {
        let isReady = sherpaQueue.sync { recognizer != nil }
        guard isReady else {
            await sendStatus("Model is not ready.")
            return false
        }
        guard !isCapturing else { return true }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let streamConfig = SCStreamConfiguration()
            
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = sampleRate
            streamConfig.channelCount = 1
            streamConfig.queueDepth = 5

            let bridge = StreamBridge(manager: self)
            self.streamBridge = bridge
            let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: bridge)
            
            let audioQueue = DispatchQueue(label: "com.parrotisle.audio", qos: .userInteractive)
            try newStream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: audioQueue)
            
            try await newStream.startCapture()

            scStream = newStream
            isCapturing = true
            
            sherpaQueue.async {
                self.committedText = ""
                self.liveText = ""
                self.recognizer?.reset()
                self.isDecodingRunning = true
                self.runDecodingLoop()
            }
            
            await sendStatus("Listening to system audio...")
            return true
        } catch {
            await sendStatus("Capture error: \(error.localizedDescription)")
            return false
        }
    }

    func stopCapture() {
        let s = scStream
        scStream = nil
        streamBridge = nil
        isCapturing = false
        
        sherpaQueue.async {
            self.isDecodingRunning = false
            self.committedText = ""
            self.liveText = ""
            self.recognizer?.reset()
        }
        
        Task.detached { try? await s?.stopCapture() }
    }

    // MARK: - Core Realtime Processing
    func ingestSamples(_ samples: [Float]) {
        guard isCapturing else { return }
        
        sherpaQueue.async { [weak self] in
            guard let self = self, self.isCapturing, let recognizer = self.recognizer else { return }
            
            var cleanSamples = samples
            for i in 0..<cleanSamples.count {
                if cleanSamples[i].isNaN || cleanSamples[i].isInfinite {
                    cleanSamples[i] = 0.0
                }
            }
            recognizer.acceptWaveform(samples: cleanSamples, sampleRate: self.sampleRate)
        }
    }

    private func runDecodingLoop() {
        guard isDecodingRunning, let recognizer = recognizer else { return }
        
        var didDecode = false
        while recognizer.isReady() {
            recognizer.decode()
            didDecode = true
        }

        if didDecode {
            if let partialText = recognizer.getResult()?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                let changed = partialText != liveText
                if changed {
                    liveText = partialText
                    pushSnapshot()
                }

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
                    recognizer.reset()
                }
            }
        }
        
        sherpaQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.runDecodingLoop()
        }
    }

    private func pushSnapshot() {
        let fullRawText = [committedText, liveText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        guard !fullRawText.isEmpty else { return }
        
        if let cb = self.onTranscriptionUpdate {
            Task { @MainActor in cb(fullRawText) }
        }
    }

    private func sendStatus(_ msg: String) async {
        if let cb = onStatusChanged {
            await MainActor.run { cb(msg) }
        }
    }
    
    // MARK: - Cleanup
    func shutdown() {
        // 1. Dừng ngay việc nhận audio mới
        isCapturing = false
        let s = scStream
        scStream = nil
        streamBridge = nil
        
        // 2. Dừng ScreenCaptureKit stream (chạy nền để không block)
        Task.detached { try? await s?.stopCapture() }
        
        // 3. Khóa queue lại để đợi decode() hiện tại chạy xong, sau đó hủy model
        sherpaQueue.sync {
            self.isDecodingRunning = false
            self.recognizer = nil // Gọi deinit của C++ một cách an toàn
        }
    }
}

// Lớp cầu nối Audio
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

        mgr.ingestSamples(samples)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let mgr = manager else { return }
        mgr.stopCapture()
        Task { [weak mgr] in
            if let cb = mgr?.onStatusChanged {
                await MainActor.run { cb("Capture stopped: \(error.localizedDescription)") }
            }
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
