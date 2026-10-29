import SwiftUI
import SwiftData
import Charts
import TipKit
import LeeoKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// 계산 탭 — 참고용 시뮬레이터 모음.
// 생애주기(모으고 쓰는 인생 자산 곡선) · 대출(종류별 상환 흐름) ·
// 저축(예금·적금·파킹 만기 수령액) · 투자(내 자산의 앞으로의 범위 예측) ·
// 구매력(과거 월급을 물가로 나눈 실질임금 = 내 구매력 변화) ·
// 시간(돈을 시간으로 환산해 하루의 밀도·순증, 저장 vs 시급 성장을 비교).
struct SimulatorView: View {
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]
    // 마지막으로 보던 계산 모드를 저장해 다시 와도 그대로.
    @AppStorage("sim.mode") private var mode: SimMode = .lifecycle
    @EnvironmentObject private var pro: LeeoStore
    @State private var paywallFeature: ProFeature?

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var totalNet: Double { assets.reduce(0) { $0 + $1.netValue } }
    // 지금 자산이 만드는 월 패시브 인컴(배당·월세·이자 + 수동 입력 배당).
    private var monthlyPassive: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
    }
    // 등록한 부채 합계(양수) — '빚 vs 투자'의 투입 금액 기본값.
    private var totalDebt: Double {
        assets.filter(\.isDebt).reduce(0) { $0 + abs($1.netValue) }
    }

    // 순서 = 퇴사각에 가까운 순. 앞의 셋이 "언제 그만둘 수 있나"를 직접 다루고,
    // 뒤의 넷은 그 답을 바꾸는 생활의 결정(빚·저축·월급·시간)을 다룬다.
    enum SimMode: String, CaseIterable, Identifiable {
        case lifecycle = "생애주기"
        case invest = "투자"
        case debtVsInvest = "빚 vs 투자"
        case loan = "대출"
        case savings = "저축"
        case wage = "구매력"
        case time = "시간"
        var id: String { rawValue }

        /// 칩에 보이는 이름.
        var title: LocalizedStringKey { LocalizedStringKey(rawValue) }

        /// 이 계산이 퇴사각과 어떻게 이어지는지 한 줄.
        var purpose: LocalizedStringKey {
            switch self {
            case .lifecycle:    return "모으는 시기와 쓰는 시기를 한 곡선으로 그려, 은퇴 후 자산이 몇 살까지 버티는지 봐요."
            case .invest:       return "지금 자산이 앞으로 어디까지 갈지, 좋을 때와 나쁠 때의 범위로 봐요."
            case .debtVsInvest: return "같은 돈으로 빚을 갚을까, 투자할까. 어느 쪽이 퇴사를 앞당기는지 비교해요."
            case .loan:         return "대출 상환에 매달 얼마가 묶이는지 봐요. 빚이 끝나는 날이 퇴사각을 바꿔요."
            case .savings:      return "예금·적금 만기에 얼마를 받는지, 이자에 세금은 얼마인지 계산해요."
            case .wage:         return "지난 월급을 물가로 나눠, 내 실질 구매력이 늘었는지 봐요."
            case .time:         return "돈을 내 시간으로 바꿔 보고, 자산 수익이 시급을 넘는 시점을 찾아요."
            }
        }

        /// 프로로 열리는 모드면 그 기능, 무료면 nil.
        var proFeature: ProFeature? {
            switch self {
            case .invest:       return .investForecast
            case .debtVsInvest: return .debtVsInvest
            case .wage:         return .purchasingPower
            case .time:         return .timeValue
            case .lifecycle, .loan, .savings: return nil
            }
        }

        /// 사용 통계 이벤트 이름에 쓰는 ASCII 키 (`calc_time` 처럼 나간다).
        var metricKey: String {
            switch self {
            case .lifecycle:    return "lifecycle"
            case .loan:         return "loan"
            case .savings:      return "savings"
            case .invest:       return "invest"
            case .debtVsInvest: return "debt_vs_invest"
            case .wage:         return "wage"
            case .time:         return "time"
            }
        }
    }

    /// 지금 모드가 잠겨 있으면 그 기능.
    private func lockedFeature(_ m: SimMode) -> ProFeature? {
        guard let f = m.proFeature, !pro.gate.allows(f.rawValue) else { return nil }
        return f
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                modeChips
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 4)

                // 모든 모드가 스크롤 없이 결과(차트)가 화면을 채우고, 값은 아래 패널에서 바꾼다.
                Group {
                    if let feature = lockedFeature(mode) {
                        ScrollView {
                            ProLockedCard(feature: feature) {
                                AppUsage.log(.paywallShown)
                                paywallFeature = feature
                            }
                        }
                        .scrollIndicators(.hidden)
                    } else {
                        switch mode {
                        case .lifecycle:
                            LifecycleSimSection(settings: settings, startAssetValue: totalNet,
                                                passiveIncomeValue: monthlyPassive)
                        case .loan: MortgageSimSection()
                        case .savings: SavingsSimSection()
                        case .invest: InvestForecastSection()
                        case .debtVsInvest:
                            // 입력 위주의 비교표라 이 모드만 스크롤로 둔다.
                            ScrollView {
                                WhatIfView(defaultAmount: totalDebt,
                                           defaultInvestRatePct: settings.expectedAnnualReturn * 100,
                                           embedded: true)
                            }
                            .scrollIndicators(.hidden)
                            .keyboardDismissable()
                        case .wage: WageSimSection()
                        case .time: TimeSimSection(settings: settings, netWorth: totalNet)
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("계산")
            .navigationBarTitleDisplayMode(.inline)
            .proPaywall($paywallFeature)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        // 불러오면 저장해 둔 모드가 펼쳐진 채로 돌아온다.
                        SavedCalcsView(onRestore: { mode = savedMode })
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .accessibilityLabel("저장한 계산")
                }
            }
        }
    }

    // 모드가 6개라 세그먼트로는 '생애주기' 같은 라벨이 잘린다 → 가로 스크롤 칩.
    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SimMode.allCases) { m in
                    Button {
                        mode = m
                        AppUsage.logCalc(m.metricKey)
                    } label: {
                        HStack(spacing: 4) {
                            if lockedFeature(m) != nil {
                                Image(systemName: "lock.fill")
                            }
                            Text(m.title)
                        }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(mode == m ? Theme.accent : Theme.surfaceHigh)
                            .foregroundStyle(mode == m ? Color.black : Theme.textSecond)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    /// 불러오기가 UserDefaults에 적어 둔 모드를 읽어 온다.
    /// (@AppStorage는 바깥에서 값이 바뀌어도 곧바로 따라오지 않아 직접 읽는다.)
    private var savedMode: SimMode {
        let raw = UserDefaults.standard.string(forKey: "sim.mode") ?? ""
        return SimMode(rawValue: raw) ?? mode
    }
}

// MARK: - 공용 입력 UI

// 모든 계산의 [해석·저장] 시트 맨 아래에 붙는 안내.
var simDisclaimer: some View {
    Text("입력값을 바탕으로 계산한 참고용 결과예요. 세금·수수료·시장 변동에 따라 실제와 다를 수 있습니다.")
        .font(.caption2)
        .foregroundStyle(Theme.textSecond)
        .frame(maxWidth: .infinity, alignment: .leading)
}

// 계산 결과를 자산/설정으로 보내는 큰 액션 버튼 — 확인 다이얼로그 포함.
private func simActionButton(title: String, done: Bool,
                            confirmTitle: String, confirmMessage: String,
                            isPresented: Binding<Bool>,
                            action: @escaping () -> Void) -> some View {
    Button { isPresented.wrappedValue = true } label: {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "plus.circle.fill")
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if !done { Image(systemName: "arrow.right") }
        }
        .foregroundStyle(done ? Theme.positive : Color.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(done ? Theme.surfaceHigh : Theme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(done)
    .confirmationDialog(confirmTitle, isPresented: isPresented, titleVisibility: .visible) {
        Button("추가하기") { action() }
        Button("취소", role: .cancel) {}
    } message: { Text(confirmMessage) }
}

private func simStat(_ label: String, _ value: String, tint: Color = Theme.textPrimary) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(label)
            .font(.caption2)
            .foregroundStyle(Theme.textSecond)
        Text(value)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - 결과 중심 한 화면 — 공용 조각
//
// 모든 계산 모드가 같은 모양을 쓴다:
//   판정 한 줄 + [해석·저장] → 핵심 숫자 둘 → 남는 높이를 다 쓰는 차트 → 조작 패널.
// 설명 글·부가 옵션·저장은 [해석·저장] 시트로 빼서 차트 자리를 지킨다.

// 선택 칩 하나 — 대출 종류·상환 방식처럼 숫자가 아닌 입력.
struct SimOption: Identifiable {
    let id: String
    let selected: Bool
    let action: () -> Void
}

// 조작 패널에서 바꿀 수 있는 값 하나. value 가 있으면 슬라이더, options 가 있으면 선택 칩.
struct SimLever: Identifiable {
    let id: String               // 칩 라벨
    var value: Binding<Double>? = nil
    var range: ClosedRange<Double> = 0...1
    var step: Double = 1
    var text: String = ""        // 큰 글씨로 보이는 지금 값
    var unit: Double = 1         // 직접 입력 단위(금액은 만원)
    var unitLabel: String = ""
    var options: [SimOption] = []

    // 지금 값이 기본 범위를 벗어나 있어도 슬라이더가 그 값을 품도록 넓힌다.
    static func fit(_ r: ClosedRange<Double>, _ v: Double) -> ClosedRange<Double> {
        min(r.lowerBound, v)...max(r.upperBound, v)
    }

    // 문자열로 저장된 금액 칸(원) — 직접 입력은 만원 단위.
    static func money(_ label: String, _ text: Binding<String>, _ range: ClosedRange<Double>,
                      step: Double, prefix: String = "") -> SimLever {
        let b = Binding<Double>(get: { Double(text.wrappedValue) ?? 0 },
                                set: { text.wrappedValue = String(Int($0.rounded())) })
        return SimLever(id: label, value: b, range: fit(range, b.wrappedValue), step: step,
                        text: String(localized: "\(prefix)\(Fmt.krw(b.wrappedValue))원"), unit: 10_000, unitLabel: String(localized: "만원"))
    }

    // 문자열로 저장된 % 칸 — 소수 한 자리까지.
    static func percent(_ label: String, _ text: Binding<String>, _ range: ClosedRange<Double>,
                        step: Double, prefix: String = String(localized: "연 "), suffix: String = "%") -> SimLever {
        let b = Binding<Double>(get: { Double(text.wrappedValue) ?? 0 },
                                set: { text.wrappedValue = Fmt.trimNumber(($0 * 10).rounded() / 10) })
        return SimLever(id: label, value: b, range: fit(range, b.wrappedValue), step: step,
                        text: "\(prefix)\(Fmt.trimNumber(b.wrappedValue))\(suffix)", unitLabel: suffix)
    }

    // 문자열로 저장된 정수 칸 — 년·개월·시간.
    static func count(_ label: String, _ text: Binding<String>, _ range: ClosedRange<Double>,
                      step: Double = 1, prefix: String = "", suffix: String) -> SimLever {
        let b = Binding<Double>(get: { Double(text.wrappedValue) ?? range.lowerBound },
                                set: { text.wrappedValue = String(Int($0.rounded())) })
        return SimLever(id: label, value: b, range: fit(range, b.wrappedValue), step: step,
                        text: "\(prefix)\(Int(b.wrappedValue.rounded()))\(suffix)", unitLabel: suffix)
    }

    static func choice(_ label: String, current: String, _ options: [SimOption]) -> SimLever {
        SimLever(id: label, text: current, options: options)
    }
}

// 조작 패널 — 칩으로 값을 고르고, 슬라이더·−/+ 로 밀거나 숫자를 눌러 직접 입력.
struct SimLeverPanel<Trailing: View, Footer: View>: View {
    let levers: [SimLever]
    @Binding var selection: String
    var onBeginEdit: () -> Void = {}
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var footer: Footer

    @State private var typing = false
    @State private var draft = ""

    private var current: SimLever? {
        levers.first { $0.id == selection } ?? levers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if levers.count > 1 { chips }

            HStack(alignment: .firstTextBaseline) {
                if let lv = current {
                    if let v = lv.value {
                        // 숫자를 누르면 직접 입력 — 슬라이더로 맞추기 어려운 정확한 값.
                        Button {
                            draft = Fmt.trimNumber(v.wrappedValue / lv.unit)
                            typing = true
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                valueText(lv.text)
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecond)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("눌러서 직접 입력")
                    } else {
                        valueText(lv.text)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }

            if let lv = current {
                if !lv.options.isEmpty {
                    optionChips(lv.options)
                } else if let v = lv.value {
                    HStack(spacing: 10) {
                        stepButton("minus") { nudge(lv, v, -1) }
                        Slider(value: v, in: lv.range, step: lv.step) { editing in
                            if editing { onBeginEdit() }
                        }
                        .tint(Theme.accent)
                        // 원시 숫자 대신 화면에 보이는 값(단위 포함)을 읽게 한다.
                        .accessibilityLabel(Text(LocalizedStringKey(lv.id)))
                        .accessibilityValue(lv.text)
                        stepButton("plus") { nudge(lv, v, 1) }
                    }
                }
            }

            // 차트가 높이를 다 가져가도 안내문은 '…'로 잘리지 않게.
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.surfaceHigh.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sensoryFeedback(.selection, trigger: current?.text ?? "")
        .alert("\(current?.id ?? "") 직접 입력", isPresented: $typing) {
            TextField(current?.unitLabel ?? "", text: $draft)
                .keyboardType(.decimalPad)
            Button("취소", role: .cancel) {}
            Button("적용") {
                guard let lv = current, let v = lv.value,
                      let n = Double(draft.replacingOccurrences(of: ",", with: "")) else { return }
                onBeginEdit()
                v.wrappedValue = max(0, n * lv.unit)
            }
        } message: {
            Text("단위: \(current?.unitLabel ?? "")")
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(levers) { l in
                        let on = l.id == current?.id
                        Button {
                            selection = l.id
                            withAnimation { proxy.scrollTo(l.id, anchor: .center) }
                        } label: {
                            Text(LocalizedStringKey(l.id))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(on ? Theme.textPrimary : Theme.surfaceHigh)
                                .foregroundStyle(on ? Theme.bg : Theme.textSecond)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .id(l.id)
                    }
                }
            }
        }
    }

    private func optionChips(_ options: [SimOption]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { o in
                    Button {
                        onBeginEdit()
                        o.action()
                    } label: {
                        Text(LocalizedStringKey(o.id))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(o.selected ? Theme.accent.opacity(0.2) : Theme.surface)
                            .foregroundStyle(o.selected ? Theme.accentText : Theme.textPrimary)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(o.selected ? Theme.accent.opacity(0.6) : Theme.hairline,
                                                      lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(o.selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func nudge(_ lv: SimLever, _ v: Binding<Double>, _ dir: Double) {
        onBeginEdit()
        let next = v.wrappedValue + lv.step * dir
        v.wrappedValue = min(max(next, lv.range.lowerBound), lv.range.upperBound)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "plus" ? "올리기" : "내리기")
    }
}

// 패널 오른쪽 위의 작은 버튼 — 되돌리기·목록 편집 같은 보조 동작.
struct SimPanelButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecond)
        }
        .buttonStyle(.plain)
    }
}

// 결과 한 줄 + [해석·저장] 버튼.
struct SimResultHeader: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Theme.textPrimary
    let onInfo: () -> Void
    var body: some View {
        // 판정 … [해석·저장] — 한 줄에 안 들어가면 버튼을 판정 아래 줄로 내린다.
        AdaptiveRow(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(tint)
            }
        } trailing: {
            // 해석·가정·저장은 따로 띄워 차트 자리를 지킨다.
            Button(action: onInfo) {
                Label("해석·저장", systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceHigh, in: Capsule())
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }
}

// [해석·저장] 이나 목록 편집처럼 결과 화면 위로 띄우는 시트의 틀.
struct SimSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(.horizontal, Theme.gutter).padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// 시트 안의 글 카드 — 제목 + 내용.
struct SimInfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// 결과 카드 바깥 틀 — 남는 높이를 다 쓰게.
extension View {
    func simResultCard() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardStyle()
    }
}

private func simLegend(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 5) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(text).foregroundStyle(Theme.textSecond)
    }
    .font(.caption2)
}

// MARK: - 생애주기 자산 시뮬레이션

private struct LifecycleSimSection: View {
    // 설정·현재 자산은 처음 한 번만 미리 채우고, 이후엔 사용자가 바꾼 값을 저장·유지.
    let settings: FireSettings
    let startAssetValue: Double
    let passiveIncomeValue: Double

    @AppStorage("sim.life.currentAge")   private var currentAge = ""
    @AppStorage("sim.life.retireAge")    private var retireAge = ""
    @AppStorage("sim.life.endAge")       private var endAge = "90"
    @AppStorage("sim.life.startAsset")   private var startAsset = ""
    @AppStorage("sim.life.grossSalary")  private var grossSalary = "50000000"
    @AppStorage("sim.life.raisePct")     private var raisePct = "3"
    @AppStorage("sim.life.monthlyLiving") private var monthlyLiving = ""
    @AppStorage("sim.life.retireMonthly") private var retireMonthly = ""
    @AppStorage("sim.life.retirePension") private var retirePension = "0"
    @AppStorage("sim.life.passiveMonthly") private var passiveMonthly = ""
    @AppStorage("sim.life.returnPct")    private var returnPct = ""
    @AppStorage("sim.life.inflationPct") private var inflationPct = "2.5"
    // C — 수익률이 해마다 출렁이는 폭(변동성). 밴드의 넓이를 정한다.
    @AppStorage("sim.life.volatilityPct") private var volatilityPct = "12"
    // B — 규모별 수익률 가정. 켜면 자산이 클수록 연 수익률을 조금씩 더해준다.
    // Fagereng(2020)·Piketty 근거이되 '낙관 가정'이므로 기본은 꺼둔다.
    @AppStorage("sim.life.scaleReturns") private var scaleReturns = false
    @AppStorage("sim.life.seeded")       private var seeded = false

    @Environment(\.modelContext) private var context
    @State private var showReflectConfirm = false
    @State private var reflected = false
    // 차트 바로 아래 조작 패널 — 고른 값 하나를 슬라이더로 밀면 곡선이 바로 바뀐다.
    @State private var leverID = Lever.retireMonthly.rawValue
    // 처음 만지기 직전의 곡선. 점선으로 남겨 '얼마나 달라졌나'를 보이게 한다.
    @State private var baseline: Baseline?
    // 차트를 손가락으로 훑을 때 고른 나이.
    @State private var selectedAge: Int?
    @State private var showInfo = false

    // 4단계 "충분의 거울" 성찰 팁 — 쓰는 흐름 속에서 질문을 던진다.
    private let vanityMirrorTip = VanityMirrorTip()   // 1단계 — 월 생활비
    private let bucketListTip = BucketListTip()        // 2단계 — 희망 월수령액
    private let enoughAnchorTip = EnoughAnchorTip()    // 3단계 — 판정 카드

    // 최초 1회만 설정·현재 자산값으로 빈 칸을 채운다(이후엔 저장된 값 유지).
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        if currentAge.isEmpty   { currentAge = settings.currentAge > 0 ? String(settings.currentAge) : "30" }
        if retireAge.isEmpty    { retireAge = settings.targetRetireAge > 0 ? String(settings.targetRetireAge) : "60" }
        if startAsset.isEmpty   { startAsset = startAssetValue > 0 ? String(Int(startAssetValue)) : "0" }
        if monthlyLiving.isEmpty { monthlyLiving = settings.plannedMonthlyExpense > 0 ? String(Int(settings.plannedMonthlyExpense)) : "2500000" }
        if retireMonthly.isEmpty { retireMonthly = settings.incomeGoalMonthly > 0 ? String(Int(settings.incomeGoalMonthly)) : "3000000" }
        if returnPct.isEmpty    { returnPct = settings.expectedAnnualReturn > 0 ? Fmt.trimNumber(settings.expectedAnnualReturn * 100) : "4" }
        if passiveMonthly.isEmpty { passiveMonthly = passiveIncomeValue > 0 ? String(Int(passiveIncomeValue)) : "0" }
    }

    private struct LifePoint: Identifiable {
        let id = UUID()
        let age: Int
        let value: Double
        let phase: String
    }

    // 세전 연봉 → 세후 근사 (사회보험료 + 누진세 실효율 구간 근사).
    private func netAnnual(_ gross: Double) -> Double {
        let rate: Double
        switch gross {
        case ..<30_000_000:  rate = 0.90
        case ..<50_000_000:  rate = 0.86
        case ..<80_000_000:  rate = 0.82
        case ..<120_000_000: rate = 0.76
        case ..<200_000_000: rate = 0.70
        default:             rate = 0.62
        }
        return gross * rate
    }

    // B — 규모별 수익률. 자산이 클수록 연 수익률을 단계적으로 더한다(낙관 가정).
    // 근거: 큰 자산일수록 리스크 감내·대체투자 접근·낮은 수수료로 평균 수익이 높다
    // (Fagereng 2020; Piketty 기금 사례 — 규모 클수록 실질수익 ~2%p 높음).
    private func scaledReturn(base r: Double, asset: Double) -> Double {
        guard scaleReturns else { return r }
        let bump: Double
        switch asset {
        case ..<300_000_000:    bump = 0       // 3억 미만
        case ..<1_000_000_000:  bump = 0.005   // 3~10억  +0.5%p
        case ..<5_000_000_000:  bump = 0.010   // 10~50억 +1.0%p
        default:                bump = 0.015   // 50억+   +1.5%p
        }
        return r + bump
    }

    private var ages: (cur: Int, retire: Int, end: Int) {
        let cur = max(15, Int(currentAge) ?? 30)
        let retire = max(cur + 1, Int(retireAge) ?? 60)
        let end = max(retire + 1, Int(endAge) ?? 90)
        return (cur, retire, end)
    }

    // 연 단위 시뮬레이션: 일할 땐 (세후소득 − 생활비)를 모으고, 은퇴 후엔
    // 희망 월수령액(물가 반영)을 꺼내 쓴다. 자산엔 매년 수익률이 붙는다.
    private var sim: (points: [LifePoint], peak: Double, end: Double, depletionAge: Int?, crossoverAge: Int?) {
        let a = ages
        var asset = Double(startAsset) ?? 0
        let r = (Double(returnPct) ?? 0) / 100
        let infl = (Double(inflationPct) ?? 0) / 100
        let raise = (Double(raisePct) ?? 0) / 100
        var salary = Double(grossSalary) ?? 0
        var living = (Double(monthlyLiving) ?? 0) * 12
        let wantYear = (Double(retireMonthly) ?? 0) * 12
        let pensionYear = (Double(retirePension) ?? 0) * 12
        let passiveYear = (Double(passiveMonthly) ?? 0) * 12

        var pts: [LifePoint] = [LifePoint(age: a.cur, value: asset, phase: String(localized: "모으는 시기"))]
        var peak = asset
        var depletion: Int? = nil
        // 분기점 — 한 해 투자수익(자산×수익률)이 그 해 순저축을 넘어서는 첫 나이.
        // 이때부터 곡선이 직선(저축 주도)에서 지수(수익 주도)로 휘기 시작한다.
        var crossover: Int? = nil
        for age in (a.cur + 1)...a.end {
            let working = age <= a.retire
            let yearsOut = Double(age - a.cur)
            let rEff = scaledReturn(base: r, asset: asset)  // B — 규모 반영 수익률
            // 성장 적용 전에, 이 해의 수익과 순저축을 비교해 분기점을 잡는다.
            if working, crossover == nil {
                let yearReturn = asset * rEff
                let yearSavings = netAnnual(salary) - living
                if yearSavings > 0, yearReturn >= yearSavings { crossover = age }
            }
            asset *= (1 + rEff)
            // 패시브 인컴(배당·월세)은 일할 때도 은퇴 후에도 들어온다.
            // 물가만큼 자라는 것으로 가정(임대료·배당 성장 근사).
            asset += passiveYear * pow(1 + infl, yearsOut)
            if working {
                asset += netAnnual(salary) - living
                salary *= (1 + raise)
                living *= (1 + infl)
            } else {
                asset += pensionYear - wantYear * pow(1 + infl, yearsOut)
            }
            if asset <= 0, depletion == nil, age > a.retire { depletion = age }
            asset = max(0, asset)
            let phase = working ? String(localized: "모으는 시기") : String(localized: "쓰는 시기")
            pts.append(LifePoint(age: age, value: asset, phase: phase))
            if age == a.retire {
                peak = asset
                // 경계점을 양쪽 단계에 모두 넣어 라인이 끊기지 않게.
                pts.append(LifePoint(age: age, value: asset, phase: String(localized: "쓰는 시기")))
            }
        }
        return (pts, peak, asset, depletion, crossover)
    }

    // MARK: - 변동성 밴드 (C — 단일 선의 거짓 정밀함을 부채꼴로)
    //
    // 단일 수익률 선은 "딱 이렇게 된다"는 환상을 준다. 실제 수익은 해마다 출렁이고,
    // 그 불확실성은 시간이 갈수록 벌어진다(sequence-of-returns risk). 그래서 같은
    // 모델을 수익률만 정규분포로 흔들어 여러 번 돌리고(몬테카를로), 가운데 50%
    // 구간(p25~p75)을 띠로 그린다. 시드를 고정해 입력이 같으면 띠도 흔들리지 않는다.

    private struct BandPoint: Identifiable { let id = UUID(); let age: Int; let low: Double; let high: Double }

    // 입력이 같으면 결과도 같은 시드 고정 난수기(xorshift64 + Box–Muller).
    private struct SeededGen {
        var state: UInt64
        mutating func uniform() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)  // [0,1)
        }
        mutating func normal() -> Double {  // 표준정규 한 표본
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    private var band: [BandPoint] {
        let a = ages
        let r = (Double(returnPct) ?? 0) / 100
        let infl = (Double(inflationPct) ?? 0) / 100
        let raise = (Double(raisePct) ?? 0) / 100
        let sigma = (Double(volatilityPct) ?? 0) / 100
        let start = Double(startAsset) ?? 0
        let salary0 = Double(grossSalary) ?? 0
        let living0 = (Double(monthlyLiving) ?? 0) * 12
        let wantYear = (Double(retireMonthly) ?? 0) * 12
        let pensionYear = (Double(retirePension) ?? 0) * 12
        let passiveYear = (Double(passiveMonthly) ?? 0) * 12
        let span = a.end - a.cur
        guard span > 0 else { return [] }

        let trials = 400
        var samples = Array(repeating: [Double](), count: span + 1)
        var gen = SeededGen(state: 0x9E37_79B9_7F4A_7C15)  // 고정 시드

        for _ in 0..<trials {
            var asset = start, salary = salary0, living = living0
            samples[0].append(asset)
            for (i, age) in ((a.cur + 1)...a.end).enumerated() {
                let yearsOut = Double(age - a.cur)
                let rEff = scaledReturn(base: r, asset: asset)  // B — 규모 반영
                asset *= (1 + rEff + sigma * gen.normal())  // 수익률만 흔든다
                asset += passiveYear * pow(1 + infl, yearsOut)
                if age <= a.retire {
                    asset += netAnnual(salary) - living
                    salary *= (1 + raise); living *= (1 + infl)
                } else {
                    asset += pensionYear - wantYear * pow(1 + infl, yearsOut)
                }
                asset = max(0, asset)
                samples[i + 1].append(asset)
            }
        }

        return samples.enumerated().map { idx, vals in
            let s = vals.sorted()
            return BandPoint(age: a.cur + idx, low: pct(s, 0.25), high: pct(s, 0.75))
        }
    }

    private func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(i, 0), sorted.count - 1)]
    }

    // 결과 판정 — 화면의 배지와 저장 목록의 한 줄이 같은 문구를 쓰도록 한곳에서 만든다.
    private var verdict: (feasible: Bool, comfy: Bool, headline: String, reason: String) {
        let result = sim
        let a = ages
        let want = Double(retireMonthly) ?? 0
        let feasible = result.depletionAge == nil
        let comfy = feasible && result.end >= result.peak
        let headline = feasible
            ? (comfy ? String(localized: "여유로운 은퇴 전략이에요") : String(localized: "은퇴 가능한 전략이에요"))
            : String(localized: "은퇴하기엔 아직 부족한 전략이에요")
        let reason: String
        if let dep = result.depletionAge {
            reason = String(localized: "은퇴 후 \(dep)세에 자산이 바닥나요. 은퇴 후 월 생활비를 줄이거나, 은퇴를 늦추거나, 수익률·저축을 높여보세요.")
        } else if comfy {
            reason = String(localized: "은퇴(\(a.retire)세) 후 월 \(Fmt.krw(want))원을 써도 \(a.end)세에 \(Fmt.krw(result.end))원이 남아요.")
        } else {
            reason = String(localized: "은퇴(\(a.retire)세) 후 월 \(Fmt.krw(want))원으로 \(a.end)세까지 버틸 수 있어요.")
        }
        return (feasible, comfy, headline, reason)
    }

    /// 저장 목록에 남길 조건 요약.
    private var conditionSummary: String {
        let a = ages
        return String(localized: "\(a.cur)세 → \(a.retire)세 은퇴 · 시작 \(Fmt.krw(Double(startAsset) ?? 0))원 · ")
            + String(localized: "연봉 \(Fmt.krw(Double(grossSalary) ?? 0))원 · 수익률 \(returnPct)% · 희망 월 \(Fmt.krw(Double(retireMonthly) ?? 0))원")
    }

    var body: some View {
        let result = sim
        let a = ages
        let v = verdict
        mainCard(result, a, v)
            .sheet(isPresented: $showInfo) { infoSheet(result, a, v) }
        .onAppear {
            seedIfNeeded()
            // 화면에 들어온 순간의 곡선을 기준으로 — 이후 무엇을 고쳐도 점선과 비교된다.
            captureBaseline()
            // 1단계 거울은 이 화면에 있을 때만 묻는다. 3단계 닻은 계산이 성립할 때.
            VanityMirrorTip.onLifecycleScreen = true
            EnoughAnchorTip.hasFeasibleResult = (sim.depletionAge == nil)
        }
        .onDisappear { VanityMirrorTip.onLifecycleScreen = false }
        // 값이 바뀌면 다시 반영할 수 있게 버튼 상태를 되돌린다.
        .onChange(of: [currentAge, retireAge, retireMonthly, returnPct, monthlyLiving, grossSalary]) { _, _ in
            reflected = false
            // 결과가 성립(은퇴 가능)할 때만 3단계 닻을 깨운다.
            EnoughAnchorTip.hasFeasibleResult = (sim.depletionAge == nil)
        }
        // 1단계(월 생활비)를 실제로 만지면 거울을 닫고, 2단계 버킷을 깨운다 — 빼기 다음 더하기.
        .onChange(of: monthlyLiving) { _, _ in
            vanityMirrorTip.invalidate(reason: .actionPerformed)
            BucketListTip.mirrorDone = true
        }
        // 2단계(희망 월수령액)를 만지면 버킷 질문은 역할을 다한 것.
        .onChange(of: retireMonthly) { _, _ in
            bucketListTip.invalidate(reason: .actionPerformed)
        }
        // B 토글은 곡선 자체를 바꾸므로 판정도 다시 계산.
        .onChange(of: scaleReturns) { _, _ in
            reflected = false
            EnoughAnchorTip.hasFeasibleResult = (sim.depletionAge == nil)
        }
    }

    // 한 화면 결과 영역 — 판정 한 줄 · 차트(남는 높이 전부) · 조작 패널.
    private func mainCard(_ result: (points: [LifePoint], peak: Double, end: Double, depletionAge: Int?, crossoverAge: Int?),
                             _ a: (cur: Int, retire: Int, end: Int),
                             _ v: (feasible: Bool, comfy: Bool, headline: String, reason: String)) -> some View {
        let tint: Color = v.feasible ? Theme.positive : Theme.negative
        let icon = v.feasible
            ? (v.comfy ? "checkmark.seal.fill" : "checkmark.circle.fill")
            : "exclamationmark.triangle.fill"
        return VStack(alignment: .leading, spacing: 10) {
            SimResultHeader(title: v.headline, icon: icon, tint: tint) { showInfo = true }
            // 3단계 — 닻: '충분한 삶'의 값을 마주하되 매일 쫓지 말라고 짚는다.
            .popoverTip(enoughAnchorTip)

            HStack(alignment: .top, spacing: 12) {
                simStat(String(localized: "은퇴(\(a.retire)세) 자산"), String(localized: "\(Fmt.krw(result.peak))원"), tint: .blue)
                if let dep = result.depletionAge {
                    simStat(String(localized: "자산 고갈"), String(localized: "\(dep)세"), tint: Theme.negative)
                } else {
                    simStat(String(localized: "\(a.end)세 잔액"), String(localized: "\(Fmt.krw(result.end))원"), tint: .orange)
                }
            }

            let bandPts = band
            Chart {
                // C — 변동성 밴드(가운데 50% 구간). 선 뒤에 깔아 부채꼴로 보이게.
                ForEach(bandPts) { b in
                    AreaMark(x: .value("나이", b.age),
                             yStart: .value("하한", b.low),
                             yEnd: .value("상한", b.high))
                        .foregroundStyle(Theme.accent.opacity(0.13))
                        .interpolationMethod(.catmullRom)
                }
                ForEach(result.points) { p in
                    LineMark(x: .value("나이", p.age), y: .value("자산", p.value))
                        .foregroundStyle(by: .value("시기", p.phase))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                RuleMark(x: .value("은퇴", a.retire))
                    .foregroundStyle(Theme.textSecond.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("은퇴")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                // A — 분기점: 수익이 저축을 앞서는 나이. "돈이 일하기 시작하는" 지점.
                if let cross = result.crossoverAge, cross < a.retire {
                    RuleMark(x: .value("분기점", cross))
                        .foregroundStyle(Theme.positive.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            Text("돈이 일함")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.positive)
                        }
                }
                PointMark(x: .value("나이", a.retire), y: .value("자산", result.peak))
                    .foregroundStyle(.blue)
                    .symbolSize(70)
                if let dep = result.depletionAge {
                    RuleMark(x: .value("고갈", dep))
                        .foregroundStyle(Theme.negative.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                // 바꾸기 전 곡선 — 같은 눈금 위에 점선으로 겹쳐 차이를 바로 보게.
                if let base = baseline, isChanged(result.points) {
                    ForEach(base.points) { p in
                        LineMark(x: .value("나이", p.age), y: .value("자산", p.value),
                                 series: .value("곡선", String(localized: "바꾸기 전")))
                            .foregroundStyle(Theme.textSecond.opacity(0.55))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                // 손가락으로 훑으면 그 나이의 자산을 읽어 준다.
                if let age = selectedAge, let p = result.points.last(where: { $0.age == age }) {
                    RuleMark(x: .value("선택", age))
                        .foregroundStyle(Theme.textPrimary.opacity(0.35))
                        .annotation(position: .top, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("\(age)세 · \(Fmt.krw(p.value))원")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.surfaceHigh, in: Capsule())
                        }
                }
            }
            .chartXSelection(value: $selectedAge)
            .chartForegroundStyleScale([String(localized: "모으는 시기"): Color.blue, String(localized: "쓰는 시기"): Color.orange])
            .chartXScale(domain: a.cur...a.end)
            .chartLegend(.hidden)
            .chartPlotStyle { $0.padding(.top, 16) }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    if let age = value.as(Int.self) {
                        AxisValueLabel {
                            Text("\(age)세")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)

            SimLeverPanel(levers: Lever.allCases.map(lever), selection: $leverID,
                          onBeginEdit: captureBaseline) {
                if isChanged(result.points) {
                    SimPanelButton(title: String(localized: "되돌리기"), icon: "arrow.uturn.backward", action: resetToBaseline)
                }
            } footer: {
                if let b = baseline, isChanged(result.points) {
                    changeSummary(result, b)
                } else {
                    Text("밀면 곡선이 바로 바뀌어요. 숫자를 누르면 직접 입력, 차트를 훑으면 나이별 자산.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            // 1단계 — 거울: 허영을 덜어낸 '진짜 나의 만족점'은 얼마인가.
            .popoverTip(vanityMirrorTip)
            // 2단계 — 버킷: 이 돈으로 무엇을 누리고 싶은가(빼기 다음 더하기).
            .popoverTip(bucketListTip)
        }
        .simResultCard()
    }

    // 정보성 글 · 가정 · 반영/저장 — 버튼을 눌렀을 때만 띄운다.
    private func infoSheet(_ result: (points: [LifePoint], peak: Double, end: Double, depletionAge: Int?, crossoverAge: Int?),
                           _ a: (cur: Int, retire: Int, end: Int),
                           _ v: (feasible: Bool, comfy: Bool, headline: String, reason: String)) -> some View {
        SimSheet(title: String(localized: "해석·저장")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("이 결과의 뜻")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(v.reason)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                // A — 분기점 설명: 곡선이 왜 휘는지.
                if let cross = result.crossoverAge, cross < a.retire {
                    Text("\(cross)세부터는 한 해 투자수익이 저축보다 커져요 — 여기서부터 돈이 당신 대신 법니다. 곡선이 직선에서 지수로 휘는 지점이에요.")
                        .font(.caption)
                        .foregroundStyle(Theme.positive)
                }
                // C — 밴드 설명: 단일 선은 환상, 띠가 현실.
                Text("음영은 수익률이 해마다 출렁일 때의 ‘가운데 50%’ 범위예요(연 변동성 \(volatilityPct.isEmpty ? "0" : volatilityPct)% 가정). 미래는 선 하나가 아니라 이 폭 안에서 움직여요 — 시간이 갈수록 넓어지죠.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                Text("파란 선은 모으는 시기, 주황 선은 쓰는 시기예요. 값을 바꾸면 바꾸기 전 곡선이 회색 점선으로 남아요.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                if scaleReturns {
                    Text("‘규모별 수익률’ 가정이 켜져 있어요 — 자산이 클수록 연 수익률을 +0.5~1.5%p 더해 계산한 낙관 시나리오예요(Fagereng 2020·Piketty). 실제로 그 초과수익엔 더 큰 리스크가 따라요.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            VStack(alignment: .leading, spacing: 12) {
                Text("가정")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("수익률 변동성")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                volatilityPresets
                // B — 규모별 수익률 토글(낙관 가정).
                Toggle(isOn: $scaleReturns) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("규모별 수익률 가정")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("자산이 클수록 연 수익률 +0.5~1.5%p (낙관)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
                .tint(Theme.accent)
                Text("세후 소득은 사회보험료·누진세 근사값이에요. 나이·자산·수익률·패시브 인컴은 설정과 등록한 자산에서 처음 한 번 채워지고, 여기서 바꾸면 이 계산에만 반영됩니다.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // 계산값을 그대로 목표·설정으로 — 따로 설정 탭에서 다시 입력할 필요 없이.
            reflectButton
            CalcSaveRow(kind: .lifecycle, headline: v.headline, detail: conditionSummary)
            simDisclaimer
        }
    }

    // MARK: - 바로 바꿔 보기 (차트 아래 조작 패널)

    // 예전 아래 카드의 입력칸을 모두 여기로 — 자주 바꾸는 순서대로.
    enum Lever: String, CaseIterable, Identifiable {
        case retireMonthly = "은퇴 후 생활비"
        case retireAge = "은퇴 나이"
        case living = "지금 생활비"
        case salary = "연봉"
        case returnPct = "수익률"
        case startAsset = "지금 자산"
        case passive = "패시브 인컴"
        case pension = "은퇴 후 연금"
        case raise = "연봉 인상률"
        case inflation = "물가"
        case volatility = "변동성"
        case currentAge = "지금 나이"
        case endAge = "계산 끝 나이"
        var id: String { rawValue }
    }

    private struct Baseline {
        let values: [String]       // leverValues 순서 그대로
        let points: [LifePoint]
        let peak: Double
        let end: Double
        let depletionAge: Int?
    }

    private func lever(_ l: Lever) -> SimLever {
        let ag = ages
        switch l {
        case .retireMonthly: return .money(l.rawValue, $retireMonthly, 500_000...15_000_000, step: 100_000, prefix: String(localized: "월 "))
        case .living:        return .money(l.rawValue, $monthlyLiving, 500_000...10_000_000, step: 100_000, prefix: String(localized: "월 "))
        case .salary:        return .money(l.rawValue, $grossSalary, 10_000_000...300_000_000, step: 1_000_000, prefix: String(localized: "연 "))
        case .startAsset:    return .money(l.rawValue, $startAsset, 0...3_000_000_000, step: 10_000_000)
        case .passive:       return .money(l.rawValue, $passiveMonthly, 0...5_000_000, step: 50_000, prefix: String(localized: "월 "))
        case .pension:       return .money(l.rawValue, $retirePension, 0...5_000_000, step: 50_000, prefix: String(localized: "월 "))
        case .returnPct:     return .percent(l.rawValue, $returnPct, 0...12, step: 0.5)
        case .raise:         return .percent(l.rawValue, $raisePct, 0...10, step: 0.5)
        case .inflation:     return .percent(l.rawValue, $inflationPct, 0...6, step: 0.1)
        case .volatility:    return .percent(l.rawValue, $volatilityPct, 0...30, step: 1)
        // 나이는 서로 물려 있어(지금 < 은퇴 < 끝) 보정된 값으로 읽는다.
        case .retireAge:
            let b = Binding<Double>(get: { Double(ages.retire) },
                                    set: { retireAge = String(Int($0.rounded())) })
            return SimLever(id: l.rawValue, value: b,
                            range: Double(ag.cur + 1)...Double(max(ag.cur + 2, 80, ag.retire)),
                            step: 1, text: String(localized: "\(ag.retire)세"), unitLabel: String(localized: "세"))
        case .currentAge:
            let b = Binding<Double>(get: { Double(ages.cur) },
                                    set: { currentAge = String(Int($0.rounded())) })
            return SimLever(id: l.rawValue, value: b, range: 15...Double(max(80, ag.cur)),
                            step: 1, text: String(localized: "\(ag.cur)세"), unitLabel: String(localized: "세"))
        case .endAge:
            let b = Binding<Double>(get: { Double(ages.end) },
                                    set: { endAge = String(Int($0.rounded())) })
            return SimLever(id: l.rawValue, value: b, range: Double(ag.retire + 1)...Double(max(110, ag.end)),
                            step: 1, text: String(localized: "\(ag.end)세까지"), unitLabel: String(localized: "세"))
        }
    }

    private var leverValues: [String] {
        [retireMonthly, retireAge, returnPct, monthlyLiving, grossSalary, startAsset, passiveMonthly,
         retirePension, inflationPct, endAge, volatilityPct, currentAge, raisePct]
    }

    // 아래 카드의 어느 칸을 고쳐도 잡히도록 값이 아니라 곡선 자체를 비교한다.
    private func isChanged(_ points: [LifePoint]) -> Bool {
        guard let b = baseline else { return false }
        return b.points.map(\.value) != points.map(\.value) || b.points.map(\.age) != points.map(\.age)
    }

    // 처음 만질 때 한 번만 지금 곡선을 기준으로 잡는다.
    private func captureBaseline() {
        guard baseline == nil else { return }
        let r = sim
        baseline = Baseline(values: leverValues, points: r.points, peak: r.peak,
                            end: r.end, depletionAge: r.depletionAge)
    }

    private func resetToBaseline() {
        guard let b = baseline, b.values.count == 13 else { return }
        let v = b.values
        retireMonthly = v[0]; retireAge = v[1]; returnPct = v[2]; monthlyLiving = v[3]
        grossSalary = v[4]; startAsset = v[5]; passiveMonthly = v[6]; retirePension = v[7]
        inflationPct = v[8]; endAge = v[9]; volatilityPct = v[10]; currentAge = v[11]
        raisePct = v[12]
    }

    // 바꾸기 전 → 지금. 은퇴 시점 자산과 끝(잔액 또는 고갈 나이)만 짧게.
    private func changeSummary(_ r: (points: [LifePoint], peak: Double, end: Double, depletionAge: Int?, crossoverAge: Int?),
                               _ b: Baseline) -> some View {
        let endText: (Double, Int?) -> String = { end, dep in
            if let dep { return String(localized: "\(dep)세 고갈") }
            return String(localized: "\(Fmt.krw(end))원 남음")
        }
        let better = (r.depletionAge ?? 999, r.end) >= (b.depletionAge ?? 999, b.end)
        return VStack(alignment: .leading, spacing: 3) {
            Text("은퇴 때 \(Fmt.krw(b.peak))원 → \(Fmt.krw(r.peak))원")
            Text("\(ages.end)세에 \(endText(b.end, b.depletionAge)) → \(endText(r.end, r.depletionAge))")
                .foregroundStyle(better ? Theme.positive : Theme.negative)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
        .monospacedDigit()
    }

    // 변동성 빠른 프리셋 — 보수(8)/균형(12)/공격(18)으로 한 탭 세팅.
    private var volatilityPresets: some View {
        HStack(spacing: 8) {
            ForEach([(String(localized: "보수 8%"), "8"), (String(localized: "균형 12%"), "12"), (String(localized: "공격 18%"), "18")], id: \.0) { label, value in
                Button { volatilityPct = value } label: {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(volatilityPct == value ? Theme.accent.opacity(0.25) : Theme.surfaceHigh)
                        .foregroundStyle(Theme.textPrimary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(volatilityPct == value ? Theme.accent : Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // 계산값을 그대로 목표·설정(설정 탭)으로 보내는 버튼.
    private var reflectButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showReflectConfirm = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: reflected ? "checkmark.circle.fill" : "target")
                    Text(reflected ? "내 목표에 반영됨" : "이 값을 내 목표에 반영")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !reflected { Image(systemName: "arrow.right") }
                }
                .foregroundStyle(reflected ? Theme.positive : Color.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .background(reflected ? Theme.surfaceHigh : Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .confirmationDialog("내 목표를 이 계산값으로 덮어쓸까요?",
                                isPresented: $showReflectConfirm, titleVisibility: .visible) {
                Button("반영하기") { reflectToSettings() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("나이·은퇴 나이·연 수익률, 은퇴 후 월 지출(희망 월수령액), 월 생활비, 세후 월급이 내 목표(여정 탭)에 저장되고 대시보드 퇴사각에 바로 반영됩니다. (현재 패시브 인컴은 보유 자산에서 자동 계산되므로 바꾸지 않아요.)")
            }
            if reflected {
                Text("내 목표에 반영했어요. 대시보드 퇴사각이 이 값으로 다시 계산돼요.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }

    // 계산 입력값을 FireSettings에 기록 — 설정 탭과 대시보드 목표가 같은 값을 쓰게 한다.
    private func reflectToSettings() {
        // 설정 레코드가 아직 컨텍스트에 없으면(드묾) 먼저 넣어 반영이 저장되게 한다.
        if settings.modelContext == nil { context.insert(settings) }
        if let v = Int(currentAge), v > 0 { settings.currentAge = v }
        if let v = Int(retireAge), v > 0 { settings.targetRetireAge = v }
        if let v = Double(returnPct), v > 0 { settings.expectedAnnualReturn = v / 100 }
        // 희망 월수령액 = 은퇴 후 월 지출 → FIRE 목표·목표 패시브 인컴의 기준.
        if let v = Double(retireMonthly), v > 0 { settings.targetAnnualExpense = v * 12 }
        if let v = Double(monthlyLiving), v > 0 { settings.plannedMonthlyExpense = v }
        if let g = Double(grossSalary), g > 0 { settings.monthlyTakeHome = (netAnnual(g) / 12).rounded() }
        // 직접 넣은 월 저축이 월급−생활비보다 우선하므로, 그대로 두면 방금 반영한
        // 월급·생활비가 예측에 안 쓰인다. 둘 다 있으면 월 저축도 같이 맞춘다.
        if settings.monthlyTakeHome > 0, settings.plannedMonthlyExpense > 0 {
            settings.plannedNetSavings = settings.monthlyTakeHome - settings.plannedMonthlyExpense
        }
        FireSettings.markGoalConfigured()
        // 월 패시브 인컴은 계산용 입력(자산에서 미리 채운 값)이라 반영하지 않는다.
        // 현재 패시브 인컴은 실제 보유 자산(주식 배당 등)에서만 나와야 한다.
        guard context.saveReporting(String(localized: "목표")) else { return }
        reflected = true
        // 만족점을 다시 확정한 순간 — 4단계 재점검 타이머를 리셋하고 닻 질문은 닫는다.
        ReflectionState.markReviewed()
        enoughAnchorTip.invalidate(reason: .actionPerformed)
    }
}

// MARK: - 주담대 상환 시뮬레이션

private struct MortgageSimSection: View {
    @AppStorage("sim.mtg.principal") private var principal = "300000000"
    @AppStorage("sim.mtg.ratePct")   private var ratePct = "4.2"
    @AppStorage("sim.mtg.years")     private var years = "30"
    @AppStorage("sim.mtg.method")    private var method: RepayMethod = .equalPayment
    // 대출 종류 — 고르면 원금·금리·기간·상환방식이 그 대출의 일반적인 조건으로 채워진다.
    @AppStorage("sim.mtg.kind")      private var loanKind: LoanKind = .mortgage

    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @State private var added = false
    @State private var showAddConfirm = false
    @State private var showInfo = false
    @State private var leverID = String(localized: "원금")

    enum RepayMethod: String, CaseIterable, Identifiable {
        case equalPayment = "원리금균등"
        case equalPrincipal = "원금균등"
        case bullet = "만기일시"
        var id: String { rawValue }
    }

    enum LoanKind: String, CaseIterable, Identifiable {
        case mortgage = "주담대"
        case jeonse   = "전세대출"
        case credit   = "신용대출"
        case car      = "자동차 할부"
        case minus    = "마이너스통장"
        var id: String { rawValue }

        // 자산 탭에 부채로 추가할 때 쓰는 정식 이름.
        var assetName: String {
            switch self {
            case .mortgage: return String(localized: "주택담보대출")
            case .jeonse:   return String(localized: "전세자금대출")
            case .credit:   return String(localized: "신용대출")
            case .car:      return String(localized: "자동차 할부")
            case .minus:    return String(localized: "마이너스통장")
            }
        }
        // 종류별 일반적인 조건(2026 기준 근사) — 선택 시 입력칸에 시드된다.
        var defaults: (principal: String, rate: String, years: String, method: RepayMethod) {
            switch self {
            case .mortgage: return ("300000000", "4.2", "30", .equalPayment)
            case .jeonse:   return ("150000000", "3.8", "2",  .bullet)
            case .credit:   return ("50000000",  "5.5", "5",  .equalPayment)
            case .car:      return ("30000000",  "5.2", "5",  .equalPayment)
            case .minus:    return ("30000000",  "6.0", "1",  .bullet)
            }
        }
    }

    private struct PayPoint: Identifiable {
        let id = UUID()
        let month: Int
        let payment: Double
        let balance: Double
    }

    // 월별 상환 스케줄. (납입액, 남은 원금)
    private var schedule: [PayPoint] {
        let p = Double(principal) ?? 0
        let n = max(1, (Int(years) ?? 0) * 12)
        let i = (Double(ratePct) ?? 0) / 100 / 12
        guard p > 0 else { return [] }
        var balance = p
        var pts: [PayPoint] = []
        switch method {
        case .equalPayment:
            let m = i > 0 ? p * i * pow(1 + i, Double(n)) / (pow(1 + i, Double(n)) - 1) : p / Double(n)
            for k in 1...n {
                let interest = balance * i
                balance = max(0, balance - (m - interest))
                pts.append(PayPoint(month: k, payment: m, balance: balance))
            }
        case .equalPrincipal:
            let principalPart = p / Double(n)
            for k in 1...n {
                let interest = balance * i
                balance = max(0, balance - principalPart)
                pts.append(PayPoint(month: k, payment: principalPart + interest, balance: balance))
            }
        case .bullet:
            let interest = p * i
            for k in 1...n {
                let last = k == n
                pts.append(PayPoint(month: k, payment: last ? interest + p : interest,
                                    balance: last ? 0 : p))
            }
        }
        return pts
    }

    // 차트용 한 점 — 남은 원금과 그때까지 낸 이자 누적.
    private struct LoanPoint: Identifiable {
        let id = UUID()
        let month: Int
        let balance: Double
        let paidInterest: Double
    }

    var body: some View {
        let sched = schedule
        let p = Double(principal) ?? 0
        let totalPaid = sched.reduce(0) { $0 + $1.payment }
        let totalInterest = max(0, totalPaid - p)
        // 낸 돈 누적 − 갚은 원금 = 그때까지 낸 이자. 차트는 듬성듬성(최대 ~120점) 샘플링해 가볍게.
        let step = max(1, sched.count / 120)
        var paid = 0.0
        var pts: [LoanPoint] = [LoanPoint(month: 0, balance: p, paidInterest: 0)]
        for (idx, pt) in sched.enumerated() {
            paid += pt.payment
            if idx % step == 0 || idx == sched.count - 1 {
                pts.append(LoanPoint(month: pt.month, balance: pt.balance,
                                     paidInterest: max(0, paid - (p - pt.balance))))
            }
        }
        let monthlyText: String = {
            if method == .equalPrincipal, let f = sched.first, let l = sched.last {
                return String(localized: "\(Fmt.krw(f.payment)) → \(Fmt.krw(l.payment))원")
            }
            return String(localized: "\(Fmt.krw(sched.first?.payment ?? 0))원")
        }()

        return VStack(alignment: .leading, spacing: 10) {
            SimResultHeader(title: String(localized: "총 이자 \(Fmt.krw(totalInterest))원 · 원금의 \(Fmt.percent(p > 0 ? totalInterest / p : 0, fraction: 0))"),
                            icon: "banknote", tint: Theme.negative) { showInfo = true }

            HStack(alignment: .top, spacing: 12) {
                simStat(method == .bullet ? String(localized: "월 이자") : String(localized: "월 상환액"), monthlyText)
                simStat(String(localized: "총 상환액"), String(localized: "\(Fmt.krw(totalPaid))원"))
            }

            // 남은 원금이 줄어드는 동안 낸 이자가 얼마나 쌓이는지 — 같은 눈금 위에.
            Chart {
                ForEach(pts) { pt in
                    AreaMark(x: .value("개월", pt.month), y: .value("남은 원금", pt.balance))
                        .foregroundStyle(
                            LinearGradient(colors: [Theme.negative.opacity(0.3), Theme.negative.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    LineMark(x: .value("개월", pt.month), y: .value("남은 원금", pt.balance),
                             series: .value("선", String(localized: "남은 원금")))
                        .foregroundStyle(Theme.negative)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(x: .value("개월", pt.month), y: .value("낸 이자", pt.paidInterest),
                             series: .value("선", String(localized: "낸 이자")))
                        .foregroundStyle(Theme.accentText)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Fmt.krw(v)).font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .chartXScale(domain: 0...max(1, sched.count))
            .chartXAxis { simMonthAxis() }
            .frame(minHeight: 140, maxHeight: .infinity)

            HStack(spacing: 14) {
                simLegend(Theme.negative, String(localized: "남은 원금"))
                simLegend(Theme.accent, String(localized: "그때까지 낸 이자"))
            }

            SimLeverPanel(levers: levers, selection: $leverID) {
                EmptyView()
            } footer: {
                EmptyView()
            }
        }
        .simResultCard()
        .sheet(isPresented: $showInfo) {
            SimSheet(title: String(localized: "해석·저장")) {
                SimInfoCard(title: String(localized: "상환 결과")) {
                    HStack(alignment: .top, spacing: 12) {
                        simStat(String(localized: "총 상환액"), String(localized: "\(Fmt.krw(totalPaid))원"))
                        simStat(String(localized: "총 이자"), String(localized: "\(Fmt.krw(totalInterest))원"), tint: Theme.negative)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        simStat(String(localized: "이자 비율(원금 대비)"), Fmt.percent(p > 0 ? totalInterest / p : 0, fraction: 1),
                                tint: Theme.negative)
                        simStat(method == .bullet ? String(localized: "월 이자") : String(localized: "월 상환액"), monthlyText)
                    }
                    Text(methodNote)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 이 대출을 자산 목록에 부채로 추가 — 따로 입력할 필요 없이.
                // 같은 대출이 이미 자산에 있으면 '추가됨'으로 — 화면을 나갔다 와도 두 번 넣지 않게.
                if !sched.isEmpty {
                    let debtAdded = added || assets.contains {
                        $0.assetClass == .debt && $0.name == loanKind.assetName && $0.amount == p
                    }
                    simActionButton(
                        title: debtAdded ? String(localized: "부채로 추가됨") : String(localized: "이 대출을 자산에 부채로 추가"),
                        done: debtAdded,
                        confirmTitle: String(localized: "이 대출을 부채로 추가할까요?"),
                        confirmMessage: String(localized: "남은 대출 잔액 \(Fmt.krw(p))원과 연 이자율 \(ratePct)%가 자산 탭에 ‘부채’로 등록됩니다."),
                        isPresented: $showAddConfirm,
                        action: addAsDebt
                    )

                    CalcSaveRow(
                        kind: .loan,
                        headline: String(localized: "총 이자 \(Fmt.krw(totalInterest))원 · 총 상환 \(Fmt.krw(totalPaid))원"),
                        detail: String(localized: "\(String(localized: String.LocalizationValue(loanKind.rawValue))) · 원금 \(Fmt.krw(p))원 · 연 \(ratePct)% · \(years)년 · \(String(localized: String.LocalizationValue(method.rawValue)))")
                    )
                }
                simDisclaimer
            }
        }
    }

    private var methodNote: String {
        switch method {
        case .equalPayment:   return String(localized: "원리금균등 — 매달 같은 금액을 내요. 초반엔 이자 비중이 크고, 갈수록 원금 비중이 커져요.")
        case .equalPrincipal: return String(localized: "원금균등 — 원금을 매달 같은 만큼 갚아 첫 달 부담이 크지만, 총 이자는 원리금균등보다 적어요.")
        case .bullet:         return String(localized: "만기일시 — 매달 이자만 내고 원금은 마지막에 한 번에 갚아요. 총 이자가 가장 커요.")
        }
    }

    // 조작 패널의 값들 — 대출 종류를 고르면 그 대출의 일반적인 조건으로 채운다.
    private var levers: [SimLever] {
        [
            .choice(String(localized: "대출 종류"), current: loanKind.rawValue, LoanKind.allCases.map { k in
                SimOption(id: k.rawValue, selected: loanKind == k) {
                    loanKind = k
                    let d = k.defaults
                    principal = d.principal
                    ratePct = d.rate
                    years = d.years
                    method = d.method
                    added = false
                }
            }),
            .money(String(localized: "원금"), $principal, 10_000_000...2_000_000_000, step: 10_000_000),
            .percent(String(localized: "이자율"), $ratePct, 0...15, step: 0.1),
            .count(String(localized: "기간"), $years, 1...40, suffix: String(localized: "년")),
            .choice(String(localized: "상환 방식"), current: method.rawValue, RepayMethod.allCases.map { m in
                SimOption(id: m.rawValue, selected: method == m) { method = m }
            }),
        ]
    }

    // 대출 조건을 부채 자산으로 만들어 카탈로그에 넣는다.
    private func addAsDebt() {
        let asset = Asset(name: loanKind.assetName, assetClass: .debt,
                          amount: Double(principal) ?? 0,
                          incomeKind: .interest,
                          annualYieldPct: Double(ratePct) ?? 0,
                          sortOrder: assets.count)
        context.insert(asset)
        added = context.saveReporting(String(localized: "자산"))
    }

    // x축을 '년' 단위 라벨로.
    private func simMonthAxis() -> some AxisContent {
        AxisMarks(values: .stride(by: Double(max(12, (Int(years) ?? 1) * 12 / 4 / 12 * 12)))) { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            if let m = value.as(Int.self) {
                AxisValueLabel {
                    Text("\(m / 12)년")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
    }
}

// MARK: - 예적금 시뮬레이션

private struct SavingsSimSection: View {
    @AppStorage("sim.sav.kind")      private var kind: SavingKind = .deposit
    @AppStorage("sim.sav.principal") private var principal = "10000000"
    @AppStorage("sim.sav.monthly")   private var monthly = "500000"
    @AppStorage("sim.sav.months")    private var months = "12"
    @AppStorage("sim.sav.ratePct")   private var ratePct = "3.5"
    @AppStorage("sim.sav.compound")  private var compound: CompoundKind = .simple
    @AppStorage("sim.sav.taxed")     private var taxed = true
    @AppStorage("sim.sav.goal")      private var goal = ""

    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @State private var added = false
    @State private var showAddConfirm = false
    @State private var showInfo = false
    @State private var leverID = String(localized: "기간")

    enum SavingKind: String, CaseIterable, Identifiable {
        case deposit = "정기예금"
        case installment = "적금"
        case parking = "파킹·CMA"
        var id: String { rawValue }

        // 종류별 일반적인 금리 시드 — 선택 시 이자율 칸에 채워진다.
        var defaultRate: String {
            switch self {
            case .deposit:     return "3.5"
            case .installment: return "4.0"
            case .parking:     return "3.0"
            }
        }
    }
    enum CompoundKind: String, CaseIterable, Identifiable {
        case simple = "단리"
        case monthlyCompound = "월 복리"
        var id: String { rawValue }
    }

    // (원금 합계, 세전 이자)
    private var result: (principal: Double, interest: Double) {
        let m = max(1, Int(months) ?? 12)
        let r = (Double(ratePct) ?? 0) / 100
        let i = r / 12
        switch kind {
        case .deposit:
            let p = Double(principal) ?? 0
            let interest = compound == .simple
                ? p * r * Double(m) / 12
                : p * (pow(1 + i, Double(m)) - 1)
            return (p, interest)
        case .installment:
            let d = Double(monthly) ?? 0
            let total = d * Double(m)
            let interest: Double
            if compound == .simple {
                // 매달 말 납입 단리: k번째 납입은 (m−k)개월치 이자.
                interest = d * r * Double(m * (m - 1)) / 2 / 12
            } else {
                interest = i > 0 ? d * ((pow(1 + i, Double(m)) - 1) / i) - total : 0
            }
            return (total, interest)
        case .parking:
            // 자유 입출금(파킹·CMA) — 원금 + 매달 자유 입금, 월 복리로 근사.
            let p = Double(principal) ?? 0
            let d = Double(monthly) ?? 0
            var value = p
            for _ in 0..<m { value = value * (1 + i) + d }
            let total = p + d * Double(m)
            return (total, max(0, value - total))
        }
    }

    private struct SavPoint: Identifiable { let id = UUID(); let month: Int; let value: Double }

    // 월별 누적 잔액(세후 이자 반영) — 0개월부터 만기까지. 그래프용.
    private var series: [SavPoint] {
        let m = max(1, Int(months) ?? 12)
        let r = (Double(ratePct) ?? 0) / 100
        let i = r / 12
        let taxFactor = taxed ? (1 - 0.154) : 1.0
        var pts: [SavPoint] = []
        switch kind {
        case .deposit:
            let p = Double(principal) ?? 0
            for k in 0...m {
                let interest = compound == .simple ? p * r * Double(k) / 12
                                                   : p * (pow(1 + i, Double(k)) - 1)
                pts.append(SavPoint(month: k, value: p + interest * taxFactor))
            }
        case .installment:
            let d = Double(monthly) ?? 0
            for k in 0...m {
                let contributed = d * Double(k)
                let interest: Double
                if compound == .simple {
                    interest = d * r * Double(k * (k - 1)) / 2 / 12
                } else {
                    interest = i > 0 ? d * ((pow(1 + i, Double(k)) - 1) / i) - contributed : 0
                }
                pts.append(SavPoint(month: k, value: contributed + interest * taxFactor))
            }
        case .parking:
            let p = Double(principal) ?? 0
            let d = Double(monthly) ?? 0
            var value = p
            pts.append(SavPoint(month: 0, value: p))
            for k in 1...m {
                value = value * (1 + i) + d
                let contributed = p + d * Double(k)
                pts.append(SavPoint(month: k, value: contributed + max(0, value - contributed) * taxFactor))
            }
        }
        return pts
    }

    private var goalValue: Double { Double(goal) ?? 0 }

    var body: some View {
        let r = result
        let tax = taxed ? r.interest * 0.154 : 0
        let afterTax = r.interest - tax
        let maturity = r.principal + afterTax
        let reached = goalValue > 0 && maturity >= goalValue
        let headline: String = {
            if goalValue > 0 {
                return reached ? String(localized: "만기 \(Fmt.krw(maturity))원 · 목표 달성")
                               : String(localized: "만기 \(Fmt.krw(maturity))원 · 목표의 \(Fmt.percent(min(maturity / goalValue, 1), fraction: 0))")
            }
            return String(localized: "만기에 \(Fmt.krw(maturity))원을 받아요")
        }()
        VStack(alignment: .leading, spacing: 10) {
            SimResultHeader(title: headline, icon: reached ? "checkmark.seal.fill" : "banknote",
                            tint: Theme.positive) { showInfo = true }

            HStack(alignment: .top, spacing: 12) {
                simStat(String(localized: "원금"), String(localized: "\(Fmt.krw(r.principal))원"))
                simStat(taxed ? String(localized: "세후 이자") : String(localized: "이자"), String(localized: "+\(Fmt.krw(afterTax))원"), tint: Theme.positive)
            }

            // 목표까지 모이는 흐름 — 월별 누적 잔액 곡선 + 목표선.
            growthChart
                .frame(minHeight: 140, maxHeight: .infinity)

            SimLeverPanel(levers: levers, selection: $leverID) {
                EmptyView()
            } footer: {
                if goalValue > 0, maturity < goalValue {
                    Text("목표까지 \(Fmt.krw(goalValue - maturity))원 부족해요. 기간·납입액·이자율을 올려보세요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
        .simResultCard()
        .onChange(of: kind) { _, newValue in
            ratePct = newValue.defaultRate
            added = false
        }
        .sheet(isPresented: $showInfo) {
            SimSheet(title: String(localized: "해석·저장")) {
                SimInfoCard(title: String(localized: "만기 수령액")) {
                    Text("\(Fmt.krw(maturity))원")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.positive)
                    // 한글 단위 모드에서만 전체 숫자를 보조로. ('숫자만' 모드면 위와 중복이라 생략)
                    if !Fmt.numbersOnly {
                        Text("= \(Fmt.won(maturity))원")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                    // 원금 vs 이자 구성 — 한 막대.
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            if maturity > 0 {
                                Theme.textSecond.opacity(0.35)
                                    .frame(width: max(2, geo.size.width * (r.principal / maturity)))
                                Theme.positive
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                    HStack(alignment: .top, spacing: 12) {
                        simStat(String(localized: "원금"), String(localized: "\(Fmt.krw(r.principal))원"))
                        simStat(String(localized: "세전 이자"), String(localized: "\(Fmt.krw(r.interest))원"), tint: Theme.positive)
                    }
                    HStack(spacing: 0) {
                        if taxed {
                            simStat(String(localized: "세금(15.4%)"), String(localized: "−\(Fmt.krw(tax))원"), tint: Theme.negative)
                        }
                        simStat(String(localized: "세후 이자"), String(localized: "\(Fmt.krw(afterTax))원"), tint: Theme.positive)
                    }
                    if kind == .parking {
                        Text("파킹·CMA는 매일 이자가 붙어 월 복리로 근사해서 계산해요.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                }

                // 예금·파킹은 지금 넣어둔 원금이 곧 현재 자산 → 현금·예금으로 바로 추가.
                if kind != .installment, (Double(principal) ?? 0) > 0 {
                    let cashName = kind == .deposit ? String(localized: "정기예금") : String(localized: "파킹통장")
                    let cashAdded = added || assets.contains {
                        $0.assetClass == .cash && $0.name == cashName && $0.amount == (Double(principal) ?? 0)
                    }
                    simActionButton(
                        title: cashAdded ? String(localized: "현금·예금에 추가됨") : String(localized: "이 \(kind == .deposit ? String(localized: "예금") : String(localized: "잔액"))을 자산에 추가"),
                        done: cashAdded,
                        confirmTitle: String(localized: "자산에 추가할까요?"),
                        confirmMessage: String(localized: "\(kind == .deposit ? String(localized: "원금") : String(localized: "잔액")) \(Fmt.krw(Double(principal) ?? 0))원이 ‘현금·예금’으로 등록되고, 연 \(ratePct)% 이자가 패시브 인컴에 반영됩니다."),
                        isPresented: $showAddConfirm,
                        action: addAsCash
                    )
                }

                CalcSaveRow(
                    kind: .savings,
                    headline: String(localized: "만기 \(Fmt.krw(maturity))원 · 세후 이자 \(Fmt.krw(afterTax))원"),
                    detail: String(localized: "\(String(localized: String.LocalizationValue(kind.rawValue))) · \(kind == .installment ? String(localized: "월 \(Fmt.krw(Double(monthly) ?? 0))원") : String(localized: "원금 \(Fmt.krw(Double(principal) ?? 0))원")) · \(months)개월 · 연 \(ratePct)%\(taxed ? String(localized: " · 이자소득세 반영") : "")")
                )
                simDisclaimer
            }
        }
    }

    // 조작 패널의 값들 — 종류에 따라 원금·월 납입이 바뀌어 보인다.
    private var levers: [SimLever] {
        var list: [SimLever] = [
            .choice(String(localized: "종류"), current: kind.rawValue, SavingKind.allCases.map { k in
                SimOption(id: k.rawValue, selected: kind == k) { kind = k }
            }),
        ]
        switch kind {
        case .deposit:
            list.append(.money(String(localized: "원금"), $principal, 1_000_000...500_000_000, step: 1_000_000))
        case .installment:
            list.append(.money(String(localized: "월 납입액"), $monthly, 100_000...5_000_000, step: 100_000, prefix: String(localized: "월 ")))
        case .parking:
            list.append(.money(String(localized: "현재 잔액"), $principal, 0...500_000_000, step: 1_000_000))
            list.append(.money(String(localized: "월 추가 입금"), $monthly, 0...5_000_000, step: 100_000, prefix: String(localized: "월 ")))
        }
        list.append(.count(String(localized: "기간"), $months, 1...120, suffix: String(localized: "개월")))
        list.append(.percent(String(localized: "이자율"), $ratePct, 0...10, step: 0.1))
        if kind != .parking {
            list.append(.choice(String(localized: "이자 계산"), current: compound.rawValue, CompoundKind.allCases.map { c in
                SimOption(id: c.rawValue, selected: compound == c) { compound = c }
            }))
        }
        list.append(.choice(String(localized: "세금"), current: taxed ? String(localized: "이자과세 15.4%") : String(localized: "비과세"), [
            SimOption(id: String(localized: "이자과세 15.4%"), selected: taxed) { taxed = true },
            SimOption(id: String(localized: "비과세"), selected: !taxed) { taxed = false },
        ]))
        list.append(.money(String(localized: "목표 금액"), $goal, 0...1_000_000_000, step: 1_000_000))
        return list
    }

    // 예금·파킹 원금을 현금·예금 자산으로 만들어 카탈로그에 넣는다.
    private func addAsCash() {
        let asset = Asset(name: kind == .deposit ? String(localized: "정기예금") : String(localized: "파킹통장"), assetClass: .cash,
                          amount: Double(principal) ?? 0,
                          incomeKind: .interest,
                          annualYieldPct: Double(ratePct) ?? 0,
                          sortOrder: assets.count)
        context.insert(asset)
        added = context.saveReporting(String(localized: "자산"))
    }

    // 월별 누적 잔액 곡선 + 목표선.
    private var growthChart: some View {
        let pts = series
        let m = pts.last?.month ?? 1
        let byYear = m > 18
        let floor = pts.map(\.value).min() ?? 0
        return Chart {
            ForEach(pts) { p in
                // 면은 가장 낮은 잔액부터 — 0부터 깔면 눈금이 0까지 내려가 선이 평평해진다.
                AreaMark(x: .value("개월", p.month), yStart: .value("바닥", floor),
                         yEnd: .value("잔액", p.value))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.positive.opacity(0.28), Theme.positive.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("개월", p.month), y: .value("잔액", p.value))
                    .foregroundStyle(Theme.positive)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            if goalValue > 0 {
                RuleMark(y: .value("목표", goalValue))
                    .foregroundStyle(Theme.accent.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("목표 \(Fmt.krw(goalValue))원")
                            .font(.caption2)
                            .foregroundStyle(Theme.accentText)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Fmt.krw(v))원").font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        // 원금에 비해 이자가 작아 0부터 그리면 선이 평평해 보인다 — 바닥을 띄운다.
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXScale(domain: 0...m)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                if let mm = value.as(Int.self) {
                    AxisValueLabel {
                        Text(byYear ? "\(mm / 12)년" : "\(mm)개월")
                            .font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
    }
}

// MARK: - 투자 예측 (내 자산이 앞으로 어떻게 될까)

// 보유 자산의 과거 기록(스냅샷)과 자산 종류별 일반 변동성을 함께 써서, 앞으로의
// 자산 흐름을 몬테카를로로 추정한다. 정확한 예언이 아니라 '이 정도 범위' 감각용 —
// 변동성이 큰 자산(코인·주식)이 많을수록 범위 밴드가 넓게 벌어진다.
private struct InvestForecastSection: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]

    @AppStorage("sim.invest.years")   private var yearsText = "5"
    @AppStorage("sim.invest.monthly") private var monthlyAdd = "0"
    @State private var showInfo = false
    @State private var leverID = String(localized: "기간")

    // 예측에 쓰는 자산 종류 하나 — 현재액 + 가정한 연 수익률·변동성.
    private struct ClassAssumption: Identifiable {
        let id = UUID()
        let assetClass: AssetClass
        let current: Double
        let mu: Double          // 연 기대수익률
        let sigma: Double       // 연 변동성
        let fromHistory: Bool   // 과거 기록으로 보정했는지
    }

    private struct BandPoint: Identifiable {
        let id = UUID()
        let month: Int
        let low: Double     // 보수적 (하위 10%)
        let mid: Double     // 중앙값
        let high: Double    // 낙관적 (상위 10%)
    }

    // xorshift 고정 시드 난수 — 입력이 같으면 그래프도 같게(리렌더 안정).
    private struct RNG {
        var state: UInt64
        mutating func uniform() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
        mutating func normal() -> Double {
            let u1 = max(uniform(), 1e-9), u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }

    // 자산 종류별 일반적인 연 수익률·변동성 (장기 통계 근사).
    private static func prior(for ac: AssetClass) -> (mu: Double, sigma: Double) {
        switch ac {
        case .stocks:     return (0.07,  0.15)
        case .fund:       return (0.06,  0.12)
        case .crypto:     return (0.15,  0.60)
        case .bond:       return (0.035, 0.05)
        case .cash:       return (0.03,  0.005)
        case .realEstate: return (0.04,  0.08)
        case .pension:    return (0.04,  0.06)
        case .jeonse:     return (0.0,   0.0)
        case .deposit:    return (0.025, 0.01)
        case .insurance:  return (0.03,  0.03)
        default:          return (0.03,  0.05)
        }
    }

    private var years: Int { min(30, max(1, Int(yearsText) ?? 5)) }

    // 부채를 뺀, 값이 있는 자산 종류별 현재 합계.
    private var currentByClass: [(ac: AssetClass, value: Double)] {
        AssetClass.allCases.compactMap { ac in
            guard ac != .debt else { return nil }
            let v = assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
            return v > 0 ? (ac, v) : nil
        }
    }

    private var currentTotal: Double { currentByClass.reduce(0) { $0 + $1.value } }

    // 과거 스냅샷에서 이 종류의 월 수익률을 추정해 일반값과 반반 섞는다.
    // 기록엔 저축 입금도 섞여 있어 수익률이 부풀 수 있으니 상한을 함께 둔다.
    private func estimate(for ac: AssetClass) -> (mu: Double, sigma: Double, fromHistory: Bool) {
        let prior = Self.prior(for: ac)
        let series = snapshots.compactMap { s -> (date: Date, value: Double)? in
            let v = s.total(for: ac)
            return v > 0 ? (s.date, v) : nil
        }
        var rets: [Double] = []
        for k in 1..<max(1, series.count) {
            let dtMonths = series[k].date.timeIntervalSince(series[k - 1].date) / 86_400 / 30.44
            guard dtMonths > 0.25 else { continue }
            let r = log(series[k].value / series[k - 1].value) / dtMonths
            if r.isFinite { rets.append(max(-0.5, min(0.5, r))) }
        }
        guard rets.count >= 4 else { return (prior.mu, prior.sigma, false) }
        let meanM = rets.reduce(0, +) / Double(rets.count)
        let varM = rets.reduce(0) { $0 + pow($1 - meanM, 2) } / Double(max(1, rets.count - 1))
        // 기록이 쌓일수록 과거 데이터의 가중치를 올린다 — 4개(1/3 남짓)부터 시작해
        // 2년치(24개)면 70%까지. 입금이 섞인 왜곡은 상한 클램프로 계속 막는다.
        let w = min(0.7, Double(rets.count) / 24)
        let mu = max(-0.10, min(0.20, meanM * 12 * w + prior.mu * (1 - w)))
        let sigma = max(0.005, min(0.80, sqrt(varM * 12) * w + prior.sigma * (1 - w)))
        return (mu, sigma, true)
    }

    // 시장 공통 충격에 대한 민감도 — 주식·펀드는 거의 같이 움직이고, 코인·부동산도
    // 어느 정도 따라간다. 위험자산이 동시에 빠지는 현실을 밴드에 반영한다.
    private static func marketBeta(for ac: AssetClass) -> Double {
        switch ac {
        case .stocks, .fund: return 0.85
        case .crypto:        return 0.5
        case .realEstate:    return 0.3
        case .bond:          return 0.15
        default:             return 0.05
        }
    }

    private var assumptions: [ClassAssumption] {
        currentByClass.map { item in
            let e = estimate(for: item.ac)
            return ClassAssumption(assetClass: item.ac, current: item.value,
                                   mu: e.mu, sigma: e.sigma, fromHistory: e.fromHistory)
        }
    }

    // 비율(0.07)을 %로 바꿔 소수 둘째 자리까지 반올림 — 부동소수점 꼬리
    // (7.000000000001%) 가 그대로 노출되지 않게 한다.
    private func pct2(_ ratio: Double) -> String {
        Fmt.trimNumber((ratio * 10_000).rounded() / 100)
    }

    private func pctile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }

    // 몬테카를로 — 종류별로 매달 (μ, σ) 로그정규 성장을 굴려 합산, 분위수 밴드로.
    private func makeBand(_ asm: [ClassAssumption]) -> [BandPoint] {
        guard !asm.isEmpty else { return [] }
        let months = years * 12
        let add = Double(monthlyAdd) ?? 0
        let total = asm.reduce(0) { $0 + $1.current }
        let weights = asm.map { $0.current / max(total, 1) }
        let paths = 200
        var totalsByMonth = Array(repeating: [Double](), count: months + 1)
        var rng = RNG(state: 88_172_645_463_325_252)
        for _ in 0..<paths {
            var values = asm.map(\.current)
            totalsByMonth[0].append(values.reduce(0, +))
            for mIdx in 1...months {
                // 이번 달의 시장 공통 충격 — 각 자산은 베타만큼 함께 흔들리고,
                // 나머지는 자기만의 충격으로 움직인다.
                let zMarket = rng.normal()
                for c in asm.indices {
                    let muM = asm[c].mu / 12
                    let sigM = asm[c].sigma / sqrt(12)
                    let beta = Self.marketBeta(for: asm[c].assetClass)
                    let z = beta * zMarket + sqrt(max(0, 1 - beta * beta)) * rng.normal()
                    let growth = exp(muM - sigM * sigM / 2 + sigM * z)
                    values[c] = values[c] * growth + add * weights[c]
                }
                totalsByMonth[mIdx].append(values.reduce(0, +))
            }
        }
        let step = max(1, months / 60)
        return (0...months).compactMap { mIdx in
            guard mIdx % step == 0 || mIdx == months else { return nil }
            let sortedVals = totalsByMonth[mIdx].sorted()
            return BandPoint(month: mIdx,
                             low: pctile(sortedVals, 0.10),
                             mid: pctile(sortedVals, 0.50),
                             high: pctile(sortedVals, 0.90))
        }
    }

    var body: some View {
        let asm = assumptions
        let band = makeBand(asm)
        let last = band.last
        VStack(alignment: .leading, spacing: 10) {
            if asm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(.largeTitle))
                        .foregroundStyle(Theme.textSecond)
                    Text("자산 탭에 자산을 등록하면\n앞으로의 흐름을 예측해드려요.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SimResultHeader(title: String(localized: "\(years)년 뒤 \(Fmt.krw(last?.mid ?? 0))원 (중앙값)"),
                                icon: "chart.line.uptrend.xyaxis", tint: Theme.accent) { showInfo = true }

                HStack(alignment: .top, spacing: 12) {
                    simStat(String(localized: "보수적 (하위 10%)"), String(localized: "\(Fmt.krw(last?.low ?? 0))원"))
                    simStat(String(localized: "낙관적 (상위 10%)"), String(localized: "\(Fmt.krw(last?.high ?? 0))원"), tint: Theme.accent)
                }

                forecastChart(band)
                    .frame(minHeight: 140, maxHeight: .infinity)

                SimLeverPanel(levers: levers, selection: $leverID) {
                    EmptyView()
                } footer: {
                    Text("음영은 열에 여덟이 들어오는 범위예요. 기간이 길수록 넓어져요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
        .simResultCard()
        .sheet(isPresented: $showInfo) {
            SimSheet(title: String(localized: "해석·저장")) {
                SimInfoCard(title: String(localized: "\(years)년 뒤 내 자산은")) {
                    if let last {
                        Text("\(Fmt.krw(last.mid))원")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.accentText)
                        Text("보수적 \(Fmt.krw(last.low))원 ~ 낙관적 \(Fmt.krw(last.high))원")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                    if let year1 = band.first(where: { $0.month >= 12 }) {
                        simStat(String(localized: "1년 후 (중앙값)"), String(localized: "\(Fmt.krw(year1.mid))원"))
                    }
                    Text("지금 자산을 종류별로 나눠, 해마다 출렁이는 수익률로 200번 굴려 본 결과예요. 가운데 선은 중앙값, 음영은 하위 10% ~ 상위 10% 범위예요. 정확한 예언이 아니라 ‘이 정도 범위’ 감각용이에요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
                assumptionCard(asm)
                // 온디바이스 파운데이션 모델 해석 — 숫자 예측은 몬테카를로가 하고,
                // 모델은 그 결과의 '읽기'(리스크 구성·조언)만 맡는다.
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *),
                   case .available = SystemLanguageModel.default.availability {
                    ForecastAICard(prompt: aiPrompt(asm, band: band))
                }
                #endif

                if let tail = band.last {
                    CalcSaveRow(
                        kind: .invest,
                        headline: String(localized: "\(yearsText)년 뒤 중앙값 \(Fmt.krw(tail.mid))원"),
                        detail: String(localized: "보수 \(Fmt.krw(tail.low))원 ~ 낙관 \(Fmt.krw(tail.high))원 · 월 추가 \(Fmt.krw(Double(monthlyAdd) ?? 0))원 · 자산 \(asm.count)종")
                    )
                }
                simDisclaimer
            }
        }
    }

    private var levers: [SimLever] {
        [
            .count(String(localized: "기간"), $yearsText, 1...30, suffix: String(localized: "년 뒤")),
            .money(String(localized: "월 추가 투자"), $monthlyAdd, 0...10_000_000, step: 100_000, prefix: String(localized: "월 ")),
        ]
    }

    // 모델에게 넘길 요약 — 구성·가정·예측 범위를 짧은 한국어 프롬프트로.
    /// 설명을 받을 말 — 앱을 보고 있는 언어로 답하게 한다.
    private static var answerLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "ko"
        if code.hasPrefix("ko") { return "한국어 존댓말로" }
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        return "\(name)(언어 코드 \(code))로"
    }

    private func aiPrompt(_ asm: [ClassAssumption], band: [BandPoint]) -> String {
        let comp = asm.map {
            "\($0.assetClass.label) \(Fmt.krw($0.current))원(연 \(pct2($0.mu))%±\(pct2($0.sigma))%)"
        }.joined(separator: ", ")
        let tail = band.last.map {
            "\(years)년 뒤 중앙값 \(Fmt.krw($0.mid))원, 보수적 \(Fmt.krw($0.low))원 ~ 낙관적 \(Fmt.krw($0.high))원"
        } ?? ""
        return """
        다음은 한 개인 투자자의 자산 구성과 몬테카를로 예측 결과다.
        구성: \(comp).
        예측: \(tail).
        위 숫자를 바탕으로, 포트폴리오의 변동성 구성이 예측 범위에 어떤 영향을 주는지와 \
        범위를 좁히고 싶을 때 고려할 점을 \(Self.answerLanguage) 3문장 이내로 설명하라. \
        새로운 숫자를 지어내지 말고, 특정 종목 추천은 하지 마라.
        """
    }

    private func forecastChart(_ band: [BandPoint]) -> some View {
        Chart {
            ForEach(band) { p in
                AreaMark(x: .value("개월", p.month),
                         yStart: .value("보수적", p.low),
                         yEnd: .value("낙관적", p.high))
                    .foregroundStyle(Theme.accent.opacity(0.14))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("개월", p.month), y: .value("중앙값", p.mid))
                    .foregroundStyle(Theme.accentText)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            RuleMark(y: .value("지금", currentTotal))
                .foregroundStyle(Theme.hairline)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .bottom, alignment: .trailing) {
                    Text("지금 \(Fmt.krw(currentTotal))원")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Fmt.krw(v))").font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        // 0부터 그리면 범위가 위쪽에 눌려 보인다 — 바닥을 띄워 띠를 크게.
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                if let mm = value.as(Int.self) {
                    AxisValueLabel {
                        Text(mm >= 12 ? "\(mm / 12)년" : "지금")
                            .font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
    }

    private func assumptionCard(_ asm: [ClassAssumption]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("종류별 가정")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(asm) { a in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hexCode: a.assetClass.colorHex))
                        .frame(width: 8, height: 8)
                    Text(a.assetClass.label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    if a.fromHistory {
                        Text("기록 기반")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.15))
                            .foregroundStyle(Theme.accentText)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Fmt.krw(a.current))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("연 \(pct2(a.mu))% ± \(pct2(a.sigma))%")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
            }
            Text("‘기록 기반’은 여정 탭에 쌓인 기록으로 수익률을 보정한 종류예요. 기록에는 저축 입금도 섞여 있어 실제 수익률보다 높게 잡힐 수 있고, 그래서 종류별 일반값과 반반 섞어 계산합니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// 연도를 문자열로 — Text 보간에 Int를 그대로 넣으면 "2,026년"처럼 천 단위가 끼어든다.
private func yearLabel(_ year: Int) -> String { String(year) }

// MARK: - 월급 · 실질임금(구매력)

// 과거 월급을 연도별로 적어두면 그때의 물가로 나눠 '실질임금'을 계산한다.
// 명목 월급이 올라도 물가가 더 오르면 실제로 살 수 있는 양(구매력)은 줄어드는데,
// 그 차이를 두 가지 기준으로 보여준다.
//   · 지금 돈 기준 — 그때 월급이 오늘 물가로 얼마인지 환산 (× 기준연도 CPI ÷ 그해 CPI)
//   · 2020년 기준 — 명목 ÷ CPI × 100, 통계청·고용노동부가 쓰는 실질임금 그 자체
// 물가표는 나라별(CPIData)이라 해외 근무·이민 이력도 그 나라 물가로 계산된다.
private struct WageSimSection: View {
    @AppStorage("sim.wage.entries") private var entriesJSON = ""
    @AppStorage("sim.wage.mode")    private var realMode: RealMode = .today
    @AppStorage("sim.wage.country") private var countryCode = "KR"

    @State private var entries: [WageEntry] = []
    @State private var newYear = WageSimSection.thisYear
    @State private var loaded = false
    @State private var showInfo = false
    @State private var showList = false
    @State private var leverID = ""
    @State private var sliderMax: Double = 5_000_000

    private static var thisYear: Int { Calendar.current.component(.year, from: Date()) }
    // 물가를 적용할 나라 — 금액 표기(통화)도 여기를 따른다.
    private var country: CPICountry { CPIData.country(countryCode) }
    // 환산 기준연도 — 올해. 아직 확정 물가가 없으면 그 나라 표의 마지막 해로 맞춘다.
    private var baseYear: Int { min(Self.thisYear, country.lastYear) }

    enum RealMode: String, CaseIterable, Identifiable {
        case today = "지금 돈 기준"
        case index2020 = "2020년 기준"
        var id: String { rawValue }
    }

    private struct WageEntry: Codable, Identifiable, Equatable {
        var id = UUID()
        var year: Int
        var monthly: Double
    }

    // 한 해치 계산 결과. 증감률은 '직전 기록과의 간격'으로 연평균 환산한다
    // (2016 → 2021처럼 띄엄띄엄 적어도 왜곡되지 않게).
    private struct WageRow: Identifiable {
        var id: Int { year }
        let year: Int
        let nominal: Double
        let realToday: Double    // 올해 물가로 환산한 금액
        let realIndexed: Double  // 명목 ÷ CPI × 100 (2020년 물가 기준 금액)
        let gapYears: Int
        let nominalRate: Double? // 내 월급 인상률(연평균)
        let inflationRate: Double? // 같은 구간 물가상승률(연평균)
        let realRate: Double?    // 실질임금 증감률(연평균)
    }

    private var validEntries: [WageEntry] {
        entries.filter { $0.monthly > 0 }.sorted { $0.year < $1.year }
    }

    private var rows: [WageRow] {
        let list = validEntries
        return list.enumerated().map { i, e in
            let cpi = country.cpi(e.year)
            let realIdx = cpi > 0 ? e.monthly / cpi * 100 : 0
            let realToday = realIdx * country.cpi(baseYear) / 100
            var gap = 0
            var nRate: Double?
            var iRate: Double?
            var rRate: Double?
            if i > 0 {
                let prev = list[i - 1]
                gap = max(1, e.year - prev.year)
                let n = 1.0 / Double(gap)
                let prevCPI = country.cpi(prev.year)
                let prevReal = prevCPI > 0 ? prev.monthly / prevCPI * 100 : 0
                if prev.monthly > 0 { nRate = pow(e.monthly / prev.monthly, n) - 1 }
                if prevCPI > 0 { iRate = pow(cpi / prevCPI, n) - 1 }
                if prevReal > 0 { rRate = pow(realIdx / prevReal, n) - 1 }
            }
            return WageRow(year: e.year, nominal: e.monthly, realToday: realToday,
                           realIndexed: realIdx, gapYears: gap,
                           nominalRate: nRate, inflationRate: iRate, realRate: rRate)
        }
    }

    // 첫 기록 → 마지막 기록 구간 요약.
    private var span: (first: WageRow, last: WageRow, years: Int)? {
        let r = rows
        guard let f = r.first, let l = r.last, f.year != l.year else { return nil }
        return (f, l, max(1, l.year - f.year))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let span {
                let change = span.first.realIndexed > 0
                    ? span.last.realIndexed / span.first.realIndexed - 1 : 0
                let nominal = span.first.nominal > 0 ? span.last.nominal / span.first.nominal - 1 : 0
                SimResultHeader(title: String(localized: "\(yearLabel(span.first.year))→\(yearLabel(span.last.year))년 구매력 \(change >= 0 ? "▲" : "▼") \(Fmt.percent(abs(change)))"),
                                icon: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                                tint: change >= 0 ? Theme.rise : Theme.fall) { showInfo = true }
                HStack(alignment: .top, spacing: 12) {
                    simStat(String(localized: "명목 월급"), signed(nominal))
                    simStat(String(localized: "실질(구매력)"), signed(change), tint: change >= 0 ? Theme.rise : Theme.fall)
                }
                nominalRealChart
                    .frame(minHeight: 140, maxHeight: .infinity)
                HStack(spacing: 14) {
                    simLegend(Theme.textSecond.opacity(0.35), String(localized: "명목(통장에 찍힌 돈)"))
                    simLegend(Theme.accent, String(localized: "실질 · \(realMode == .today ? String(localized: "\(yearLabel(baseYear))년") : String(localized: "2020년")) 물가 기준"))
                }
            } else {
                SimResultHeader(title: String(localized: "월급 기록으로 구매력 보기"), icon: "wonsign.circle",
                                tint: Theme.textPrimary) { showInfo = true }
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            SimLeverPanel(levers: levers, selection: $leverID) {
                SimPanelButton(title: String(localized: "월급 기록"), icon: "list.bullet") { showList = true }
            } footer: {
                EmptyView()
            }
        }
        .simResultCard()
        .sheet(isPresented: $showInfo) {
            SimSheet(title: String(localized: "해석·저장")) {
                if let span {
                    purchasingPowerCard(span)
                    summaryCard(span)
                    yearlyCard
                    let change = span.first.realIndexed > 0
                        ? span.last.realIndexed / span.first.realIndexed - 1 : 0
                    CalcSaveRow(
                        kind: .wage,
                        headline: String(localized: "\(yearLabel(span.first.year))→\(yearLabel(span.last.year))년 구매력 \(change >= 0 ? "▲" : "▼") \(Fmt.percent(abs(change)))"),
                        detail: String(localized: "\(country.flag) \(country.name) 물가 기준 · 월급 기록 \(rows.count)개 · \(span.years)년")
                    )
                } else if rows.count == 1, let only = rows.first {
                    singleEntryCard(only)
                }
                Text(sourceNote)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                    .frame(maxWidth: .infinity, alignment: .leading)
                simDisclaimer
            }
        }
        .sheet(isPresented: $showList) {
            SimSheet(title: String(localized: "월급 기록")) { inputCard }
        }
        .onAppear {
            load()
            rescale()
        }
        .onChange(of: entries) { _, _ in save() }
        .onChange(of: entries.count) { _, _ in rescale() }
        .onChange(of: leverID) { _, _ in rescale() }
        .onChange(of: countryCode) { _, _ in
            newYear = min(max(newYear, country.firstYear), max(Self.thisYear, country.lastYear))
            rescale()
        }
    }

    // 기록이 없거나 하나뿐일 때 — 차트 자리에 다음 할 일을 둔다.
    @ViewBuilder private var emptyState: some View {
        if rows.count == 1, let only = rows.first {
            VStack(spacing: 8) {
                Text("\(yearLabel(only.year))년 \(country.money(only.nominal))은")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                Text("지금 \(country.money(only.realToday))")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.accentText)
                Text("다른 해의 월급도 한 줄 더 넣으면 구매력 변화가 보여요.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.textSecond)
                Text("기억나는 해의 월급을 두 개 이상 넣으면\n물가를 뺀 구매력 변화가 보여요.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                HStack(spacing: 8) {
                    if country.code == "KR" {
                        capsuleButton(String(localized: "예시로 채워보기")) { fillExample() }
                    }
                    capsuleButton(String(localized: "월급 기록 넣기")) { showList = true }
                }
            }
        }
    }

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.surfaceHigh)
                .foregroundStyle(Theme.textPrimary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // 조작 패널 — 적어 둔 해마다 월급 하나씩 + 실질 기준 + 나라.
    private var levers: [SimLever] {
        let won = country.code == "KR"
        var list: [SimLever] = validEntries.map { e in
            let id = e.id
            let b = Binding<Double>(
                get: { entries.first { $0.id == id }?.monthly ?? 0 },
                set: { v in
                    if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].monthly = v.rounded() }
                }
            )
            return SimLever(id: String(localized: "\(yearLabel(e.year))년"), value: b,
                            range: SimLever.fit(0...sliderMax, b.wrappedValue),
                            step: sliderStep, text: country.money(b.wrappedValue),
                            unit: won ? 10_000 : 1,
                            unitLabel: won ? String(localized: "만원") : country.symbol.trimmingCharacters(in: .whitespaces))
        }
        list.append(.choice(String(localized: "실질 기준"), current: realMode.rawValue, RealMode.allCases.map { m in
            SimOption(id: m.rawValue, selected: realMode == m) { realMode = m }
        }))
        list.append(.choice(String(localized: "나라"), current: "\(country.flag) \(country.name)", CPIData.all.map { c in
            SimOption(id: "\(c.flag) \(c.name)", selected: c.code == countryCode) { countryCode = c.code }
        }))
        return list
    }

    // 월급 슬라이더 폭 — 끄는 동안 범위가 따라 움직이지 않게, 칩을 고를 때·기록이 바뀔 때만 다시 잡는다.
    private func rescale() {
        let top = entries.map(\.monthly).max() ?? 0
        let base = max(top * 2, country.code == "KR" ? 5_000_000 : 5_000)
        let mag = pow(10, floor(log10(base)))
        sliderMax = (base / mag).rounded(.up) * mag
    }

    private var sliderStep: Double {
        country.code == "KR" ? 10_000 : max(1, pow(10, floor(log10(max(sliderMax, 10)))) / 100)
    }

    // 자료 출처 + 그 나라 확정 물가가 어디까지인지.
    private var sourceNote: String {
        let range = String(localized: "\(yearLabel(country.firstYear))~\(yearLabel(country.lastYear))년")
        let clamped = Self.thisYear > country.lastYear
            ? String(localized: " \(yearLabel(country.lastYear))년 이후 월급은 \(yearLabel(country.lastYear))년 물가로 계산해요(그 뒤 물가는 아직 확정 전).")
            : ""
        return String(localized: "물가는 \(country.flag) \(country.name)의 소비자물가지수(2020년 = 100) 연평균이고 \(range) 자료가 들어 있어요.\(clamped) 출처는 World Bank(원자료는 각국 통계기관)이고, 전국 평균이라 내가 실제로 쓰는 품목과는 다를 수 있어요.")
    }

    // MARK: 입력

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("내 월급 기록")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                // 물가·통화를 적용할 나라. 해외 근무 이력이 있으면 바꿔서 본다.
                Picker("나라", selection: $countryCode) {
                    ForEach(CPIData.all) { c in
                        Text("\(c.flag) \(c.name)").tag(c.code)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
            }
            Text("기억나는 해의 월급만 적어도 돼요. 세전·세후 중 하나로만 통일하면 비교는 정확해요. 금액은 \(country.name) 통화 기준이에요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            ForEach(entries.sorted { $0.year < $1.year }) { entry in
                if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                    entryRow(idx)
                }
            }

            Divider().overlay(Theme.hairline)

            HStack(spacing: 10) {
                Picker("연도", selection: $newYear) {
                    ForEach(yearOptions, id: \.self) { Text("\(yearLabel($0))년").tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                Spacer()
                Button {
                    addYear(newYear)
                } label: {
                    Label("추가", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                }
                .buttonStyle(.plain)
            }

            if entries.isEmpty, country.code == "KR" {
                Button {
                    fillExample()
                } label: {
                    Text("예시로 채워보기")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surfaceHigh)
                        .foregroundStyle(Theme.textPrimary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if entries.isEmpty {
                Text("연도를 고르고 그때 받던 월급을 적어보세요. 두 해 이상이면 구매력 변화가 보여요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            } else if !entries.contains(where: { $0.year >= baseYear }) {
                Text("지금 월급도 넣으면 최근 물가(\(yearLabel(baseYear))년)까지 이어서 볼 수 있어요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func entryRow(_ idx: Int) -> some View {
        // 삭제는 인덱스가 아니라 id로 — 배열을 읽으면서 동시에 지우지 않도록.
        let rowID = entries[idx].id
        return HStack(spacing: 10) {
            Text("\(yearLabel(entries[idx].year))년")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textSecond)
                .frame(width: 62, alignment: .leading)
            TextField("0", text: amountBinding(idx).commaGrouped)
                .keyboardType(.numberPad)
                .accessibilityLabel("\(yearLabel(entries[idx].year))년")
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(country.symbol.trimmingCharacters(in: .whitespaces))
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            Button {
                entries.removeAll { $0.id == rowID }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textSecond.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("삭제")
        }
    }

    private func amountBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard entries.indices.contains(idx), entries[idx].monthly > 0 else { return "" }
                return String(Int(entries[idx].monthly))
            },
            set: { newValue in
                guard entries.indices.contains(idx) else { return }
                entries[idx].monthly = Double(newValue.filter(\.isNumber)) ?? 0
            }
        )
    }

    private var yearOptions: [Int] {
        Array((country.firstYear...max(Self.thisYear, country.lastYear)).reversed())
    }

    private func addYear(_ year: Int) {
        guard !entries.contains(where: { $0.year == year }) else { return }
        entries.append(WageEntry(year: year, monthly: 0))
        entries.sort { $0.year < $1.year }
        // 다음 추가는 그 다음 해가 기본값이 되도록.
        newYear = min(year + 1, max(Self.thisYear, country.lastYear))
    }

    private func fillExample() {
        entries = [
            WageEntry(year: 2016, monthly: 2_500_000),
            WageEntry(year: 2021, monthly: 3_200_000),
            WageEntry(year: baseYear, monthly: 4_230_000),
        ]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = entriesJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([WageEntry].self, from: data) else { return }
        entries = list.sorted { $0.year < $1.year }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries),
              let text = String(data: data, encoding: .utf8) else { return }
        entriesJSON = text
    }

    // MARK: 결과

    // 첫 월급이 오늘 물가로 얼마인지 vs 지금 월급 — 구매력이 늘었는지 줄었는지.
    private func purchasingPowerCard(_ span: (first: WageRow, last: WageRow, years: Int)) -> some View {
        let change = span.first.realIndexed > 0
            ? span.last.realIndexed / span.first.realIndexed - 1 : 0
        let up = change >= 0
        let thenInToday = span.first.realToday
        let nowNominal = span.last.nominal
        let peak = max(thenInToday, nowNominal, 1)
        return VStack(alignment: .leading, spacing: 14) {
            AdaptiveRow {
                Text("내 구매력")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
            } trailing: {
                Text("\(yearLabel(span.first.year)) → \(yearLabel(span.last.year))년")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            Text("\(up ? "▲" : "▼") \(Fmt.percent(abs(change)))")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(up ? Theme.rise : Theme.fall)
                .contentTransition(.numericText())
            Text(up
                 ? "물가를 빼고 봐도 \(span.years)년 동안 실제 살 수 있는 양이 늘었어요."
                 : "월급은 올랐어도 물가가 더 올라서, 실제 살 수 있는 양은 줄었어요.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            // 같은 잣대(오늘 물가)로 옮겨 놓고 나란히 비교.
            VStack(spacing: 10) {
                compareBar(label: String(localized: "\(yearLabel(span.first.year))년 월급을 오늘 물가로"),
                           value: thenInToday, peak: peak, color: Theme.textSecond.opacity(0.45))
                compareBar(label: String(localized: "\(yearLabel(span.last.year))년 월급"),
                           value: nowNominal, peak: peak, color: up ? Theme.rise : Theme.fall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func compareBar(label: String, value: Double, peak: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            AdaptiveRow {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            } trailing: {
                Text(country.money(value))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * min(1, value / peak)))
            }
            .frame(height: 8)
            .background(Theme.surfaceHigh, in: Capsule())
        }
    }

    // 명목(막대) vs 실질(선) — 두 선이 벌어질수록 물가에 깎인 몫이다.
    private var nominalRealChart: some View {
        let data = rows
        return Chart {
            ForEach(data) { r in
                BarMark(x: .value("연도", "\(r.year)"),
                        y: .value("명목", r.nominal),
                        width: .ratio(0.45))
                    .foregroundStyle(Theme.textSecond.opacity(0.3))
                    .cornerRadius(4)
            }
            ForEach(data) { r in
                LineMark(x: .value("연도", "\(r.year)"),
                         y: .value("실질", realValue(r)))
                    .foregroundStyle(Theme.accentText)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("연도", "\(r.year)"),
                          y: .value("실질", realValue(r)))
                    .foregroundStyle(Theme.accentText)
                    .symbolSize(50)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(country.money(v)).font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let s = value.as(String.self) {
                        Text(s).font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: realMode)
    }

    private func realValue(_ r: WageRow) -> Double {
        realMode == .today ? r.realToday : r.realIndexed
    }

    // 연도별 상세 — 직전 기록 대비 내 인상률과 물가상승률을 나란히.
    private var yearlyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("연도별로 보기")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(yearLabel(r.year))년")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(country.money(r.nominal))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(realMode == .today
                                 ? "지금 돈으로 \(country.money(r.realToday))"
                                 : "실질 \(country.money(r.realIndexed)) (2020년 기준)")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                        Spacer()
                        if let real = r.realRate {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(real >= 0 ? "▲" : "▼") \(Fmt.percent(abs(real)))")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(real >= 0 ? Theme.rise : Theme.fall)
                                Text(r.gapYears > 1 ? "실질 · 연평균" : "실질")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecond)
                            }
                        } else {
                            Text("시작")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    if let n = r.nominalRate, let i = r.inflationRate {
                        Text("내 인상 \(signed(n)) · 물가 \(signed(i))\(r.gapYears > 1 ? String(localized: " (\(r.gapYears)년 연평균)") : "")")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                            .padding(.leading, 62)
                    }
                }
                if r.id != rows.last?.id {
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func signed(_ v: Double) -> String {
        "\(v >= 0 ? "+" : "−")\(Fmt.percent(abs(v)))"
    }

    // 구간 전체 숫자 정리 — 명목 상승, 물가 상승, 그리고 남은 몫.
    private func summaryCard(_ span: (first: WageRow, last: WageRow, years: Int)) -> some View {
        let years = Double(span.years)
        let nominalTotal = span.first.nominal > 0
            ? span.last.nominal / span.first.nominal - 1 : 0
        let priceTotal = country.inflation(from: span.first.year, to: span.last.year)
        let realTotal = span.first.realIndexed > 0
            ? span.last.realIndexed / span.first.realIndexed - 1 : 0
        let nominalCAGR = pow(1 + nominalTotal, 1 / years) - 1
        let priceCAGR = pow(1 + priceTotal, 1 / years) - 1
        let realCAGR = pow(1 + realTotal, 1 / years) - 1
        let lost = span.last.nominal - span.first.realToday
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(span.years)년 동안")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(alignment: .top, spacing: 12) {
                simStat(String(localized: "명목 월급"), signed(nominalTotal))
                simStat(String(localized: "물가"), signed(priceTotal), tint: Theme.negative)
                simStat(String(localized: "실질(구매력)"), signed(realTotal),
                        tint: realTotal >= 0 ? Theme.rise : Theme.fall)
            }
            HStack(alignment: .top, spacing: 12) {
                simStat(String(localized: "연평균 인상"), signed(nominalCAGR))
                simStat(String(localized: "연평균 물가"), signed(priceCAGR), tint: Theme.negative)
                simStat(String(localized: "연평균 실질"), signed(realCAGR),
                        tint: realCAGR >= 0 ? Theme.rise : Theme.fall)
            }
            Divider().overlay(Theme.hairline)
            Text(realTotal >= 0
                 ? "지금 월급 \(country.money(span.last.nominal))은 \(yearLabel(span.first.year))년 월급을 오늘 물가로 옮긴 \(country.money(span.first.realToday))보다 \(country.money(abs(lost))) 많아요."
                 : "지금 월급 \(country.money(span.last.nominal))은 \(yearLabel(span.first.year))년 월급을 오늘 물가로 옮긴 \(country.money(span.first.realToday))보다 \(country.money(abs(lost))) 적어요. 그만큼 구매력이 깎인 셈이에요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
            Text("실질임금 = 명목임금 ÷ 소비자물가지수 × 100. 인상률이 그해 물가상승률보다 낮으면 실질임금은 마이너스예요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 기록이 하나뿐일 때 — 그 월급의 오늘 가치만이라도 바로 보여준다.
    private func singleEntryCard(_ r: WageRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(yearLabel(r.year))년 \(country.money(r.nominal))은")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
            Text("지금 \(country.money(r.realToday))")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.accentText)
            Text("\(yearLabel(r.year))년 → \(yearLabel(baseYear))년 물가가 \(Fmt.percent(country.inflation(from: r.year, to: baseYear))) 올랐어요. 다른 해의 월급도 한 줄 더 넣으면 구매력 변화를 볼 수 있어요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 파운데이션 모델 해석 카드 (iOS 26 + Apple Intelligence 기기 전용)

#if canImport(FoundationModels)
// 예측 결과를 온디바이스 모델이 자연어로 풀어주는 카드 — 수치는 건드리지 않고
// '읽는 법'만 돕는다. 버튼을 눌렀을 때만 생성하고, 결과는 참고용임을 명시한다.
@available(iOS 26.0, *)
private struct ForecastAICard: View {
    let prompt: String

    @State private var summary: String?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 해석", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if loading { ProgressView() }
            }
            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !loading {
                Button {
                    generate()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                        Text(failed ? "다시 시도" : "이 예측, 어떻게 읽어야 할까?")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accentText)
                }
                .buttonStyle(.borderless)
            }
            Text("기기 안에서 동작하는 애플 파운데이션 모델의 참고용 해석이에요. 투자 조언이 아닙니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        // 기간·구성이 바뀌어 프롬프트가 달라지면 이전 해석은 비운다.
        .onChange(of: prompt) { _, _ in summary = nil; failed = false }
    }

    private func generate() {
        loading = true
        failed = false
        let request = prompt
        Task { @MainActor in
            defer { loading = false }
            do {
                let session = LanguageModelSession()
                summary = try await session.respond(to: request).content
            } catch {
                failed = true
            }
        }
    }
}
#endif
