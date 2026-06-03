import SwiftUI

// Centralized visual language. Warm-dark editorial palette with a single
// gold accent, kept consistent with a "quiet money" aesthetic.
enum Theme {
    static let bg          = Color(hex: "12100E")
    static let surface     = Color(hex: "1C1916")
    static let surfaceHigh = Color(hex: "262119")
    static let accent      = Color(hex: "E8A33D")
    static let accentSoft  = Color(hex: "E8A33D").opacity(0.15)
    static let positive    = Color(hex: "4CAF8E")
    static let negative    = Color(hex: "EF6B5B")
    static let textPrimary = Color(hex: "F5F0E8")
    static let textSecond  = Color(hex: "A39E94")
    static let hairline    = Color(hex: "F5F0E8").opacity(0.08)
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
