import SwiftUI
import ScreenCaptureKit

@main
struct ParrotIsleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {}
}

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String

    static let whisperLanguages: [LanguageOption] = {
        let mapping: [(id: String, name: String)] = [
            ("en", "English"),
            ("vi", "Vietnamese"),
            ("zh", "Chinese"),
            ("ja", "Japanese"),
            ("ko", "Korean"),
            ("fr", "French"),
            ("de", "German"),
            ("es", "Spanish"),
            ("pt", "Portuguese"),
            ("ru", "Russian"),
            ("it", "Italian"),
            ("th", "Thai"),
            ("id", "Indonesian"),
            ("ar", "Arabic"),
            ("hi", "Hindi"),
            ("tr", "Turkish"),
            ("nl", "Dutch"),
            ("pl", "Polish"),
            ("sv", "Swedish"),
            ("da", "Danish"),
            ("fi", "Finnish"),
            ("el", "Greek"),
            ("cs", "Czech"),
            ("ro", "Romanian"),
            ("hu", "Hungarian")
        ]
        
        // Convert sang LanguageOption và sắp xếp theo bảng chữ cái
        return mapping.map { LanguageOption(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }()
}
