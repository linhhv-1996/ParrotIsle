import SwiftUI
import Translation
import Combine
import CoreGraphics
import AppKit

// MARK: - App Status
enum AppStatus: Equatable {
    case loadingApp
    case loadingModel
    case missingPermission
    case ready
    case recording
    case error(String)
}

// MARK: - UIState Logic
@MainActor
final class UIState: ObservableObject {
    @Published var status: AppStatus = .loadingApp
    @Published var stableLines: [String] = []
    @Published var pendingText = ""
    
    var isRecording: Bool { status == .recording }
    var hasScreenRecordPermission: Bool = false
    private var isModelLoaded: Bool = false

    private let audioManager = AudioStreamManager()

    var displayText: String {
        (stableLines + [pendingText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    
    func setTranslationSession(_ session: TranslationSession) {
        Task {
            await audioManager.setTranslationSession(session)
        }
    }

    init() {
        Task {
            await setupCallbacks()
            checkPermission()
            updateStatusBasedOnState()
        }
        
        Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in notifications {
                guard let self else { break }
                self.checkPermission()
                self.updateStatusBasedOnState()
            }
        }
    }
    
    private func setupCallbacks() async {
        await audioManager.setCallbacks(
            onModelReady: { [weak self] in
                guard let self else { return }
                self.isModelLoaded = true
                self.updateStatusBasedOnState()
            },
            onStatusChanged: { [weak self] statusMsg in
                let lowerMsg = statusMsg.lowercased()
                if lowerMsg.contains("failed") || lowerMsg.contains("error") || lowerMsg.contains("not found") {
                    self?.status = .error(statusMsg)
                } else if lowerMsg.contains("initializing") {
                    self?.status = .loadingModel
                }
            },
            onSubtitleSnapshot: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.updateSubtitle(snapshot)
                }
            }
        )
    }
    
    func checkPermission() {
        hasScreenRecordPermission = CGPreflightScreenCaptureAccess()
    }
    
    func requestPermission() {
        hasScreenRecordPermission = CGRequestScreenCaptureAccess()
        if !hasScreenRecordPermission {
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        updateStatusBasedOnState()
    }
    
    private func updateStatusBasedOnState() {
        // KHÔNG update status linh tinh nếu đang thu âm
        if status == .recording { return }
        
        if !hasScreenRecordPermission {
            status = .missingPermission
        } else if !isModelLoaded {
            if case .error = status { return }
            if status != .loadingModel {
                status = .loadingModel
                Task { await audioManager.prepareModel() }
            }
        } else {
            status = .ready
        }
    }

    private func updateSubtitle(_ snapshot: SubtitleSnapshot) {
        stableLines = snapshot.stableLines
        pendingText = snapshot.pendingText
    }

    func toggleRecording() {
        if status == .recording {
            stopRecording()
        } else if status == .ready {
            startRecording()
        } else if status == .missingPermission {
            requestPermission()
        } else if case .error(_) = status {
            status = .loadingModel
            Task { await audioManager.prepareModel() }
        }
    }

    private func startRecording() {
        // Đổi UI ngay lập tức cho mượt
        status = .recording
        Task {
            let didStart = await audioManager.startCapture()
            if !didStart {
                // Nếu backend fail, trả lại trạng thái cũ
                await MainActor.run {
                    self.status = .ready
                    self.updateStatusBasedOnState()
                }
            }
        }
    }

    func stopRecording() {
        // Đổi UI ngay lập tức thoát khỏi trạng thái recording
        self.status = .ready
        stableLines = []
        pendingText = ""
        
        Task {
            // Backend từ từ ngắt stream sau
            await audioManager.stopCapture()
            await MainActor.run { self.updateStatusBasedOnState() }
        }
    }
}


// MARK: - Views (Phần UI giữ nguyên)
struct DynamicIslandView: View {
    @ObservedObject var uiState: UIState
    
    @State private var isSettingsMode = false
    @State private var isSettingsHovered = false
    @State private var isQuitHovered = false
    @State private var isActivateHovered = false
    @State private var translationConfig: TranslationSession.Configuration?
    
    @AppStorage("sourceLanguage") private var sourceLanguage = "en"
    @AppStorage("targetLanguage") private var targetLanguage = "none"
    @AppStorage("licenseKey") private var licenseKey = ""
    @AppStorage("isFirstLaunch") private var isFirstLaunch = true

    var body: some View {
        VStack(spacing: 0) {
            mainSubtitleContent
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSettingsMode {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isSettingsMode = false
                        }
                    } else {
                        uiState.toggleRecording()
                    }
                }
            
            if isSettingsMode {
                Divider()
                    .background(.white.opacity(0.15))
                    .padding(.horizontal, 20)
                
                settingsContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.1, blue: 0.12), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 6)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSettingsMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .translationTask(translationConfig) { session in
            uiState.setTranslationSession(session)
            try? await Task.sleep(for: .seconds(1_000_000_000))
        }
        .onChange(of: sourceLanguage) { _, newValue in
            updateTranslationConfig(source: newValue, target: targetLanguage)
        }
        .onChange(of: targetLanguage) { _, newValue in
            updateTranslationConfig(source: sourceLanguage, target: newValue)
        }
        .onAppear {
            updateTranslationConfig(source: sourceLanguage, target: targetLanguage)
            if isFirstLaunch {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isSettingsMode = true
                }
                isFirstLaunch = false
            }
        }
    }
    
    private func updateTranslationConfig(source: String, target: String) {
        guard target != "none", source != target else {
            translationConfig = nil
            return
        }
        let sourceLang = Locale.Language(identifier: source)
        let targetLang = Locale.Language(identifier: target)
        translationConfig = TranslationSession.Configuration(source: sourceLang, target: targetLang)
    }

    private var mainSubtitleContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statusIndicator
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                
                Spacer()
                
                CircleButton(icon: isSettingsMode ? "chevron.up" : "gearshape.fill", isHovered: $isSettingsHovered) {
                    isSettingsMode.toggle()
                }
                
                CircleButton(icon: "xmark", isHovered: $isQuitHovered, activeColor: .red.opacity(0.7)) {
                    NSApplication.shared.terminate(nil)
                }
            }
            
            if uiState.displayText.isEmpty {
                Text(actionText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(actionTextColor)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                Text(uiState.displayText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            }
        }
    }

    private var titleText: String {
        switch uiState.status {
        case .recording: return "LIVE SUBTITLE"
        case .ready: return "READY"
        case .missingPermission: return "PERMISSION REQUIRED"
        case .loadingModel, .loadingApp: return "INITIALIZING"
        case .error: return "SYSTEM ERROR"
        }
    }
    
    private var subtitleText: String {
        switch uiState.status {
        case .recording: return "Listening to system audio..."
        case .ready: return "Model loaded. Tap to start."
        case .missingPermission: return "Check Screen Recording settings"
        case .loadingModel, .loadingApp: return "Loading Sherpa-onnx model..."
        case .error(let msg): return msg
        }
    }
    
    private var actionText: String {
        switch uiState.status {
        case .recording: return "Listening..."
        case .ready: return "Tap to start transcription"
        case .missingPermission: return "Grant Permission to Start"
        case .loadingModel, .loadingApp: return "Warming up AI..."
        case .error: return "Tap to retry loading model"
        }
    }
    
    private var statusIndicator: some View {
        Circle()
            .fill(uiState.isRecording ? Color.red : (uiState.status == .ready ? Color.green : Color.orange))
            .frame(width: 8, height: 8)
    }
    
    private var actionTextColor: Color {
        switch uiState.status {
        case .missingPermission, .error: return .orange
        default: return .white.opacity(0.6)
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 12) {
            settingsRow(label: "Spoken") {
                let currentName = LanguageOption.whisperLanguages.first(where: { $0.id == sourceLanguage })?.name ?? "Select"
                CustomDropdown(text: currentName) {
                    ForEach(LanguageOption.whisperLanguages) { lang in
                        Button(lang.name) { sourceLanguage = lang.id }
                    }
                }
            }
            
            settingsRow(label: "Subtitle") {
                let currentTargetName = targetLanguage == "none" ? "Do not translate" :
                    (LanguageOption.whisperLanguages.first(where: { $0.id == targetLanguage })?.name ?? "Select")
                
                CustomDropdown(text: currentTargetName) {
                    Button("Do not translate") { targetLanguage = "none" }
                    Divider()
                    ForEach(LanguageOption.whisperLanguages) { lang in
                        Button(lang.name) { targetLanguage = lang.id }
                    }
                }
            }

            settingsRow(label: "License") {
                HStack(spacing: 6) {
                    TextField("Enter key...", text: $licenseKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                    
                    Button {
                        print("Activating: \(licenseKey)")
                    } label: {
                        Text("Activate")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(isActivateHovered ? Color.blue : Color.blue.opacity(0.8))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 75, height: 30)
                    .onHover { isActivateHovered = $0 }
                }
            }
        }
    }

    @ViewBuilder
    private func CustomDropdown<Content: View>(text: String, @ViewBuilder items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            HStack {
                Text(text).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(Color.white.opacity(0.08))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 70, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }
    
    @ViewBuilder
    private func CircleButton(icon: String, isHovered: Binding<Bool>, activeColor: Color = .white.opacity(0.15), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered.wrappedValue ? .white : .white.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(isHovered.wrappedValue ? activeColor : Color.white.opacity(0.05))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered.wrappedValue = $0 }
    }
}
