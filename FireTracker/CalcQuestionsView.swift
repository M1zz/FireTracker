import SwiftUI
import LeeoKit

// 계산 탭 — 질문으로 계산기 고르기.
//
// 계산기가 여덟 개라 처음부터 다 늘어놓으면 무엇을 눌러야 할지 모른다.
// 그래서 계산기 이름 대신 "이게 궁금하신가요?" 를 먼저 묻고, 그렇다고 하면
// 그 답을 내는 계산기를 계산 탭에 넣을지 한 번 더 묻는다. 넣은 계산기만 칩으로 보인다.

typealias SimMode = SimulatorView.SimMode

extension SimulatorView.SimMode {
    /// 이 계산기가 답하는 질문 — 사용자가 실제로 헷갈려 하는 말로.
    var question: String {
        switch self {
        case .lifecycle:    return String(localized: "지금처럼 모으면 은퇴 후 몇 살까지 버틸 수 있을지 궁금하신가요?")
        case .invest:       return String(localized: "지금 자산이 10년 뒤에 얼마가 될지 궁금하신가요?")
        case .debtVsInvest: return String(localized: "빚을 먼저 갚는 게 나을지, 투자하는 게 나을지 헷갈리시나요?")
        case .loan:         return String(localized: "대출을 받으면 매달 얼마씩 갚아야 하는지 궁금하신가요?")
        case .savings:      return String(localized: "예금이나 적금 만기에 실제로 얼마를 받는지 궁금하신가요?")
        case .wage:         return String(localized: "월급은 올랐는데 왜 살림은 그대로인지 궁금하신가요?")
        case .time:         return String(localized: "돈을 써서 시간을 사는 게 이득인지 헷갈리시나요?")
        case .ruler:        return String(localized: "내 자산이 물가나 금값보다 정말 더 오른 건지 헷갈리시나요?")
        }
    }

    /// 칩 이름의 번역된 글자 — 문장 안에 넣을 때 쓴다.
    var titleText: String { String(localized: String.LocalizationValue(rawValue)) }
}

/// 계산 탭에 넣어 둔 계산기 목록. `metricKey` 를 쉼표로 이어 UserDefaults 에 둔다.
enum CalcShelf {
    static let key = "calc.shelf"

    /// 처음 한 번 정하는 값. 계산기를 이미 써 본 사람(`sim.` 값이 남아 있음)은
    /// 하던 대로 전부 보이게 두고, 새로 온 사람은 비워서 질문부터 보여 준다.
    static var initial: String {
        let used = UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix("sim.") }
        return used ? SimMode.allCases.map(\.metricKey).joined(separator: ",") : ""
    }

    static func modes(_ raw: String) -> [SimMode] {
        let keys = Set(raw.split(separator: ",").map(String.init))
        return SimMode.allCases.filter { keys.contains($0.metricKey) }
    }

    static func adding(_ m: SimMode, to raw: String) -> String {
        (modes(raw) + [m]).map(\.metricKey).joined(separator: ",")
    }

    static func removing(_ m: SimMode, from raw: String) -> String {
        modes(raw).filter { $0 != m }.map(\.metricKey).joined(separator: ",")
    }
}

/// 질문 카드 목록. 계산기가 하나도 없을 땐 계산 탭 본문에, 있으면 [+] 시트에 뜬다.
struct CalcQuestionList: View {
    @Binding var shelfRaw: String
    let onAdd: (SimMode) -> Void

    @EnvironmentObject private var pro: LeeoStore
    @State private var asking: SimMode?

    private var shelf: [SimMode] { CalcShelf.modes(shelfRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("무엇이 궁금하세요?")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("궁금한 질문을 고르면 그 답을 계산해 주는 계산기를 계산 탭에 넣어 드려요.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            ForEach(SimMode.allCases) { m in
                card(m)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: asking)
        .animation(.easeInOut(duration: 0.2), value: shelfRaw)
    }

    private func card(_ m: SimMode) -> some View {
        let added = shelf.contains(m)
        let locked = m.proFeature.map { !pro.access.allows($0.rawValue) } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(m.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                        .accessibilityLabel("Plus")
                }
            }

            if added {
                HStack {
                    Label("추가됨", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.positive)
                    Spacer()
                    Button("빼기") { shelfRaw = CalcShelf.removing(m, from: shelfRaw) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                        .buttonStyle(.plain)
                }
            } else if asking == m {
                Text("‘\(m.titleText)’ 계산기가 이 질문에 답해 줘요. 계산 탭에 추가할까요?")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    capsule(String(localized: "추가하기"), filled: true) {
                        shelfRaw = CalcShelf.adding(m, to: shelfRaw)
                        asking = nil
                        onAdd(m)
                    }
                    capsule(String(localized: "다음에"), filled: false) { asking = nil }
                }
            } else {
                capsule(String(localized: "네, 궁금해요"), filled: false) { asking = m }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func capsule(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(filled ? Theme.accent : Theme.surfaceHigh)
                .foregroundStyle(filled ? Color.black : Theme.textPrimary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
