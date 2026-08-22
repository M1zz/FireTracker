import SwiftUI
import SwiftData
import Charts

// 계산 탭 — '시간' 모드.
//
// 돈을 시간으로 환산해서 하루의 '두께'를 보는 계산기.
//  1) 시급 세 가지 — 회계적(평균) · 한계(추가 1시간) · FIRE(자산이 대신 버는 시급).
//     의사결정에는 한계 시급을 쓴다.
//  2) 하루의 밀도 — 시간등가 = 24 + (시간을 돌려받는 지출 ÷ 산 시급), 밀도 = 시간등가 ÷ 24.
//     환율이 둘(번 시급 · 산 시급)이라 밀도만 봐선 안 되고 순증을 같이 봐야 한다.
//     순증 = 돌려받은 시간 − (지출 ÷ 번 시급). 번÷산 > 1일 때만 시간이 실제로 늘어난다.
//  3) 저장할까 나중에 벌까 — 자산수익률 r vs 시급성장률 g. g > r이면 시급에 투자,
//     r > g가 되는 지점이 FIRE 전환점.
//  4) 지금 1시간의 값 — 팔면 미래에 몇 시간으로 돌아오는지 vs 안 팔았을 때 그 1시간의 미래 가격.
struct TimeSimSection: View {
    let settings: FireSettings
    let netWorth: Double

    // 구매력 탭(WageSimSection)에 적어 둔 월급 기록 — 여기서 그대로 읽어 쓴다.
    @AppStorage("sim.wage.entries")      private var wageEntriesJSON = ""
    @AppStorage("sim.wage.country")      private var wageCountry = "KR"

    // 시급
    @AppStorage("sim.time.netMonthly")   private var netMonthly = ""
    @AppStorage("sim.time.weeklyHours")  private var weeklyHours = "50"
    @AppStorage("sim.time.marginal")     private var marginalText = ""
    @AppStorage("sim.time.returnPct")    private var returnPct = ""
    @AppStorage("sim.time.seeded")       private var seeded = false

    // 밀도
    @AppStorage("sim.time.earnWage")     private var earnWageText = ""
    @AppStorage("sim.time.buys")         private var buysJSON = ""

    // 저장 vs 성장
    @AppStorage("sim.time.growthPct")    private var growthPct = "9"
    @AppStorage("sim.time.decayPct")     private var decayPct = "8"
    @AppStorage("sim.time.horizon")      private var horizonText = "20"
    @AppStorage("sim.time.lifePct")      private var lifePct = "1.5"

    @State private var buys: [TimeBuy] = []
    @State private var loaded = false

    // MARK: 모델

    // 구매력 탭이 저장한 월급 한 줄을 읽기 위한 최소 타입.
    fileprivate struct WageRecord: Codable {
        var year: Int
        var monthly: Double
    }

    // 시간을 돌려받는 지출 한 줄. 주기가 달라도(매일 택시 / 매주 가사도우미) 하루 기준으로 환산해서 합친다.
    fileprivate struct TimeBuy: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var cost: Double      // 주기당 지출액(원)
        var hours: Double     // 주기당 돌려받는 시간
        var cycle: Cycle

        var dailyCost: Double { cost / cycle.days }
        var dailyHours: Double { hours / cycle.days }
        // 이 항목만 놓고 본 '산 시급' — 시간 1개를 얼마에 샀나.
        var boughtWage: Double { hours > 0 ? cost / hours : 0 }
    }

    fileprivate enum Cycle: String, Codable, CaseIterable, Identifiable {
        case daily = "매일"
        case weekly = "매주"
        case monthly = "매월"
        var id: String { rawValue }
        // 한 번의 주기가 며칠인지 — 하루 기준 환산에 쓴다.
        var days: Double {
            switch self {
            case .daily: return 1
            case .weekly: return 7
            case .monthly: return 30.44
            }
        }
    }

    // MARK: 계산 — 시급

    // 구매력 탭 기록 중 가장 최근 해의 월급. 그쪽은 나라별 통화라
    // 원화 계산과 섞이지 않게 한국 기록일 때만 가져온다.
    private var latestWageRecord: (year: Int, monthly: Double)? {
        guard wageCountry == "KR" else { return nil }
        guard let data = wageEntriesJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([WageRecord].self, from: data),
              let last = list.filter({ $0.monthly > 0 }).max(by: { $0.year < $1.year })
        else { return nil }
        return (last.year, last.monthly)
    }

    // 직접 적은 값이 있으면 그것이 우선, 비어 있으면 구매력 탭 기록을 쓴다.
    // 그래서 월급을 이미 적어 둔 사람은 근로시간만 넣으면 시급이 바로 나온다.
    private var monthlyIncome: Double {
        let typed = tvNum(netMonthly)
        return typed > 0 ? typed : (latestWageRecord?.monthly ?? 0)
    }
    private var hoursPerWeek: Double { max(1, tvNum(weeklyHours, 50)) }
    // 한 달에 실제로 쏟는 시간 (주 → 월: 52 ÷ 12 = 4.345주).
    private var monthlyHours: Double { hoursPerWeek * 52.0 / 12.0 }

    // 회계적 시급 — 번 돈 ÷ 실제로 쓴 시간. 출퇴근·준비까지 넣어야 정직해진다.
    private var accountingWage: Double {
        monthlyHours > 0 ? monthlyIncome / monthlyHours : 0
    }
    // 한계 시급 — 지금 1시간을 더 넣었을 때 실제로 늘어나는 돈. 의사결정용.
    private var marginalWage: Double {
        let v = tvNum(marginalText)
        return v > 0 ? v : accountingWage
    }
    private var annualReturn: Double { tvNum(returnPct, 4) / 100 }
    // FIRE 시급 — 자산이 나 대신 버는 시급. 내가 자는 시간에도 흐르므로 8,760시간으로 나눈다.
    private var fireWage: Double { netWorth * annualReturn / 8_760 }

    // MARK: 계산 — 밀도

    private var earnWage: Double {
        let v = tvNum(earnWageText)
        return v > 0 ? v : marginalWage
    }
    private var boughtHours: Double { buys.reduce(0) { $0 + $1.dailyHours } }
    private var boughtCost: Double { buys.reduce(0) { $0 + $1.dailyCost } }
    // 산 시급 — 돌려받은 시간 1개당 실제로 치른 값(여러 항목의 가중평균).
    private var boughtWage: Double { boughtHours > 0 ? boughtCost / boughtHours : 0 }
    private var timeEquivalent: Double { 24 + boughtHours }
    private var density: Double { timeEquivalent / 24 }
    // 순증 — 돌려받은 시간에서, 그 돈을 벌기 위해 판 시간을 뺀 값. 진짜로 생긴 두께.
    private var netGain: Double {
        earnWage > 0 ? boughtHours - boughtCost / earnWage : 0
    }
    // 환율 배율 — 번 시급 ÷ 산 시급. 1보다 커야 시간이 실제로 늘어난다.
    private var wageRatio: Double { boughtWage > 0 ? earnWage / boughtWage : 0 }

    // MARK: 계산 — 저장 vs 성장

    private var g0: Double { tvNum(growthPct, 9) / 100 }
    private var decay: Double { min(0.95, max(0, tvNum(decayPct, 8) / 100)) }
    private var horizon: Int { Int(min(50, max(1, tvNum(horizonText, 20)))) }
    private var lifeDiscount: Double { max(0, tvNum(lifePct, 1.5) / 100) }

    // t년차의 시급 성장률 — 해마다 둔화한다고 본다.
    private func growth(at t: Int) -> Double { g0 * pow(1 - decay, Double(t)) }

    // 성장률이 수익률 아래로 내려가는 해 = FIRE 전환점. 이후로는 저장이 유리해진다.
    private var crossoverYear: Double? {
        guard g0 > annualReturn, annualReturn > 0, decay > 0 else { return nil }
        let t = log(annualReturn / g0) / log(1 - decay)
        return t.isFinite && t > 0 ? t : nil
    }

    // N년 뒤 내 시급 배수 — 해마다 다른 성장률을 그대로 곱해 나간다.
    private func wageMultiple(after years: Int) -> Double {
        var m = 1.0
        for t in 0..<years { m *= (1 + growth(at: t)) }
        return m
    }

    private var futureWage: Double { marginalWage * wageMultiple(after: horizon) }
    // 지금 1시간을 팔아 만든 돈을 자산에 넣어 두었다가, N년 뒤 그때 시급으로 되사면 몇 시간인가.
    private var boughtBackHours: Double {
        let m = wageMultiple(after: horizon)
        guard m > 0 else { return 0 }
        return pow(1 + annualReturn, Double(horizon)) / m
    }
    // 미래의 시간은 생존·체력으로 한 번 더 할인된다.
    private var usableBoughtBack: Double {
        boughtBackHours * pow(1 - lifeDiscount, Double(horizon))
    }

    // MARK: 본문

    var body: some View {
        VStack(spacing: 20) {
            wageCard
            densityCard
            assetWageCard
            crossoverCard
            oneHourCard
            conclusionCard
        }
        .onAppear(perform: load)
        .onChange(of: buys) { _, _ in save() }
    }

    // MARK: 1 — 시급 세 가지

    // 월소득을 어디서 가져왔는지 한 줄로 밝힌다. 구매력 탭에 이미 적어 둔 사람은
    // 근로시간만 넣으면 되고, 다른 통화로 적어 둔 사람은 왜 안 가져왔는지 알 수 있게.
    private var incomeSourceNote: String {
        if tvNum(netMonthly) > 0 {
            if let r = latestWageRecord {
                return "직접 적은 금액으로 계산해요. 구매력 탭 기록은 \(r.year)년 \(tvWon(r.monthly))이에요."
            }
            return "세전이 아니라 실제로 통장에 들어오는 금액으로 적어야 시급이 정직해져요."
        }
        if let r = latestWageRecord {
            return "구매력 탭에 적어 둔 \(r.year)년 월급 \(tvWon(r.monthly))을 쓰고 있어요. 근로시간만 넣으면 시급이 나와요."
        }
        if wageCountry != "KR" {
            let c = CPIData.country(wageCountry)
            return "구매력 탭 기록이 \(c.flag) \(c.name) 통화라 원화 계산과 섞이지 않게 가져오지 않았어요. 여기 직접 적어 주세요."
        }
        return "구매력 탭에 월급을 적어 두면 여기서 자동으로 가져와요."
    }

    private var wageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("내 시급 세 가지")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("같은 '시급'이라도 셋이 다 달라요. 뭘 할지 정할 땐 평균이 아니라 한계 시급을 봐야 해요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                tvRow("세후 월소득", $netMonthly, suffix: "원", money: true,
                      placeholder: latestWageRecord.map { Fmt.won($0.monthly) } ?? "0")
                Text(incomeSourceNote)
                    .font(.caption2)
                    .foregroundStyle(latestWageRecord != nil && tvNum(netMonthly) <= 0
                                     ? Theme.accent : Theme.textSecond)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                tvRow("주 실제 투입시간", $weeklyHours, suffix: "시간", decimal: true)
                Text("근무만이 아니라 출퇴근·준비·업무 생각까지 넣어야 정직한 시급이 나와요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                    .frame(maxWidth: .infinity, alignment: .leading)
                tvRow("한계 시급", $marginalText, suffix: "원", money: true,
                      placeholder: Fmt.won(accountingWage))
                Text("지금 1시간을 더 넣으면 실제로 얼마가 더 들어오나요? 비워 두면 회계적 시급을 그대로 써요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                    .frame(maxWidth: .infinity, alignment: .leading)
                tvRow("자산 기대수익률", $returnPct, suffix: "%", decimal: true)
            }

            Divider().overlay(Theme.hairline)

            HStack(alignment: .top, spacing: 10) {
                tvStat("회계적 시급", tvWon(accountingWage), sub: "번 돈 ÷ 쓴 시간")
                tvStat("한계 시급", tvWon(marginalWage), sub: "추가 1시간의 값",
                       tint: Theme.accent)
                tvStat("FIRE 시급", tvWon(fireWage), sub: "자산이 버는 시급",
                       tint: Theme.positive)
            }

            if accountingWage > 0 {
                // 시급은 '일하는 시간'에만 적용되는 국소 밀도라, 하루 전체로 펴면 3분의 1 수준으로 내려간다.
                let localShare = monthlyHours / (30.44 * 24)
                Text("시급은 일하는 시간에만 붙는 국소 밀도예요. 하루 24시간 전체로 펴면 시간당 \(tvWon(accountingWage * localShare)) 수준이에요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 2 — 하루의 밀도

    private var densityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("하루의 밀도")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("하루는 누구나 24시간이지만 두께는 달라요. 저가치 시간을 돈으로 사서 없애면 하루가 두꺼워져요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            tvRow("번 시급", $earnWageText, suffix: "원", money: true,
                  placeholder: Fmt.won(marginalWage))

            Divider().overlay(Theme.hairline)

            Text("시간을 돌려받는 지출")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("외식·쇼핑처럼 시간이 돌아오지 않는 지출은 여기 넣지 않아요. 밀도와 상관이 없거든요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(buys) { buy in
                if let idx = buys.firstIndex(where: { $0.id == buy.id }) {
                    buyRow(idx)
                }
            }

            presetChips

            if buys.isEmpty {
                Text("위 칩을 눌러 시간을 사는 지출을 넣어 보세요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            } else {
                densityResult
            }

            Divider().overlay(Theme.hairline)

            Text("예시로 확인하기")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecond)
            scenarioChips
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func buyRow(_ idx: Int) -> some View {
        let rowID = buys[idx].id
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("이름", text: nameBinding(idx))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                Picker("", selection: cycleBinding(idx)) {
                    ForEach(Cycle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                Button {
                    buys.removeAll { $0.id == rowID }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecond.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                TextField("0", text: costBinding(idx).commaGrouped)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("원 →")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                TextField("0", text: hoursBinding(idx))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 70)
                Text("시간")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            // 이 줄만 놓고 본 산 시급 — 번 시급보다 싸야 남는 장사다.
            if buys[idx].boughtWage > 0 {
                let cheap = buys[idx].boughtWage < earnWage
                Text("산 시급 \(tvWon(buys[idx].boughtWage)) · 내 시급보다 \(cheap ? "싸요" : "비싸요")")
                    .font(.caption2)
                    .foregroundStyle(cheap ? Theme.positive : Theme.negative)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.name) { p in
                    Button {
                        buys.append(TimeBuy(name: p.name, cost: p.cost, hours: p.hours, cycle: p.cycle))
                    } label: {
                        Text("+ \(p.name)")
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
            .padding(.vertical, 2)
        }
    }

    private static let presets: [(name: String, cost: Double, hours: Double, cycle: Cycle)] = [
        ("가사도우미", 100_000, 4, .weekly),
        ("배달·밀키트", 15_000, 1, .daily),
        ("택시", 12_000, 0.5, .daily),
        ("세탁 서비스", 30_000, 2, .weekly),
        ("식기세척기·로봇청소기", 50_000, 10, .monthly),
        ("직접 입력", 0, 0, .monthly),
    ]

    // 네 가지 하루 — 밀도만 보면 놓치는 것을 순증이 잡아낸다.
    private var scenarioChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.scenarios, id: \.label) { s in
                    Button {
                        earnWageText = String(Int(s.earn))
                        buys = s.buys()
                    } label: {
                        Text(s.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.accentSoft)
                            .foregroundStyle(Theme.textPrimary)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private static let scenarios: [(label: String, earn: Double, buys: () -> [TimeBuy])] = [
        // 24시간을 전부 팔았지만 산 시간은 없다 → 밀도 1.0, 순증 0.
        ("A 24시간 다 판 날", 10_000, { [] }),
        // 번 만큼 그대로 되샀다 → 밀도 2.0이지만 순증은 0. 두께는 빌려온 것.
        ("B 번 만큼 되산 날", 10_000, {
            [TimeBuy(name: "산 시간", cost: 240_000, hours: 24, cycle: .daily)]
        }),
        // 내 시급보다 훨씬 싸게 샀다 → 순증 +4.1시간.
        ("C 싸게 산 날", 100_000, {
            [TimeBuy(name: "산 시간", cost: 90_000, hours: 5, cycle: .daily)]
        }),
        // 내 시급보다 비싼 시간을 샀다 → 밀도는 올라도 순증 −3.2시간.
        ("D 비싸게 산 날", 15_000, {
            [TimeBuy(name: "산 시간", cost: 70_000, hours: 1.5, cycle: .daily)]
        }),
    ]

    private var densityResult: some View {
        let gain = netGain
        let up = gain > 0.05
        let flat = abs(gain) <= 0.05
        return VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(Theme.hairline)

            // 24시간 위에 '산 시간'을 얹어 두께를 보여준다.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("시간등가 \(tvHours(timeEquivalent))")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("밀도 ×\(String(format: "%.2f", density))")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                densityBar
                Text("하루 24시간 + 돈으로 되찾은 \(tvHours(boughtHours))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }

            // 밀도는 빌려서도 오른다. 진짜로 늘었는지는 순증이 답한다.
            VStack(alignment: .leading, spacing: 6) {
                Text("순증")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                Text("\(gain >= 0 ? "+" : "−")\(tvHours(abs(gain)))")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(up ? Theme.positive : (flat ? Theme.textSecond : Theme.negative))
                    .contentTransition(.numericText())
                Text(densityVerdict)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 10) {
                tvStat("번 시급", tvWon(earnWage), sub: "내 시간을 판 값")
                tvStat("산 시급", tvWon(boughtWage), sub: "남의 시간을 산 값")
                tvStat("환율 배율", wageRatio > 0 ? "×\(String(format: "%.2f", wageRatio))" : "—",
                       sub: "번 ÷ 산", tint: up ? Theme.positive : (flat ? Theme.textSecond : Theme.negative))
            }

            Text("하루 기준으로 지출 \(tvWon(boughtCost)) · 되찾은 시간 \(tvHours(boughtHours))")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
    }

    private var densityVerdict: String {
        if boughtHours <= 0 {
            return "산 시간이 없어요. 24시간을 어떻게 쓰든 하루의 두께는 그대로 1이에요."
        }
        if wageRatio > 1.05 {
            return "번 시급이 산 시급보다 비싸요. 두께가 진짜로 \(tvHours(netGain))만큼 늘었어요."
        }
        if wageRatio >= 0.95 {
            return "번 시급과 산 시급이 같아요. 밀도는 올랐지만 시간이 자리만 옮겼을 뿐, 늘지는 않았어요."
        }
        return "내 시급보다 비싼 시간을 샀어요. 밀도는 올라 보여도 실제로는 \(tvHours(abs(netGain)))을 잃었어요."
    }

    private var densityBar: some View {
        GeometryReader { geo in
            let total = max(timeEquivalent, 24)
            let baseW = geo.size.width * 24 / total
            let addW = geo.size.width * boughtHours / total
            HStack(spacing: 0) {
                Rectangle().fill(Theme.textSecond.opacity(0.28)).frame(width: baseW)
                Rectangle().fill(Theme.accent).frame(width: addW)
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .background(Theme.surfaceHigh, in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: boughtHours)
    }

    // MARK: 3 — 자산 수익은 번 시급이 무한대

    private var assetWageCard: some View {
        // 자산 수익은 내 시간을 전혀 팔지 않고 들어온 돈이다. 판 시간이 0이라 순증에서 빼일 게 없다.
        let monthlyAssetIncome = netWorth * annualReturn / 12
        let hoursFromAssets = boughtWage > 0 ? monthlyAssetIncome / boughtWage : 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("자산이 버는 돈은 따로 봐요")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("자산 수익은 내 시간을 한 시간도 팔지 않고 들어온 돈이에요. 번 시급이 사실상 무한대라, 이 돈으로 산 시간은 전부 순증이 돼요. 부피 없는 질량인 셈이에요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                tvStat("FIRE 시급", tvWon(fireWage), sub: "자산 \(Fmt.krw(netWorth))원 기준",
                       tint: Theme.positive)
                tvStat("월 자산수익", tvWon(monthlyAssetIncome), sub: "연 \(Fmt.percent(annualReturn)) 가정")
                tvStat("살 수 있는 시간", hoursFromAssets > 0 ? "월 \(tvHours(hoursFromAssets))" : "—",
                       sub: "지금 산 시급 기준", tint: Theme.accent)
            }
            if fireWage > 0 && marginalWage > 0 {
                let share = fireWage / marginalWage
                Text(share >= 1
                     ? "자산이 버는 시급이 내 한계 시급을 넘었어요. 시간을 팔지 않아도 되는 구간이에요."
                     : "자산이 내 한계 시급의 \(Fmt.percent(share))만큼을 대신 벌고 있어요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 4 — 저장할까, 나중에 벌까

    private var crossoverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("지금 저장할까, 나중에 벌까")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("돈은 내 시급이 아니라 시장 시급으로 저장돼요. 시급이 오르는 동안 판 시간은 나중에 헐값이 되죠. 자산수익률 r과 시급성장률 g의 싸움이에요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                tvRow("자산수익률 r", $returnPct, suffix: "%", decimal: true)
                tvRow("시급성장률 g (지금)", $growthPct, suffix: "%", decimal: true)
                tvRow("성장 둔화", $decayPct, suffix: "%/년", decimal: true)
            }
            Text("성장 둔화는 시급이 오르는 속도가 해마다 얼마씩 꺾이는지예요. 8%면 올해 9%였던 성장률이 내년엔 8.3%가 돼요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            crossoverChart
            crossoverLegend

            VStack(alignment: .leading, spacing: 6) {
                Text(crossoverHeadline)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(g0 > annualReturn ? Theme.accent : Theme.positive)
                Text(crossoverBody)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private struct RatePoint: Identifiable {
        var id: Int { year }
        let year: Int
        let growth: Double
    }

    private var crossoverChart: some View {
        let points = (0...30).map { RatePoint(year: $0, growth: growth(at: $0)) }
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("연차", p.year), y: .value("시급성장률", p.growth))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            RuleMark(y: .value("자산수익률", annualReturn))
                .foregroundStyle(Theme.positive)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            if let x = crossoverYear, x <= 30 {
                PointMark(x: .value("전환점", x), y: .value("전환점", annualReturn))
                    .foregroundStyle(Theme.textPrimary)
                    .symbolSize(90)
                    .annotation(position: .topTrailing) {
                        Text("FIRE 전환점 \(String(format: "%.0f", x))년 뒤")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Fmt.percent(v, fraction: 0)).font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 10, 20, 30]) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)년").font(.caption2).foregroundStyle(Theme.textSecond)
                    }
                }
            }
        }
        .frame(height: 180)
    }

    // 범례는 차트 위에 얹지 않고 아래 한 줄로 — 곡선·주석과 겹치지 않게.
    private var crossoverLegend: some View {
        HStack(spacing: 14) {
            tvLegend(Theme.accent, "시급성장률 g")
            tvLegend(Theme.positive, "자산수익률 r")
        }
        .font(.caption2)
    }

    private var crossoverHeadline: String {
        if g0 > annualReturn {
            if let x = crossoverYear, x <= 40 {
                let age = settings.currentAge > 0 ? " · \(settings.currentAge + Int(x.rounded()))세" : ""
                return "지금은 시급에 투자할 때 (전환점 \(String(format: "%.0f", x))년 뒤\(age))"
            }
            return "지금은 시급에 투자할 때"
        }
        return "이미 저장이 유리한 구간 — FIRE 전환점을 지났어요"
    }

    private var crossoverBody: String {
        if g0 > annualReturn {
            return "시급이 자산보다 빨리 크고 있어요. 지금 1시간을 팔아 저장하면 나중에 헐값이 되니, 그 시간은 시급을 올리는 데 쓰는 편이 나아요. 전환점을 지나면 반대가 돼요."
        }
        return "시급 성장이 자산 수익보다 느려요. 지금부터는 번 시간을 저장해서 자산이 대신 벌게 하는 쪽이 유리해요."
    }

    // MARK: 5 — 지금 1시간의 값

    private var oneHourCard: some View {
        let back = boughtBackHours
        let usable = usableBoughtBack
        return VStack(alignment: .leading, spacing: 14) {
            Text("지금 1시간의 진짜 값")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("미래의 1시간은 팔 때 비싸고, 지금의 1시간은 팔지 않을 때 비싸요. 시급과 기회비용이 다르기 때문이에요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                tvRow("몇 년 뒤로 볼까요", $horizonText, suffix: "년", decimal: false)
                tvRow("체력·생존 할인", $lifePct, suffix: "%/년", decimal: true)
            }
            Text("나이가 들수록 같은 1시간을 실제로 쓸 수 있는 몫이 줄어요. 그만큼 미래 시간을 깎아서 봐요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 12) {
                // 판 경우 — 돈은 r로 불지만, 되살 때 값은 g로 더 빨리 오른다.
                VStack(alignment: .leading, spacing: 4) {
                    Text("지금 1시간을 팔면")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("\(horizon)년 뒤 \(tvHours(usable))으로 돌아와요")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(usable < 1 ? Theme.negative : Theme.positive)
                    Text("\(tvWon(marginalWage))을 받아 연 \(Fmt.percent(annualReturn))로 굴리면 \(tvWon(marginalWage * pow(1 + annualReturn, Double(horizon))))이 되지만, 그때 시급은 \(tvWon(futureWage))이에요. 되사면 \(tvHours(back)), 체력 할인까지 넣으면 \(tvHours(usable))이에요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 안 판 경우 — 그 시간을 시급에 넣으면 1시간은 그대로 남고, 가격만 오른다.
                VStack(alignment: .leading, spacing: 4) {
                    Text("팔지 않고 시급에 투자하면")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("1시간이 \(tvWon(futureWage))짜리로 남아요")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.accent)
                    if marginalWage > 0 {
                        Text("지금 시급의 \(String(format: "%.1f", futureWage / marginalWage))배예요. 지금 1시간의 진짜 가격은 오늘 시급이 아니라, 그 시간이 올려 줄 미래 시급이에요.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 판 시간 vs 지킨 시간 — 길이로 바로 비교.
            VStack(spacing: 8) {
                tvCompareBar("팔았을 때 돌아오는 시간", value: usable, peak: max(1, usable),
                             color: usable < 1 ? Theme.negative : Theme.positive,
                             caption: tvHours(usable))
                tvCompareBar("팔지 않았을 때 남는 시간", value: 1, peak: max(1, usable),
                             color: Theme.accent, caption: "1시간")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 6 — 결론

    private var conclusionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("두 줄 결론", systemImage: "quote.opening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecond)
            Text("시급이 오르는 동안엔 시간을 팔지 말고 시급에 투자할 것.")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("팔아서 만든 돈은 내 시간이 아니라 남의 시간을 사는 데만 쓸 것.")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: 저장·프리필

    private func load() {
        guard !loaded else { return }
        loaded = true
        if !seeded {
            seeded = true
            if returnPct.isEmpty {
                returnPct = settings.expectedAnnualReturn > 0
                    ? Fmt.trimNumber(settings.expectedAnnualReturn * 100) : "4"
            }
        }
        if returnPct.isEmpty { returnPct = "4" }
        guard let data = buysJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([TimeBuy].self, from: data) else { return }
        buys = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(buys),
              let text = String(data: data, encoding: .utf8) else { return }
        buysJSON = text
    }

    // 인덱스가 아니라 값으로 접근 — 목록을 그리는 중에 지워져도 범위를 벗어나지 않게 가드한다.
    private func nameBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { buys.indices.contains(idx) ? buys[idx].name : "" },
            set: { if buys.indices.contains(idx) { buys[idx].name = $0 } }
        )
    }

    private func costBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard buys.indices.contains(idx), buys[idx].cost > 0 else { return "" }
                return String(Int(buys[idx].cost))
            },
            set: {
                guard buys.indices.contains(idx) else { return }
                buys[idx].cost = Double($0.filter(\.isNumber)) ?? 0
            }
        )
    }

    private func hoursBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard buys.indices.contains(idx), buys[idx].hours > 0 else { return "" }
                return Fmt.trimNumber(buys[idx].hours)
            },
            set: {
                guard buys.indices.contains(idx) else { return }
                buys[idx].hours = Double($0.filter { $0.isNumber || $0 == "." }) ?? 0
            }
        )
    }

    private func cycleBinding(_ idx: Int) -> Binding<Cycle> {
        Binding(
            get: { buys.indices.contains(idx) ? buys[idx].cycle : .daily },
            set: { if buys.indices.contains(idx) { buys[idx].cycle = $0 } }
        )
    }

    // MARK: 작은 조각들

    private func tvRow(_ label: String, _ text: Binding<String>, suffix: String,
                       money: Bool = false, decimal: Bool = false,
                       placeholder: String = "0") -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                Spacer()
                TextField(placeholder, text: money ? text.commaGrouped : text)
                    .keyboardType(decimal ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 150)
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            // 큰 금액은 콤마만으론 안 읽혀서 한글 단위를 아래에 붙인다.
            if money, !Fmt.numbersOnly, let v = Double(text.wrappedValue), v > 0 {
                Text("= \(Fmt.krw(v))원")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }

    private func tvStat(_ label: String, _ value: String, sub: String,
                        tint: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(Theme.textSecond.opacity(0.8))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tvLegend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(Theme.textSecond)
        }
    }

    private func tvCompareBar(_ label: String, value: Double, peak: Double,
                              color: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Theme.textSecond)
                Spacer()
                Text(caption)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * min(1, value / max(peak, 0.0001))))
            }
            .frame(height: 8)
            .background(Theme.surfaceHigh, in: Capsule())
        }
    }
}

// MARK: - 파일 안에서 쓰는 작은 유틸

// "1,200,000" 처럼 콤마가 섞여 들어와도 숫자로 읽는다. 빈 칸이면 기본값.
private func tvNum(_ s: String, _ fallback: Double = 0) -> Double {
    let cleaned = s.replacingOccurrences(of: ",", with: "")
    guard let v = Double(cleaned), v.isFinite else { return fallback }
    return v
}

// 시급은 만원 단위로 자르면 18,462원이 '1만원'이 돼 버린다.
// 100만원 미만은 원 단위로 정확히, 그 위는 앱 표기(억·만)를 따른다.
private func tvWon(_ v: Double) -> String {
    guard v.isFinite else { return "0원" }
    if abs(v) < 1_000_000 { return "\(Int(v.rounded()).formatted())원" }
    return Fmt.wonKo(v)
}

// 3.17 → "3.2시간", 24 → "24시간".
private func tvHours(_ v: Double) -> String {
    guard v.isFinite else { return "0시간" }
    if abs(v - v.rounded()) < 0.05 { return "\(Int(v.rounded()))시간" }
    return "\(String(format: "%.1f", v))시간"
}
