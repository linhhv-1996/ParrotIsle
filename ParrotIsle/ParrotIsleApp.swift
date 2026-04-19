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
            ("ar", "Arabic"),
            ("en", "English"),
            ("id", "Indonesian"),
            ("ja", "Japanese"),
            ("ru", "Russian"),
            ("th", "Thai"),
            ("vi", "Vietnamese"),
            ("zh", "Chinese")
        ]
        
        return mapping.map { LanguageOption(id: $0.id, name: $0.name) }
            .sorted { $0.name < $1.name }
    }()
}
