import SwiftUI
import SwiftData
import Charts

// 계산 탭 — '잣대' 모드.
//
// 자산이 원화로 두 배가 됐어도 같은 기간 물가·금·달러가 더 올랐다면 실제로는 뒤처진 것이다.
// 자산이 오른 배수를 잣대가 오른 배수로 나눠, 잣대마다 능가 · 따라감 · 못 따라감을 판정한다.
//   잣대 대비 = (지금 값 + 받은 돈) ÷ 그때 값 ÷ (잣대 지금 ÷ 잣대 그때)
// 물가는 앱에 든 한국 CPI 표, 나머지는 Yahoo 월봉을 원화로 바꿔 쓴다
// (지난 해는 그해 월 종가의 중앙값, 지금은 최근 가격).
// 평균이 아니라 중앙값인 까닭: Yahoo 원/달러 월봉에 0.11 같은 깨진 달이 섞여 있어
// 평균을 쓰면 그해 환율이 수백 원씩 낮게 나온다.

// MARK: - 잣대

enum ValueRuler: String, CaseIterable, Identifiable {
    case cpi, gold, usd, sp500, kospi
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpi:   return String(localized: "물가")
        case .gold:  return String(localized: "금")
        case .usd:   return String(localized: "달러")
        case .sp500: return String(localized: "S&P500")
        case .kospi: return String(localized: "코스피")
        }
    }

    /// 이 잣대를 이겼다는 게 무슨 뜻인지 한 줄.
    var question: String {
        switch self {
        case .cpi:   return String(localized: "물가보다 더 올랐다면 실제로 더 부자가 된 거예요.")
        case .gold:  return String(localized: "금보다 더 올랐다면 돈 가치가 떨어진 만큼을 이긴 거예요.")
        case .usd:   return String(localized: "달러보다 더 올랐다면 세계 기준으로도 불어난 거예요.")
        case .sp500: return String(localized: "미국 시장 전체를 샀을 때보다 나았는지 봐요.")
        case .kospi: return String(localized: "한국 시장 전체를 샀을 때보다 나았는지 봐요.")
        }
    }

    /// 원화 값을 만드는 데 곱하는 Yahoo 심볼들. 물가는 앱 안의 표를 쓴다.
    var symbols: [String] {
        switch self {
        case .cpi:   return []
        case .gold:  return ["GC=F", "KRW=X"]   // 달러/온스 × 원/달러
        case .usd:   return ["KRW=X"]
        case .sp500: return ["^GSPC", "KRW=X"]  // 원화로 산 사람 기준
        case .kospi: return ["^KS11"]
        }
    }
}

enum RulerVerdict {
    case beat, track, lag

    init(_ rel: Double, band: Double) {
        self = rel > 1 + band ? .beat : rel < 1 - band ? .lag : .track
    }

    var label: String {
        switch self {
        case .beat:  return String(localized: "능가")
        case .track: return String(localized: "따라감")
        case .lag:   return String(localized: "못 따라감")
        }
    }

    var tint: Color {
        switch self {
        case .beat:  return Theme.rise
        case .track: return Theme.textSecond
        case .lag:   return Theme.fall
        }
    }
}

// MARK: - 잣대 시세

@MainActor
final class RulerPrices: ObservableObject {
    static let shared = RulerPrices()

    struct Series: Codable {
        var yearly: [Int: Double]   // 그해 월 종가의 중앙값
        var latest: Double
    }

    @Published private(set) var series: [String: Series] = [:]
    @Published private(set) var loading = false

    private static let symbols = ["GC=F", "KRW=X", "^GSPC", "^KS11"]
    // 'sim.' 으로 시작하지 않아 계산 저장에 섞이지 않는다.
    private static let cacheKey = "cache.ruler.prices.v2"   // v2: 연 중앙값
    private static let fetchedKey = "cache.ruler.fetchedAt.v2"

    var isComplete: Bool { Self.symbols.allSatisfy { series[$0] != nil } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([String: Series].self, from: data) {
            series = saved
        }
    }

    /// 반나절이 지났거나 빠진 시세가 있을 때만 다시 받는다.
    func refreshIfStale() async {
        let last = UserDefaults.standard.double(forKey: Self.fetchedKey)
        guard !isComplete || Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var got = series
        await withTaskGroup(of: (String, Series?).self) { group in
            for s in Self.symbols { group.addTask { (s, await Self.fetch(s)) } }
            for await (s, value) in group { if let value { got[s] = value } }
        }
        series = got
        if let data = try? JSONEncoder().encode(got) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.fetchedKey)
        }
    }

    /// 잣대의 원화 값. year 가 nil 이면 지금. 자료가 없으면 nil.
    func value(_ ruler: ValueRuler, year: Int?) -> Double? {
        if ruler == .cpi {
            return CPIData.country("KR").cpi(year ?? Calendar.current.component(.year, from: .now))
        }
        var v = 1.0
        for s in ruler.symbols {
            guard let ser = series[s], let x = year.map({ ser.yearly[$0] }) ?? ser.latest else { return nil }
            v *= x
        }
        return ruler == .gold ? v / 31.1034768 : v   // 트로이온스 → g
    }

    nonisolated private static func fetch(_ symbol: String) async -> Series? {
        let path = symbol.replacingOccurrences(of: "^", with: "%5E")
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(path)?interval=1mo&range=max") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((obj["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let stamps = result["timestamp"] as? [Double],
              let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first,
              let closes = quote["close"] as? [Any]
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        var byYear: [Int: [Double]] = [:]
        var lastClose: Double?
        for (t, c) in zip(stamps, closes) {
            guard let v = c as? Double, v > 0 else { continue }
            byYear[cal.component(.year, from: Date(timeIntervalSince1970: t)), default: []].append(v)
            lastClose = v
        }
        let meta = result["meta"] as? [String: Any]
        guard let latest = (meta?["regularMarketPrice"] as? Double) ?? lastClose, !byYear.isEmpty else { return nil }
        return Series(yearly: byYear.mapValues { $0.sorted()[$0.count / 2] }, latest: latest)
    }
}

// MARK: - 화면

struct RulerSimSection: View {
    @Query(sort: \Asset.sortOrder) private var myAssets: [Asset]
    @ObservedObject private var prices = RulerPrices.shared

    @AppStorage("sim.ruler.items")    private var itemsJSON = ""
    @AppStorage("sim.ruler.selected") private var selectedID = ""
    @AppStorage("sim.ruler.band")     private var bandText = "10"

    @State private var items: [Item] = []
    @State private var loaded = false
    @State private var showInfo = false
    @State private var showList = false
    @State private var leverID = ""
    @State private var sliderMax: Double = 100_000_000

    private static var thisYear: Int { Calendar.current.component(.year, from: .now) }
    private static let firstYear = 1995

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var year: Int
        var then: Double
        var now: Double
        var income: Double = 0

        /// 받은 돈까지 넣은 원화 배수.
        var multiple: Double? { then > 0 ? (now + income) / then : nil }
    }

    struct Row: Identifiable {
        let ruler: ValueRuler
        let rulerMultiple: Double?
        let rel: Double?          // 잣대 대비 배수
        var id: String { ruler.id }
    }

    private var band: Double { max(0, Double(bandText) ?? 10) / 100 }

    private var current: Item? {
        items.first { $0.id.uuidString == selectedID } ?? items.first
    }

    private func rows(_ item: Item) -> [Row] {
        ValueRuler.allCases.map { r in
            guard let a = prices.value(r, year: item.year), a > 0,
                  let b = prices.value(r, year: nil), let m = item.multiple else {
                return Row(ruler: r, rulerMultiple: nil, rel: nil)
            }
            return Row(ruler: r, rulerMultiple: b / a, rel: m / (b / a))
        }
    }

    private func years(_ item: Item) -> Int { max(1, Self.thisYear - item.year) }

    private func headline(_ item: Item) -> String {
        let known = rows(item).compactMap(\.rel)
        let wins = known.filter { RulerVerdict($0, band: band) == .beat }.count
        return String(localized: "\(item.name) · 잣대 \(known.count)개 중 \(wins)개 능가")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = current, let m = item.multiple {
                let list = rows(item)
                let wins = list.filter { $0.rel.map { RulerVerdict($0, band: band) == .beat } ?? false }.count
                SimResultHeader(title: headline(item), icon: "scalemass",
                                tint: wins > 0 ? Theme.rise : Theme.textPrimary) { showInfo = true }
                HStack(alignment: .top, spacing: 12) {
                    stat(String(localized: "원화로"), signed(m - 1))
                    stat(String(localized: "연평균"), signed(pow(m, 1 / Double(years(item))) - 1))
                    stat(String(localized: "기간"), String(localized: "\(String(item.year))년부터"))
                }
                rulerChart(list)
                    .frame(minHeight: 150, maxHeight: .infinity)
                statusLine(list)
            } else {
                SimResultHeader(title: String(localized: "여러 잣대로 자산 재기"), icon: "scalemass",
                                tint: Theme.textPrimary) { showInfo = true }
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            SimLeverPanel(levers: levers, selection: $leverID) {
                SimPanelButton(title: String(localized: "자산 목록"), icon: "list.bullet") { showList = true }
            } footer: {
                EmptyView()
            }
        }
        .simResultCard()
        .sheet(isPresented: $showInfo) {
            SimSheet(title: String(localized: "해석·저장")) { infoContent }
        }
        .sheet(isPresented: $showList) {
            SimSheet(title: String(localized: "자산 목록")) { listCard }
        }
        .task { await prices.refreshIfStale() }
        .onAppear { load(); rescale() }
        .onChange(of: items) { _, _ in save() }
        .onChange(of: items.count) { _, _ in rescale() }
        .onChange(of: selectedID) { _, _ in rescale() }
        .onChange(of: leverID) { _, _ in rescale() }
    }

    // MARK: 결과

    // 잣대마다 '잣대보다 몇 % 더 올랐나' 막대. 가운데 옅은 띠가 '따라감' 폭이다.
    private func rulerChart(_ list: [Row]) -> some View {
        let known = list.filter { $0.rel != nil }
        let values = known.map { ($0.rel! - 1) * 100 } + [band * 100, -band * 100]
        // 막대 끝에 '잣대 이름 +12%' 가 붙을 자리를 남긴다.
        let pad = max(45, (values.map(abs).max() ?? 0) * 1.3)
        let lo = min(0, values.min() ?? 0) - pad
        let hi = max(0, values.max() ?? 0) + pad
        return Chart {
            RectangleMark(xStart: .value("따라감 폭", -band * 100), xEnd: .value("따라감 폭", band * 100))
                .foregroundStyle(Theme.textSecond.opacity(0.1))
            RuleMark(x: .value("기준", 0))
                .foregroundStyle(Theme.textSecond.opacity(0.4))
            ForEach(known) { r in
                let pct = (r.rel! - 1) * 100
                BarMark(x: .value("잣대 대비", pct), y: .value("잣대", r.ruler.title), height: .ratio(0.55))
                    .foregroundStyle(RulerVerdict(r.rel!, band: band).tint)
                    .cornerRadius(4)
                    .annotation(position: pct >= 0 ? .trailing : .leading, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(verbatim: "\(r.ruler.title) \(signed(r.rel! - 1))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize()
                    }
            }
        }
        .chartXScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: "\(Int(v))%").font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func statusLine(_ list: [Row]) -> some View {
        if prices.loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("금 · 달러 · 주가지수 시세를 불러오는 중이에요.")
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecond)
        } else if list.contains(where: { $0.rel == nil }) && !prices.isComplete {
            Button {
                Task { await prices.refresh() }
            } label: {
                Label("일부 잣대의 시세가 없어요. 다시 불러오기", systemImage: "arrow.clockwise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
            }
            .buttonStyle(.plain)
        } else if list.contains(where: { $0.rel == nil }) {
            Text("이 해에는 자료가 없는 잣대가 있어요. 금 · 달러 · S&P500은 2003년부터 볼 수 있어요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        } else {
            HStack(spacing: 12) {
                legend(Theme.rise, RulerVerdict.beat.label)
                legend(Theme.textSecond, String(localized: "따라감 ±\(Fmt.trimNumber(band * 100) + "%")"))
                legend(Theme.fall, RulerVerdict.lag.label)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scalemass")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.textSecond)
            Text("자산의 그때 값과 지금 값을 넣으면\n물가 · 금 · 달러 · 주가지수보다 더 올랐는지 보여 줘요.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
            HStack(spacing: 8) {
                capsuleButton(String(localized: "예시로 채워보기")) { fillExample() }
                capsuleButton(String(localized: "자산 넣기")) { showList = true }
            }
        }
    }

    // MARK: 조작 패널

    private var levers: [SimLever] {
        guard let item = current else { return [] }
        var list: [SimLever] = []
        if items.count > 1 {
            list.append(.choice(String(localized: "자산"), current: item.name, items.map { i in
                SimOption(id: i.name, selected: i.id == item.id) { selectedID = i.id.uuidString }
            }))
        }
        let yearBinding = Binding<Double>(
            get: { Double(current?.year ?? Self.thisYear) },
            set: { v in update { $0.year = Int(v.rounded()) } }
        )
        list.append(SimLever(id: String(localized: "산 해"), value: yearBinding,
                             range: Double(Self.firstYear)...Double(Self.thisYear), step: 1,
                             text: String(localized: "\(String(item.year))년"), unitLabel: String(localized: "년")))
        list.append(moneyLever(String(localized: "그때 값"), \.then))
        list.append(moneyLever(String(localized: "지금 값"), \.now))
        list.append(moneyLever(String(localized: "받은 돈"), \.income))
        list.append(.percent(String(localized: "따라감 폭"), $bandText, 0...30, step: 1, prefix: "±"))
        return list
    }

    private func moneyLever(_ label: String, _ key: WritableKeyPath<Item, Double>) -> SimLever {
        let b = Binding<Double>(
            get: { current?[keyPath: key] ?? 0 },
            set: { v in update { $0[keyPath: key] = max(0, v.rounded()) } }
        )
        let step = max(10_000, pow(10, floor(log10(max(sliderMax, 1)))) / 100)
        return SimLever(id: label, value: b, range: SimLever.fit(0...sliderMax, b.wrappedValue), step: step,
                        text: Fmt.wonKo(b.wrappedValue), unit: 10_000, unitLabel: String(localized: "만원"))
    }

    private func update(_ change: (inout Item) -> Void) {
        guard let id = current?.id, let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    // 금액 슬라이더 폭 — 끄는 동안 범위가 따라 움직이지 않게, 자산·칩이 바뀔 때만 다시 잡는다.
    private func rescale() {
        let top = max(current?.then ?? 0, current?.now ?? 0, current?.income ?? 0)
        let base = max(top * 2, 10_000_000)
        let mag = pow(10, floor(log10(base)))
        sliderMax = (base / mag).rounded(.up) * mag
    }

    // MARK: 해석·저장

    @ViewBuilder private var infoContent: some View {
        if !items.isEmpty {
            SimInfoCard(title: String(localized: "자산별 판정")) {
                ForEach(items) { item in
                    verdictBlock(item)
                    if item.id != items.last?.id { Divider().overlay(Theme.hairline) }
                }
            }
        }
        if let item = current {
            SimInfoCard(title: String(localized: "\(String(item.year))년부터 잣대가 오른 만큼")) {
                ForEach(rows(item)) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(r.ruler.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(r.rulerMultiple.map { "×" + String(format: "%.2f", $0) } ?? "—")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                        }
                        Text(r.ruler.question)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        SimInfoCard(title: String(localized: "읽는 법")) {
            Text("잣대 대비 = (지금 값 + 받은 돈) ÷ 그때 값 ÷ 잣대가 오른 배수")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.accentText)
                .fixedSize(horizontal: false, vertical: true)
            Text("원화로 두 배가 됐어도 같은 기간 금이 세 배가 됐다면, 그 자산을 팔아 살 수 있는 금은 오히려 줄었어요. 잣대마다 결과가 다르면 자산보다 잣대 쪽이 크게 움직인 거예요. 여러 잣대에서 모두 능가했다면 확실히 잘 오른 자산이에요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
            Text("받은 돈에는 들고 있는 동안 받은 배당 · 월세 · 이자를 더해요. 주가지수는 배당을 뺀 값이라 지수 쪽이 조금 불리해요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let item = current, item.multiple != nil {
            CalcSaveRow(kind: .ruler, headline: headline(item),
                        detail: String(localized: "\(String(item.year))년부터 · 원화 \(signed((item.multiple ?? 1) - 1))"))
        }
        Text("물가는 한국 소비자물가지수(World Bank), 금 · 달러 · 주가지수는 Yahoo Finance 월별 가격이에요. 지난 해는 그해 평균, 지금은 최근 가격으로 계산하고 모두 원화로 바꿔 비교해요. 올해 물가는 확정 전이라 작년 값을 써요.")
            .font(.caption2)
            .foregroundStyle(Theme.textSecond)
            .frame(maxWidth: .infinity, alignment: .leading)
        simDisclaimer
    }

    private func verdictBlock(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(String(localized: "\(String(item.year))년부터 · 원화 \(signed((item.multiple ?? 1) - 1))"))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            ForEach(rows(item)) { r in
                HStack {
                    Text(r.ruler.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Spacer()
                    if let rel = r.rel {
                        let v = RulerVerdict(rel, band: band)
                        Text(signed(rel - 1))
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                        Text(v.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(v.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(v.tint)
                    } else {
                        Text(verbatim: "—").font(.caption).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
    }

    // MARK: 자산 목록

    private var importable: [Asset] {
        myAssets.filter { !$0.isDebt && $0.costBasis > 0 }
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("산 해, 그때 값, 지금 값을 적어요. 받은 돈은 들고 있는 동안 받은 배당 · 월세 · 이자의 합계예요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($items) { $item in
                itemEditor($item)
            }

            HStack(spacing: 12) {
                Button {
                    let item = Item(name: String(localized: "자산 \(items.count + 1)"), year: Self.thisYear - 10, then: 0, now: 0)
                    items.append(item)
                    selectedID = item.id.uuidString
                } label: {
                    Label("자산 추가", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                }
                .buttonStyle(.plain)
                Spacer()
                if !importable.isEmpty {
                    Menu {
                        ForEach(importable) { a in
                            Button(a.name) { importAsset(a) }
                        }
                    } label: {
                        Label("내 자산에서 가져오기", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                }
            }
            if !importable.isEmpty {
                Text("내 자산에서 가져오면 투자 원금이 그때 값, 지금 평가액이 지금 값이 돼요. 여러 번 나눠 샀다면 첫 매수한 해로 잡아요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func itemEditor(_ item: Binding<Item>) -> some View {
        let id = item.wrappedValue.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("이름", text: item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Picker("산 해", selection: item.year) {
                    ForEach((Self.firstYear...Self.thisYear).reversed(), id: \.self) {
                        Text("\(String($0))년").tag($0)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                Button {
                    items.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecond.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("삭제")
            }
            amountField(String(localized: "그때 값"), item.then)
            amountField(String(localized: "지금 값"), item.now)
            amountField(String(localized: "받은 돈"), item.income)
        }
        .padding(12)
        .background(Theme.surfaceHigh.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func amountField(_ label: String, _ value: Binding<Double>) -> some View {
        let text = Binding<String>(
            get: { value.wrappedValue > 0 ? String(Int(value.wrappedValue)) : "" },
            set: { value.wrappedValue = Double($0.filter(\.isNumber)) ?? 0 }
        )
        return HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            TextField("0", text: text.commaGrouped)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .accessibilityLabel(label)
            Text("원")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    private func importAsset(_ a: Asset) {
        let first = a.tradeList.map(\.date).min() ?? a.createdAt
        let year = min(max(Calendar.current.component(.year, from: first), Self.firstYear), Self.thisYear)
        let item = Item(name: a.name, year: year, then: a.costBasis, now: a.amount)
        items.append(item)
        selectedID = item.id.uuidString
    }

    private func fillExample() {
        let item = Item(name: String(localized: "예시 아파트"), year: Self.thisYear - 10,
                        then: 300_000_000, now: 600_000_000)
        items = [item]
        selectedID = item.id.uuidString
    }

    // MARK: 저장

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = itemsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        itemsJSON = String(decoding: data, as: UTF8.self)
    }

    // MARK: 작은 조각

    private func signed(_ v: Double) -> String {
        "\(v >= 0 ? "+" : "−")\(Fmt.percent(abs(v), fraction: 0))"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(Theme.textSecond)
        }
        .font(.caption2)
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
}
