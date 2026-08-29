import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "SecondSightUILanguage"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    static var savedOrSystemDefault: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: preferenceKey),
           let language = AppLanguage(rawValue: saved) {
            return language
        }
        return .chinese
    }
}

struct LocalizedCopy: Equatable, Sendable {
    let chinese: String
    let english: String

    func text(for language: AppLanguage) -> String {
        language == .chinese ? chinese : english
    }

    static func verbatim(_ text: String) -> LocalizedCopy {
        LocalizedCopy(chinese: text, english: text)
    }
}

func copy(_ chinese: String, _ english: String) -> LocalizedCopy {
    LocalizedCopy(chinese: chinese, english: english)
}

func localized(_ chinese: String, _ english: String, for language: AppLanguage) -> String {
    language == .chinese ? chinese : english
}

struct ActionButtonLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.system(size: 24, weight: .bold))
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }
}

extension View {
    func secondSightActionButton() -> some View {
        controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 12))
    }
}
