import SwiftUI
import SwiftData
import Charts

// 계산 탭 — 참고용 시뮬레이터 모음.
// 생애주기(모으고 쓰는 인생 자산 곡선) · 주담대(상환 흐름) · 예적금(만기 수령액).
struct SimulatorView: View {
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]
    // 마지막으로 보던 계산 모드를 저장해 다시 와도 그대로.
    @AppStorage("sim.mode") private var mode: SimMode = .lifecycle

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var totalNet: Double { assets.reduce(0) { $0 + $1.netValue } }
    // 지금 자산이 만드는 월 패시브 인컴(배당·월세·이자 + 수동 입력 배당).
    private var monthlyPassive: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } + settings.manualMonthlyDividend
    }

    enum SimMode: String, CaseIterable, Identifiable {
        case lifecycle = "생애주기"
        case mortgage = "주담대"
        case savings = "예적금"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("", selection: $mode) {
                        ForEach(SimMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .lifecycle:
                        LifecycleSimSection(settings: settings, startAssetValue: totalNet,
                                            passiveIncomeValue: monthlyPassive)
                    case .mortgage:
                        MortgageSimSection()
                    case .savings:
                        SavingsSimSection()
                    }

                    Text("입력값을 바탕으로 계산한 참고용 결과예요. 세금·수수료·시장 변동에 따라 실제와 다를 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("계산")
        }
    }
}

// MARK: - 공용 입력 UI

// 라벨 왼쪽 · 입력 오른쪽 한 줄 행.
private func simInputRow(_ label: String, text: Binding<String>, suffix: String,
                         money: Bool = false, decimal: Bool = false) -> some View {
    HStack(spacing: 8) {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(Theme.textSecond)
        Spacer()
        TextField("0", text: money ? text.commaGrouped : text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: 150)
        Text(suffix)
            .font(.caption)
            .foregroundStyle(Theme.textSecond)
    }
}

// 금액 빠른 증감 칩 — +10만 / +100만 / −10만 같은 한 탭 보정.
private func simMoneyChips(_ text: Binding<String>,
                           steps: [(label: String, amount: Double)]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(steps, id: \.label) { step in
                Button {
                    let cur = Double(text.wrappedValue) ?? 0
                    text.wrappedValue = String(Int(max(0, cur + step.amount)))
                } label: {
                    Text(step.label)
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

private func simStat(_ label: String, _ value: String, tint: Color = Theme.textPrimary) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(label)
            .font(.caption2)
            .foregroundStyle(Theme.textSecond)
        Text(value)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - 생애주기 자산 시뮬레이션

private struct LifecycleSimSection: View {
    // 설정·현재 자산은 처음 한 번만 미리 채우고, 이후엔 사용자가 바꾼 값을 저장·유지.
    let settings: FireSettings
    let startAssetValue: Double
    let passiveIncomeValue: Double

    @AppStorage("sim.life.currentAge")   private var currentAge = ""
    @AppStorage("sim.life.retireAge")    private var retireAge = ""
    @AppStorage("sim.life.endAge")       private var endAge = "90"
    @AppStorage("sim.life.startAsset")   private var startAsset = ""
    @AppStorage("sim.life.grossSalary")  private var grossSalary = "50000000"
    @AppStorage("sim.life.raisePct")     private var raisePct = "3"
    @AppStorage("sim.life.monthlyLiving") private var monthlyLiving = ""
    @AppStorage("sim.life.retireMonthly") private var retireMonthly = ""
    @AppStorage("sim.life.retirePension") private var retirePension = "0"
    @AppStorage("sim.life.passiveMonthly") private var passiveMonthly = ""
    @AppStorage("sim.life.returnPct")    private var returnPct = ""
    @AppStorage("sim.life.inflationPct") private var inflationPct = "2.5"
    @AppStorage("sim.life.seeded")       private var seeded = false

    // 최초 1회만 설정·현재 자산값으로 빈 칸을 채운다(이후엔 저장된 값 유지).
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        if currentAge.isEmpty   { currentAge = settings.currentAge > 0 ? String(settings.currentAge) : "30" }
        if retireAge.isEmpty    { retireAge = settings.targetRetireAge > 0 ? String(settings.targetRetireAge) : "60" }
        if startAsset.isEmpty   { startAsset = startAssetValue > 0 ? String(Int(startAssetValue)) : "0" }
        if monthlyLiving.isEmpty { monthlyLiving = settings.plannedMonthlyExpense > 0 ? String(Int(settings.plannedMonthlyExpense)) : "2500000" }
        if retireMonthly.isEmpty { retireMonthly = settings.incomeGoalMonthly > 0 ? String(Int(settings.incomeGoalMonthly)) : "3000000" }
        if returnPct.isEmpty    { returnPct = settings.expectedAnnualReturn > 0 ? Fmt.trimNumber(settings.expectedAnnualReturn * 100) : "4" }
        if passiveMonthly.isEmpty { passiveMonthly = passiveIncomeValue > 0 ? String(Int(passiveIncomeValue)) : "0" }
    }

    private struct LifePoint: Identifiable {
        let id = UUID()
        let age: Int
        let value: Double
        let phase: String
    }

    // 세전 연봉 → 세후 근사 (사회보험료 + 누진세 실효율 구간 근사).
    private func netAnnual(_ gross: Double) -> Double {
        let rate: Double
        switch gross {
        case ..<30_000_000:  rate = 0.90
        case ..<50_000_000:  rate = 0.86
        case ..<80_000_000:  rate = 0.82
        case ..<120_000_000: rate = 0.76
        case ..<200_000_000: rate = 0.70
        default:             rate = 0.62
        }
        return gross * rate
    }

    private var ages: (cur: Int, retire: Int, end: Int) {
        let cur = max(15, Int(currentAge) ?? 30)
        let retire = max(cur + 1, Int(retireAge) ?? 60)
        let end = max(retire + 1, Int(endAge) ?? 90)
        return (cur, retire, end)
    }

    // 연 단위 시뮬레이션: 일할 땐 (세후소득 − 생활비)를 모으고, 은퇴 후엔
    // 희망 월수령액(물가 반영)을 꺼내 쓴다. 자산엔 매년 수익률이 붙는다.
    private var sim: (points: [LifePoint], peak: Double, end: Double, depletionAge: Int?) {
        let a = ages
        var asset = Double(startAsset) ?? 0
        let r = (Double(returnPct) ?? 0) / 100
        let infl = (Double(inflationPct) ?? 0) / 100
        let raise = (Double(raisePct) ?? 0) / 100
        var salary = Double(grossSalary) ?? 0
        var living = (Double(monthlyLiving) ?? 0) * 12
        let wantYear = (Double(retireMonthly) ?? 0) * 12
        let pensionYear = (Double(retirePension) ?? 0) * 12
        let passiveYear = (Double(passiveMonthly) ?? 0) * 12

        var pts: [LifePoint] = [LifePoint(age: a.cur, value: asset, phase: "모으는 시기")]
        var peak = asset
        var depletion: Int? = nil
        for age in (a.cur + 1)...a.end {
            let working = age <= a.retire
            let yearsOut = Double(age - a.cur)
            asset *= (1 + r)
            // 패시브 인컴(배당·월세)은 일할 때도 은퇴 후에도 들어온다.
            // 물가만큼 자라는 것으로 가정(임대료·배당 성장 근사).
            asset += passiveYear * pow(1 + infl, yearsOut)
            if working {
                asset += netAnnual(salary) - living
                salary *= (1 + raise)
                living *= (1 + infl)
            } else {
                asset += pensionYear - wantYear * pow(1 + infl, yearsOut)
            }
            if asset <= 0, depletion == nil, age > a.retire { depletion = age }
            asset = max(0, asset)
            let phase = working ? "모으는 시기" : "쓰는 시기"
            pts.append(LifePoint(age: age, value: asset, phase: phase))
            if age == a.retire {
                peak = asset
                // 경계점을 양쪽 단계에 모두 넣어 라인이 끊기지 않게.
                pts.append(LifePoint(age: age, value: asset, phase: "쓰는 시기"))
            }
        }
        return (pts, peak, asset, depletion)
    }

    var body: some View {
        let result = sim
        let a = ages
        VStack(spacing: 20) {
            // 결과 — 차트가 먼저.
            VStack(alignment: .leading, spacing: 14) {
                Text("생애주기 자산 추이")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    simStat("은퇴(\(a.retire)세) 자산", "\(Fmt.wonKo(result.peak))", tint: .blue)
                    if let dep = result.depletionAge {
                        simStat("자산 고갈", "\(dep)세", tint: Theme.negative)
                    } else {
                        simStat("\(a.end)세 잔액", "\(Fmt.wonKo(result.end))", tint: .orange)
                    }
                }

                Chart {
                    ForEach(result.points) { p in
                        LineMark(x: .value("나이", p.age), y: .value("자산", p.value))
                            .foregroundStyle(by: .value("시기", p.phase))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    RuleMark(x: .value("은퇴", a.retire))
                        .foregroundStyle(Theme.textSecond.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("은퇴")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    PointMark(x: .value("나이", a.retire), y: .value("자산", result.peak))
                        .foregroundStyle(.blue)
                        .symbolSize(70)
                    if let dep = result.depletionAge {
                        RuleMark(x: .value("고갈", dep))
                            .foregroundStyle(Theme.negative.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(["모으는 시기": Color.blue, "쓰는 시기": Color.orange])
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        if let age = value.as(Int.self) {
                            AxisValueLabel {
                                Text("\(age)세")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecond)
                            }
                        }
                    }
                }
                .frame(height: 220)

                if result.depletionAge == nil, result.end > 0 {
                    Text("\(a.end)세까지 자산이 버팁니다. 희망 월수령액을 올려 여유를 확인해보세요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                } else if let dep = result.depletionAge {
                    Text("\(dep)세에 자산이 고갈돼요. 월수령액을 줄이거나 은퇴를 늦추면 곡선이 달라집니다.")
                        .font(.caption2)
                        .foregroundStyle(Theme.negative)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // 목표 — 은퇴 후 얼마나 쓰고 싶은지.
            VStack(alignment: .leading, spacing: 12) {
                Text("목표")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                simInputRow("희망 월수령액", text: $retireMonthly, suffix: "원", money: true)
                simMoneyChips($retireMonthly, steps: [("+10만", 100_000), ("+100만", 1_000_000), ("−10만", -100_000)])
                simInputRow("시뮬레이션 종료 나이", text: $endAge, suffix: "세")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // 기본 — 나이와 가정.
            VStack(alignment: .leading, spacing: 12) {
                Text("기본 설정")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                simInputRow("현재 나이", text: $currentAge, suffix: "세")
                simInputRow("은퇴 나이", text: $retireAge, suffix: "세")
                simInputRow("현재 자산", text: $startAsset, suffix: "원", money: true)
                simInputRow("연 수익률", text: $returnPct, suffix: "%", decimal: true)
                simInputRow("물가상승률", text: $inflationPct, suffix: "%", decimal: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // 소득 — 모으는 시기의 엔진.
            VStack(alignment: .leading, spacing: 12) {
                Text("소득 · 지출")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                simInputRow("세전 연봉", text: $grossSalary, suffix: "원", money: true)
                simMoneyChips($grossSalary, steps: [("+100만", 1_000_000), ("+1,000만", 10_000_000), ("−100만", -1_000_000)])
                simInputRow("연봉 인상률", text: $raisePct, suffix: "%", decimal: true)
                simInputRow("월 생활비", text: $monthlyLiving, suffix: "원", money: true)
                simInputRow("월 패시브 인컴(배당·월세)", text: $passiveMonthly, suffix: "원", money: true)
                simMoneyChips($passiveMonthly, steps: [("+10만", 100_000), ("+50만", 500_000), ("−10만", -100_000)])
                simInputRow("은퇴 후 월 소득(연금 등)", text: $retirePension, suffix: "원", money: true)
                Text("세후 소득은 사회보험료·누진세 근사값이고, 패시브 인컴은 등록한 자산의 현재 값으로 미리 채워져요. 일할 때도 은퇴 후에도 들어오며 물가만큼 자란다고 가정합니다.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .onAppear { seedIfNeeded() }
    }
}

// MARK: - 주담대 상환 시뮬레이션

private struct MortgageSimSection: View {
    @AppStorage("sim.mtg.principal") private var principal = "300000000"
    @AppStorage("sim.mtg.ratePct")   private var ratePct = "4.2"
    @AppStorage("sim.mtg.years")     private var years = "30"
    @AppStorage("sim.mtg.method")    private var method: RepayMethod = .equalPayment

    enum RepayMethod: String, CaseIterable, Identifiable {
        case equalPayment = "원리금균등"
        case equalPrincipal = "원금균등"
        case bullet = "만기일시"
        var id: String { rawValue }
    }

    private struct PayPoint: Identifiable {
        let id = UUID()
        let month: Int
        let payment: Double
        let balance: Double
    }

    // 월별 상환 스케줄. (납입액, 남은 원금)
    private var schedule: [PayPoint] {
        let p = Double(principal) ?? 0
        let n = max(1, (Int(years) ?? 0) * 12)
        let i = (Double(ratePct) ?? 0) / 100 / 12
        guard p > 0 else { return [] }
        var balance = p
        var pts: [PayPoint] = []
        switch method {
        case .equalPayment:
            let m = i > 0 ? p * i * pow(1 + i, Double(n)) / (pow(1 + i, Double(n)) - 1) : p / Double(n)
            for k in 1...n {
                let interest = balance * i
                balance = max(0, balance - (m - interest))
                pts.append(PayPoint(month: k, payment: m, balance: balance))
            }
        case .equalPrincipal:
            let principalPart = p / Double(n)
            for k in 1...n {
                let interest = balance * i
                balance = max(0, balance - principalPart)
                pts.append(PayPoint(month: k, payment: principalPart + interest, balance: balance))
            }
        case .bullet:
            let interest = p * i
            for k in 1...n {
                let last = k == n
                pts.append(PayPoint(month: k, payment: last ? interest + p : interest,
                                    balance: last ? 0 : p))
            }
        }
        return pts
    }

    var body: some View {
        let sched = schedule
        let p = Double(principal) ?? 0
        let totalPaid = sched.reduce(0) { $0 + $1.payment }
        let totalInterest = max(0, totalPaid - p)
        // 차트는 듬성듬성 샘플링(최대 ~120점)해 가볍게.
        let step = max(1, sched.count / 120)
        let sampled = sched.enumerated().compactMap { idx, pt in
            (idx % step == 0 || idx == sched.count - 1) ? pt : nil
        }
        VStack(spacing: 20) {
            // 조건.
            VStack(alignment: .leading, spacing: 12) {
                Text("대출 조건")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                simInputRow("대출 원금", text: $principal, suffix: "원", money: true)
                simMoneyChips($principal, steps: [("+1,000만", 10_000_000), ("+1억", 100_000_000), ("−1,000만", -10_000_000)])
                simInputRow("연 이자율", text: $ratePct, suffix: "%", decimal: true)
                simInputRow("대출 기간", text: $years, suffix: "년")
                Picker("", selection: $method) {
                    ForEach(RepayMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            if !sched.isEmpty {
                // 결과.
                VStack(alignment: .leading, spacing: 14) {
                    Text("상환 결과")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 0) {
                        simStat("총 상환액", "\(Fmt.krw(totalPaid))원")
                        simStat("총 이자", "\(Fmt.krw(totalInterest))원", tint: Theme.negative)
                    }
                    HStack(spacing: 0) {
                        simStat("이자 비율(원금 대비)", Fmt.percent(p > 0 ? totalInterest / p : 0, fraction: 1),
                                tint: Theme.negative)
                        if method == .equalPrincipal, let first = sched.first, let last = sched.last {
                            simStat("월 상환액", "\(Fmt.wonKo(first.payment)) → \(Fmt.wonKo(last.payment))")
                        } else if let first = sched.first {
                            simStat(method == .bullet ? "월 이자" : "월 상환액", "\(Fmt.krw(first.payment))원")
                        }
                    }

                    // 월 상환액 흐름.
                    Text("월 상환액")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Chart(sampled) { pt in
                        LineMark(x: .value("개월", pt.month), y: .value("상환액", pt.payment))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis { simMonthAxis() }
                    .frame(height: 110)

                    // 남은 원금.
                    Text("남은 원금")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Chart(sampled) { pt in
                        AreaMark(x: .value("개월", pt.month), y: .value("잔액", pt.balance))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.negative.opacity(0.35), Theme.negative.opacity(0.03)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        LineMark(x: .value("개월", pt.month), y: .value("잔액", pt.balance))
                            .foregroundStyle(Theme.negative)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis { simMonthAxis() }
                    .frame(height: 110)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
        }
    }

    // x축을 '년' 단위 라벨로.
    private func simMonthAxis() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            if let m = value.as(Int.self) {
                AxisValueLabel {
                    Text("\(m / 12)년")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
    }
}

// MARK: - 예적금 시뮬레이션

private struct SavingsSimSection: View {
    @AppStorage("sim.sav.kind")      private var kind: SavingKind = .deposit
    @AppStorage("sim.sav.principal") private var principal = "10000000"
    @AppStorage("sim.sav.monthly")   private var monthly = "500000"
    @AppStorage("sim.sav.months")    private var months = "12"
    @AppStorage("sim.sav.ratePct")   private var ratePct = "3.5"
    @AppStorage("sim.sav.compound")  private var compound: CompoundKind = .simple
    @AppStorage("sim.sav.taxed")     private var taxed = true

    enum SavingKind: String, CaseIterable, Identifiable {
        case deposit = "정기예금"
        case installment = "적금"
        var id: String { rawValue }
    }
    enum CompoundKind: String, CaseIterable, Identifiable {
        case simple = "단리"
        case monthlyCompound = "월 복리"
        var id: String { rawValue }
    }

    // (원금 합계, 세전 이자)
    private var result: (principal: Double, interest: Double) {
        let m = max(1, Int(months) ?? 12)
        let r = (Double(ratePct) ?? 0) / 100
        let i = r / 12
        switch kind {
        case .deposit:
            let p = Double(principal) ?? 0
            let interest = compound == .simple
                ? p * r * Double(m) / 12
                : p * (pow(1 + i, Double(m)) - 1)
            return (p, interest)
        case .installment:
            let d = Double(monthly) ?? 0
            let total = d * Double(m)
            let interest: Double
            if compound == .simple {
                // 매달 말 납입 단리: k번째 납입은 (m−k)개월치 이자.
                interest = d * r * Double(m * (m - 1)) / 2 / 12
            } else {
                interest = i > 0 ? d * ((pow(1 + i, Double(m)) - 1) / i) - total : 0
            }
            return (total, interest)
        }
    }

    var body: some View {
        let r = result
        let tax = taxed ? r.interest * 0.154 : 0
        let afterTax = r.interest - tax
        let maturity = r.principal + afterTax
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("조건")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Picker("", selection: $kind) {
                    ForEach(SavingKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .deposit {
                    simInputRow("원금", text: $principal, suffix: "원", money: true)
                    simMoneyChips($principal, steps: [("+100만", 1_000_000), ("+1,000만", 10_000_000), ("−100만", -1_000_000)])
                } else {
                    simInputRow("월 납입액", text: $monthly, suffix: "원", money: true)
                    simMoneyChips($monthly, steps: [("+10만", 100_000), ("+50만", 500_000), ("−10만", -100_000)])
                }
                simInputRow("기간", text: $months, suffix: "개월")
                simInputRow("연 이자율", text: $ratePct, suffix: "%", decimal: true)
                Picker("", selection: $compound) {
                    ForEach(CompoundKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $taxed) {
                    Text("이자과세 15.4%")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            VStack(alignment: .leading, spacing: 14) {
                Text("만기 수령액")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(Fmt.krw(maturity))원")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.positive)
                Text("= \(Fmt.wonKo(maturity))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)

                // 원금 vs 이자 구성 — 한 막대.
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        if maturity > 0 {
                            Theme.textSecond.opacity(0.35)
                                .frame(width: max(2, geo.size.width * (r.principal / maturity)))
                            Theme.positive
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)

                HStack(spacing: 0) {
                    simStat("원금", "\(Fmt.krw(r.principal))원")
                    simStat("세전 이자", "\(Fmt.krw(r.interest))원", tint: Theme.positive)
                }
                HStack(spacing: 0) {
                    if taxed {
                        simStat("세금(15.4%)", "−\(Fmt.krw(tax))원", tint: Theme.negative)
                    }
                    simStat("세후 이자", "\(Fmt.krw(afterTax))원", tint: Theme.positive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }
}
