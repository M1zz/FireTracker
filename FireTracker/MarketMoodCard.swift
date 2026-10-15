import SwiftUI

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
