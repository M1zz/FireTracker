import Foundation
import SwiftData

// 데모 데이터 — 가상의 36세 직장인 '김미래'의 자산 상황을 통째로 채워 넣어,
// 실데이터 없이도 자산·추이·계산·대시보드 모든 화면을 확인할 수 있게 한다.
//
// 인물 설정: 36세, 55세 조기은퇴 목표. 월 실수령 480만 · 지출 약 300만.
// 실거주 아파트(주담대 남음) + 국내외 주식·ETF·코인 + 파킹통장 + IRP·청약.
// 지난 9개월의 월별 기록과 이번 달 중간 기록 2개까지 넣어 추이 차트가 살아난다.
enum DemoData {

    // 과거→현재 순 월별 평가액 흐름. 마지막 값이 현재 자산의 평가액과 일치한다.
    private static let monthsBack = 10

    private struct Item {
        let asset: Asset
        let history: [Double]        // monthsBack개, 백만원 단위 아님 — 원 단위
        let annualYieldPct: Double   // 스냅샷의 패시브 인컴 근사 계산용
    }

    private static func makeItems(now: Date) -> [Item] {
        let m = 1_000_000.0
        return [
            Item(asset: Asset(name: "래미안 아파트", assetClass: .realEstate,
                              amount: 650 * m, costBasis: 520 * m,
                              realEstateUse: .residence, liquidity: .locked),
                 history: [610, 612, 615, 618, 622, 628, 635, 640, 645, 650].map { $0 * m },
                 annualYieldPct: 0),
            Item(asset: Asset(name: "주택담보대출", assetClass: .debt,
                              amount: 280 * m, incomeKind: .other, monthlyIncome: 1_250_000),
                 history: [302.5, 300, 297.5, 295, 292.5, 290, 287.5, 285, 282.5, 280].map { $0 * m },
                 annualYieldPct: 0),
            Item(asset: Asset(name: "삼성전자", assetClass: .stocks,
                              amount: 11.7 * m, quantity: 150, symbol: "005930",
                              currency: "KRW", autoPriced: true, unitPriceKRW: 78_000,
                              lastPriced: now, incomeKind: .dividend, annualYieldPct: 2.1,
                              costBasis: 10.68 * m),
                 history: [7.1, 7.4, 6.9, 7.6, 8.2, 8.0, 10.9, 11.2, 11.5, 11.7].map { $0 * m },
                 annualYieldPct: 2.1),
            Item(asset: Asset(name: "Apple", assetClass: .stocks,
                              amount: 3.48 * m, quantity: 12, symbol: "AAPL",
                              currency: "USD", autoPriced: true, unitPriceKRW: 290_000,
                              lastPriced: now, incomeKind: .dividend, annualYieldPct: 0.5,
                              costBasis: 3.1 * m),
                 history: [2.9, 3.0, 3.1, 2.95, 3.05, 3.2, 3.15, 3.3, 3.4, 3.48].map { $0 * m },
                 annualYieldPct: 0.5),
            Item(asset: Asset(name: "KODEX 200", assetClass: .fund,
                              amount: 8.4 * m, quantity: 200, symbol: "069500",
                              currency: "KRW", autoPriced: true, unitPriceKRW: 42_000,
                              lastPriced: now, incomeKind: .dividend, annualYieldPct: 1.8,
                              costBasis: 7.6 * m),
                 history: [6.2, 6.5, 6.4, 6.8, 7.1, 7.0, 7.6, 7.9, 8.2, 8.4].map { $0 * m },
                 annualYieldPct: 1.8),
            Item(asset: Asset(name: "비트코인", assetClass: .crypto,
                              amount: 12.8 * m, quantity: 0.08, symbol: "BTC",
                              currency: "KRW", autoPriced: true, unitPriceKRW: 160 * m,
                              lastPriced: now, costBasis: 9.5 * m),
                 history: [8.2, 9.6, 8.8, 10.4, 12.5, 11.2, 13.8, 12.6, 12.2, 12.8].map { $0 * m },
                 annualYieldPct: 0),
            Item(asset: Asset(name: "파킹통장", assetClass: .cash,
                              amount: 28 * m, incomeKind: .interest, annualYieldPct: 3.0),
                 history: [16, 17.5, 19, 20.5, 21, 22.5, 24, 25.5, 26.5, 28].map { $0 * m },
                 annualYieldPct: 3.0),
            Item(asset: Asset(name: "퇴직연금 IRP", assetClass: .pension,
                              amount: 42 * m, costBasis: 36 * m, liquidity: .locked),
                 history: [36.5, 37, 37.6, 38.2, 38.8, 39.4, 40, 40.7, 41.3, 42].map { $0 * m },
                 annualYieldPct: 0),
            Item(asset: Asset(name: "주택청약저축", assetClass: .deposit,
                              amount: 12 * m, liquidity: .locked),
                 history: [9.3, 9.6, 9.9, 10.2, 10.5, 10.8, 11.1, 11.4, 11.7, 12].map { $0 * m },
                 annualYieldPct: 0),
        ]
    }

    // 데모 데이터가 들어와 있는지 — 최상단 배너·설정 토글이 공유하는 플래그.
    static let activeKey = "demoDataActive"
    static var isActive: Bool { UserDefaults.standard.bool(forKey: activeKey) }

    // 데모를 보는 동안 원래(실) 데이터를 통째로 보관해두는 스태시 파일.
    private static var stashURL: URL {
        BackupManager.backupDirectory.appendingPathComponent("real-data-stash.json")
    }

    /// 데모 켜기 — 지금 데이터를 스태시 파일로 보관한 뒤 데모 데이터로 교체한다.
    /// 토글을 끄면 스태시에서 원래 데이터가 그대로 돌아온다.
    @MainActor
    static func enable(context: ModelContext) throws {
        let backup = try BackupManager.makeBackup(context: context)
        try FileManager.default.createDirectory(at: BackupManager.backupDirectory,
                                                withIntermediateDirectories: true)
        try BackupManager.encode(backup).write(to: stashURL, options: .atomic)
        try load(context: context)
        UserDefaults.standard.set(true, forKey: activeKey)
    }

    /// 데모 끄기 — 스태시에 보관해둔 원래 데이터로 복귀한다.
    /// (스태시가 없으면 빈 상태로 초기화 — 처음부터 데이터가 없던 사용자.)
    @MainActor
    static func disable(context: ModelContext) throws {
        if let data = try? Data(contentsOf: stashURL) {
            let backup = try BackupManager.decode(data)
            try BackupManager.restore(from: backup, context: context)
            try? FileManager.default.removeItem(at: stashURL)
        } else {
            try wipe(context: context)
            context.insert(FireSettings())
            try context.save()
        }
        UserDefaults.standard.set(false, forKey: activeKey)
    }

    // 자동 백업 한 벌을 남기고 모든 데이터를 지운다.
    @MainActor
    private static func wipe(context: ModelContext) throws {
        BackupManager.autoBackup(context: context)
        try context.delete(model: AssetDetail.self)
        try context.delete(model: AssetEntry.self)
        try context.delete(model: Asset.self)
        try context.delete(model: NetWorthSnapshot.self)
        try context.delete(model: FireSettings.self)
    }

    /// 모든 데이터를 지우고 데모 데이터를 채운다. 보통은 enable/disable을 쓸 것.
    @MainActor
    static func load(context: ModelContext) throws {
        try wipe(context: context)

        let now = Date()
        let cal = Calendar.current

        // 설정 — 36세, 55세 은퇴, 은퇴 후 월 350만 지출 목표(4% 룰 → 10.5억).
        let settings = FireSettings(targetAnnualExpense: 42_000_000,
                                    safeWithdrawalRate: 0.04,
                                    expectedAnnualReturn: 0.05,
                                    monthlyTakeHome: 4_800_000,
                                    plannedMonthlyExpense: 3_000_000)
        settings.currentAge = 36
        settings.targetRetireAge = 55
        context.insert(settings)

        // 자산 카탈로그.
        let items = makeItems(now: now)
        for (i, item) in items.enumerated() {
            item.asset.sortOrder = i
            context.insert(item.asset)
        }

        // 특정 시점(history 인덱스)의 값들로 스냅샷 하나를 만들어 context에 넣는다.
        // 부채는 카탈로그와 같은 규약(netValue = 음수)으로 저장한다.
        // 관계 연결은 반드시 양쪽 모두 insert된 뒤에 — 안 그러면 save가 실패한다.
        func insertSnapshot(date: Date, values: [Double], expense: Double) {
            let liquidClasses: Set<AssetClass> = [.cash, .stocks, .fund, .bond, .crypto]
            var passive = 0.0
            var liquid = 0.0
            let snap = NetWorthSnapshot(date: date, note: "데모 데이터",
                                        monthlyIncome: 4_800_000, monthlyExpense: expense)
            context.insert(snap)
            for (item, value) in zip(items, values) {
                let a = item.asset
                let signed = a.isDebt ? -value : value
                if item.annualYieldPct > 0 { passive += value * item.annualYieldPct / 100 / 12 }
                if liquidClasses.contains(a.assetClass) { liquid += value }
                let entry = AssetEntry(assetClass: a.assetClass, name: a.name,
                                       amount: signed, catalogKey: a.key,
                                       symbol: a.symbol, quantity: a.quantity,
                                       currency: a.currency, autoPriced: a.autoPriced,
                                       unitPriceKRW: a.unitPriceKRW, lastPriced: a.lastPriced)
                context.insert(entry)
                entry.snapshot = snap
                snap.entries.append(entry)
            }
            snap.monthlyPassiveIncome = passive
            snap.liquidNetWorth = liquid
        }

        // 지난 (monthsBack−1)개월 — 매달 25일에 기록한 것으로.
        let expenses: [Double] = [3_100_000, 2_900_000, 3_300_000, 3_000_000, 2_800_000,
                                  3_200_000, 2_900_000, 3_000_000, 3_100_000]
        for j in 0..<(monthsBack - 1) {
            let monthsAgo = (monthsBack - 1) - j
            guard let shifted = cal.date(byAdding: .month, value: -monthsAgo, to: now),
                  let monthStart = cal.dateInterval(of: .month, for: shifted)?.start,
                  let date = cal.date(byAdding: .day, value: 24, to: monthStart) else { continue }
            let values = items.map { $0.history[j] }
            insertSnapshot(date: date, values: values, expense: expenses[j])
        }

        // 이번 달 초·중순 기록 2개 — '이번 달' 카드가 촘촘히 그려지게.
        // 값은 지난달 값과 현재 값 사이를 보간한다. (오늘 이후 날짜는 만들지 않음)
        if let monthStart = cal.dateInterval(of: .month, for: now)?.start {
            for (day, t) in [(4, 0.4), (11, 0.75)] {
                guard let date = cal.date(byAdding: .day, value: day, to: monthStart),
                      date < now else { continue }
                let values = items.map { item -> Double in
                    let prev = item.history[monthsBack - 2]
                    let cur = item.history[monthsBack - 1]
                    return prev + (cur - prev) * t
                }
                insertSnapshot(date: date, values: values, expense: 3_000_000)
            }
        }

        try context.save()
        UserDefaults.standard.set(true, forKey: activeKey)
    }
}
