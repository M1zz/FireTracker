import SwiftUI
import SwiftData
import Charts
import TipKit

// Surfaces the 기간별 목표 feature and points to where it's set up (설정).
struct MilestoneSetupTip: Tip {
    var title: Text { Text("기간별 목표를 켜보세요") }
    var message: Text? {
        Text("설정 ▸ ‘목표 측정 & 기간’에서 현재 나이와 목표 은퇴 나이를 넣으면, 은퇴까지 필요한 속도로 이번달·올해·5년·은퇴 목표를 단계별로 보여드려요.")
    }
    var image: Image? { Image(systemName: "target") }
}

// One-time nudge teaching that the small ⓘ buttons reveal each card's details.
struct InfoButtonTip: Tip {
    var title: Text { Text("자세한 설명은 ⓘ에서") }
    var message: Text? { Text("카드의 ⓘ 버튼을 누르면 그 지표가 무슨 뜻인지, 어떻게 계산했는지 볼 수 있어요.") }
    var image: Image? { Image(systemName: "info.circle") }
}

// A small ⓘ button that reveals a card's detail text in a popover, so the
// "짜잘한" explanations aren't shown all the time.
struct InfoPopoverButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecond)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(16)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Theme.surface)
        }
    }
}

// Which total the asset-composition card headlines: gross (자산 합계) or net
// (부채 차감 후).
enum AssetTotalMode: String, CaseIterable, Identifiable {
    case gross = "총자산"
    case net   = "순자산"
    var id: String { rawValue }
}

// One slice of the asset-composition donut. Debt rides along as its own slice
// (drawn from its absolute size) so liabilities are visible in the mix.
private struct AllocationSlice: Identifiable {
    let id: String
    let label: String
    let amount: Double
    let color: Color
}

// One point on the FIRE trajectory: where you should be at a given time.
private struct TrajPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let label: String
}

// Traffic-light reading of a single financial signal.
enum SignalLevel {
    case good, caution, bad, neutral
    var color: Color {
        switch self {
        case .good:    return Theme.positive
        case .caution: return Theme.accent
        case .bad:     return Theme.negative
        case .neutral: return Theme.textSecond
        }
    }
}

struct FinancialSignal: Identifiable {
    let title: String
    let detail: String
    let level: SignalLevel
    let symbol: String
    var id: String { title }
}

struct DashboardView: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]

    @State private var showingAddAsset = false
    @State private var totalMode: AssetTotalMode = .gross
    @State private var milestoneMetric: FireGoalType = .assets
    private let milestoneSetupTip = MilestoneSetupTip()

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var latest: NetWorthSnapshot? {
        snapshots.sorted { $0.date > $1.date }.first
    }
    // Sum of the live catalog — used before the first record is saved so the
    // dashboard reflects registered assets immediately.
    private var hasCatalog: Bool { !assets.isEmpty }
    private var catalogTotal: Double { assets.reduce(0) { $0 + $1.netValue } }
    private func catalogTotal(for ac: AssetClass) -> Double {
        assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
    }
    // Live catalog is the source of truth for "current"; fall back to the last
    // recorded snapshot only when no assets are registered.
    private var netWorth: Double { hasCatalog ? catalogTotal : (latest?.netWorth ?? 0) }

    // Spendable (liquid) net worth — the figure that actually matters for FIRE.
    private var catalogLiquid: Double { assets.reduce(0) { $0 + $1.liquidValue } }
    private var liquidNetWorth: Double { hasCatalog ? catalogLiquid : (latest?.liquidNetWorth ?? 0) }
    private var lockedNetWorth: Double { netWorth - liquidNetWorth }

    // Passive cash flow the catalog produces, and how much of the FIRE target
    // expense it already covers — the real measure of financial independence.
    private var monthlyPassiveIncome: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } + settings.manualMonthlyDividend
    }
    // Money debts pull out every month (이자/상환) — the opposite of income.
    private var monthlyDebtCost: Double { assets.reduce(0) { $0 + $1.monthlyDebtCost } }
    private var incomeCoverage: Double {
        let target = settings.targetAnnualExpense
        guard target > 0 else { return 0 }
        return (monthlyPassiveIncome * 12) / target
    }
    // The monthly spending you want your income to cover — the FIRE goal
    // expense expressed per month (연간 목표 지출 ÷ 12).
    private var targetMonthlyExpense: Double { settings.targetAnnualExpense / 12 }
    // Weekly equivalent of the monthly income (avg 4.345 weeks per month).
    private var weeklyPassiveIncome: Double { monthlyPassiveIncome / 4.345 }
    // How far the monthly income still falls short of / overshoots the goal.
    private var incomeShortfall: Double { max(0, targetMonthlyExpense - monthlyPassiveIncome) }
    private var incomeSurplus: Double { max(0, monthlyPassiveIncome - targetMonthlyExpense) }

    // --- 목표 수입에 필요한 자금 (현재 전략 기준) ---
    // The goal income is the spending you want covered, expressed monthly.
    private var targetMonthlyIncome: Double { targetMonthlyExpense }
    private var annualPassiveIncome: Double { monthlyPassiveIncome * 12 }
    // Capital that is actually producing income right now (per-asset). Falls
    // back to all investable (liquid, non-debt) assets when income is entered as
    // a manual lump (설정의 연간 배당) with no specific holding behind it.
    private var yieldingCapital: Double {
        assets.filter { !$0.isDebt && $0.effectiveMonthlyIncome > 0 }.reduce(0) { $0 + $1.amount }
    }
    private var strategyCapitalBase: Double { yieldingCapital > 0 ? yieldingCapital : catalogLiquid }
    // The blended yield of the current strategy: how fast your money makes
    // income today. e.g. 연 3.2%.
    private var strategyYield: Double {
        guard strategyCapitalBase > 0, annualPassiveIncome > 0 else { return 0 }
        return annualPassiveIncome / strategyCapitalBase
    }
    // Capital required to throw off the target income at that same yield.
    private var capitalNeeded: Double {
        guard strategyYield > 0 else { return 0 }
        return (targetMonthlyIncome * 12) / strategyYield
    }
    private var capitalGap: Double { max(0, capitalNeeded - strategyCapitalBase) }
    // Nothing registered and nothing recorded yet → show onboarding.
    private var isEmpty: Bool { assets.isEmpty && snapshots.isEmpty }
    private var fireNumber: Double { settings.fireNumber }
    private var avgSavings: Double {
        FireEngine.averageMonthlySavings(snapshots: snapshots)
    }

    // --- Year-end projection ---
    // Use the planned salary-based savings; fall back to the recorded average.
    private var plannedSavings: Double {
        settings.plannedMonthlySavings != 0 ? settings.plannedMonthlySavings : avgSavings
    }
    private var monthsLeftInYear: Int { FireEngine.monthsLeftInYear(asOf: Date()) }
    // The projection starts from whichever total the toggle is showing, so the
    // year-end figure changes when you switch 총자산 ↔ 순자산.
    private var projectionBase: Double { effectiveMode == .net ? netAssets : grossAssets }
    private var projectedYearEnd: Double {
        FireEngine.projectedYearEnd(currentNetWorth: projectionBase,
                                    monthlySavings: plannedSavings,
                                    monthlyPassiveIncome: monthlyPassiveIncome,
                                    asOf: Date())
    }
    private var yearEndLabel: String {
        let year = Calendar.current.component(.year, from: Date())
        let basis = hasDebt ? (effectiveMode == .net ? " (순자산 기준)" : " (총자산 기준)") : ""
        return "\(year)년 말 예상 자산\(basis)"
    }
    private var yearsToFire: Double? {
        FireEngine.yearsToFire(
            currentNetWorth: netWorth,
            fireNumber: fireNumber,
            monthlySavings: avgSavings,
            annualReturn: settings.expectedAnnualReturn
        )
    }
    private var delta: Double? {
        FireEngine.latestDelta(snapshots: snapshots)
    }

    // --- 첫 화면 요약: 지난 기록 이후 변화 & 목표 근접도 ---
    // Change since the last saved record, counting only assets that existed in
    // that record so newly-registered holdings don't look like growth. Gross
    // tracks asset value only; net also folds in debt changes — the two differ
    // when debt moved, so we surface both.
    private var lastRecordChange: (gross: Double, net: Double)? {
        guard let last = latest else { return nil }
        var recorded: [UUID: Double] = [:]
        for entry in last.entries {
            if let key = entry.catalogKey { recorded[key, default: 0] += entry.amount }
        }
        guard !recorded.isEmpty else {
            let d = netWorth - last.netWorth
            return (d, d)
        }
        var gross = 0.0, net = 0.0
        for asset in assets {
            guard let prior = recorded[asset.key] else { continue }
            net += asset.netValue - prior
            if !asset.isDebt { gross += asset.netValue - prior }
        }
        return (gross, net)
    }
    private var goalProgress: Double { fireNumber > 0 ? netWorth / fireNumber : 0 }
    private var goalRemaining: Double { max(0, fireNumber - netWorth) }
    // Percentage points of the goal gained (or lost) since the last record, by
    // net worth — the figure the FIRE goal is measured against.
    private var goalChangePP: Double {
        guard fireNumber > 0, let c = lastRecordChange else { return 0 }
        return c.net / fireNumber
    }

    // --- 재정 신호등 (financial health signals) ---
    // Monthly savings to read now: the latest recorded month, else the plan.
    private var monthlySavingsNow: Double {
        if let s = latest, s.monthlyIncome > 0 || s.monthlyExpense > 0 || s.monthlyNetSavings > 0 {
            return s.monthlySavings
        }
        return settings.plannedMonthlySavings
    }
    private var debtRatio: Double { grossAssets > 0 ? totalDebt / grossAssets : 0 }

    private var signals: [FinancialSignal] {
        var out: [FinancialSignal] = []

        // 1) 자산 추세 — the signal the user cares most about (줄어드는가).
        if let d = delta {
            if d > 0 {
                out.append(.init(title: "자산 추세",
                                 detail: "지난 기록보다 +\(Fmt.krw(d))원 — 늘고 있어요",
                                 level: .good, symbol: "arrow.up.right"))
            } else if d < 0 {
                out.append(.init(title: "자산 추세",
                                 detail: "지난 기록보다 \(Fmt.krw(d))원 — 줄고 있어요",
                                 level: .bad, symbol: "arrow.down.right"))
            } else {
                out.append(.init(title: "자산 추세",
                                 detail: "지난 기록과 비슷해요", level: .caution, symbol: "arrow.right"))
            }
        } else {
            out.append(.init(title: "자산 추세",
                             detail: "기록 2개부터 늘었는지 줄었는지 알 수 있어요",
                             level: .neutral, symbol: "chart.xyaxis.line"))
        }

        // 2) 월 저축 — 버는 것보다 많이 쓰면 경고.
        let sav = monthlySavingsNow
        if sav > 0 {
            out.append(.init(title: "월 저축",
                             detail: "매달 +\(Fmt.krw(sav))원씩 쌓이는 중", level: .good, symbol: "tray.and.arrow.down.fill"))
        } else if sav < 0 {
            out.append(.init(title: "월 저축",
                             detail: "버는 것보다 \(Fmt.krw(-sav))원 더 써요", level: .bad, symbol: "tray.and.arrow.up.fill"))
        } else {
            out.append(.init(title: "월 저축",
                             detail: "월 저축을 입력하면 신호가 켜져요", level: .neutral, symbol: "tray.fill"))
        }

        // 3) 패시브 인컴 — 있으면 좋은 신호 (선택의 영역).
        if monthlyPassiveIncome > 0 {
            out.append(.init(title: "패시브 인컴",
                             detail: "월 \(Fmt.krw(monthlyPassiveIncome))원이 들어와요", level: .good, symbol: "dollarsign.arrow.circlepath"))
        } else {
            out.append(.init(title: "패시브 인컴",
                             detail: "배당·월세·이자를 넣으면 들어오는 돈이 보여요", level: .neutral, symbol: "dollarsign.circle"))
        }

        // 4) 부채 비중 — 총자산 대비 빚이 과한가.
        if hasDebt {
            let pct = Fmt.percent(debtRatio, fraction: 0)
            let level: SignalLevel = debtRatio < 0.4 ? .good : (debtRatio < 0.7 ? .caution : .bad)
            let tail = debtRatio < 0.4 ? "적정 수준" : (debtRatio < 0.7 ? "다소 높아요" : "부담이 커요")
            out.append(.init(title: "부채 비중",
                             detail: "총자산의 \(pct) — \(tail)", level: level, symbol: "creditcard.trianglebadge.exclamationmark"))
        }

        return out
    }

    private var overallSignal: SignalLevel {
        if signals.contains(where: { $0.level == .bad }) { return .bad }
        if signals.contains(where: { $0.level == .caution }) { return .caution }
        if signals.contains(where: { $0.level == .good }) { return .good }
        return .neutral
    }

    private var overallHeadline: String {
        switch overallSignal {
        case .good:    return "재정이 순항 중이에요"
        case .caution: return "조금 주의가 필요해요"
        case .bad:     return "점검이 필요한 신호가 있어요"
        case .neutral: return "기록을 모으면 신호가 켜져요"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    onboarding
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            welcomeCard
                            goalProgressCard
                            if settings.monthsToRetire != nil {
                                milestoneGoalsCard
                            } else {
                                TipView(milestoneSetupTip)
                                    .tipBackground(Theme.surface)
                            }
                            cashFlowCard
                            capitalNeededCard
                            NavigationLink {
                                ProjectionDetailView(startingAssets: projectionBase,
                                                     basisLabel: hasDebt ? (effectiveMode == .net ? "순자산" : "총자산") : nil,
                                                     monthlyTakeHome: settings.monthlyTakeHome,
                                                     plannedExpense: settings.plannedMonthlyExpense,
                                                     monthlySavings: plannedSavings,
                                                     monthlyPassiveIncome: monthlyPassiveIncome)
                            } label: {
                                projectionCard
                            }
                            .buttonStyle(.plain)
                            liquidityCard
                            metricsGrid
                            NavigationLink {
                                WhatIfView(defaultAmount: totalDebt,
                                           defaultInvestRatePct: settings.expectedAnnualReturn * 100)
                            } label: {
                                whatIfCard
                            }
                            .buttonStyle(.plain)
                            allocationCard
                            signalCard
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddAsset) {
                AssetEditor(asset: nil, nextSortOrder: 0)
            }
        }
    }

    // First-run guidance: walk the user through registering assets instead of
    // showing an empty 0% ring.
    private var onboarding: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "flame.fill")
                        .font(.system(.largeTitle))
                        .foregroundStyle(Theme.accent)
                    Text("FIRE 여정을 시작해볼까요?")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("보유한 자산을 등록하면 목표까지의\n달성률과 예상 시점을 추적해드립니다.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .padding(.top, 24)

                VStack(spacing: 14) {
                    stepRow(number: 1,
                            title: "보유 자산 등록",
                            detail: "주식·코인·부동산·전세·현금 등을 목록으로",
                            symbol: "wonsign.circle.fill")
                    stepRow(number: 2,
                            title: "FIRE 목표 설정",
                            detail: "설정 탭에서 연 목표 지출·인출률 입력",
                            symbol: "target")
                    stepRow(number: 3,
                            title: "매달 기록 저장",
                            detail: "자산 탭에서 한 번씩 저장하면 추이가 쌓여요",
                            symbol: "chart.xyaxis.line")
                }

                Button { showingAddAsset = true } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("자산 등록하기")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func stepRow(number: Int, title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 36, height: 36)
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
            Image(systemName: symbol)
                .font(.system(.title3))
                .foregroundStyle(Theme.accent.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // First thing you see: how much you rose (붉은색) or fell (푸른색) since the
    // last record, how much closer to the goal that put you, and a glance at the
    // health signals.
    // One change line (총자산 또는 순자산): arrow glyph + amount in a single Text
    // so no HStack is needed; 오르면 빨강, 내리면 파랑.
    private func changeBlock(title: String, value: Double) -> some View {
        let flat = abs(value) < 1
        let up = value >= 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            Text(flat ? "– 변화 없음"
                      : "\(up ? "▲ +" : "▼ −")\(Fmt.krw(abs(value)))원")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(flat ? Theme.textSecond : (up ? Theme.rise : Theme.fall))
        }
    }

    // One bar chart for the change breakdown: 총자산·순자산·부채 변화. Each bar is
    // signed from the zero line (양수 = 늘어남), with its value labelled.
    // 총자산 변화 = 순자산 변화 + 부채 변화.
    private func changeComposition(grossChange: Double, netChange: Double) -> some View {
        let debtChange = grossChange - netChange   // 양수 = 빚이 늘어남
        let debtColor = Color(hex: AssetClass.debt.colorHex)
        let bars: [(label: String, value: Double, color: Color)] = [
            ("총자산", grossChange, grossChange >= 0 ? Theme.rise : Theme.fall),
            ("순자산", netChange, netChange >= 0 ? Theme.rise : Theme.fall),
            ("부채", debtChange, debtColor)
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("총자산의 변화량은 이렇게 구성돼요")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            Chart(bars, id: \.label) { b in
                BarMark(
                    x: .value("구분", b.label),
                    y: .value("변화", b.value),
                    width: .ratio(0.5)
                )
                .foregroundStyle(b.color)
                .cornerRadius(4)
                .annotation(position: b.value >= 0 ? .top : .bottom, spacing: 3) {
                    Text(abs(b.value) < 1 ? "0"
                         : "\(b.value >= 0 ? "+" : "−")\(Fmt.krw(abs(b.value)))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(b.color)
                }
            }
            .chartXScale(domain: bars.map(\.label))
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(Fmt.krw(d)).font(.caption2) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            Text(s).font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .frame(height: 160)
        }
    }

    // A labelled progress bar for a FIRE goal达성률 (자산 또는 패시브 인컴).
    private func goalBar(title: String, progress: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                Spacer()
                Text(Fmt.percent(min(progress, 1), fraction: 1))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(progress >= 1 ? Theme.positive : Theme.accent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(progress >= 1 ? Theme.positive : Theme.accent)
                        .frame(width: max(2, geo.size.width * min(progress, 1)))
                }
            }
            .frame(height: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 카드 타이틀 — 다른 카드(내 패시브 인컴)와 같은 레벨.
            Text("지난 기록 이후")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            // 지난 기록 이후 변화 — 부채가 함께 움직였으면 바 차트로, 아니면 한 수치로.
            if let c = lastRecordChange, latest != nil {
                if abs(c.gross - c.net) >= 1 {
                    changeComposition(grossChange: c.gross, netChange: c.net)
                } else {
                    changeBlock(title: "총자산 변화", value: c.gross)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("아직 비교할 기록이 없어요")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("자산 탭에서 ‘이번 달 기록 저장’을 누르면 다음부터 변화가 여기 표시돼요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            InfoPopoverButton(text: "지난번 기록 대비 변화예요. 한국식으로 오르면 붉은색, 내리면 푸른색. 막대는 총자산·순자산·부채의 변화를 보여줘요(총자산 변화 = 순자산 변화 + 부채 변화). 부채 막대가 양수(+)면 빚이 그만큼 늘었다는 뜻이고, 빚이 늘면 총자산이 그대로여도 순자산은 줄어요. 새로 등록한 자산은 변화에서 빼서 등록만으로 오른 것처럼 보이지 않게 했어요.")
                .popoverTip(InfoButtonTip())
        }
        .cardStyle()
    }

    // FIRE 목표 달성률 — 설정한 기준(자산/패시브 인컴/둘 다)에 따라 보여줌.
    private var goalProgressCard: some View {
        let gt = settings.fireGoalType
        let showAsset = (gt == .assets || gt == .both) && fireNumber > 0
        let showIncome = (gt == .income || gt == .both) && settings.incomeGoalMonthly > 0
        return VStack(alignment: .leading, spacing: 14) {
            Text("목표 달성률")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if showAsset {
                goalBar(title: "자산 목표 달성률",
                        progress: goalProgress,
                        detail: "목표까지 \(Fmt.krw(goalRemaining))원 남음"
                            + ((lastRecordChange?.net ?? 0) != 0
                               ? " · 이번에 \((lastRecordChange?.net ?? 0) > 0 ? "+" : "−")\(Fmt.percent(abs(goalChangePP), fraction: 1)) \((lastRecordChange?.net ?? 0) > 0 ? "가까워졌어요" : "멀어졌어요")"
                               : ""))
            }
            if showIncome {
                let cov = settings.incomeGoalMonthly > 0 ? monthlyPassiveIncome / settings.incomeGoalMonthly : 0
                goalBar(title: "패시브 인컴 목표 달성률",
                        progress: cov,
                        detail: "원하는 월 지출 \(Fmt.krw(settings.incomeGoalMonthly))원의 \(Fmt.percent(min(cov, 1), fraction: 0)) 커버")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Horizons to slice the retirement goal into. Only those nearer than
    // retirement get their own row; the final row is always 은퇴.
    private var milestoneHorizons: [(label: String, months: Int)] {
        guard let m = settings.monthsToRetire else { return [] }
        var out: [(String, Int)] = []
        for (label, mo) in [("이번 달", 1), ("올해", max(1, monthsLeftInYear)), ("5년", 60)] where mo < m {
            out.append((label, mo))
        }
        out.append(("은퇴", m))
        return out
    }

    private func milestoneRow(label: String, months: Int, metric: FireGoalType) -> some View {
        let isAsset = metric == .assets
        let current = isAsset ? netWorth : monthlyPassiveIncome
        let goal = isAsset ? fireNumber : settings.incomeGoalMonthly
        let target = FireEngine.milestoneTarget(current: current, goal: goal,
                                                monthsToRetire: settings.monthsToRetire ?? 0,
                                                horizonMonths: months)
        let progress = target > 0 ? min(current / target, 1) : 0
        let gap = max(0, target - current)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(isAsset ? "\(Fmt.krw(target))원" : "월 \(Fmt.krw(target))원")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(progress >= 1 ? Theme.positive : Theme.accent)
                        .frame(width: max(2, geo.size.width * progress))
                }
            }
            .frame(height: 7)
            Text(gap < 1
                 ? "이미 달성 🎉"
                 : "\(Fmt.percent(progress, fraction: 0)) · \(isAsset ? "" : "월 ")\(Fmt.krw(gap))원 더 필요")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
    }

    // Points along the required path from now to retirement (now → 이번달 →
    // 올해 → 5년 → 은퇴). They sit on the linear trajectory, so a line through
    // them *is* the path you need to climb.
    private func trajectoryPoints(metric: FireGoalType) -> [TrajPoint] {
        guard let m = settings.monthsToRetire else { return [] }
        let isAsset = metric == .assets
        let current = isAsset ? netWorth : monthlyPassiveIncome
        let goal = isAsset ? fireNumber : settings.incomeGoalMonthly
        let cal = Calendar.current
        let now = Date()
        func date(_ months: Int) -> Date { cal.date(byAdding: .month, value: months, to: now) ?? now }
        var pts: [TrajPoint] = [TrajPoint(date: now, value: current, label: "지금")]
        for (label, mo) in [("이번 달", 1), ("올해", max(1, monthsLeftInYear)), ("5년", 60)] where mo < m {
            let t = FireEngine.milestoneTarget(current: current, goal: goal,
                                               monthsToRetire: m, horizonMonths: mo)
            pts.append(TrajPoint(date: date(mo), value: t, label: label))
        }
        pts.append(TrajPoint(date: date(m), value: goal, label: "은퇴"))
        return pts
    }

    private func trajectoryChart(metric: FireGoalType) -> some View {
        let pts = trajectoryPoints(metric: metric)
        let isAsset = metric == .assets
        return Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("시점", p.date), y: .value("값", p.value))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
            }
            ForEach(pts) { p in
                LineMark(x: .value("시점", p.date), y: .value("값", p.value))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            ForEach(pts) { p in
                let edge = p.label == "지금" || p.label == "은퇴"
                PointMark(x: .value("시점", p.date), y: .value("값", p.value))
                    .foregroundStyle(p.label == "지금" ? Theme.positive : Theme.accent)
                    .symbolSize(edge ? 90 : 45)
                    .annotation(position: .top, spacing: 3) {
                        if edge {
                            Text(p.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(p.label == "지금" ? Theme.positive : Theme.accent)
                        }
                    }
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(isAsset ? Fmt.krw(d) : "월\(Fmt.krw(d))").font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .year)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.year())
            }
        }
        .frame(height: 190)
    }

    // The retirement goal, sliced into 이번달·올해·5년·은퇴 so progress isn't only
    // measured against the far-off finish line.
    private var milestoneGoalsCard: some View {
        let metric = settings.fireGoalType == .both ? milestoneMetric : settings.fireGoalType
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("기간별 목표")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if settings.fireGoalType == .both {
                    Picker("", selection: $milestoneMetric) {
                        Text("자산").tag(FireGoalType.assets)
                        Text("패시브 인컴").tag(FireGoalType.income)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            // 은퇴까지 자산 궤도 — 지금 위치에서 은퇴 목표까지 올라야 할 길.
            trajectoryChart(metric: metric)
            if let m = settings.monthsToRetire {
                let goal = metric == .assets ? fireNumber : settings.incomeGoalMonthly
                Text("은퇴까지 \(m / 12)년 \(m % 12)개월 · \(metric == .assets ? "목표 \(Fmt.krw(goal))원" : "목표 월 \(Fmt.krw(goal))원")")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }

            Divider().overlay(Theme.hairline)
            VStack(spacing: 14) {
                ForEach(milestoneHorizons, id: \.label) { h in
                    milestoneRow(label: h.label, months: h.months, metric: metric)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Hero: the cash-flow question — does the income my assets produce cover the
    // monthly spending I want? This, not a static asset total, is the real
    // measure of financial independence and current liquidity.
    // 재정 신호등 — a quick green/yellow/red read on financial health, with the
    // individual signals behind it. "괜찮은가?" answered at a glance.
    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("재정 신호등")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(overallHeadline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(overallSignal.color)
                }
                Spacer()
                ZStack {
                    Circle().fill(overallSignal.color.opacity(0.18)).frame(width: 44, height: 44)
                    Circle().fill(overallSignal.color).frame(width: 22, height: 22)
                }
            }

            VStack(spacing: 12) {
                ForEach(signals) { sig in
                    HStack(spacing: 12) {
                        Image(systemName: sig.symbol)
                            .font(.system(.subheadline))
                            .foregroundStyle(sig.level.color)
                            .frame(width: 24, height: 24)
                            .background(sig.level.color.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sig.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(sig.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                        Spacer(minLength: 8)
                        Circle().fill(sig.level.color).frame(width: 9, height: 9)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var cashFlowCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("내 패시브 인컴")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("자산이 만들어내는 현금흐름")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
                Spacer()
                InfoPopoverButton(text: "일하지 않아도 들어오는 돈이에요 — 월세·배당·이자·연금·스테이킹과 설정의 ‘연간 배당수익’을 합산했어요. 주 수입은 월÷4.345로 환산했고, 막대는 원하는 월 지출(연간 목표 지출÷12)을 얼마나 커버하는지 보여줘요.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if monthlyPassiveIncome > 0 {
                // 월·주 수입을 함께 — 현금이 들어오는 속도감을 보여줌.
                VStack(alignment: .leading, spacing: 4) {
                    Text("월 \(Fmt.krw(monthlyPassiveIncome))원")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.positive)
                    Text("주 \(Fmt.krw(weeklyPassiveIncome))원 · 연 \(Fmt.krw(monthlyPassiveIncome * 12))원")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                if monthlyDebtCost > 0 {
                    HStack {
                        Text("부채가 가져가는 돈")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecond)
                        Spacer()
                        Text("월 −\(Fmt.krw(monthlyDebtCost))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.negative)
                    }
                    let net = monthlyPassiveIncome - monthlyDebtCost
                    Text("월 순현금흐름 \(net >= 0 ? "+" : "−")\(Fmt.krw(abs(net)))원 (수입 − 부채)")
                        .font(.caption)
                        .foregroundStyle(net >= 0 ? Theme.positive : Theme.negative)
                }

                // 원하는 월 지출을 얼마나 커버하는가 — FIRE 달성의 핵심 지표.
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline)
                            Capsule()
                                .fill(incomeCoverage >= 1 ? Theme.accent : Theme.positive)
                                .frame(width: max(2, geo.size.width * min(incomeCoverage, 1)))
                        }
                    }
                    .frame(height: 10)
                    if incomeShortfall > 0 {
                        Text("원하는 월 지출 \(Fmt.krw(targetMonthlyExpense))원의 \(Fmt.percent(incomeCoverage, fraction: 0)) 커버 · 월 \(Fmt.krw(incomeShortfall))원 부족")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    } else {
                        Text("원하는 월 지출 \(Fmt.krw(targetMonthlyExpense))원을 모두 커버 · 월 \(Fmt.krw(incomeSurplus))원 여유 🎉")
                            .font(.caption)
                            .foregroundStyle(Theme.positive)
                    }
                }
            } else {
                // 수입이 잡히는 자산이 없을 때 — 입력을 유도.
                VStack(alignment: .leading, spacing: 6) {
                    if monthlyDebtCost > 0 {
                        HStack {
                            Text("부채가 가져가는 돈")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecond)
                            Spacer()
                            Text("월 −\(Fmt.krw(monthlyDebtCost))원")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.negative)
                        }
                    }
                    Text("아직 수입이 잡히는 자산이 없어요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("자산 탭에서 월세·배당·이자 등을 입력하거나, 설정에서 ‘연간 배당수익’을 대략 넣으면 여기에 월·주 수입이 표시됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("원하는 월 지출 \(Fmt.krw(targetMonthlyExpense))원 · 설정의 ‘연간 목표 지출’에서 변경")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // How much capital it takes to throw off the target monthly income, using
    // the yield the user's *current* portfolio actually produces (not the 4%
    // rule). Answers "내가 지금 전략대로면 목표 수입까지 자금이 얼마나 필요한가".
    private var capitalNeededCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("목표 패시브 인컴에 필요한 자금")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("지금 전략(실제 수익률) 기준")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
                Spacer()
                InfoPopoverButton(text: "목표 패시브 인컴을 ‘지금 포트폴리오가 실제로 내는 수익률’로 나눠 필요한 자본을 계산해요. 같은 수익률을 유지한다고 가정한 값이라, 더 높은 배당·이자 전략을 쓰면 필요 자금은 줄어듭니다. 참고로 4% 룰 기준 필요 자금은 \(Fmt.krw(fireNumber))원이에요.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if strategyYield > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("약 \(Fmt.krw(capitalNeeded))원")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("월 \(Fmt.krw(targetMonthlyIncome))원 패시브 인컴을 만들려면 · 현재 전략 수익률 연 \(Fmt.percent(strategyYield, fraction: 1))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                // Progress of current income-producing capital toward the goal.
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline)
                            Capsule()
                                .fill(incomeCoverage >= 1 ? Theme.accent : Theme.positive)
                                .frame(width: max(2, geo.size.width * min(incomeCoverage, 1)))
                        }
                    }
                    .frame(height: 10)
                    if capitalGap > 0 {
                        Text("현재 투자 자본 \(Fmt.krw(strategyCapitalBase))원 · 약 \(Fmt.krw(capitalGap))원 더 필요")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    } else {
                        Text("이미 목표 패시브 인컴을 낼 만큼 자본이 충분해요 🎉")
                            .font(.caption)
                            .foregroundStyle(Theme.positive)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("아직 현재 전략 수익률을 계산할 수 없어요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("배당·이자·월세 등 수입이 잡혀야 ‘내 전략의 수익률’이 계산돼요. 자산에 배당률을 넣거나 설정에서 연간 배당을 입력해보세요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    if fireNumber > 0 {
                        Text("참고: 4% 룰 기준 필요 자금은 \(Fmt.krw(fireNumber))원이에요.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            MetricCard(
                title: "예상 달성 시점",
                value: Fmt.years(yearsToFire),
                symbol: "calendar",
                tint: Theme.accent
            )
            MetricCard(
                title: "월 평균 저축",
                value: "\(Fmt.krw(avgSavings))원",
                symbol: "arrow.up.forward",
                tint: Theme.positive
            )
            MetricCard(
                title: "전월 대비",
                value: delta != nil ? "\(delta! >= 0 ? "+" : "")\(Fmt.krw(delta!))원" : "—",
                symbol: delta ?? 0 >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                tint: (delta ?? 0) >= 0 ? Theme.rise : Theme.fall
            )
            MetricCard(
                title: "최근 저축률",
                value: Fmt.percent(latest?.savingsRate ?? 0, fraction: 0),
                symbol: "percent",
                tint: Theme.accent
            )
        }
    }

    // Projects assets to year-end from expected inflows only: salary-based
    // savings plus scheduled passive income. No asset-appreciation guesswork.
    private var projectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(yearEndLabel)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                HStack(spacing: 2) {
                    Text("근거 보기")
                    Image(systemName: "chevron.right")
                }
                .font(.caption)
                .foregroundStyle(Theme.accent)
            }
            Text("\(Fmt.krw(projectedYearEnd))원")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("= \(Fmt.wonKo(projectedYearEnd))")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)

            if plannedSavings != 0 || monthlyPassiveIncome > 0 {
                Text("현재 \(Fmt.krw(projectionBase))원 + (월 저축 \(Fmt.krw(plannedSavings))원"
                     + (monthlyPassiveIncome > 0 ? " + 월 패시브 인컴 \(Fmt.krw(monthlyPassiveIncome))원" : "")
                     + ") × 남은 \(monthsLeftInYear)개월. 자산 가치 상승은 반영하지 않아요.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            } else {
                Text("설정에서 세후 월급·월 지출을 입력하면 예정된 수입으로 올해 말 자산을 예측합니다.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Spendable vs. locked — FIRE is about usable money, not total net worth.
    private var liquidityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("쓸 수 있는 돈 (유동)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                        InfoPopoverButton(text: "순자산 \(Fmt.krw(netWorth))원 중 실제 쓸 수 있는 돈입니다. 실거주 부동산·전세보증금·연금·부채는 묶인 돈으로 빠집니다.")
                    }
                    Text("\(Fmt.krw(liquidNetWorth))원")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.positive)
                }
                Spacer()
                if lockedNetWorth > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("묶인 돈", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                        Text("\(Fmt.krw(lockedNetWorth))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textSecond)
                    }
                }
            }

            GeometryReader { geo in
                HStack(spacing: 2) {
                    if liquidNetWorth > 0 {
                        Capsule().fill(Theme.positive)
                            .frame(width: max(2, geo.size.width * (netWorth > 0 ? liquidNetWorth / netWorth : 0)))
                    }
                    if lockedNetWorth > 0 {
                        Capsule().fill(Theme.textSecond.opacity(0.4))
                            .frame(width: max(2, geo.size.width * (netWorth > 0 ? lockedNetWorth / netWorth : 0)))
                    }
                }
            }
            .frame(height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Per-class total, preferring the last recorded snapshot, falling back to
    // the live catalog. Debt comes back negative (netValue), assets positive.
    private func classTotal(for ac: AssetClass) -> Double {
        latest?.total(for: ac) ?? catalogTotal(for: ac)
    }
    // Positive asset classes that make up the composition (debt excluded here —
    // it can't be a positive slice and is handled separately).
    private var assetSlices: [(AssetClass, Double)] {
        AssetClass.allCases.compactMap { ac in
            guard ac != .debt else { return nil }
            let total = classTotal(for: ac)
            return total > 0 ? (ac, total) : nil
        }
    }
    private var totalDebt: Double { abs(classTotal(for: .debt)) }
    private var grossAssets: Double { assetSlices.reduce(0) { $0 + $1.1 } }
    private var netAssets: Double { grossAssets - totalDebt }
    // The toggle only matters when there's debt (otherwise 총자산 == 순자산), so
    // without debt we always present 총자산 regardless of the stored selection.
    private var hasDebt: Bool { totalDebt > 0 }
    private var effectiveMode: AssetTotalMode { hasDebt ? totalMode : .gross }
    // Donut slices follow the toggle: 총자산 shows assets only (debt isn't an
    // asset); 순자산 adds a red debt slice so you see how it eats into the total.
    private var allocationSlices: [AllocationSlice] {
        var slices = assetSlices.map {
            AllocationSlice(id: $0.0.rawValue, label: $0.0.label,
                            amount: $0.1, color: Color(hex: $0.0.colorHex))
        }
        if effectiveMode == .net && totalDebt > 0 {
            slices.append(AllocationSlice(id: AssetClass.debt.rawValue,
                                          label: AssetClass.debt.label,
                                          amount: totalDebt,
                                          color: Color(hex: AssetClass.debt.colorHex)))
        }
        return slices
    }

    // Entry point to the what-if comparison ("빚 갚기 vs 투자하기").
    private var whatIfCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("만약에 — 빚 갚기 vs 투자하기")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("같은 돈으로 빚을 갚을 때 아낄 이자와 투자 기대 수익을 비교")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("자산 구성")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                // Only offer the toggle when debt makes 총자산 ≠ 순자산.
                if hasDebt {
                    Picker("", selection: $totalMode) {
                        ForEach(AssetTotalMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            // Headline total for the selected mode, with the other figure as context.
            VStack(alignment: .leading, spacing: 2) {
                Text(effectiveMode == .gross ? "총자산" : "순자산")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                Text("\(Fmt.krw(effectiveMode == .gross ? grossAssets : netAssets))원")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(effectiveMode == .gross ? Theme.textPrimary : Theme.accent)
                if hasDebt {
                    Text(effectiveMode == .gross
                         ? "부채 \(Fmt.krw(totalDebt))원 차감 시 순자산 \(Fmt.krw(netAssets))원"
                         : "총자산 \(Fmt.krw(grossAssets))원 − 부채 \(Fmt.krw(totalDebt))원")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }

            if allocationSlices.isEmpty {
                Text("기록된 자산이 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
            } else {
                Chart(allocationSlices) { slice in
                    SectorMark(
                        angle: .value("금액", slice.amount),
                        innerRadius: .ratio(0.6),
                        angularInset: 2
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(4)
                }
                .frame(height: 180)
                .animation(.easeInOut(duration: 0.45), value: allocationSlices.map(\.amount))

                VStack(spacing: 8) {
                    ForEach(allocationSlices) { slice in
                        let isDebt = slice.id == AssetClass.debt.rawValue
                        HStack {
                            Circle()
                                .fill(slice.color)
                                .frame(width: 10, height: 10)
                            Text(slice.label)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(isDebt ? "-" : "")\(Fmt.krw(slice.amount))원")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(isDebt ? Theme.negative : Theme.textSecond)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.45), value: allocationSlices.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// Detailed basis for the year-end projection: assumptions + month-by-month sim.
struct ProjectionDetailView: View {
    let startingAssets: Double
    // "총자산"/"순자산" when debt makes the distinction meaningful, else nil.
    let basisLabel: String?
    let monthlyTakeHome: Double
    let plannedExpense: Double
    let monthlySavings: Double
    let monthlyPassiveIncome: Double

    private var steps: [FireEngine.ProjectionStep] {
        FireEngine.projectionSteps(currentNetWorth: startingAssets,
                                   monthlySavings: monthlySavings,
                                   monthlyPassiveIncome: monthlyPassiveIncome,
                                   asOf: Date())
    }
    private var projected: Double { steps.last?.end ?? startingAssets }
    private var totalSavings: Double { steps.reduce(0) { $0 + $1.savings } }
    private var totalPassive: Double { steps.reduce(0) { $0 + $1.passiveIncome } }

    var body: some View {
        Form {
            Section {
                resultRow("올해 말 예상 자산", projected, tint: Theme.accent, big: true)
            } footer: {
                Text("예정된 수입만 더한 값입니다. 주식·부동산 등 자산 가치가 오를 거라는 가정은 넣지 않았어요.")
                    .font(.caption)
            }

            Section("계산 가정") {
                assumptionRow(basisLabel == nil ? "현재 자산" : "현재 \(basisLabel!)",
                              Fmt.krwBoth(startingAssets))
                if monthlyTakeHome > 0 {
                    assumptionRow("세후 월급", Fmt.krwBoth(monthlyTakeHome))
                }
                if plannedExpense > 0 {
                    assumptionRow("월 지출", Fmt.krwBoth(plannedExpense))
                }
                assumptionRow("월 저축", Fmt.krwBoth(monthlySavings),
                              tint: monthlySavings >= 0 ? Theme.positive : Theme.negative)
                assumptionRow("월 패시브 인컴 (배당·월세 등)", Fmt.krwBoth(monthlyPassiveIncome),
                              tint: monthlyPassiveIncome > 0 ? Theme.positive : Theme.textPrimary)
                assumptionRow("올해 남은 개월", "\(steps.count)개월")
            }

            Section("기간 합계") {
                resultRow("저축 누적", totalSavings, tint: Theme.positive)
                resultRow("수입 누적 (배당·월세 등)", totalPassive, tint: Theme.accent)
            }

            Section("월별 시뮬레이션") {
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(monthName(step.date))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(Fmt.krw(step.end))원")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text("시작 \(Fmt.krw(step.start)) + 저축 \(Fmt.krw(step.savings))"
                             + (step.passiveIncome >= 1 ? " + 수입 \(Fmt.krw(step.passiveIncome))" : ""))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("예상 근거")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func assumptionRow(_ title: String, _ value: String, tint: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecond)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(tint)
        }
    }

    private func resultRow(_ title: String, _ value: Double, tint: Color, big: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Fmt.krw(value))원")
                    .font(.system(big ? .title3 : .body, design: .rounded).weight(.bold))
                    .foregroundStyle(tint)
                Text("\(Fmt.wonKo(value))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }

    private func monthName(_ date: Date) -> String {
        let m = Calendar.current.component(.month, from: date)
        return "\(m)월"
    }
}

// "만약에…" — compares deploying the same lump sum toward debt payoff vs. an
// investment over a horizon. Paying down debt is a guaranteed saving equal to
// its interest; investing is an expected (risky) return. Whichever compounds
// faster over the period wins. All inputs are entered by hand (직접 입력).
struct WhatIfView: View {
    let defaultAmount: Double
    let defaultInvestRatePct: Double

    @State private var amountText: String
    @State private var debtRatePct: Double   // 부채 연이자율 (%)
    @State private var investRatePct: Double // 투자 연수익률 (%)
    @State private var years: Double = 5

    init(defaultAmount: Double, defaultInvestRatePct: Double) {
        self.defaultAmount = defaultAmount
        self.defaultInvestRatePct = defaultInvestRatePct
        _amountText = State(initialValue: defaultAmount > 0 ? String(Int(defaultAmount)) : "")
        _debtRatePct = State(initialValue: 5)
        _investRatePct = State(initialValue: defaultInvestRatePct > 0 ? defaultInvestRatePct : 7)
    }

    private var amount: Double { Double(amountText) ?? 0 }
    private var rDebt: Double { debtRatePct / 100 }
    private var rInvest: Double { investRatePct / 100 }
    // Interest avoided by paying the debt down for `years`.
    private var savedInterest: Double { amount * (pow(1 + rDebt, years) - 1) }
    // Gain earned by investing the same amount for `years`.
    private var investGain: Double { amount * (pow(1 + rInvest, years) - 1) }
    // Positive → investing comes out ahead; negative → paying the debt does.
    private var diff: Double { investGain - savedInterest }
    private var investWins: Bool { diff > 0 }
    private var yearsInt: Int { Int(years) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                inputCard
                if amount > 0 {
                    verdictCard
                    HStack(spacing: 14) {
                        outcomeCard(title: "빚 갚기",
                                    subtitle: "아낀 이자",
                                    value: savedInterest,
                                    tag: "확정",
                                    tint: Theme.positive,
                                    highlighted: !investWins)
                        outcomeCard(title: "투자하기",
                                    subtitle: "기대 수익",
                                    value: investGain,
                                    tag: "변동 위험",
                                    tint: Theme.accent,
                                    highlighted: investWins)
                    }
                    noteCard
                } else {
                    Text("투입할 금액을 입력하면 두 선택의 결과를 비교해드려요.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("만약에")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("투입 금액")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    TextField("예: 10,000,000", text: $amountText.commaGrouped)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .rounded))
                    Text("원").foregroundStyle(Theme.textSecond)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .inputBox()
                if defaultAmount > 0 {
                    Text("현재 총부채 \(Fmt.krw(defaultAmount))원이 기본값으로 들어가 있어요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }

            rateSlider(title: "부채 연이자율", value: $debtRatePct, tint: Theme.negative)
            rateSlider(title: "투자 연수익률", value: $investRatePct, tint: Theme.accent)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("기간")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(yearsInt)년")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accentSoft)
                        .clipShape(Capsule())
                }
                Slider(value: $years, in: 1...30, step: 1)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func rateSlider(title: String, value: Binding<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("연 \(Fmt.percent(value.wrappedValue / 100, fraction: 1))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.15))
                    .clipShape(Capsule())
            }
            Slider(value: value, in: 0...15, step: 0.5)
                .tint(tint)
        }
    }

    // The headline call: which choice wins and by how much over the horizon.
    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(investWins ? "투자가 유리해요" : "빚 갚기가 유리해요")
                .font(.title3.weight(.bold))
                .foregroundStyle(investWins ? Theme.accent : Theme.positive)
            Text("\(yearsInt)년 후 약 \(Fmt.krw(abs(diff)))원 \(investWins ? "더 벌 수 있어요" : "더 아낄 수 있어요").")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Text(investWins
                 ? "투자 수익률(\(Fmt.percent(rInvest, fraction: 1)))이 부채 이자율(\(Fmt.percent(rDebt, fraction: 1)))보다 높기 때문이에요. 단, 투자는 손실 위험이 있어요."
                 : "부채 이자율(\(Fmt.percent(rDebt, fraction: 1)))이 투자 수익률(\(Fmt.percent(rInvest, fraction: 1)))보다 높아요. 빚 상환은 위험 없는 확정 이득이에요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func outcomeCard(title: String, subtitle: String, value: Double,
                             tag: String, tint: Color, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(tag)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            Text("+\(Fmt.krw(value))원")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(highlighted ? tint.opacity(0.12) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(highlighted ? tint.opacity(0.6) : Theme.hairline, lineWidth: 1)
        )
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("비교 기준", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecond)
            Text("빚 갚기 = 투입금에 부채 이자율을 \(yearsInt)년 복리로 적용해 ‘안 내도 되는 이자’를 계산해요. 투자하기 = 같은 돈을 투자 수익률로 \(yearsInt)년 복리 운용한 수익이에요. 세금·중도상환수수료·추가 납입은 빼고 단순 비교한 값입니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
