import SwiftUI
import SwiftData
import Charts

struct TrendView: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]
    @State private var mode: TrendMode = .netWorth
    @State private var period: TrendPeriod = .month
    @State private var selectedIndex: Int?

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    enum TrendMode: String, CaseIterable, Identifiable {
        case netWorth = "총자산"
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
    // 한 항목(종목/자산)의 금액과 부채 여부 — 기간 간 변동 계산용.
    struct AssetSlice { let amount: Double; let isDebt: Bool }

    struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let netWorth: Double
        let liquidNetWorth: Double
        let monthlyPassiveIncome: Double
        let savingsRate: Double
        let byClass: [AssetClass: Double]
        let byAsset: [String: AssetSlice]
        func total(for ac: AssetClass) -> Double { byClass[ac] ?? 0 }
        // 부채 규모(양수)와 보유 자산 합계(사용자 용어로 '순자산').
        // 총자산(net) = 순자산 − 부채 = netWorth.
        var debt: Double { abs(byClass[.debt] ?? 0) }
        var grossAssets: Double { netWorth + debt }
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
        var byAsset: [String: AssetSlice] = [:]
        for a in assets {
            let key = a.name.isEmpty ? a.displayClassLabel : a.name
            byAsset[key] = AssetSlice(amount: (byAsset[key]?.amount ?? 0) + a.netValue, isDebt: a.isDebt)
        }
        let sr = settings.monthlyTakeHome > 0
            ? (settings.monthlyTakeHome - settings.plannedMonthlyExpense) / settings.monthlyTakeHome
            : 0
        return TrendPoint(date: Date(), netWorth: net, liquidNetWorth: liquid,
                          monthlyPassiveIncome: passive, savingsRate: sr,
                          byClass: byClass, byAsset: byAsset)
    }

    private func classMap(_ s: NetWorthSnapshot) -> [AssetClass: Double] {
        var m: [AssetClass: Double] = [:]
        for ac in AssetClass.allCases {
            let t = s.total(for: ac)
            if t != 0 { m[ac] = t }
        }
        return m
    }

    private func assetMap(_ s: NetWorthSnapshot) -> [String: AssetSlice] {
        var m: [String: AssetSlice] = [:]
        for e in s.entries {
            let key = e.name.isEmpty ? e.assetClass.label : e.name
            m[key] = AssetSlice(amount: (m[key]?.amount ?? 0) + e.amount, isDebt: e.assetClass == .debt)
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
                       byClass: classMap(s), byAsset: assetMap(s))
        }
        if hasCatalog { raw.append(currentPoint) }

        let cal = Calendar.current
        var byKey: [Date: TrendPoint] = [:]
        for p in raw.sorted(by: { $0.date < $1.date }) {
            let start = cal.dateInterval(of: period.component, for: p.date)?.start ?? p.date
            byKey[start] = TrendPoint(date: start, netWorth: p.netWorth,
                                      liquidNetWorth: p.liquidNetWorth,
                                      monthlyPassiveIncome: p.monthlyPassiveIncome,
                                      savingsRate: p.savingsRate, byClass: p.byClass, byAsset: p.byAsset)
        }
        return byKey.values.sorted { $0.date < $1.date }
    }

    // 인덱스를 부여한 추이 포인트 — 막대와 순자산 라인을 같은 정수 x축에 정렬한다.
    private var indexedPoints: [(idx: Int, point: TrendPoint)] {
        sorted.enumerated().map { (idx: $0.offset, point: $0.element) }
    }

    // 토스 스타일 월별 컬럼: 순자산(보유 자산·초록·위) + 부채(회색·아래),
    // 총자산(= 순자산 − 부채)은 원형 라인.
    private var netWorthChart: some View {
        let pts = indexedPoints
        let count = pts.count
        let shownIdx = (selectedIndex.flatMap { (0..<count).contains($0) ? $0 : nil }) ?? (count - 1)
        let shown: TrendPoint? = (0..<count).contains(shownIdx) ? pts[shownIdx].point : nil
        let prevPoint: TrendPoint? = shownIdx > 0 ? pts[shownIdx - 1].point : nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("순자산 · 부채 · 총자산")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                legendSquare("순자산", Theme.positive)
                legendSquare("부채", Theme.textSecond.opacity(0.35))
                legendDot("총자산", Theme.accent)
            }

            if let s = shown {
                tooltipCard(s)
                let ds = deltas(from: prevPoint, to: s)
                if !ds.isEmpty { trendBreakdown(ds) }
            }

            Chart {
                ForEach(pts, id: \.idx) { item in
                    BarMark(
                        x: .value("기간", item.idx),
                        yStart: .value("기준", 0.0),
                        yEnd: .value("순자산", item.point.grossAssets),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(Theme.positive)
                    .cornerRadius(3)
                    BarMark(
                        x: .value("기간", item.idx),
                        yStart: .value("기준", 0.0),
                        yEnd: .value("부채", -item.point.debt),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(Theme.textSecond.opacity(0.3))
                    .cornerRadius(3)
                }
                RuleMark(y: .value("0", 0.0))
                    .foregroundStyle(Theme.hairline)
                ForEach(pts, id: \.idx) { item in
                    LineMark(
                        x: .value("기간", item.idx),
                        y: .value("총자산", item.point.netWorth)
                    )
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("기간", item.idx),
                        y: .value("총자산", item.point.netWorth)
                    )
                    .symbol {
                        Circle()
                            .fill(Theme.surface)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Theme.accent, lineWidth: 2.5))
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: labelIndices(count)) { value in
                    if let i = value.as(Int.self), (0..<count).contains(i) {
                        AxisValueLabel {
                            Text(periodLabel(pts[i].point.date))
                                .font(.caption2)
                                .foregroundStyle(i == count - 1 ? Theme.accent : Theme.textSecond)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedIndex)
            .frame(height: 240)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 막대를 탭하면 그 칸의 순자산·부채·총자산을 띄운다(선택 없으면 최근 칸).
    private func tooltipCard(_ s: TrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(periodLabelFull(s.date))
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
            tooltipRow("순자산", s.grossAssets, Theme.positive)
            tooltipRow("부채", -s.debt, Theme.textSecond)
            tooltipRow("총자산", s.netWorth, Theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tooltipRow(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Theme.textSecond)
            Spacer()
            Text("\(value < 0 ? "−" : "")\(Fmt.won(abs(value)))원")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
        }
    }

    // 이전 기간 대비 항목별 변동.
    struct TrendDelta: Identifiable {
        let name: String
        let net: Double
        let isDebt: Bool
        var id: String { (isDebt ? "d:" : "a:") + name }
        var display: Double { isDebt ? -net : net }   // 부채 증가를 +로
    }

    private func deltas(from prev: TrendPoint?, to cur: TrendPoint) -> [TrendDelta] {
        guard let prev else { return [] }
        let keys = Set(prev.byAsset.keys).union(cur.byAsset.keys)
        var out: [TrendDelta] = []
        for k in keys {
            let d = (cur.byAsset[k]?.amount ?? 0) - (prev.byAsset[k]?.amount ?? 0)
            guard abs(d) >= 1 else { continue }
            let isDebt = cur.byAsset[k]?.isDebt ?? prev.byAsset[k]?.isDebt ?? false
            out.append(TrendDelta(name: k, net: d, isDebt: isDebt))
        }
        return out.sorted { abs($0.net) > abs($1.net) }
    }

    // 선택한 기간에 '무엇이 얼마나' 바뀌었는지 — 자산=초록, 부채=빨강.
    private func trendBreakdown(_ items: [TrendDelta]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("이 기간에 바뀐 것")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            ForEach(items.prefix(8)) { it in
                let good = it.isDebt ? it.display < 0 : it.display > 0
                HStack(spacing: 8) {
                    Circle().fill(it.isDebt ? Theme.negative : Theme.positive).frame(width: 6, height: 6)
                    Text(it.name).font(.caption).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(it.isDebt ? "부채" : "자산").font(.caption2).foregroundStyle(Theme.textSecond)
                    Spacer()
                    Text("\(it.display > 0 ? "+" : "−")\(Fmt.krw(abs(it.display)))원")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(good ? Theme.positive : Theme.negative)
                }
            }
            if items.count > 8 {
                Text("외 \(items.count - 8)개").font(.caption2).foregroundStyle(Theme.textSecond)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // 라벨을 찍을 인덱스 — 처음·끝을 포함해 4칸 안팎으로 솎는다.
    private func labelIndices(_ count: Int) -> [Int] {
        guard count > 1 else { return [0] }
        let step = max(1, Int((Double(count) / 4).rounded()))
        var idx = Array(stride(from: 0, to: count, by: step))
        if idx.last != count - 1 { idx.append(count - 1) }
        return idx
    }

    private func periodLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = period == .week ? "M/d" : "M월"
        return f.string(from: date)
    }
    private func periodLabelFull(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = period == .week ? "yyyy년 M월 d일" : "yyyy년 M월"
        return f.string(from: date)
    }

    private func legendSquare(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecond)
        }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().stroke(color, lineWidth: 2).frame(width: 9, height: 9)
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
