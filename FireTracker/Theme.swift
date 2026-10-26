import SwiftUI

// A color that resolves to a different hex in light vs dark mode, so the whole
// app follows the system appearance.
extension Color {
    init(light: String, dark: String) {
        self = Color(uiColor: UIColor { trait in
            UIColor(Color(hexCode: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

// Centralized visual language. Toplify 를 본뜬 중립 팔레트 — 밝으면 옅은 회색 바탕에
// 흰 카드, 어두우면 검정 바탕에 짙은 회색 카드. 색은 브랜드 골드와 좋음(초록)·나쁨(빨강)만.
enum Theme {
    static let bg          = Color(light: "F2F2F5", dark: "000000")
    static let surface     = Color(light: "FFFFFF", dark: "1C1C1E")
    static let surfaceHigh = Color(light: "EDEDF0", dark: "2C2C2E")
    // Same gold in both modes so black-on-accent buttons stay legible.
    static let accent      = Color(hexCode: "E8A33D")
    static let accentSoft  = accent.opacity(0.15)
    static let positive    = Color(light: "1FA05A", dark: "34C759")
    static let negative    = Color(light: "E5484D", dark: "FF6B6B")
    // 금액 변화 방향(한국식): 오르면 붉은색, 내리면 푸른색.
    static let rise        = Color(light: "D6493B", dark: "EF5350")
    static let fall        = Color(light: "2F6FE0", dark: "4C8DFF")
    static let textPrimary = Color(light: "111113", dark: "FFFFFF")
    static let textSecond  = Color(light: "6E6E73", dark: "98989F")
    static let hairline    = Color(light: "111113", dark: "FFFFFF").opacity(0.08)

    // 화면 좌우 여백 — 카드가 화면 폭을 거의 다 쓰게 좁게 둔다.
    static let gutter: CGFloat = 12
    static let cardRadius: CGFloat = 24

    // Dynamic UIColors for UIKit appearance proxies (nav/tab bars).
    static let surfaceUI = UIColor { trait in
        UIColor(Color(hexCode: trait.userInterfaceStyle == .dark ? "1C1C1E" : "FFFFFF"))
    }
    static let bgUI = UIColor { trait in
        UIColor(Color(hexCode: trait.userInterfaceStyle == .dark ? "000000" : "F2F2F5"))
    }
}

extension View {
    // Card container used throughout the app.
    func cardStyle() -> some View {
        self
            .padding(18)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            // 밝은 화면에선 테두리 대신 옅은 그림자로 카드를 띄운다(어두우면 거의 안 보임).
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
    }

    // 숫자 하나를 담는 작은 타일 — 카드보다 여백만 줄였다.
    func tileStyle() -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
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

// 한 줄 행(이름 … 금액·칩·버튼) — 한 줄에 들어가면 한 줄, 안 들어가면 뒤쪽을 다음 줄로 통째로 내린다.
// '…'로 자르지도, 단어 중간에서 쪼개지도 않게. 뒤쪽(trailing)은 언제나 한 덩어리로 둔다.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = 8
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) {
                leading
                Spacer(minLength: spacing)
                trailing.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                leading.fixedSize(horizontal: false, vertical: true)
                trailing.fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
