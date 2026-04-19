import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - Audio Stream Manager
final class AudioStreamManager: NSObject, @unchecked Sendable {
    private let sampleRate = 16_000
    
    // 1. TÁCH 2 QUEUE RÕ RÀNG NHƯ BẠN NÓI
    // Queue chuyên nhận Audio cực nhanh (User Interactive)
    private let audioQueue = DispatchQueue(label: "com.parrotisle.audio", qos: .userInteractive)
    
    // Queue chuyên chạy vòng lặp Decode nặng nề (User Initiated)
    private let decodeQueue = DispatchQueue(label: "com.parrotisle.decode", qos: .userInitiated)
    
    private var recognizer: SherpaOnnxRecognizer?
    private var scStream: SCStream?
    private var streamBridge: StreamBridge?
    
    // Dùng cờ báo hiệu để kiểm soát vòng lặp decode
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
            
            let featConfig = await sherpaOnnxFeatureConfig(sampleRate: self.sampleRate, featureDim: 80)
            let transducerConfig = await sherpaOnnxOnlineTransducerModelConfig(encoder: encoderPath, decoder: decoderPath, joiner: joinerPath)
            let modelConfig = await sherpaOnnxOnlineModelConfig(tokens: tokensPath, transducer: transducerConfig, numThreads: 4, debug: 0)
            
            var config = await sherpaOnnxOnlineRecognizerConfig(
                featConfig: featConfig,
                modelConfig: modelConfig,
                enableEndpoint: true,
                rule1MinTrailingSilence: 0.6,
                rule2MinTrailingSilence: 0.5,
                rule3MinUtteranceLength: 20.0
            )
            
            let newRecognizer = await SherpaOnnxRecognizer(config: &config)
            
            self.decodeQueue.async {
                self.recognizer = newRecognizer
                Task {
                    await self.sendStatus("Ready!")
                    await MainActor.run { self.onModelReady?() }
                }
            }
        }
    }
    
    func startCapture() async -> Bool {
        guard recognizer != nil else {
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
            
            // Ép ScreenCaptureKit đẩy audio vào audioQueue của chúng ta
            try newStream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: audioQueue)
            
            try await newStream.startCapture()

            scStream = newStream
            isCapturing = true
            
            // Reset trạng thái
            decodeQueue.async {
                self.committedText = ""
                self.liveText = ""
                self.recognizer?.reset()
            }
            
            // KÍCH HOẠT VÒNG LẶP DECODE ĐỘC LẬP
            startDecodingLoop()
            
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
        isCapturing = false // Cờ này sẽ làm vòng lặp decode tự chết
        
        Task.detached { try? await s?.stopCapture() }
    }

    // MARK: - Core Realtime Processing
    
    // Hàm này CHỈ CHẠY TRÊN audioQueue (cực nhanh, không block)
    func ingestSamples(_ samples: [Float]) {
        guard isCapturing, let recognizer = recognizer else { return }
        
        var cleanSamples = samples
        for i in 0..<cleanSamples.count {
            if cleanSamples[i].isNaN || cleanSamples[i].isInfinite {
                cleanSamples[i] = 0.0
            }
        }
        
        // Mớm data vào C++ buffer. Tuyệt đối không gọi decode() ở đây!
        recognizer.acceptWaveform(samples: cleanSamples, sampleRate: sampleRate)
    }
    
    // Vòng lặp này CHỈ CHẠY TRÊN decodeQueue (độc lập hoàn toàn)
        private func startDecodingLoop() {
            decodeQueue.async { [weak self] in
                guard let self = self else { return }
                
                // Lặp vĩnh cửu cho đến khi isCapturing = false
                while self.isCapturing {
                    guard let recognizer = self.recognizer else {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    
                    // Giải mã và mớm text ra UI NGAY LẬP TỨC
                    while recognizer.isReady() {
                        recognizer.decode()
                        self.processRecognizedText(recognizer: recognizer)
                    }
                    
                    // Ngủ 20ms để nhường CPU, tránh ăn 100% Core khi không có ai nói gì
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
    
    // Hàm này được gọi bởi decodeQueue
    private func processRecognizedText(recognizer: SherpaOnnxRecognizer) {
        if let partialText = recognizer.getResult()?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            
            if partialText != liveText {
                liveText = partialText
                pushSnapshot()
            }

            // CHỈ ép ngắt cứng nếu câu dài bất thường (người dùng nói > 50 từ không hề nghỉ thở)
            // Còn bình thường sẽ dựa vào isEndpoint() để ngắt một cách tự nhiên.
            let isTextTooLong = liveText.count > 250
            
            if recognizer.isEndpoint() || isTextTooLong {
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
                
                // Xả rác bộ nhớ của Model một cách mượt mà
                recognizer.reset()
            }
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
        isCapturing = false
        let s = scStream
        scStream = nil
        streamBridge = nil
        Task.detached { try? await s?.stopCapture() }
        
        decodeQueue.sync {
            self.recognizer = nil
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
