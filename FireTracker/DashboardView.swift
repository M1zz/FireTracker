import SwiftUI
import SwiftData
import Charts

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

struct DashboardView: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]

    @State private var showingAddAsset = false
    @State private var totalMode: AssetTotalMode = .gross

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

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    onboarding
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            cashFlowCard
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
                        .font(.system(size: 48))
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
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Hero: the cash-flow question — does the income my assets produce cover the
    // monthly spending I want? This, not a static asset total, is the real
    // measure of financial independence and current liquidity.
    private var cashFlowCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("내 월 수입")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("자산이 만들어내는 현금흐름")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if monthlyPassiveIncome > 0 {
                // 월·주 수입을 함께 — 현금이 들어오는 속도감을 보여줌.
                VStack(alignment: .leading, spacing: 4) {
                    Text("월 \(Fmt.krw(monthlyPassiveIncome))원")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.positive)
                    Text("주 \(Fmt.krw(weeklyPassiveIncome))원 · 연 \(Fmt.krw(monthlyPassiveIncome * 12))원")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
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
                tint: (delta ?? 0) >= 0 ? Theme.positive : Theme.negative
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
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text("= \(Fmt.wonKo(projectedYearEnd))")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)

            if plannedSavings != 0 || monthlyPassiveIncome > 0 {
                Text("현재 \(Fmt.krw(projectionBase))원 + (월 저축 \(Fmt.krw(plannedSavings))원"
                     + (monthlyPassiveIncome > 0 ? " + 월 수입 \(Fmt.krw(monthlyPassiveIncome))원" : "")
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
                    Text("쓸 수 있는 돈 (유동)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("\(Fmt.krw(liquidNetWorth))원")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
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

            Text("순자산 \(Fmt.krw(netWorth))원 중 실제 쓸 수 있는 돈입니다. 실거주 부동산·전세보증금·연금·부채는 묶인 돈으로 빠집니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
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
                .font(.system(size: 18, weight: .semibold))
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
                    .font(.system(size: 24, weight: .bold, design: .rounded))
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
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
                assumptionRow("월 수입 (배당·월세 등)", Fmt.krwBoth(monthlyPassiveIncome),
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
        .preferredColorScheme(.dark)
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
        .preferredColorScheme(.dark)
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
                .font(.system(size: 20, weight: .bold, design: .rounded))
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
