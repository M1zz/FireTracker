import SwiftUI
import SwiftData
import Charts

struct TrendView: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]
    @State private var mode: TrendMode = .netWorth
    @State private var period: TrendPeriod = .month

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    enum TrendMode: String, CaseIterable, Identifiable {
        case netWorth = "순자산"
        case passiveIncome = "패시브 인컴"
        case savingsRate = "저축률"
        case allocation = "자산 구성"
        var id: String { rawValue }
    }

    enum TrendPeriod: String, CaseIterable, Identifiable {
        case week = "주"
        case month = "월"
        var id: String { rawValue }
        var component: Calendar.Component { self == .week ? .weekOfYear : .month }
        var label: String { self == .week ? "주" : "달" }
    }

    // A point on the trend — either a saved snapshot or the live "now" state,
    // bucketed to the start of its week/month so changes read against 월초/주초.
    struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let netWorth: Double
        let liquidNetWorth: Double
        let monthlyPassiveIncome: Double
        let savingsRate: Double
        let byClass: [AssetClass: Double]
        func total(for ac: AssetClass) -> Double { byClass[ac] ?? 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("", selection: $mode) {
                        ForEach(TrendMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("기준")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                        Picker("", selection: $period) {
                            ForEach(TrendPeriod.allCases) { Text("\($0.label) 단위").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer()
                    }

                    if sorted.count < 2 {
                        emptyState
                    } else {
                        switch mode {
                        case .netWorth:      netWorthChart
                        case .passiveIncome: passiveIncomeChart
                        case .savingsRate:   savingsChart
                        case .allocation:    allocationChart
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("추이")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.textSecond)
            Text(hasCatalog
                 ? "이번 \(period.label)의 현재 값만 있어요.\n다음 \(period.label)이 되면 변화가 자동으로 그려집니다."
                 : "자산을 등록하면 지금까지의 추이가\n자동으로 표시됩니다.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .cardStyle()
    }

    private var hasCatalog: Bool { !assets.isEmpty }

    // The live state right now, derived from the catalog — appended so the trend
    // is always current without needing a fresh manual record.
    private var currentPoint: TrendPoint {
        let net = assets.reduce(0) { $0 + $1.netValue }
        let liquid = assets.reduce(0) { $0 + $1.liquidValue }
        let passive = assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } + settings.manualMonthlyDividend
        var byClass: [AssetClass: Double] = [:]
        for ac in AssetClass.allCases {
            let t = assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
            if t != 0 { byClass[ac] = t }
        }
        let sr = settings.monthlyTakeHome > 0
            ? (settings.monthlyTakeHome - settings.plannedMonthlyExpense) / settings.monthlyTakeHome
            : 0
        return TrendPoint(date: Date(), netWorth: net, liquidNetWorth: liquid,
                          monthlyPassiveIncome: passive, savingsRate: sr, byClass: byClass)
    }

    private func classMap(_ s: NetWorthSnapshot) -> [AssetClass: Double] {
        var m: [AssetClass: Double] = [:]
        for ac in AssetClass.allCases {
            let t = s.total(for: ac)
            if t != 0 { m[ac] = t }
        }
        return m
    }

    // Snapshots + live "now", bucketed to each period start (월초/주초). When more
    // than one point falls in a bucket, the latest wins, so the current period
    // always reflects the live value.
    private var sorted: [TrendPoint] {
        var raw = snapshots.map { s in
            TrendPoint(date: s.date, netWorth: s.netWorth, liquidNetWorth: s.liquidNetWorth,
                       monthlyPassiveIncome: s.monthlyPassiveIncome, savingsRate: s.savingsRate,
                       byClass: classMap(s))
        }
        if hasCatalog { raw.append(currentPoint) }

        let cal = Calendar.current
        var byKey: [Date: TrendPoint] = [:]
        for p in raw.sorted(by: { $0.date < $1.date }) {
            let start = cal.dateInterval(of: period.component, for: p.date)?.start ?? p.date
            byKey[start] = TrendPoint(date: start, netWorth: p.netWorth,
                                      liquidNetWorth: p.liquidNetWorth,
                                      monthlyPassiveIncome: p.monthlyPassiveIncome,
                                      savingsRate: p.savingsRate, byClass: p.byClass)
        }
        return byKey.values.sorted { $0.date < $1.date }
    }

    private var netWorthChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("순자산 · 유동 자산 변화")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                legendDot("순자산", Theme.accent)
                legendDot("유동", Theme.positive)
            }
            Chart {
                ForEach(sorted) { s in
                    AreaMark(
                        x: .value("월", s.date),
                        y: .value("순자산", s.netWorth)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("월", s.date),
                        y: .value("순자산", s.netWorth),
                        series: .value("구분", "순자산")
                    )
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                    // Spendable (liquid) net worth — what you can actually use.
                    LineMark(
                        x: .value("월", s.date),
                        y: .value("유동 자산", s.liquidNetWorth),
                        series: .value("구분", "유동")
                    )
                    .foregroundStyle(Theme.positive)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("월", s.date),
                        y: .value("유동 자산", s.liquidNetWorth)
                    )
                    .foregroundStyle(Theme.positive)
                    .symbolSize(40)
                }
                RuleMark(y: .value("목표", settings.fireNumber))
                    .foregroundStyle(Theme.accent.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("FIRE 목표")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
            }
            .chartYAxis(.hidden)
            .frame(height: 240)

            if let last = sorted.last, last.netWorth > 0 {
                let ratio = last.liquidNetWorth / last.netWorth
                Text("현재 순자산의 \(Fmt.percent(ratio, fraction: 0))가 실제 쓸 수 있는 유동 자산입니다.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecond)
        }
    }

    // Monthly passive cash flow over time, against the target monthly spend —
    // the line you must cross to be financially independent.
    private var monthlyTargetExpense: Double { settings.targetAnnualExpense / 12 }

    private var passiveIncomeChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("패시브 인컴 성장")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart {
                ForEach(sorted) { s in
                    AreaMark(
                        x: .value("월", s.date),
                        y: .value("패시브 인컴", s.monthlyPassiveIncome)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.positive.opacity(0.3), Theme.positive.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("월", s.date),
                        y: .value("패시브 인컴", s.monthlyPassiveIncome)
                    )
                    .foregroundStyle(Theme.positive)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("월", s.date),
                        y: .value("패시브 인컴", s.monthlyPassiveIncome)
                    )
                    .foregroundStyle(Theme.positive)
                }
                if monthlyTargetExpense > 0 {
                    RuleMark(y: .value("목표 지출", monthlyTargetExpense))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("목표 월 지출")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                        }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 240)

            if let last = sorted.last, monthlyTargetExpense > 0 {
                let coverage = last.monthlyPassiveIncome / monthlyTargetExpense
                Text("현재 패시브 인컴이 목표 월 지출의 \(Fmt.percent(coverage, fraction: 0))를 커버합니다.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var savingsChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("월별 저축률")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart(sorted) { s in
                BarMark(
                    x: .value("기간", s.date, unit: period.component),
                    y: .value("저축률", s.savingsRate)
                )
                .foregroundStyle(
                    s.savingsRate >= 0 ? Theme.positive : Theme.negative
                )
                .cornerRadius(4)
            }
            .chartYAxis(.hidden)
            .frame(height: 240)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var allocationChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("자산 구성 변화")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart {
                ForEach(sorted) { s in
                    ForEach(AssetClass.allCases) { ac in
                        let amount = s.total(for: ac)
                        if amount > 0 {
                            BarMark(
                                x: .value("기간", s.date, unit: period.component),
                                y: .value("금액", amount)
                            )
                            .foregroundStyle(Color(hex: ac.colorHex))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: AssetClass.allCases.map { $0.label },
                range: AssetClass.allCases.map { Color(hex: $0.colorHex) }
            )
            .chartYAxis(.hidden)
            .frame(height: 240)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
