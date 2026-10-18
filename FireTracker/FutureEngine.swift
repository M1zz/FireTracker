//
//  FutureEngine.swift
//  FireTracker
//
//  퇴사 그날 미리보기의 계산 엔진 — 화면과 무관한 순수 계산만 둔다.
//
//  1) 퇴사 후 고정비: 지역가입자 건강보험료 · 임의계속가입 · 피부양자 가능성 ·
//     국민연금 임의가입 · 실업급여
//  2) 인출 순서: 일반계좌 · ISA · 연금계좌(연금저축+IRP)를 어떤 순서로 꺼내야 세금이 적은지
//  3) 몬테카를로: 수천 가지 시장 흐름에서 돈이 몇 살까지 버티는지
//  4) 시나리오: 퇴사 시점·저축·생활비를 바꾼 계획끼리 비교
//
//  제도 숫자는 2026년 기준(KoreaRules2026)이고, 출처끼리 엇갈리는 값은 사용자가
//  고칠 수 있는 '가정'으로 화면에 드러낸다. 모든 금액은 원, 오늘 돈 기준(실질)이다.
//

import Foundation

// MARK: - 2026년 제도 숫자

enum KoreaRules2026 {
    // 건강보험
    static let healthRate = 0.0719               // 건강보험료율(직장·지역 소득)
    static let longTermCareRatio = 0.1314        // 장기요양 = 건보료 × 13.14%
    static let propertyPointValue = 211.5        // 지역 재산 점수당 금액(원)
    static let propertyBaseDeduction = 100_000_000.0 // 재산 기본공제 1억
    static let healthMinimum = 20_160.0          // 월 하한(건보료)
    static let healthMaximum = 4_591_740.0       // 월 상한(건보료)
    static let financialIncomeThreshold = 10_000_000.0 // 이자·배당 이 금액 초과 시 전액 반영
    static let rentDepositRatio = 0.30           // 전월세 보증금 평가 비율
    static let dependentIncomeLimit = 20_000_000.0
    static let dependentPropertyLimit = 540_000_000.0
    static let dependentPropertyUpper = 900_000_000.0
    static let dependentIncomeLimitHigh = 10_000_000.0 // 5.4억~9억 구간 소득 한도

    // 국민연금 — 2026년 9.5%, 해마다 0.5%p 올라 2033년 13%
    static func pensionRate(year: Int) -> Double {
        min(0.13, 0.095 + 0.005 * Double(max(0, year - 2026)))
    }
    static let pensionVoluntaryEndAge = 60

    // 실업급여(구직급여)
    static let unemploymentDailyMin = 66_048.0
    static let unemploymentDailyMax = 68_100.0

    // 연금계좌
    static let pensionStartAge = 55
    static let pensionLowTaxLimit = 15_000_000.0 // 사적연금 연 1,500만원까지 저율 분리과세
    static let pensionOverTaxRate = 0.165        // 초과 시 전액 16.5% 분리과세 선택 가정
    static let pensionEarlyTaxRate = 0.165       // 55세 전·한도 초과 인출(기타소득세)
    static func pensionTaxRate(age: Int) -> Double {
        age >= 80 ? 0.033 : age >= 70 ? 0.044 : 0.055
    }

    // ISA
    static let isaOverTaxRate = 0.099

    /// 재산등급별 점수 — 국민건강보험법 시행령 [별표 4]. (상한 만원, 점수)
    static let propertyScoreTable: [(upperManwon: Double, score: Double)] = [
        (450, 22), (900, 44), (1_350, 66), (1_800, 97), (2_250, 122),
        (2_700, 146), (3_150, 171), (3_600, 195), (4_050, 219), (4_500, 244),
        (5_020, 268), (5_590, 294), (6_220, 320), (6_930, 344), (7_710, 365),
        (8_590, 386), (9_570, 412), (10_700, 439), (11_900, 465), (13_300, 490),
        (14_800, 516), (16_400, 535), (18_300, 559), (20_400, 586), (22_700, 611),
        (25_300, 637), (28_100, 659), (31_300, 681), (34_900, 706), (38_800, 731),
        (43_200, 757), (48_100, 785), (53_600, 812), (59_700, 841), (66_500, 881),
        (74_000, 921), (82_400, 961), (91_800, 1_001), (103_000, 1_041), (114_000, 1_091),
        (127_000, 1_141), (142_000, 1_191), (158_000, 1_241), (176_000, 1_291), (196_000, 1_341),
        (218_000, 1_391), (242_000, 1_451), (270_000, 1_511), (300_000, 1_571), (330_000, 1_641),
        (363_000, 1_711), (399_300, 1_781), (439_230, 1_851), (483_153, 1_921), (531_468, 1_991),
        (584_615, 2_061), (643_077, 2_131), (707_385, 2_201), (778_124, 2_271),
    ]
    static let propertyScoreTop = 2_341.0

    static func propertyScore(base: Double) -> Double {
        guard base > 0 else { return 0 }
        let manwon = base / 10_000
        for row in propertyScoreTable where manwon <= row.upperManwon { return row.score }
        return propertyScoreTop
    }

    /// 구직급여 소정급여일수 — (피보험기간, 50세 이상·장애인 여부).
    static func unemploymentDays(insuredYears: Double, age50Plus: Bool) -> Int {
        switch insuredYears {
        case ..<1:  return 120
        case ..<3:  return age50Plus ? 180 : 150
        case ..<5:  return age50Plus ? 210 : 180
        case ..<10: return age50Plus ? 240 : 210
        default:    return age50Plus ? 270 : 240
        }
    }
}

// MARK: - 사용자가 넣는 미래 프로필

/// 미리보기 전체가 같이 쓰는 입력. 스키마 변경 없이 UserDefaults 에 JSON 으로 둔다.
struct FutureProfile: Codable, Equatable {
    // 시점
    var quitAge: Int = 0            // 0이면 퇴사각 계산값(목표 자산 도달 나이)
    var endAge: Int = 95

    // 생활비·시장 가정(실질)
    var monthlySpend: Double = 0    // 0이면 목표 생활비(설정)
    var realReturnPct: Double = 4.0
    var volatilityPct: Double = 12.0

    // 건강보험
    var lastMonthlySalary: Double = 0      // 퇴사 직전 세전 월급(보수월액)
    var yearsEmployed: Double = 3          // 퇴사 직전 18개월 안에서 직장가입 1년 이상이면 임의계속 가능
    var housePublicPrice: Double = 0       // 보유 주택 공시가격 합
    var housePriceRatio: Double = 60       // 공시가격 → 재산 과표 비율(%) 가정
    var otherPropertyBase: Double = 0      // 토지·건물 등 다른 재산 과표
    var rentDepositPaid: Double = 0        // 내가 낸 전월세 보증금
    var annualFinancialIncome: Double = 0  // 이자·배당(연)
    var annualOtherIncome: Double = 0      // 사업·기타·근로 소득(연, 퇴사 후)
    var hasFamilyEmployee: Bool = false    // 피부양자로 올라갈 직장가입자 가족이 있는지

    // 국민연금
    var publicPensionMonthly: Double = 0   // 예상 노령연금 월액(오늘 돈)
    var publicPensionStartAge: Int = 65
    var voluntaryPension: Bool = false     // 퇴사 후 60세까지 임의가입
    var voluntaryBaseIncome: Double = 1_000_000

    // 실업급여
    var involuntaryQuit: Bool = false      // 권고사직·계약만료 등 비자발적 퇴사
    var averageDailyWage: Double = 0       // 퇴사 전 3개월 평균임금 일액

    // 계좌(퇴사 시점 기준 비중으로 나눈다)
    var pensionAccountShare: Double = 0    // 연금저축+IRP 비중(%) — 0이면 자산에서 추정
    var isaShare: Double = 0               // ISA 비중(%)
    var isaGainRatio: Double = 30          // ISA 평가액 중 수익 비율(%)
    var isaTaxFreeLimit: Double = 2_000_000

    static let storageKey = "future.profile"

    static func load() -> FutureProfile {
        guard let s = UserDefaults.standard.string(forKey: storageKey),
              let d = s.data(using: .utf8),
              let p = try? JSONDecoder().decode(FutureProfile.self, from: d) else { return FutureProfile() }
        return p
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: Self.storageKey)
    }
}

// MARK: - 1) 퇴사 후 고정비

struct PostQuitCosts {
    struct Health {
        let incomeMonthly: Double       // 보험료 산정 소득월액
        let incomePremium: Double
        let propertyBase: Double        // 공제 후 재산 과표
        let propertyScore: Double
        let propertyPremium: Double
        let total: Double               // 장기요양 포함 월액
    }
    let regional: Health
    let continued: Double?              // 임의계속가입 월액(장기요양 포함). 자격 없으면 nil
    let dependentPossible: Bool
    let bestHealthMonthly: Double
    let bestHealthLabel: String
    let voluntaryPensionMonthly: Double
    let unemploymentTotal: Double
    let unemploymentDays: Int
    let unemploymentDaily: Double

    /// 퇴사 후 매달 새로 생기는 고정비(건보료 최선안 + 국민연금 임의가입).
    var monthlyFixed: Double { bestHealthMonthly + voluntaryPensionMonthly }

    static func compute(_ p: FutureProfile, quitAge: Int, quitYear: Int) -> PostQuitCosts {
        typealias R = KoreaRules2026
        // 지역가입자 소득: 이자·배당은 1천만원 초과 시 전액, 공적연금은 50%(퇴사 직후엔 보통 0).
        let fin = p.annualFinancialIncome > R.financialIncomeThreshold ? p.annualFinancialIncome : 0
        let pensionCounted = quitAge >= p.publicPensionStartAge ? p.publicPensionMonthly * 12 * 0.5 : 0
        let incomeMonthly = (fin + p.annualOtherIncome + pensionCounted) / 12
        let incomePremium = incomeMonthly * R.healthRate

        let rawBase = p.housePublicPrice * p.housePriceRatio / 100
            + p.otherPropertyBase
            + p.rentDepositPaid * R.rentDepositRatio
        let base = max(0, rawBase - R.propertyBaseDeduction)
        let score = R.propertyScore(base: base)
        let propertyPremium = score * R.propertyPointValue
        let health = min(R.healthMaximum, max(R.healthMinimum, incomePremium + propertyPremium))
        let regional = Health(incomeMonthly: incomeMonthly, incomePremium: incomePremium,
                              propertyBase: base, propertyScore: score,
                              propertyPremium: propertyPremium,
                              total: health * (1 + R.longTermCareRatio))

        // 임의계속가입: 직전 12개월 평균 보수월액 기준. 회사 몫까지 본인이 내지만 고시로 50% 경감돼
        // 결국 다닐 때 월급에서 빠지던 금액과 같다.
        var continued: Double?
        if p.yearsEmployed >= 1, p.lastMonthlySalary > 0 {
            let h = min(R.healthMaximum, p.lastMonthlySalary * R.healthRate) * 0.5
            continued = h * (1 + R.longTermCareRatio)
        }

        // 피부양자: 재산 과표(공제 전, 보증금 제외) + 연소득(사적연금 제외) 기준.
        let depProperty = p.housePublicPrice * p.housePriceRatio / 100 + p.otherPropertyBase
        let depIncome = p.annualFinancialIncome + p.annualOtherIncome
            + (quitAge >= p.publicPensionStartAge ? p.publicPensionMonthly * 12 : 0)
        let dependentOK = p.hasFamilyEmployee && depIncome <= R.dependentIncomeLimit
            && (depProperty <= R.dependentPropertyLimit
                || (depProperty <= R.dependentPropertyUpper && depIncome <= R.dependentIncomeLimitHigh))

        let best: (Double, String)
        if dependentOK {
            best = (0, String(localized: "가족의 피부양자"))
        } else if let c = continued, c < regional.total {
            best = (c, String(localized: "임의계속가입(최대 3년)"))
        } else {
            best = (regional.total, String(localized: "지역가입자"))
        }

        let voluntary = p.voluntaryPension && quitAge < R.pensionVoluntaryEndAge
            ? p.voluntaryBaseIncome * R.pensionRate(year: quitYear) : 0

        var uDays = 0, uDaily = 0.0, uTotal = 0.0
        if p.involuntaryQuit, p.yearsEmployed >= 0.5 {
            uDays = R.unemploymentDays(insuredYears: p.yearsEmployed, age50Plus: quitAge >= 50)
            uDaily = min(R.unemploymentDailyMax, max(R.unemploymentDailyMin, p.averageDailyWage * 0.6))
            uTotal = uDaily * Double(uDays)
        }

        return PostQuitCosts(regional: regional, continued: continued,
                             dependentPossible: dependentOK,
                             bestHealthMonthly: best.0, bestHealthLabel: best.1,
                             voluntaryPensionMonthly: voluntary,
                             unemploymentTotal: uTotal, unemploymentDays: uDays,
                             unemploymentDaily: uDaily)
    }
}

// MARK: - 2) 인출 순서

struct WithdrawalPlan {
    struct Year: Identifiable {
        let age: Int
        var id: Int { age }
        let taxable: Double
        let isa: Double
        let pension: Double
        let tax: Double
        let remaining: Double
    }
    let years: [Year]
    let totalTax: Double
    let depletionAge: Int?   // 돈이 바닥나는 나이, 끝까지 버티면 nil

    enum Strategy { case smart, naive }

    /// - Parameters:
    ///   - taxable/isa/pension: 퇴사 시점 계좌 잔액
    ///   - annualSpend: 연 생활비(실질, 고정비 포함)
    ///   - publicPension: 국민연금 연액, startAge 부터
    static func simulate(strategy: Strategy,
                         taxable: Double, isa: Double, pension: Double,
                         isaGainRatio: Double, isaTaxFreeLimit: Double,
                         annualSpend: Double, publicPension: Double, publicPensionStart: Int,
                         quitAge: Int, endAge: Int, realReturn: Double) -> WithdrawalPlan {
        typealias R = KoreaRules2026
        var t = taxable, i = isa, p = pension
        var isaTaxPaid = false
        var rows: [Year] = []
        var totalTax = 0.0
        var depletion: Int?
        var pensionYear = 0   // 연금 수령 연차

        guard quitAge < endAge else { return WithdrawalPlan(years: [], totalTax: 0, depletionAge: nil) }
        for age in quitAge..<endAge {
            var need = max(0, annualSpend - (age >= publicPensionStart ? publicPension : 0))
            var fromT = 0.0, fromI = 0.0, fromP = 0.0, tax = 0.0

            // ISA는 처음 꺼낼 때 수익에 대한 세금을 한 번 정산한다(비과세 한도 초과분 9.9%).
            func takeISA(_ want: Double) {
                guard want > 0, i > 0 else { return }
                if !isaTaxPaid {
                    let gain = i * isaGainRatio / 100
                    let t0 = max(0, gain - isaTaxFreeLimit) * R.isaOverTaxRate
                    tax += t0; i -= t0; isaTaxPaid = true
                }
                let x = min(want, i); i -= x; fromI += x; need -= x
            }
            func takeTaxable(_ want: Double) {
                guard want > 0, t > 0 else { return }
                // 국내 상장주식 매매차익은 비과세, 배당세는 보유 중 이미 냈다고 본다.
                let x = min(want, t); t -= x; fromT += x; need -= x
            }
            func pensionLimit() -> Double {
                let n = pensionYear + 1
                return n <= 10 ? p / Double(11 - n) * 1.2 : .infinity
            }
            /// 연금계좌에서 세후 `want` 를 받도록 꺼낸다. lowTaxCap 안쪽은 저율, 넘으면 16.5%.
            func takePension(_ want: Double, cap: Double) {
                guard want > 0, p > 0 else { return }
                let early = age < R.pensionStartAge
                let rate = early ? R.pensionEarlyTaxRate : R.pensionTaxRate(age: age)
                let gross = min(p, cap, want / (1 - rate))
                let tx = gross * rate
                p -= gross; fromP += gross; tax += tx; need -= (gross - tx)
            }

            switch strategy {
            case .smart:
                if age < R.pensionStartAge {
                    takeTaxable(need); takeISA(need)
                    takePension(need, cap: .infinity)
                } else {
                    // 저율 한도(1,500만원·수령한도) 안에서 연금 먼저 → 일반 → ISA → 마지막에 연금 초과분.
                    takePension(need, cap: min(R.pensionLowTaxLimit, pensionLimit()))
                    takeTaxable(need); takeISA(need)
                    if need > 0, p > 0 {
                        // 그래도 모자라면 연금을 더 꺼낸다. 1,500만원을 넘기면 그해 사적연금 전액이
                        // 16.5%로 바뀌므로, 이미 꺼낸 몫에도 세율 차이만큼 더 낸다(어림).
                        let rate = R.pensionOverTaxRate
                        let surcharge = fromP * (rate - R.pensionTaxRate(age: age))
                        need += surcharge
                        let gross = min(p, need / (1 - rate))
                        p -= gross; fromP += gross
                        tax += gross * rate + surcharge
                        need -= gross * (1 - rate)
                    }
                }
            case .naive:
                // 가장 흔한 실수: 55세가 되면 연금부터 필요한 만큼 한꺼번에 꺼낸다.
                if age < R.pensionStartAge {
                    takeTaxable(need); takeISA(need)
                    takePension(need, cap: .infinity)
                } else {
                    let low = R.pensionTaxRate(age: age)
                    let grossLow = need / (1 - low)
                    let rate = grossLow > R.pensionLowTaxLimit ? R.pensionOverTaxRate : low
                    let gross = min(p, need / (1 - rate))
                    p -= gross; fromP += gross; tax += gross * rate; need -= gross * (1 - rate)
                    takeTaxable(need); takeISA(need)
                }
            }
            if age >= R.pensionStartAge, fromP > 0 { pensionYear += 1 }

            totalTax += tax
            if need > 1, depletion == nil { depletion = age }
            // 남은 돈은 그해 수익률만큼 자란다.
            t *= 1 + realReturn; i *= 1 + realReturn; p *= 1 + realReturn
            rows.append(Year(age: age, taxable: fromT, isa: fromI, pension: fromP, tax: tax,
                             remaining: t + i + p))
        }
        return WithdrawalPlan(years: rows, totalTax: totalTax, depletionAge: depletion)
    }
}

// MARK: - 3) 몬테카를로

struct MonteCarloResult {
    struct Band: Identifiable {
        let age: Int
        var id: Int { age }
        let p10: Double
        let p50: Double
        let p90: Double
    }
    let successRate: Double          // 끝 나이까지 바닥나지 않은 비율
    let bands: [Band]
    let medianAtQuit: Double
    let badCaseDepletionAge: Int?    // 하위 10% 경로가 바닥나는 나이
}

/// 재현 가능한 난수 — 같은 입력이면 화면을 다시 그려도 같은 결과가 나온다.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum MonteCarlo {
    struct Input: Equatable {
        var startAssets: Double
        var currentAge: Int
        var quitAge: Int
        var endAge: Int
        var annualSavingsUntilQuit: Double
        var annualSpendAfterQuit: Double     // 고정비 포함
        var publicPensionAnnual: Double
        var publicPensionStart: Int
        var oneTimeAtQuit: Double = 0        // 실업급여 등 퇴사 때 한 번 들어오는 돈
        var realReturn: Double
        var volatility: Double
        var paths: Int = 2000
    }

    static func run(_ x: Input) -> MonteCarloResult {
        let years = max(1, x.endAge - x.currentAge)
        var rng = SplitMix64(state: 0xF1_2E_7A_C0)
        var matrix = [[Double]](repeating: [], count: x.paths)
        var success = 0
        for path in 0..<x.paths {
            var a = x.startAssets
            var series = [Double]()
            series.reserveCapacity(years + 1)
            series.append(a)
            var alive = true
            for k in 0..<years {
                let age = x.currentAge + k
                let r = x.realReturn + x.volatility * normal(&rng)
                a *= 1 + r
                if age < x.quitAge {
                    a += x.annualSavingsUntilQuit
                } else {
                    if age == x.quitAge { a += x.oneTimeAtQuit }
                    a -= x.annualSpendAfterQuit
                    if age >= x.publicPensionStart { a += x.publicPensionAnnual }
                }
                if a < 0 { alive = false; a = 0 }
                series.append(a)
            }
            if alive { success += 1 }
            matrix[path] = series
        }
        var bands: [MonteCarloResult.Band] = []
        var badDepletion: Int?
        for k in 0...years {
            let col = matrix.map { $0[k] }.sorted()
            let p10 = col[Int(Double(col.count - 1) * 0.1)]
            bands.append(.init(age: x.currentAge + k, p10: p10,
                               p50: col[Int(Double(col.count - 1) * 0.5)],
                               p90: col[Int(Double(col.count - 1) * 0.9)]))
            if badDepletion == nil, p10 <= 0, x.currentAge + k > x.quitAge {
                badDepletion = x.currentAge + k
            }
        }
        let quitIdx = min(years, max(0, x.quitAge - x.currentAge))
        return MonteCarloResult(successRate: Double(success) / Double(x.paths),
                                bands: bands,
                                medianAtQuit: bands[quitIdx].p50,
                                badCaseDepletionAge: badDepletion)
    }

    /// 표준정규분포 (Box–Muller).
    private static func normal(_ g: inout SplitMix64) -> Double {
        let u1 = max(Double.ulpOfOne, Double(g.next() >> 11) / Double(1 << 53))
        let u2 = Double(g.next() >> 11) / Double(1 << 53)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// MARK: - 4) 시나리오

struct FutureScenario: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var quitAgeOffset: Int        // 기준 퇴사 나이 대비 ±년 (지금 퇴사는 별도 플래그)
    var quitNow: Bool = false
    var savingsChangePct: Double  // 월 저축 증감 %
    var spendChangePct: Double    // 퇴사 후 생활비 증감 %

    static let storageKey = "future.scenarios"

    static var defaults: [FutureScenario] {
        [
            FutureScenario(name: String(localized: "지금 퇴사"), quitAgeOffset: 0, quitNow: true,
                           savingsChangePct: 0, spendChangePct: 0),
            FutureScenario(name: String(localized: "계획대로"), quitAgeOffset: 0,
                           savingsChangePct: 0, spendChangePct: 0),
            FutureScenario(name: String(localized: "2년 더 다니기"), quitAgeOffset: 2,
                           savingsChangePct: 0, spendChangePct: 0),
            FutureScenario(name: String(localized: "이직해서 저축 +30%"), quitAgeOffset: 0,
                           savingsChangePct: 30, spendChangePct: 0),
        ]
    }

    static func load() -> [FutureScenario] {
        guard let s = UserDefaults.standard.string(forKey: storageKey),
              let d = s.data(using: .utf8),
              let v = try? JSONDecoder().decode([FutureScenario].self, from: d), !v.isEmpty else { return defaults }
        return v
    }

    static func save(_ v: [FutureScenario]) {
        guard let d = try? JSONEncoder().encode(v), let s = String(data: d, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: storageKey)
    }
}
