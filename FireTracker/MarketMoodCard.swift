import SwiftUI
import Charts

// 시장 공포 나침반 — "공포에 사고 탐욕에 판다"는 규칙을 지킬 때 볼 지금의 시장 분위기.
// 바늘은 VIX(미국 S&P500 옵션에 들어 있는 공포) 하나. Yahoo 차트 API(키 불필요).
// 바닥을 알려주는 지표가 아니라 '지금 사람들이 얼마나 무서워하나'만 보여준다.

enum MarketMood: CaseIterable {
    case greed, calm, uneasy, fear, panic

    // VIX 구간. 평소 12~20, 30을 넘으면 공포, 40 이상은 2008년·2020년 3월 수준.
    init(vix: Double) {
        switch vix {
        case ..<15: self = .greed
        case ..<20: self = .calm
        case ..<30: self = .uneasy
        case ..<40: self = .fear
        default:    self = .panic
        }
    }

    var label: String {
        switch self {
        case .greed:  return String(localized: "탐욕")
        case .calm:   return String(localized: "평온")
        case .uneasy: return String(localized: "불안")
        case .fear:   return String(localized: "공포")
        case .panic:  return String(localized: "극단적 공포")
        }
    }

    // 이 구간에서 미리 정해 둔 규칙을 떠올리게 하는 한 줄. 매수·매도 지시가 아니다.
    var guide: String {
        switch self {
        case .greed:
            return String(localized: "모두 들떠 있어요. 크게 사기보다 점검할 때예요.")
        case .calm:
            return String(localized: "평소 수준이에요. 하던 대로 모으세요.")
        case .uneasy:
            return String(localized: "불안이 커지는 중이에요. 살 계획을 미리 세워 두세요.")
        case .fear:
            return String(localized: "공포 구간이에요. 정해 둔 만큼 나눠서 사는 때예요.")
        case .panic:
            return String(localized: "극단적 공포예요. 기회일 수 있지만 나눠서, 빚 없이.")
        }
    }

    var color: Color {
        switch self {
        case .greed:  return Theme.negative
        case .calm:   return Theme.positive
        case .uneasy: return Theme.accent
        case .fear:   return Theme.fall
        case .panic:  return Color(light: "5B3FD0", dark: "8C74FF")
        }
    }
}

struct MarketMoodSnapshot {
    var vix: Double
    var fetchedAt: Date
    var mood: MarketMood { MarketMood(vix: vix) }
}

enum MarketMoodService {
    // 하루에 몇 번 열어도 네트워크는 30분에 한 번만.
    @MainActor private static var cache: MarketMoodSnapshot?

    @MainActor
    static func load(force: Bool = false) async throws -> MarketMoodSnapshot {
        if !force, let c = cache, Date().timeIntervalSince(c.fetchedAt) < 30 * 60 { return c }
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/%5EVIX?interval=1d&range=1d") else {
            throw PriceError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PriceError.http(http.statusCode)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let m = ((obj?["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first?["meta"] as? [String: Any]
        guard let price = m?["regularMarketPrice"] as? Double, price > 0 else { throw PriceError.empty }
        let snap = MarketMoodSnapshot(vix: price, fetchedAt: Date())
        cache = snap
        return snap
    }
}

struct MarketMoodCard: View {
    @State private var snap: MarketMoodSnapshot?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("시장 공포 나침반")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                InfoPopoverButton(text: String(localized: "바늘은 VIX(미국 S&P500 옵션 가격에 담긴 변동성 지수)예요. 평소 12~20이고, 30을 넘으면 공포, 40 이상은 2008년·2020년 3월 같은 패닉이에요.\n\n'지금 사람들이 무서워한다'만 알려줄 뿐 바닥은 알려주지 않아요. 공포 구간에서 얼마나 나눠 살지 미리 정해 두고, 그 규칙을 지킬 때 쓰세요. 투자 권유가 아니에요."))
            }

            if let snap {
                MoodGauge(vix: snap.vix)
                VStack(spacing: 6) {
                    Text(snap.mood.label)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(snap.mood.color)
                    Text(snap.mood.guide)
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if failed {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text("불러오지 못했어요 · 다시 시도")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            // VIX 하나보다 넓게 — 여러 지표를 합친 0~100 공포·탐욕 지수로.
            NavigationLink { FearGreedView() } label: {
                HStack {
                    Text("공포·탐욕 지수 보기")
                        .font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(Theme.accentText)
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
        .task { await load(force: false) }
    }

    private func load(force: Bool) async {
        if loading { return }
        loading = true
        defer { loading = false }
        do {
            let s = try await MarketMoodService.load(force: force)
            withAnimation(.easeInOut(duration: 0.3)) { snap = s; failed = false }
        } catch {
            if snap == nil { failed = true }
        }
    }
}

// 반원 계기판 — 왼쪽 끝 탐욕, 오른쪽 끝 공포. VIX 10~50을 반원에 편다.
private struct MoodGauge: View {
    let vix: Double

    private static let lo = 10.0
    private static let hi = 50.0
    private static let bands: [(MarketMood, Double, Double)] = [
        (.greed, 10, 15), (.calm, 15, 20), (.uneasy, 20, 30), (.fear, 30, 40), (.panic, 40, 50)
    ]

    private func fraction(_ v: Double) -> Double {
        (min(max(v, Self.lo), Self.hi) - Self.lo) / (Self.hi - Self.lo)
    }

    var body: some View {
        let current = MarketMood(vix: vix)
        VStack(spacing: 2) {
            Canvas { ctx, size in
                let line: CGFloat = 16
                let r = min(size.width / 2, size.height - 9) - line / 2
                let c = CGPoint(x: size.width / 2, y: size.height - 9)
                // 왼쪽(π)에서 위(1.5π)를 지나 오른쪽(2π)으로.
                func angle(_ f: Double) -> Angle { .radians(.pi + f * .pi) }
                for (mood, a, b) in Self.bands {
                    var p = Path()
                    p.addArc(center: c, radius: r,
                             startAngle: angle(fraction(a) + 0.006), endAngle: angle(fraction(b) - 0.006),
                             clockwise: false)
                    ctx.stroke(p, with: .color(mood.color.opacity(mood == current ? 1 : 0.25)),
                               style: StrokeStyle(lineWidth: line, lineCap: .butt))
                }
                let t = angle(fraction(vix)).radians
                let tip = CGPoint(x: c.x + cos(t) * (r - line), y: c.y + sin(t) * (r - line))
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: tip)
                ctx.stroke(needle, with: .color(Theme.textPrimary), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)),
                         with: .color(Theme.textPrimary))
            }
            .frame(width: 240, height: 129)
            HStack {
                Text("탐욕")
                Spacer()
                Text("공포")
            }
            .font(.body)
            .foregroundStyle(Theme.textSecond)
            .frame(width: 272)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(current.label))
    }
}

// MARK: - 공포·탐욕 지수 (0~100)
//
// CNN Fear & Greed 와 같은 방식 — 시장 지표 여러 개를 각각 '최근 1년 중 지금이 어디쯤인가'
// (백분위)로 0~100 점수로 바꾼 뒤 똑같은 비중으로 평균낸다. 50 이 평소, 0 쪽이 공포, 100 쪽이 탐욕.
// CNN 의 7개 지표 중 무료 시세로 구할 수 있는 5개를 쓴다(풋/콜 비율·McClellan 거래량 지표 제외).
// 그래서 CNN 숫자와 똑같지는 않고 비슷하게 움직인다.

enum FearGreedBand: CaseIterable {
    case extremeFear, fear, neutral, greed, extremeGreed

    init(score: Double) {
        switch score {
        case ..<25: self = .extremeFear
        case ..<45: self = .fear
        case ..<55: self = .neutral
        case ..<75: self = .greed
        default:    self = .extremeGreed
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .extremeFear:  return 0...25
        case .fear:         return 25...45
        case .neutral:      return 45...55
        case .greed:        return 55...75
        case .extremeGreed: return 75...100
        }
    }

    var label: String {
        switch self {
        case .extremeFear:  return String(localized: "극단적 공포")
        case .fear:         return String(localized: "공포")
        case .neutral:      return String(localized: "중립")
        case .greed:        return String(localized: "탐욕")
        case .extremeGreed: return String(localized: "극단적 탐욕")
        }
    }

    var color: Color {
        switch self {
        case .extremeFear:  return Color(light: "5B3FD0", dark: "8C74FF")
        case .fear:         return Theme.fall
        case .neutral:      return Theme.textSecond
        case .greed:        return Theme.accent
        case .extremeGreed: return Theme.negative
        }
    }
}

struct FearGreedComponent: Identifiable {
    enum Kind: CaseIterable {
        case momentum, strength, volatility, safeHaven, junkBond
    }
    let kind: Kind
    let score: Double
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .momentum:   return String(localized: "시장 모멘텀")
        case .strength:   return String(localized: "주가 강도")
        case .volatility: return String(localized: "변동성")
        case .safeHaven:  return String(localized: "안전자산 수요")
        case .junkBond:   return String(localized: "정크본드 수요")
        }
    }

    var method: String {
        switch kind {
        case .momentum:
            return String(localized: "S&P 500 이 125일 이동평균보다 얼마나 위에 있나")
        case .strength:
            return String(localized: "S&P 500 이 52주 최저와 최고 사이 어디쯤인가")
        case .volatility:
            return String(localized: "VIX 가 50일 평균보다 낮을수록 탐욕")
        case .safeHaven:
            return String(localized: "최근 20일 주식(SPY) 수익률 − 미국 국채(TLT) 수익률")
        case .junkBond:
            return String(localized: "최근 20일 하이일드 채권(HYG) 수익률 − 국채(IEF) 수익률")
        }
    }
}

struct FearGreedPoint: Identifiable {
    let date: Date
    let score: Double
    var id: Date { date }
}

struct FearGreedResult {
    let score: Double
    let components: [FearGreedComponent]
    let history: [FearGreedPoint]   // 최근 1년, 오래된 순
    let fetchedAt: Date

    /// n 거래일 전 점수(없으면 nil). 0 = 오늘.
    func score(daysAgo n: Int) -> Double? {
        let i = history.count - 1 - n
        return history.indices.contains(i) ? history[i].score : nil
    }
}

enum FearGreedService {
    @MainActor private static var cache: FearGreedResult?

    private static let symbols = ["^GSPC", "^VIX", "SPY", "TLT", "HYG", "IEF"]

    @MainActor
    static func load(force: Bool = false) async throws -> FearGreedResult {
        if !force, let c = cache, Date().timeIntervalSince(c.fetchedAt) < 30 * 60 { return c }
        var series: [String: [String: Double]] = [:]
        try await withThrowingTaskGroup(of: (String, [String: Double]).self) { group in
            for sym in symbols {
                group.addTask { (sym, try await fetch(sym)) }
            }
            for try await (sym, s) in group { series[sym] = s }
        }
        guard let result = compute(series) else { throw PriceError.empty }
        cache = result
        return result
    }

    // 날짜(뉴욕 기준 yyyy-MM-dd) → 종가. ETF 는 배당까지 넣은 수정종가.
    private static func fetch(_ symbol: String) async throws -> [String: Double] {
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?interval=1d&range=3y") else {
            throw PriceError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PriceError.http(http.statusCode)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let r = ((obj?["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let ts = r["timestamp"] as? [Double],
              let ind = r["indicators"] as? [String: Any] else { throw PriceError.decode }
        let adj = ((ind["adjclose"] as? [[String: Any]])?.first?["adjclose"] as? [Any])
        let close = ((ind["quote"] as? [[String: Any]])?.first?["close"] as? [Any])
        guard let values = adj ?? close else { throw PriceError.decode }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        var out: [String: Double] = [:]
        for (t, v) in zip(ts, values) {
            if let d = v as? Double, d > 0 { out[f.string(from: Date(timeIntervalSince1970: t))] = d }
        }
        return out
    }

    private static let window = 252   // 약 1년(거래일)

    static func compute(_ series: [String: [String: Double]]) -> FearGreedResult? {
        let sets = symbols.compactMap { series[$0].map { Set($0.keys) } }
        guard sets.count == symbols.count else { return nil }
        let days = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }.sorted()
        func col(_ s: String) -> [Double] { days.map { series[s]![$0]! } }
        let spx = col("^GSPC"), vix = col("^VIX"), spy = col("SPY"), tlt = col("TLT"),
            hyg = col("HYG"), ief = col("IEF")
        let n = days.count
        guard n > window * 2 else { return nil }

        func mean(_ a: ArraySlice<Double>) -> Double { a.reduce(0, +) / Double(a.count) }
        func ret20(_ a: [Double], _ i: Int) -> Double { a[i] / a[i - 20] - 1 }

        // 지표별 원값(클수록 탐욕). 52주 범위를 쓰므로 window 번째 날부터.
        var raw: [FearGreedComponent.Kind: [Double]] = [:]
        for i in window..<n {
            let lo = spx[(i - window + 1)...i].min()!, hi = spx[(i - window + 1)...i].max()!
            raw[.momentum, default: []].append(spx[i] / mean(spx[(i - 124)...i]) - 1)
            raw[.strength, default: []].append(hi > lo ? (spx[i] - lo) / (hi - lo) : 0.5)
            raw[.volatility, default: []].append(-(vix[i] / mean(vix[(i - 49)...i]) - 1))
            raw[.safeHaven, default: []].append(ret20(spy, i) - ret20(tlt, i))
            raw[.junkBond, default: []].append(ret20(hyg, i) - ret20(ief, i))
        }

        // 지난 1년 안에서 오늘 값의 백분위 → 0~100.
        func percentile(_ a: [Double], _ i: Int) -> Double {
            let past = a[(i - window + 1)...i]
            let below = past.filter { $0 < a[i] }.count
            let same = past.filter { $0 == a[i] }.count
            return (Double(below) + Double(same) / 2) / Double(past.count) * 100
        }

        let m = raw[.momentum]!.count
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        var history: [FearGreedPoint] = []
        var last: [FearGreedComponent] = []
        for i in (window - 1)..<m {
            let comps = FearGreedComponent.Kind.allCases.map {
                FearGreedComponent(kind: $0, score: percentile(raw[$0]!, i))
            }
            let score = comps.map(\.score).reduce(0, +) / Double(comps.count)
            if let d = f.date(from: days[i + window]) {
                history.append(FearGreedPoint(date: d, score: score))
            }
            last = comps
        }
        guard let today = history.last else { return nil }
        return FearGreedResult(score: today.score, components: last,
                               history: Array(history.suffix(window)), fetchedAt: Date())
    }
}

struct FearGreedView: View {
    @State private var result: FearGreedResult?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gutter) {
                if let result {
                    headerCard(result)
                    historyCard(result)
                    chartCard(result)
                    componentsCard(result)
                    methodCard
                } else if failed {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Text("불러오지 못했어요 · 다시 시도")
                            .font(.body)
                            .foregroundStyle(Theme.textSecond)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, Theme.gutter)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("공포·탐욕 지수")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
    }

    private func load(force: Bool) async {
        if loading { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await FearGreedService.load(force: force)
            withAnimation(.easeInOut(duration: 0.3)) { result = r; failed = false }
        } catch {
            if result == nil { failed = true }
        }
    }

    private func headerCard(_ r: FearGreedResult) -> some View {
        let band = FearGreedBand(score: r.score)
        return VStack(spacing: 10) {
            Text("지금 시장을 움직이는 감정은?")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
            FearGreedGauge(score: r.score)
            Text(band.label)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(band.color)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func historyCard(_ r: FearGreedResult) -> some View {
        let rows: [(String, Int)] = [
            (String(localized: "전일 종가"), 1),
            (String(localized: "1주 전"), 5),
            (String(localized: "1달 전"), 21),
            (String(localized: "1년 전"), r.history.count - 1),
        ]
        return VStack(spacing: 12) {
            ForEach(rows, id: \.0) { title, n in
                if let s = r.score(daysAgo: n) {
                    let b = FearGreedBand(score: s)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.body)
                                .foregroundStyle(Theme.textSecond)
                            Text(b.label)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        Spacer()
                        Text("\(Int(s.rounded()))")
                            .font(.system(.body, design: .rounded, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(b.color.opacity(0.18))
                            .foregroundStyle(b.color)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }


    private func chartCard(_ r: FearGreedResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("최근 1년")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart {
                ForEach(FearGreedBand.allCases, id: \.self) { b in
                    RectangleMark(yStart: .value("from", b.range.lowerBound),
                                  yEnd: .value("to", b.range.upperBound))
                        .foregroundStyle(b.color.opacity(0.08))
                }
                ForEach(r.history) { p in
                    LineMark(x: .value("date", p.date), y: .value("score", p.score))
                        .foregroundStyle(Theme.textPrimary)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100])
            }
            .frame(height: 200)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func componentsCard(_ r: FearGreedResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("지표별 점수")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(r.components) { c in
                let b = FearGreedBand(score: c.score)
                VStack(alignment: .leading, spacing: 6) {
                    AdaptiveRow {
                        Text(c.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    } trailing: {
                        Text("\(b.label) \(Int(c.score.rounded()))")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(b.color)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.textSecond.opacity(0.15))
                            Capsule().fill(b.color)
                                .frame(width: max(6, geo.size.width * c.score / 100))
                        }
                    }
                    .frame(height: 8)
                    Text(c.method)
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("어떻게 계산하나요")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("CNN 공포·탐욕 지수와 같은 방식이에요. 지표마다 지금 값이 최근 1년 중 어디쯤인지를 0~100 점으로 바꾸고, 다섯 지표를 똑같은 비중으로 평균내요. 50이 평소, 0에 가까울수록 공포, 100에 가까울수록 탐욕이에요.")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
            Text("CNN 은 지표 7개를 쓰지만 풋/콜 비율과 거래량 폭 지표는 무료로 받을 수 없어 뺐어요. 그래서 CNN 숫자와 똑같지는 않고 비슷하게 움직여요. 미국 시장 기준이고 하루 한 번 종가로 바뀌어요. 투자 권유가 아니에요.")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// 0~100 반원 계기판 — 왼쪽 극단적 공포, 오른쪽 극단적 탐욕. 가운데 숫자.
private struct FearGreedGauge: View {
    let score: Double

    var body: some View {
        let current = FearGreedBand(score: score)
        ZStack(alignment: .bottom) {
            Canvas { ctx, size in
                let line: CGFloat = 22
                let r = min(size.width / 2, size.height) - line / 2
                let c = CGPoint(x: size.width / 2, y: size.height)
                func angle(_ v: Double) -> Angle { .radians(.pi + v / 100 * .pi) }
                for b in FearGreedBand.allCases {
                    var p = Path()
                    p.addArc(center: c, radius: r,
                             startAngle: angle(b.range.lowerBound + 0.6), endAngle: angle(b.range.upperBound - 0.6),
                             clockwise: false)
                    ctx.stroke(p, with: .color(b.color.opacity(b == current ? 1 : 0.22)),
                               style: StrokeStyle(lineWidth: line, lineCap: .butt))
                }
                let t = angle(min(max(score, 0), 100)).radians
                let tip = CGPoint(x: c.x + cos(t) * (r - line), y: c.y + sin(t) * (r - line))
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: tip)
                ctx.stroke(needle, with: .color(Theme.textPrimary), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .frame(width: 280, height: 150)
            Text("\(Int(score.rounded()))")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .background(Theme.surface, in: Capsule())
                .offset(y: 18)
        }
        .padding(.bottom, 18)
        .accessibilityElement()
        .accessibilityLabel(Text("\(current.label) \(Int(score.rounded()))"))
    }
}
