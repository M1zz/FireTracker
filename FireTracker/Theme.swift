import SwiftUI

// A color that resolves to a different hex in light vs dark mode, so the whole
// app follows the system appearance.
extension Color {
    init(light: String, dark: String) {
        self = Color(uiColor: UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

// Centralized visual language. Warm editorial palette with a single gold accent,
// "quiet money" aesthetic — now adaptive for both light and dark mode.
enum Theme {
    static let bg          = Color(light: "FAF6F0", dark: "12100E")
    static let surface     = Color(light: "FFFFFF", dark: "1C1916")
    static let surfaceHigh = Color(light: "F0EAE0", dark: "262119")
    // Same gold in both modes so black-on-accent buttons stay legible.
    static let accent      = Color(hex: "E8A33D")
    static let accentSoft  = accent.opacity(0.15)
    static let positive    = Color(light: "2E9E78", dark: "4CAF8E")
    static let negative    = Color(light: "D6493B", dark: "EF6B5B")
    // 금액 변화 방향(한국식): 오르면 붉은색, 내리면 푸른색.
    static let rise        = Color(light: "D6493B", dark: "EF5350")
    static let fall        = Color(light: "2F6FE0", dark: "4C8DFF")
    static let textPrimary = Color(light: "1F1B17", dark: "F5F0E8")
    static let textSecond  = Color(light: "6E675C", dark: "A39E94")
    static let hairline    = Color(light: "1F1B17", dark: "F5F0E8").opacity(0.10)

    // Dynamic UIColors for UIKit appearance proxies (nav/tab bars).
    static let surfaceUI = UIColor { trait in
        UIColor(Color(hex: trait.userInterfaceStyle == .dark ? "1C1916" : "FFFFFF"))
    }
    static let bgUI = UIColor { trait in
        UIColor(Color(hex: trait.userInterfaceStyle == .dark ? "12100E" : "FAF6F0"))
    }
}

extension View {
    // Card container used throughout the app.
    func cardStyle() -> some View {
        self
            .padding(18)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }

    // Adds a "완료" button above the keyboard so number-pad fields (which have
    // no return key) can be dismissed, plus swipe-to-dismiss.
    func keyboardDismissable() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("완료") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                }
            }
    }

    // Bordered field container that signals "this is editable".
    func inputBox() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
            )
    }
}
