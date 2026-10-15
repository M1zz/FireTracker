import SwiftUI

// 시장 공포 나침반 — "공포에 사고 탐욕에 판다"는 규칙을 지킬 때 볼 지금의 시장 분위기.
// 바늘은 VIX(미국 S&P500 옵션에 들어 있는 공포) 하나로 정하고, S&P500·코스피가
// 1년 고점에서 얼마나 내려왔는지를 곁들인다. 모두 Yahoo 차트 API(키 불필요).
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
            return String(localized: "모두가 편안할 때예요. 새로 크게 사기보다 비중이 너무 커진 자산이 없는지 볼 때예요.")
        case .calm:
            return String(localized: "평소 수준이에요. 하던 대로 꾸준히 모으면 돼요.")
        case .uneasy:
            return String(localized: "불안이 커지는 중이에요. 공포 구간에서 얼마나 더 살지 지금 정해 두세요.")
        case .fear:
            return String(localized: "공포 구간이에요. 미리 정해 둔 만큼만 나눠서 사는 구간이에요. 빚을 내서 사지는 마세요.")
        case .panic:
            return String(localized: "극단적 공포예요. 역사적으로 좋은 매수 기회였지만 더 빠질 수도 있어요. 나눠서, 버틸 수 있는 만큼만.")
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
    var vixYearLow: Double
    var vixYearHigh: Double
    var spxDrawdown: Double     // 1년 고점 대비 (음수 = 하락)
    var kospiDrawdown: Double
    var fetchedAt: Date
    var mood: MarketMood { MarketMood(vix: vix) }
}

enum MarketMoodService {
    // 하루에 몇 번 열어도 네트워크는 30분에 한 번만.
    @MainActor private static var cache: MarketMoodSnapshot?

    @MainActor
    static func load(force: Bool = false) async throws -> MarketMoodSnapshot {
        if !force, let c = cache, Date().timeIntervalSince(c.fetchedAt) < 30 * 60 { return c }
        async let vix = meta("^VIX")
        async let spx = meta("^GSPC")
        async let kospi = meta("^KS11")
        let (v, s, k) = try await (vix, spx, kospi)
        let snap = MarketMoodSnapshot(vix: v.price,
                                      vixYearLow: v.low,
                                      vixYearHigh: v.high,
                                      spxDrawdown: s.high > 0 ? s.price / s.high - 1 : 0,
                                      kospiDrawdown: k.high > 0 ? k.price / k.high - 1 : 0,
                                      fetchedAt: Date())
        cache = snap
        return snap
    }

    private static func meta(_ symbol: String) async throws -> (price: Double, high: Double, low: Double) {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d") else {
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
        return (price, (m?["fiftyTwoWeekHigh"] as? Double) ?? 0, (m?["fiftyTwoWeekLow"] as? Double) ?? 0)
    }
}

struct MarketMoodCard: View {
    @State private var snap: MarketMoodSnapshot?
    @State private var failed = false
    @State private var loading = false

    // 게이지 눈금: VIX 10~50을 한 줄에 편다.
    private let gaugeMin = 10.0
    private let gaugeMax = 50.0
    private let bands: [(MarketMood, Double, Double)] = [
        (.greed, 10, 15), (.calm, 15, 20), (.uneasy, 20, 30), (.fear, 30, 40), (.panic, 40, 50)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("시장 공포 나침반")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("지금 시장은 얼마나 무서워하나")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                }
                Spacer()
                InfoPopoverButton(text: String(localized: "바늘은 VIX(미국 S&P500 옵션 가격에 담긴 변동성 지수)예요. 평소 12~20이고, 30을 넘으면 공포, 40 이상은 2008년·2020년 3월 같은 패닉이에요. 아래 두 줄은 S&P500과 코스피가 최근 1년 고점에서 얼마나 내려왔는지예요.\n\n이 지표는 '지금 사람들이 무서워한다'만 알려줄 뿐 바닥은 알려주지 않아요. 공포 구간에서 얼마나 나눠 살지 미리 정해 두고, 그 규칙을 지킬 때 쓰세요. 투자 권유가 아니에요."))
            }

            if let snap {
                content(snap)
            } else if failed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("시장 데이터를 불러오지 못했어요")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Text("다시 시도")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("시장 분위기를 읽는 중")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task { await load(force: false) }
    }

    @ViewBuilder
    private func content(_ s: MarketMoodSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(s.mood.label)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(s.mood.color)
            Text(verbatim: "VIX \(s.vix.formatted(.number.precision(.fractionLength(1))))")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }

        gauge(s)

        Text(s.mood.guide)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(spacing: 8) {
            drawdownRow(String(localized: "S&P500 1년 고점 대비"), s.spxDrawdown)
            drawdownRow(String(localized: "코스피 1년 고점 대비"), s.kospiDrawdown)
            HStack {
                Text("VIX 1년 범위")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
                Spacer()
                Text(verbatim: "\(s.vixYearLow.formatted(.number.precision(.fractionLength(1)))) ~ \(s.vixYearHigh.formatted(.number.precision(.fractionLength(1))))")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private func gauge(_ s: MarketMoodSnapshot) -> some View {
        let span = gaugeMax - gaugeMin
        let pos = (min(max(s.vix, gaugeMin), gaugeMax) - gaugeMin) / span
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(bands, id: \.1) { band in
                            Rectangle()
                                .fill(band.0.color.opacity(band.0 == s.mood ? 0.9 : 0.3))
                                .frame(width: max(0, (w - 8) * (band.2 - band.1) / span))
                        }
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())
                    Circle()
                        .fill(Theme.textPrimary)
                        .overlay(Circle().stroke(Theme.surface, lineWidth: 3))
                        .frame(width: 20, height: 20)
                        .offset(x: max(0, min(w - 20, w * pos - 10)))
                }
                .frame(height: 20)
            }
            .frame(height: 20)
            HStack {
                Text("탐욕").foregroundStyle(MarketMood.greed.color)
                Spacer()
                Text("공포").foregroundStyle(MarketMood.panic.color)
            }
            .font(.body)
        }
    }

    private func drawdownRow(_ title: String, _ dd: Double) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textSecond)
            Spacer()
            Text(dd > -0.005 ? String(localized: "고점 근처") : Fmt.percent(dd, fraction: 1))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(dd <= -0.2 ? Theme.fall : Theme.textPrimary)
        }
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
