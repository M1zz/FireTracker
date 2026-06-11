import Foundation
import SwiftData

// Asset class categories tracked in the app. Ordered roughly 현금성 → 투자 →
// 부동산·실물 → 권리·채권 → 기타 → 부채, which is also the picker order.
enum AssetClass: String, Codable, CaseIterable, Identifiable {
    case cash        // 현금·예금 (보통/정기예금, MMF·CMA 등 단기금융 포함)
    case stocks      // 주식
    case fund        // 펀드·ETF
    case bond        // 채권
    case crypto      // 암호화폐
    case pension     // 연금
    case insurance   // 보험 (해지환급금)
    case realEstate  // 부동산
    case jeonse      // 전세보증금 (내가 맡긴 보증금)
    case deposit     // 보증금 (월세·기타 보증금)
    case vehicle     // 자동차
    case valuables   // 귀금속·미술품
    case receivable  // 받을 돈 (대여금·미수금)
    case ip          // 지식재산권·권리금
    case other       // 기타
    case custom      // 직접 입력 (사용자 지정)
    case debt        // 부채 (대출 등) — reduces net worth

    var id: String { rawValue }

    // Korean UI label.
    var label: String {
        switch self {
        case .cash:       return "현금·예금"
        case .stocks:     return "주식"
        case .fund:       return "펀드·ETF"
        case .bond:       return "채권"
        case .crypto:     return "암호화폐"
        case .pension:    return "연금"
        case .insurance:  return "보험"
        case .realEstate: return "부동산"
        case .jeonse:     return "전세보증금"
        case .deposit:    return "보증금"
        case .vehicle:    return "자동차"
        case .valuables:  return "귀금속·미술품"
        case .receivable: return "받을 돈"
        case .ip:         return "지식재산권"
        case .other:      return "기타"
        case .custom:     return "직접 입력"
        case .debt:       return "부채"
        }
    }

    // True for liabilities — their value subtracts from net worth.
    var isDebt: Bool { self == .debt }

    // Whether a live price/value can be fetched for this class.
    // 펀드·ETF는 ETF처럼 티커/종목코드로 거래되는 경우 주식과 동일하게 조회 가능.
    var supportsAutoPrice: Bool {
        switch self {
        case .crypto, .stocks, .fund, .realEstate: return true
        default: return false
        }
    }

    // 취득가 대비 평가차익(부가가치) 입력이 의미 있는 자산 — 사서 값이 오르내리는 것.
    var tracksCostBasis: Bool {
        switch self {
        case .stocks, .fund, .crypto, .realEstate, .vehicle, .valuables: return true
        default: return false
        }
    }

    // 이 자산이 만들 수 있는 현금흐름 종류(소득 유형 선택지). 빈 배열이면 소득 섹션을
    // 숨긴다. 부동산은 이용형태(월세)로 따로 처리하므로 여기선 빈 배열.
    var incomeKinds: [IncomeKind] {
        switch self {
        case .cash:           return [.none, .interest]
        case .stocks:         return [.none, .dividend]
        case .fund:           return [.none, .dividend, .interest]
        case .bond:           return [.none, .interest]
        case .crypto:         return [.none, .staking]
        case .pension:        return [.pension]
        case .receivable:     return [.none, .interest]
        case .ip:             return [.none, .other]
        case .other, .custom: return [.none, .interest, .dividend, .other]
        default:              return []   // insurance·전세보증금·보증금·자동차·귀금속·부동산·부채
        }
    }

    var symbolName: String {
        switch self {
        case .cash:       return "banknote.fill"
        case .stocks:     return "chart.line.uptrend.xyaxis"
        case .fund:       return "chart.pie.fill"
        case .bond:       return "doc.text.fill"
        case .crypto:     return "bitcoinsign.circle.fill"
        case .pension:    return "shield.lefthalf.filled"
        case .insurance:  return "cross.case.fill"
        case .realEstate: return "building.2.fill"
        case .jeonse:     return "house.fill"
        case .deposit:    return "lock.square.fill"
        case .vehicle:    return "car.fill"
        case .valuables:  return "sparkles"
        case .receivable: return "arrow.down.left.circle.fill"
        case .ip:         return "lightbulb.fill"
        case .other:      return "ellipsis.circle.fill"
        case .custom:     return "square.and.pencil"
        case .debt:       return "creditcard.trianglebadge.exclamationmark"
        }
    }

    // Hex color for the class, used in charts and badges.
    var colorHex: String {
        switch self {
        case .cash:       return "4CAF8E"
        case .stocks:     return "5B8DEF"
        case .fund:       return "5BA3C7"
        case .bond:       return "7E9B5B"
        case .crypto:     return "EF6B5B"
        case .pension:    return "5BC8EF"
        case .insurance:  return "5BC7A3"
        case .realEstate: return "B05BEF"
        case .jeonse:     return "E8A33D"
        case .deposit:    return "C7A15B"
        case .vehicle:    return "8A8F98"
        case .valuables:  return "C75DA0"
        case .receivable: return "B0C75B"
        case .ip:         return "9B7EDE"
        case .other:      return "9AA0A6"
        case .custom:     return "78A1B8"
        case .debt:       return "C75D5D"
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
    // Net monthly savings (수입 − 지출) entered directly, for when the user
    // doesn't want to split income/expense. Used when both of those are 0.
    var monthlyNetSavings: Double = 0
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
         monthlyNetSavings: Double = 0,
         monthlyPassiveIncome: Double = 0,
         liquidNetWorth: Double = 0,
         entries: [AssetEntry] = []) {
        self.date = date
        self.note = note
        self.monthlyIncome = monthlyIncome
        self.monthlyExpense = monthlyExpense
        self.monthlyNetSavings = monthlyNetSavings
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
        if monthlyIncome > 0 || monthlyExpense > 0 {
            return monthlyIncome - monthlyExpense
        }
        return monthlyNetSavings
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
        case .realEstate:        return .rent
        case .stocks, .fund:     return .dividend
        case .cash, .bond, .receivable: return .interest
        case .pension:           return .pension
        case .crypto:            return .staking
        default:                 return .none
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
        case .cash, .stocks, .fund, .bond, .crypto, .debt:
            return .liquid
        case .realEstate, .jeonse, .deposit, .pension, .insurance,
             .vehicle, .valuables, .receivable, .ip, .other, .custom:
            return .locked
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
    // User-typed category name, used when assetClass == .custom (직접 입력).
    var customLabel: String = ""

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

    // 세부 종목 — 카테고리 금액(예: 주식 3,000만원)을 종목별로 쪼개 할당한 내역.
    // 평가액(amount)이 진실의 원천이고, 세부 종목은 그 안의 구성을 보여준다.
    @Relationship(deleteRule: .cascade, inverse: \AssetDetail.asset)
    var details: [AssetDetail] = []

    init(name: String = "",
         assetClass: AssetClass = .stocks,
         customLabel: String = "",
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
        self.customLabel = customLabel
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

    // Category label for display: the user-typed name for 직접 입력, else the
    // built-in class label.
    var displayClassLabel: String {
        if assetClass == .custom, !customLabel.isEmpty { return customLabel }
        return assetClass.label
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

    // Monthly cash flow the asset produces. Debts don't feed income here —
    // they only reduce net worth & spendable money. Their cost is separate.
    var effectiveMonthlyIncome: Double {
        if isDebt { return 0 }
        if monthlyIncome > 0 { return monthlyIncome }
        if annualYieldPct > 0 { return amount * annualYieldPct / 100 / 12 }
        return 0
    }

    var annualIncome: Double { effectiveMonthlyIncome * 12 }

    // Money a debt pulls out every month — 이자/상환. Entered as a direct monthly
    // amount, or derived from an annual interest rate on the balance.
    var monthlyDebtCost: Double {
        guard isDebt else { return 0 }
        if monthlyIncome > 0 { return monthlyIncome }
        if annualYieldPct > 0 { return amount * annualYieldPct / 100 / 12 }
        return 0
    }

    // Capital gain (평가 차익) vs. acquisition cost — value the asset created by
    // appreciating. Zero for debt or when no cost basis is recorded.
    var hasCostBasis: Bool { !isDebt && costBasis > 0 }
    var gain: Double { hasCostBasis ? amount - costBasis : 0 }
    var gainRate: Double { hasCostBasis ? (amount - costBasis) / costBasis : 0 }

    // --- 세부 종목 할당 ---
    var sortedDetails: [AssetDetail] { details.sorted { $0.sortOrder < $1.sortOrder } }
    // 종목에 할당된 금액 합과, 평가액에서 아직 할당하지 않은 잔액.
    var allocatedAmount: Double { details.reduce(0) { $0 + $1.amount } }
    var unallocatedAmount: Double { amount - allocatedAmount }
}

// 자산 안의 세부 종목 한 줄 — 이름 + 할당 금액. 예) 주식 3,000만원 중
// 삼성전자 1,000만 · 애플 2,000만.
@Model
final class AssetDetail {
    var name: String
    var amount: Double
    var sortOrder: Int
    var asset: Asset?

    init(name: String = "", amount: Double = 0, sortOrder: Int = 0) {
        self.name = name
        self.amount = amount
        self.sortOrder = sortOrder
    }
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

// What "FIRE 달성" is measured against.
enum FireGoalType: String, Codable, CaseIterable, Identifiable {
    case assets   // 순자산이 FIRE 목표 금액에 도달
    case income   // 월 패시브 인컴이 원하는 월 지출을 커버
    case both     // 둘 다
    var id: String { rawValue }
    var label: String {
        switch self {
        case .assets: return "자산"
        case .income: return "패시브 인컴"
        case .both:   return "둘 다"
        }
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
    // Net monthly savings (수입 − 지출) entered directly. Takes priority over the
    // salary/spending breakdown when set, so the user can skip the split.
    var plannedNetSavings: Double = 0

    // Monthly savings used to project forward.
    var plannedMonthlySavings: Double {
        plannedNetSavings != 0 ? plannedNetSavings : monthlyTakeHome - plannedMonthlyExpense
    }

    // Rough annual dividend / passive income entered by hand, for people who
    // don't want to fill in each holding's dividend. Added on top of the
    // per-asset cash flow; its monthly share feeds the dashboard & snapshots.
    var manualAnnualDividend: Double = 0
    var manualMonthlyDividend: Double { manualAnnualDividend / 12 }

    // --- 목표 측정 기준 & 기간(은퇴 시점) ---
    // Whether 달성률 is measured by assets, passive income, or both.
    var fireGoalTypeRaw: String = FireGoalType.both.rawValue
    var fireGoalType: FireGoalType {
        get { FireGoalType(rawValue: fireGoalTypeRaw) ?? .both }
        set { fireGoalTypeRaw = newValue.rawValue }
    }
    // Ages drive the milestone trajectory (이번달·올해·5년·은퇴).
    var currentAge: Int = 0
    var targetRetireAge: Int = 0
    // Months from now until the target retirement age (nil until both ages set).
    var monthsToRetire: Int? {
        guard currentAge > 0, targetRetireAge > currentAge else { return nil }
        return (targetRetireAge - currentAge) * 12
    }
    // The passive-income FIRE goal: the monthly spending you want covered.
    var incomeGoalMonthly: Double { targetAnnualExpense / 12 }

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
         plannedNetSavings: Double = 0,
         manualAnnualDividend: Double = 0,
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
        self.plannedNetSavings = plannedNetSavings
        self.manualAnnualDividend = manualAnnualDividend
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
