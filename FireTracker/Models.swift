import Foundation
import SwiftData

// Asset class categories tracked in the app.
enum AssetClass: String, Codable, CaseIterable, Identifiable {
    case stocks      // 주식
    case jeonse      // 전세 (lease deposit)
    case cash        // 현금
    case realEstate  // 부동산
    case crypto      // 암호화폐
    case pension     // 연금
    case debt        // 부채 (대출 등) — reduces net worth
    case other       // 기타

    var id: String { rawValue }

    // Korean UI label.
    var label: String {
        switch self {
        case .stocks:     return "주식"
        case .jeonse:     return "전세"
        case .cash:       return "현금"
        case .realEstate: return "부동산"
        case .crypto:     return "암호화폐"
        case .pension:    return "연금"
        case .debt:       return "부채"
        case .other:      return "기타"
        }
    }

    // True for liabilities — their value subtracts from net worth.
    var isDebt: Bool { self == .debt }

    // Whether a live price/value can be fetched for this class.
    var supportsAutoPrice: Bool {
        switch self {
        case .crypto, .stocks, .realEstate: return true
        default: return false
        }
    }

    var symbolName: String {
        switch self {
        case .stocks:     return "chart.line.uptrend.xyaxis"
        case .jeonse:     return "house.fill"
        case .cash:       return "banknote.fill"
        case .realEstate: return "building.2.fill"
        case .crypto:     return "bitcoinsign.circle.fill"
        case .pension:    return "shield.lefthalf.filled"
        case .debt:       return "creditcard.trianglebadge.exclamationmark"
        case .other:      return "ellipsis.circle.fill"
        }
    }

    // Hex color for the class, used in charts and badges.
    var colorHex: String {
        switch self {
        case .stocks:     return "5B8DEF"
        case .jeonse:     return "E8A33D"
        case .cash:       return "4CAF8E"
        case .realEstate: return "B05BEF"
        case .crypto:     return "EF6B5B"
        case .pension:    return "5BC8EF"
        case .debt:       return "C75D5D"
        case .other:      return "9AA0A6"
        }
    }
}

// A single monthly snapshot of net worth. Holds the aggregate plus the
// itemized asset entries so per-class breakdowns survive over time.
@Model
final class NetWorthSnapshot {
    var date: Date
    var note: String
    // Total monthly income recorded for this period (for savings-rate calc).
    var monthlyIncome: Double
    // Total monthly expense recorded for this period.
    var monthlyExpense: Double
    // Passive cash flow the catalog produced at the time of this record
    // (월세·배당·이자·연금·스테이킹 합계). Captured so the trend can chart it.
    var monthlyPassiveIncome: Double = 0
    // Spendable (liquid) net worth at the time of this record — the money you
    // could actually use, excluding locked assets (실거주 부동산·전세보증금 등).
    var liquidNetWorth: Double = 0

    @Relationship(deleteRule: .cascade, inverse: \AssetEntry.snapshot)
    var entries: [AssetEntry]

    init(date: Date = .now,
         note: String = "",
         monthlyIncome: Double = 0,
         monthlyExpense: Double = 0,
         monthlyPassiveIncome: Double = 0,
         liquidNetWorth: Double = 0,
         entries: [AssetEntry] = []) {
        self.date = date
        self.note = note
        self.monthlyIncome = monthlyIncome
        self.monthlyExpense = monthlyExpense
        self.monthlyPassiveIncome = monthlyPassiveIncome
        self.liquidNetWorth = liquidNetWorth
        self.entries = entries
    }

    // Sum of all asset entries for this snapshot.
    var netWorth: Double {
        entries.reduce(0) { $0 + $1.amount }
    }

    // Savings rate for the period: (income - expense) / income.
    var savingsRate: Double {
        guard monthlyIncome > 0 else { return 0 }
        return (monthlyIncome - monthlyExpense) / monthlyIncome
    }

    var monthlySavings: Double {
        monthlyIncome - monthlyExpense
    }

    // Net worth grouped by asset class.
    func total(for assetClass: AssetClass) -> Double {
        entries.filter { $0.assetClass == assetClass }
            .reduce(0) { $0 + $1.amount }
    }
}

// The kind of cash flow / yield an asset produces.
enum IncomeKind: String, Codable, CaseIterable, Identifiable {
    case none        // 없음
    case rent        // 월세 (임대료)
    case dividend    // 배당
    case interest    // 이자
    case pension     // 연금 수령
    case staking     // 스테이킹 보상
    case other       // 기타

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:     return "없음"
        case .rent:     return "월세(임대료)"
        case .dividend: return "배당"
        case .interest: return "이자"
        case .pension:  return "연금 수령"
        case .staking:  return "스테이킹"
        case .other:    return "기타 소득"
        }
    }

    // Sensible default income kind for an asset class.
    static func suggested(for ac: AssetClass) -> IncomeKind {
        switch ac {
        case .realEstate: return .rent
        case .stocks:     return .dividend
        case .cash:       return .interest
        case .pension:    return .pension
        case .crypto:     return .staking
        default:          return .none
        }
    }

    // Research-based typical annual yield, shown as guidance text (2025 기준).
    var yieldHint: String {
        switch self {
        case .rent:     return "서울 아파트 ~2.4%, 오피스텔 ~5%"
        case .dividend: return "코스피 ~2%, S&P500 ~1.5%, 고배당 ETF ~4.5%"
        case .interest: return "예금 ~3%"
        case .staking:  return "ETH 스테이킹 ~3~4%"
        case .pension:  return "운용수익률 ~3~5%"
        default:        return ""
        }
    }
}

// How quickly an asset can become spendable cash. The real FIRE question is
// not total net worth but how much you can actually use.
enum Liquidity: String, Codable, CaseIterable, Identifiable {
    case liquid   // 유동 — 현금·주식·코인처럼 단기에 현금화 가능
    case locked   // 묶임 — 실거주 부동산·전세보증금·연금처럼 당장 못 씀

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liquid: return "유동 (쓸 수 있음)"
        case .locked: return "묶임 (당장 못 씀)"
        }
    }

    var shortLabel: String {
        switch self {
        case .liquid: return "유동"
        case .locked: return "묶임"
        }
    }

    // Conservative default per class — never overstate spendable money.
    static func suggested(for ac: AssetClass) -> Liquidity {
        switch ac {
        case .cash, .stocks, .crypto, .debt: return .liquid
        case .realEstate, .jeonse, .pension, .other: return .locked
        }
    }
}

// How a real-estate holding is used — drives which inputs (보증금/월세) apply.
enum RealEstateUse: String, Codable, CaseIterable, Identifiable {
    case residence   // 실거주
    case jeonse      // 전세 줌 (보증금만)
    case wolse       // 월세 줌 (월세만)
    case semiJeonse  // 반전세 (보증금 + 월세)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .residence:  return "실거주"
        case .jeonse:     return "전세 줌"
        case .wolse:      return "월세 줌"
        case .semiJeonse: return "반전세"
        }
    }

    var icon: String {
        switch self {
        case .residence:  return "house.fill"
        case .jeonse:     return "key.fill"
        case .wolse:      return "wonsign.circle.fill"
        case .semiJeonse: return "key.horizontal.fill"
        }
    }

    var hasDeposit: Bool { self == .jeonse || self == .semiJeonse }
    var hasRent: Bool { self == .wolse || self == .semiJeonse }
}

// A persistent holding in the user's asset catalog ("내 자산 목록").
// The catalog is the source of truth for *what* you own; recording it at a
// point in time produces a NetWorthSnapshot for tracking.
@Model
final class Asset {
    // Stable identity used to stitch this holding's value across snapshots.
    var key: UUID = UUID()
    var name: String
    var assetClassRaw: String

    // Current scale of the holding.
    var amount: Double          // current value in KRW (source of truth)
    var quantity: Double        // shares / coins (for auto-priced holdings)

    // Auto-pricing configuration.
    var symbol: String          // coin code / ticker / 종목코드 / 법정동코드
    var currency: String        // "KRW" | "USD"
    var autoPriced: Bool
    var unitPriceKRW: Double
    var lastPriced: Date?

    // --- Cash flow / yield this asset produces ---
    var incomeKindRaw: String = IncomeKind.none.rawValue
    // Direct monthly cash flow in KRW (월세·배당·이자 등). Takes priority.
    var monthlyIncome: Double = 0
    // Optional annual yield % — derives monthly income from value when no
    // explicit monthlyIncome is set.
    var annualYieldPct: Double = 0
    // Deposit received by leasing the asset out (전세 보증금). A liability that
    // reduces net worth but is cash you can redeploy elsewhere.
    var depositReceived: Double = 0

    // Acquisition cost (취득가) — what you paid. Drives the 평가 차익 (capital gain).
    var costBasis: Double = 0

    // For real estate: 실거주 / 전세 / 월세 / 반전세.
    var realEstateUseRaw: String = RealEstateUse.residence.rawValue

    // Whether this holding's value is actually spendable.
    var liquidityRaw: String = Liquidity.liquid.rawValue

    var sortOrder: Int
    var createdAt: Date

    init(name: String = "",
         assetClass: AssetClass = .stocks,
         amount: Double = 0,
         quantity: Double = 0,
         symbol: String = "",
         currency: String = "KRW",
         autoPriced: Bool = false,
         unitPriceKRW: Double = 0,
         lastPriced: Date? = nil,
         incomeKind: IncomeKind = .none,
         monthlyIncome: Double = 0,
         annualYieldPct: Double = 0,
         depositReceived: Double = 0,
         costBasis: Double = 0,
         realEstateUse: RealEstateUse = .residence,
         liquidity: Liquidity? = nil,
         sortOrder: Int = 0,
         createdAt: Date = .now) {
        self.key = UUID()
        self.name = name
        self.assetClassRaw = assetClass.rawValue
        self.amount = amount
        self.quantity = quantity
        self.symbol = symbol
        self.currency = currency
        self.autoPriced = autoPriced
        self.unitPriceKRW = unitPriceKRW
        self.lastPriced = lastPriced
        self.incomeKindRaw = incomeKind.rawValue
        self.monthlyIncome = monthlyIncome
        self.annualYieldPct = annualYieldPct
        self.depositReceived = depositReceived
        self.costBasis = costBasis
        self.realEstateUseRaw = realEstateUse.rawValue
        self.liquidityRaw = (liquidity ?? Liquidity.suggested(for: assetClass)).rawValue
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var assetClass: AssetClass {
        get { AssetClass(rawValue: assetClassRaw) ?? .other }
        set { assetClassRaw = newValue.rawValue }
    }

    var incomeKind: IncomeKind {
        get { IncomeKind(rawValue: incomeKindRaw) ?? .none }
        set { incomeKindRaw = newValue.rawValue }
    }

    var realEstateUse: RealEstateUse {
        get { RealEstateUse(rawValue: realEstateUseRaw) ?? .residence }
        set { realEstateUseRaw = newValue.rawValue }
    }

    var liquidity: Liquidity {
        get { Liquidity(rawValue: liquidityRaw) ?? .liquid }
        set { liquidityRaw = newValue.rawValue }
    }

    var isDebt: Bool { assetClass == .debt }

    // Net contribution to net worth. Debts subtract. For other assets the full
    // value counts: a 전세 deposit you received is cash you hold, which offsets
    // the obligation to return it, so net worth is unchanged by the deposit.
    var netValue: Double { isDebt ? -amount : amount }

    // The 전세 deposit received is held as liquid cash; the rest of the value is
    // the asset's own equity, liquid only if the asset itself is liquid.
    // e.g. 10억 아파트 + 4.2억 전세(묶임) → 현금 4.2억(유동) + 부동산 5.8억(묶임).
    var depositCash: Double { min(depositReceived, amount) }
    var equityValue: Double { amount - depositCash }

    // Spendable assets. Debt is excluded. Deposit cash is always liquid; the
    // remaining equity counts only if the asset is liquid.
    var liquidValue: Double {
        if isDebt { return 0 }
        let equityLiquid = liquidity == .liquid ? equityValue : 0
        return depositCash + equityLiquid
    }

    // Monthly cash flow the asset produces. Debts don't feed cash flow here —
    // they only reduce net worth & spendable money.
    var effectiveMonthlyIncome: Double {
        if isDebt { return 0 }
        if monthlyIncome > 0 { return monthlyIncome }
        if annualYieldPct > 0 { return amount * annualYieldPct / 100 / 12 }
        return 0
    }

    var annualIncome: Double { effectiveMonthlyIncome * 12 }

    // Capital gain (평가 차익) vs. acquisition cost — value the asset created by
    // appreciating. Zero for debt or when no cost basis is recorded.
    var hasCostBasis: Bool { !isDebt && costBasis > 0 }
    var gain: Double { hasCostBasis ? amount - costBasis : 0 }
    var gainRate: Double { hasCostBasis ? (amount - costBasis) / costBasis : 0 }
}

// One asset line item inside a snapshot.
@Model
final class AssetEntry {
    var assetClassRaw: String
    var name: String
    var amount: Double
    // Links back to the catalog Asset (Asset.key) for per-asset time series.
    var catalogKey: UUID?

    // --- Auto-pricing metadata (used when the value is fetched live) ---
    // Coin code (BTC), stock ticker/종목코드 (AAPL / 005930), or 법정동코드 5자리.
    var symbol: String = ""
    // Holdings: number of coins or shares. Unused for real estate.
    var quantity: Double = 0
    // "KRW" or "USD". For stocks this also selects the source:
    // KRW → 한국투자증권(KIS), USD → Finnhub + 환율 환산.
    var currency: String = "KRW"
    // When true, `amount` is derived from a live quote (read-only in the editor).
    var autoPriced: Bool = false
    // Last fetched unit price, already converted to KRW (for display).
    var unitPriceKRW: Double = 0
    var lastPriced: Date?

    var snapshot: NetWorthSnapshot?

    init(assetClass: AssetClass,
         name: String = "",
         amount: Double = 0,
         catalogKey: UUID? = nil,
         symbol: String = "",
         quantity: Double = 0,
         currency: String = "KRW",
         autoPriced: Bool = false,
         unitPriceKRW: Double = 0,
         lastPriced: Date? = nil) {
        self.assetClassRaw = assetClass.rawValue
        self.name = name
        self.amount = amount
        self.catalogKey = catalogKey
        self.symbol = symbol
        self.quantity = quantity
        self.currency = currency
        self.autoPriced = autoPriced
        self.unitPriceKRW = unitPriceKRW
        self.lastPriced = lastPriced
    }

    var assetClass: AssetClass {
        get { AssetClass(rawValue: assetClassRaw) ?? .other }
        set { assetClassRaw = newValue.rawValue }
    }
}

// Singleton-style settings driving the FIRE projection math.
@Model
final class FireSettings {
    // Target annual expense in retirement (KRW).
    var targetAnnualExpense: Double
    // Safe withdrawal rate, e.g. 0.04 = 4% rule.
    var safeWithdrawalRate: Double
    // Expected real annual return on invested assets.
    var expectedAnnualReturn: Double
    // Currency display unit divisor: 10_000 means amounts shown in 만원.
    var displayUnit: Double

    // --- Projection (올해 말 예측) ---
    // After-tax monthly take-home (세후 월급).
    var monthlyTakeHome: Double = 0
    // Planned monthly spending used for the savings projection.
    var plannedMonthlyExpense: Double = 0

    // Monthly savings used to project forward.
    var plannedMonthlySavings: Double { monthlyTakeHome - plannedMonthlyExpense }

    // --- API credentials for live price lookups (entered in 설정) ---
    // Finnhub token — 미국 주식 시세.
    var finnhubKey: String = ""
    // 한국투자증권 KIS OpenAPI — 국내 주식 시세.
    var kisAppKey: String = ""
    var kisAppSecret: String = ""
    // 공공데이터포털 서비스키(Decoding) — 국토부 아파트 실거래가.
    var dataGoKey: String = ""

    init(targetAnnualExpense: Double = 36_000_000,
         safeWithdrawalRate: Double = 0.04,
         expectedAnnualReturn: Double = 0.05,
         displayUnit: Double = 10_000,
         monthlyTakeHome: Double = 0,
         plannedMonthlyExpense: Double = 0,
         finnhubKey: String = "",
         kisAppKey: String = "",
         kisAppSecret: String = "",
         dataGoKey: String = "") {
        self.targetAnnualExpense = targetAnnualExpense
        self.safeWithdrawalRate = safeWithdrawalRate
        self.expectedAnnualReturn = expectedAnnualReturn
        self.displayUnit = displayUnit
        self.monthlyTakeHome = monthlyTakeHome
        self.plannedMonthlyExpense = plannedMonthlyExpense
        self.finnhubKey = finnhubKey
        self.kisAppKey = kisAppKey
        self.kisAppSecret = kisAppSecret
        self.dataGoKey = dataGoKey
    }

    // The number you must hit to be financially independent.
    var fireNumber: Double {
        guard safeWithdrawalRate > 0 else { return 0 }
        return targetAnnualExpense / safeWithdrawalRate
    }
}
