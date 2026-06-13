import SwiftUI
import SwiftData

// 시세·배당 자동 갱신을 한곳에서 관리한다.
//  • 앱 시작 시 — 마지막 갱신이 7일 이상 지났으면 자동 갱신(주 1회 보장)
//  • 자산 탭 진입 시 — 15분 쓰로틀로 최신화
//  • 수동 — 자산 탭의 새로고침 버튼
// 갱신 결과는 Asset 모델(평가액·배당률)에 바로 반영되므로, @Query로 자산을
// 구독하는 자산·대시보드·추이 화면이 함께 최신 배당/시세를 보여준다.
@MainActor
final class RefreshManager: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var statusMessage: String?

    static let weekly: TimeInterval = 7 * 24 * 3600
    static let tabThrottle: TimeInterval = 15 * 60

    private let lastRefreshKey = "lastAssetRefresh"

    init() {
        let t = UserDefaults.standard.double(forKey: lastRefreshKey)
        lastRefresh = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // 마지막 갱신이 maxAge보다 오래됐을 때만 갱신. (앱 시작·탭 진입에서 사용)
    func refreshIfStale(assets: [Asset], settings: FireSettings, context: ModelContext,
                        maxAge: TimeInterval) async {
        if isRefreshing { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < maxAge { return }
        await refresh(assets: assets, settings: settings, context: context)
    }

    // 강제 갱신. 자동 시세 자산은 평가액·단가를, 주식·ETF는 배당률을 최신화한다.
    func refresh(assets: [Asset], settings: FireSettings, context: ModelContext) async {
        guard !isRefreshing else { return }
        // 자동 시세 자산이거나, 배당을 따질 수 있는 주식·ETF만 대상.
        let targets = assets.filter {
            $0.autoPriced || $0.assetClass == .stocks || $0.assetClass == .fund
        }
        guard !targets.isEmpty else { return }

        isRefreshing = true
        statusMessage = "시세·배당 불러오는 중…"
        defer { isRefreshing = false }

        var pricedCount = 0
        var dividendCount = 0
        for asset in targets {
            let symbol = asset.symbol.trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { continue }

            // 1) 자동 시세 자산: 평가액·단가 최신화.
            if asset.autoPriced {
                if let result = try? await PriceService.autoValue(
                    assetClass: asset.assetClass,
                    symbol: asset.symbol,
                    name: asset.name,
                    quantity: asset.quantity,
                    currency: asset.currency,
                    date: Date(),
                    finnhubKey: settings.finnhubKey,
                    kisAppKey: settings.kisAppKey,
                    kisAppSecret: settings.kisAppSecret,
                    dataGoKey: settings.dataGoKey
                ) {
                    asset.amount = result.amount.rounded()
                    asset.unitPriceKRW = result.unit
                    asset.lastPriced = Date()
                    pricedCount += 1
                }
            }

            // 2) 주식·ETF 배당률 최신화 — 사용자가 배당액을 직접 넣지 않은 경우만.
            //    배당률(%)로 저장해 평가액이 바뀌어도 월 배당이 따라간다.
            if (asset.assetClass == .stocks || asset.assetClass == .fund),
               asset.monthlyIncome == 0 {
                let unit = asset.unitPriceKRW > 0
                    ? asset.unitPriceKRW
                    : (asset.quantity > 0 ? asset.amount / asset.quantity : 0)
                if unit > 0,
                   let perShare = try? await PriceService.annualDividendKRWPerShare(
                       assetClass: asset.assetClass, symbol: asset.symbol, currency: asset.currency),
                   perShare > 0 {
                    let yieldPct = (perShare / unit * 1000).rounded() / 10   // 소수 한 자리
                    asset.incomeKind = .dividend
                    asset.annualYieldPct = yieldPct
                    dividendCount += 1
                }
            }
        }
        try? context.save()

        var parts: [String] = []
        if pricedCount > 0 { parts.append("시세 \(pricedCount)건") }
        if dividendCount > 0 { parts.append("배당 \(dividendCount)건") }
        stamp(message: parts.isEmpty ? "최신 상태입니다" : parts.joined(separator: " · ") + " 갱신됨")
    }

    // 주 1회 자동 스냅샷 — 이번 주 기록(수동·자동 무관)이 아직 없으면 현재
    // 자산 상태로 하나 남긴다. 추이/변화 추적이 비지 않도록 보장한다.
    // 시세 갱신 뒤에 호출해 최신 평가액으로 기록되게 한다.
    func autoRecordIfNeeded(assets: [Asset], settings: FireSettings,
                            snapshots: [NetWorthSnapshot], context: ModelContext) {
        guard !assets.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        if snapshots.contains(where: { cal.isDate($0.date, equalTo: now, toGranularity: .weekOfYear) }) {
            return
        }
        let snap = NetWorthSnapshot(
            date: now,
            note: "자동 기록",
            monthlyIncome: settings.monthlyTakeHome,
            monthlyExpense: settings.plannedMonthlyExpense,
            monthlyNetSavings: settings.plannedNetSavings,
            monthlyPassiveIncome: passiveTotal(assets, settings),
            liquidNetWorth: assets.reduce(0) { $0 + $1.liquidValue }
        )
        context.insert(snap)
        appendEntries(to: snap, assets: assets)
        try? context.save()
    }

    // 자산 탭 데이터가 바뀔 때마다 호출 — 이번 주 기록을 현재 카탈로그로 자동 갱신.
    // 이번 주 기록이 있으면 항목·평가액·패시브 인컴을 최신화하고, 없으면 새로 만든다.
    // 사용자가 직접 만든 기록의 소득·지출 입력은 보존한다(자동 기록만 설정값으로 갱신).
    func upsertCurrentPeriodSnapshot(assets: [Asset], settings: FireSettings,
                                     snapshots: [NetWorthSnapshot], context: ModelContext) {
        guard !assets.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        let passive = passiveTotal(assets, settings)
        let liquid = assets.reduce(0) { $0 + $1.liquidValue }
        if let snap = snapshots.first(where: { cal.isDate($0.date, equalTo: now, toGranularity: .weekOfYear) }) {
            snap.date = now
            snap.monthlyPassiveIncome = passive
            snap.liquidNetWorth = liquid
            if snap.note == "자동 기록" {
                snap.monthlyIncome = settings.monthlyTakeHome
                snap.monthlyExpense = settings.plannedMonthlyExpense
                snap.monthlyNetSavings = settings.plannedNetSavings
            }
            for e in snap.entries { context.delete(e) }
            snap.entries = []
            appendEntries(to: snap, assets: assets)
        } else {
            let snap = NetWorthSnapshot(
                date: now, note: "자동 기록",
                monthlyIncome: settings.monthlyTakeHome,
                monthlyExpense: settings.plannedMonthlyExpense,
                monthlyNetSavings: settings.plannedNetSavings,
                monthlyPassiveIncome: passive, liquidNetWorth: liquid
            )
            context.insert(snap)
            appendEntries(to: snap, assets: assets)
        }
        try? context.save()
    }

    private func passiveTotal(_ assets: [Asset], _ settings: FireSettings) -> Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
    }

    private func appendEntries(to snap: NetWorthSnapshot, assets: [Asset]) {
        for asset in assets where asset.netValue != 0 {
            let entry = AssetEntry(
                assetClass: asset.assetClass,
                name: asset.name,
                amount: asset.netValue,
                catalogKey: asset.key,
                symbol: asset.symbol,
                quantity: asset.quantity,
                currency: asset.currency,
                autoPriced: asset.autoPriced,
                unitPriceKRW: asset.unitPriceKRW,
                lastPriced: asset.lastPriced
            )
            entry.snapshot = snap
            snap.entries.append(entry)
        }
    }

    private func stamp(message: String?) {
        let now = Date()
        lastRefresh = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastRefreshKey)
        statusMessage = message
    }

    // "방금 전 / N분 전 / N시간 전 / N일 전" 짧은 상대 시각.
    var lastRefreshText: String? {
        guard let last = lastRefresh else { return nil }
        let secs = Int(Date().timeIntervalSince(last))
        switch secs {
        case ..<60:      return "방금 전"
        case ..<3600:    return "\(secs / 60)분 전"
        case ..<86_400:  return "\(secs / 3600)시간 전"
        default:         return "\(secs / 86_400)일 전"
        }
    }
}
