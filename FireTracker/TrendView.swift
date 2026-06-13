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
    @State private var thisMonthSel: Date?
    @State private var passiveSel: Date?
    @State private var allocSel: Date?

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
        case year = "연"
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self {
            case .week:  return .weekOfYear
            case .month: return .month
            case .year:  return .year
            }
        }
        var label: String {
            switch self {
            case .week:  return "주"
            case .month: return "달"
            case .year:  return "해"
            }
        }
    }

    // A point on the trend — either a saved snapshot or the live "now" state,
    // bucketed to the start of its week/month so changes read against 월초/주초.
    // 한 항목(종목/자산)의 금액·부채 여부·카테고리 — 기간 간 변동 계산용.
    struct AssetSlice { let amount: Double; let isDebt: Bool; let assetClass: AssetClass }

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
                    // 차트가 가장 먼저 — 탭에 들어오자마자 추이 그래프가 보인다.
                    // (주/월 기준은 차트 카드 헤더에, 모드 전환은 차트 아래에)
                    // 기록이 한 칸뿐이어도 빈 안내 대신 현재 값으로 바로 그린다.
                    if sorted.isEmpty {
                        emptyState
                    } else {
                        switch mode {
                        case .netWorth:
                            netWorthChart
                            changeDetailCard
                        case .passiveIncome: passiveIncomeChart
                        case .savingsRate:   savingsChart
                        case .allocation:    allocationChart
                        }
                    }

                    // 이번 달 — 월 버킷에 가려진 한 달 안의 움직임 + 현재 상태.
                    if mode == .netWorth, !thisMonthPoints.isEmpty {
                        thisMonthChart
                    }

                    // 데이터가 있는 모드가 둘 이상일 때만 전환 세그먼트를 만든다.
                    if availableModes.count > 1 {
                        Picker("", selection: $mode) {
                            ForEach(availableModes) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if mode != .netWorth, availablePeriods.count > 1 {
                        HStack {
                            Text("기준")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecond)
                            Picker("", selection: $period) {
                                ForEach(availablePeriods) { Text("\($0.rawValue)간").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            Spacer()
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("추이")
            .onAppear { clampSelections() }
            .onChange(of: snapshots.count) { _, _ in clampSelections() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.textSecond)
            Text("자산을 등록하면 지금까지의 추이가\n자동으로 표시됩니다.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .cardStyle()
    }

    private var hasCatalog: Bool { !assets.isEmpty }

    // 그 기간 단위로 묶었을 때 생기는 버킷 수 — 2개 미만이면 비교가 불가능하니
    // 그 기간 세그먼트는 만들지 않는다.
    private func bucketCount(_ p: TrendPeriod) -> Int {
        let cal = Calendar.current
        var dates = snapshots.map(\.date)
        if hasCatalog { dates.append(Date()) }
        return Set(dates.map { cal.dateInterval(of: p.component, for: $0)?.start ?? $0 }).count
    }
    private var availablePeriods: [TrendPeriod] {
        TrendPeriod.allCases.filter { bucketCount($0) >= 2 }
    }

    // 보여줄 데이터가 있는 모드만 — 데이터 없는 모드는 세그먼트조차 만들지 않는다.
    private var availableModes: [TrendMode] {
        let pts = sorted
        return TrendMode.allCases.filter { m in
            switch m {
            case .netWorth:      return true
            case .passiveIncome: return pts.contains { $0.monthlyPassiveIncome > 0 }
            case .savingsRate:   return pts.contains { $0.savingsRate != 0 }
            case .allocation:    return pts.contains { $0.byClass.values.contains { $0 > 0 } }
            }
        }
    }

    // 데이터가 줄어 현재 선택이 사라진 세그먼트를 가리키면 되돌린다.
    private func clampSelections() {
        if !availableModes.contains(mode) { mode = .netWorth }
        if !availablePeriods.contains(period) { period = availablePeriods.first ?? .month }
    }

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
            byAsset[key] = AssetSlice(amount: (byAsset[key]?.amount ?? 0) + a.netValue,
                                      isDebt: a.isDebt, assetClass: a.assetClass)
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
            m[key] = AssetSlice(amount: (m[key]?.amount ?? 0) + e.amount,
                                isDebt: e.assetClass == .debt, assetClass: e.assetClass)
        }
        return m
    }

    private func point(from s: NetWorthSnapshot) -> TrendPoint {
        TrendPoint(date: s.date, netWorth: s.netWorth, liquidNetWorth: s.liquidNetWorth,
                   monthlyPassiveIncome: s.monthlyPassiveIncome, savingsRate: s.savingsRate,
                   byClass: classMap(s), byAsset: assetMap(s))
    }

    // Snapshots + live "now", bucketed to each period start (월초/주초). When more
    // than one point falls in a bucket, the latest wins, so the current period
    // always reflects the live value.
    private var sorted: [TrendPoint] {
        var raw = snapshots.map { point(from: $0) }
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

    // 토스 스타일: 헤더는 순자산 큰 숫자 + '자산·부채·변화' 요약 한 줄만,
    // 그 아래 막대(자산/부채)+라인(순자산) 차트. 항목별 상세는 별도 카드로.
    private var netWorthChart: some View {
        let pts = indexedPoints
        let count = pts.count
        let shownIdx = (selectedIndex.flatMap { (0..<count).contains($0) ? $0 : nil }) ?? (count - 1)
        let s = pts[shownIdx].point
        let prev: TrendPoint? = shownIdx > 0 ? pts[shownIdx - 1].point : nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shownIdx == count - 1 ? "현재 순자산" : "\(periodLabelFull(s.date)) 순자산")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("\(s.netWorth < 0 ? "−" : "")\(Fmt.won(abs(s.netWorth)))원")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    HStack(spacing: 8) {
                        Text("자산 \(Fmt.krw(s.grossAssets))")
                        if s.debt > 0 {
                            Text("부채 −\(Fmt.krw(s.debt))")
                        }
                        if let prev {
                            let d = s.netWorth - prev.netWorth
                            if abs(d) >= 1 {
                                Text("\(d > 0 ? "▲" : "▼") \(Fmt.krw(abs(d)))")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(d > 0 ? Theme.rise : Theme.fall)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                }
                Spacer()
                // 비교할 데이터가 있는 기간만 — 한 기간뿐이면 세그먼트를 숨긴다.
                if availablePeriods.count > 1 {
                    Picker("", selection: $period) {
                        ForEach(availablePeriods) { Text("\($0.rawValue)간").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
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
            .frame(height: 220)

            HStack(spacing: 12) {
                legendSquare("자산", Theme.positive)
                legendSquare("부채", Theme.textSecond.opacity(0.35))
                legendDot("순자산", Theme.accent)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 이번 달 안의 기록들 + 오늘(현재 상태). 월 단위 추이는 버킷당 1점이라
    // 한 달 안의 움직임이 안 보이므로, 일 단위로 그대로 펼친다.
    private var thisMonthPoints: [TrendPoint] {
        let cal = Calendar.current
        guard let month = cal.dateInterval(of: .month, for: Date()) else { return [] }
        var raw = snapshots.filter { month.contains($0.date) }.map { point(from: $0) }
        if hasCatalog { raw.append(currentPoint) }
        // 같은 날 여러 기록이면 마지막 값만.
        var byDay: [Date: TrendPoint] = [:]
        for p in raw.sorted(by: { $0.date < $1.date }) {
            byDay[cal.startOfDay(for: p.date)] = p
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    // "오늘"·"6월 8일" 같은 이번 달 날짜 라벨.
    private func thisMonthDayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "오늘" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: date)
    }

    // 이번 달 카드: 막대(자산/부채)+라인(순자산)을 일 단위로. 탭하면 그 날 값이 위에.
    private var thisMonthChart: some View {
        let pts = thisMonthPoints
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: Date())
        // 탭한 날짜에 가장 가까운 기록(없으면 최근)을 정보 카드로.
        let shown: TrendPoint? = thisMonthSel.flatMap { sel in
            pts.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }
        } ?? pts.last
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("이번 달")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if pts.count >= 2 {
                    Text("기록 \(pts.count - 1)개 + 오늘")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            if let s = shown {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(thisMonthDayLabel(s.date)) 기준")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    HStack(spacing: 10) {
                        Text("순자산 \(s.netWorth < 0 ? "−" : "")\(Fmt.krw(abs(s.netWorth)))")
                            .foregroundStyle(Theme.accent)
                        Text("자산 \(Fmt.krw(s.grossAssets))")
                            .foregroundStyle(Theme.positive)
                        if s.debt > 0 {
                            Text("부채 −\(Fmt.krw(s.debt))")
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Chart {
                ForEach(pts) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day),
                            yStart: .value("기준", 0.0),
                            yEnd: .value("자산", p.grossAssets),
                            width: .ratio(0.6))
                        .foregroundStyle(Theme.positive)
                        .cornerRadius(2)
                    BarMark(x: .value("날짜", p.date, unit: .day),
                            yStart: .value("기준", 0.0),
                            yEnd: .value("부채", -p.debt),
                            width: .ratio(0.6))
                        .foregroundStyle(Theme.textSecond.opacity(0.3))
                        .cornerRadius(2)
                }
                RuleMark(y: .value("0", 0.0))
                    .foregroundStyle(Theme.hairline)
                ForEach(pts) { p in
                    LineMark(x: .value("날짜", p.date, unit: .day),
                             y: .value("순자산", p.netWorth))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("날짜", p.date, unit: .day),
                              y: .value("순자산", p.netWorth))
                        .symbol {
                            Circle()
                                .fill(Theme.surface)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                        }
                }
            }
            .chartXScale(domain: (month?.start ?? Date()) ... (month?.end ?? Date()))
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartXSelection(value: $thisMonthSel)
            .frame(height: 150)
            if pts.count < 2 {
                Text("기록을 저장할수록 이번 달 안의 변화가 촘촘하게 그려져요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 선택한(기본: 최근) 칸의 항목별 증감 — 메인 차트와 분리된 카드.
    @ViewBuilder
    private var changeDetailCard: some View {
        let pts = sorted
        if !pts.isEmpty {
            let idx = (selectedIndex.flatMap { (0..<pts.count).contains($0) ? $0 : nil }) ?? (pts.count - 1)
            let ds = deltas(from: idx > 0 ? pts[idx - 1] : nil, to: pts[idx])
            if !ds.isEmpty {
                trendBreakdown(ds, date: pts[idx].date)
            }
        }
    }

    // 이전 기간 대비 항목별 변동 + 그 기간의 현재 금액(상태).
    struct TrendDelta: Identifiable {
        let name: String
        let net: Double       // 표시값 기준 변화 (부채는 빚 늘면 −)
        let current: Double   // 선택한 기간의 잔액 — 변화량만으론 규모를 모르니 함께.
        let assetClass: AssetClass
        var id: String { assetClass.rawValue + ":" + name }
    }

    private func deltas(from prev: TrendPoint?, to cur: TrendPoint) -> [TrendDelta] {
        guard let prev else { return [] }
        let keys = Set(prev.byAsset.keys).union(cur.byAsset.keys)
        var out: [TrendDelta] = []
        for k in keys {
            let now = cur.byAsset[k]?.amount ?? 0
            let d = now - (prev.byAsset[k]?.amount ?? 0)
            guard abs(d) >= 1 else { continue }
            let cls = cur.byAsset[k]?.assetClass ?? prev.byAsset[k]?.assetClass ?? .other
            out.append(TrendDelta(name: k, net: d, current: now, assetClass: cls))
        }
        return out.sorted { abs($0.net) > abs($1.net) }
    }

    // 주식 시세처럼 ▲빨강/▼파랑 — 표시값이 오르면 ▲, 내리면 ▼.
    private func arrowText(_ change: Double) -> Text {
        Text("\(change > 0 ? "▲" : "▼") \(Fmt.krw(abs(change)))")
            .foregroundStyle(change > 0 ? Theme.rise : Theme.fall)
    }

    // 선택한 기간에 바뀐 것 — 카테고리별로 묶고, 항목은 ▲/▼ + 잔액으로 간결하게.
    private func trendBreakdown(_ items: [TrendDelta], date: Date) -> some View {
        let groups = Dictionary(grouping: items, by: \.assetClass)
            .map { (cls: $0.key, items: $0.value, total: $0.value.reduce(0) { $0 + $1.net }) }
            .sorted { abs($0.total) > abs($1.total) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("바뀐 것")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(periodLabelFull(date))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            ForEach(groups, id: \.cls) { g in
                VStack(alignment: .leading, spacing: 6) {
                    // 카테고리 헤더: 아이콘 + 이름 + 카테고리 합계 변화.
                    HStack(spacing: 6) {
                        Image(systemName: g.cls.symbolName)
                            .font(.caption)
                            .foregroundStyle(Color(hex: g.cls.colorHex))
                            .frame(width: 16)
                        Text(g.cls.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        arrowText(g.total)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                    }
                    ForEach(g.items.prefix(5)) { it in
                        HStack(spacing: 8) {
                            Text(it.name)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecond)
                                .lineLimit(1)
                                .padding(.leading, 22)
                            Spacer()
                            arrowText(it.net)
                                .font(.system(.caption2, design: .rounded).weight(.semibold))
                            Text("\(it.current < 0 ? "−" : "")\(Fmt.krw(abs(it.current)))원")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(minWidth: 76, alignment: .trailing)
                        }
                    }
                    if g.items.count > 5 {
                        Text("외 \(g.items.count - 5)개")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
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
        switch period {
        case .week:  f.dateFormat = "M/d"
        case .month: f.dateFormat = "M월"
        case .year:  f.dateFormat = "yyyy년"
        }
        return f.string(from: date)
    }
    private func periodLabelFull(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch period {
        case .week:  f.dateFormat = "yyyy년 M월 d일"
        case .month: f.dateFormat = "yyyy년 M월"
        case .year:  f.dateFormat = "yyyy년"
        }
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
        let pts = sorted
        let shown = passiveSel.flatMap { sel in
            pts.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }
        } ?? pts.last
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text("패시브 인컴 성장")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let s = shown {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(periodLabelFull(s.date))")
                            .font(.caption2).foregroundStyle(Theme.textSecond)
                        Text("월 \(Fmt.krw(s.monthlyPassiveIncome))원")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.positive)
                            .contentTransition(.numericText())
                        if monthlyTargetExpense > 0 {
                            Text("목표의 \(Fmt.percent(s.monthlyPassiveIncome / monthlyTargetExpense, fraction: 0))")
                                .font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
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
            .chartYAxis { krwYAxis() }
            .chartXSelection(value: $passiveSel)
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

    // 공용 Y축 — 좌측에 만·억 금액 라벨.
    private func krwYAxis() -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text("\(Fmt.krw(v))원").font(.caption2).foregroundStyle(Theme.textSecond)
                }
            }
        }
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
        let pts = sorted
        // 데이터가 있는 카테고리만 — 없는 카테고리는 범례(세그먼트)조차 만들지 않는다.
        let present = AssetClass.allCases.filter { ac in pts.contains { $0.total(for: ac) > 0 } }
        let shown = allocSel.flatMap { sel in
            pts.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) }
        } ?? pts.last
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text("카테고리별 자산 · 순자산")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let s = shown {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(periodLabelFull(s.date))
                            .font(.caption2).foregroundStyle(Theme.textSecond)
                        Text("순자산 \(Fmt.krw(s.netWorth))원")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                    }
                }
            }
            // 선택한 기간의 카테고리 구성 — 큰 것부터 칩으로.
            if let s = shown {
                let comp = present.compactMap { ac -> (AssetClass, Double)? in
                    let t = s.total(for: ac); return t > 0 ? (ac, t) : nil
                }.sorted { $0.1 > $1.1 }
                if !comp.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(comp, id: \.0) { item in
                                HStack(spacing: 4) {
                                    Circle().fill(Color(hex: item.0.colorHex)).frame(width: 7, height: 7)
                                    Text(item.0.label).font(.caption2).foregroundStyle(Theme.textSecond)
                                    Text("\(Fmt.krw(item.1))원").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Theme.surfaceHigh)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            Chart {
                ForEach(pts) { s in
                    ForEach(present) { ac in
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
                // 순자산(자산 − 부채) 라인 — 카테고리 합(막대 전체)과 비교.
                ForEach(pts) { s in
                    LineMark(
                        x: .value("기간", s.date, unit: period.component),
                        y: .value("순자산", s.netWorth)
                    )
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(
                        x: .value("기간", s.date, unit: period.component),
                        y: .value("순자산", s.netWorth)
                    )
                    .symbol {
                        Circle()
                            .fill(Theme.surface)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: present.map { $0.label },
                range: present.map { Color(hex: $0.colorHex) }
            )
            .chartYAxis { krwYAxis() }
            .chartXSelection(value: $allocSel)
            .frame(height: 240)

            HStack(spacing: 12) {
                legendDot("순자산", Theme.accent)
                Text("막대는 카테고리별 자산, 라인은 부채를 뺀 순자산이에요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
