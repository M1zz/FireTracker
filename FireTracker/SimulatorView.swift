import SwiftUI
import SwiftData
import Charts
import TipKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// 계산 탭 — 참고용 시뮬레이터 모음.
// 생애주기(모으고 쓰는 인생 자산 곡선) · 대출(종류별 상환 흐름) ·
// 저축(예금·적금·파킹 만기 수령액) · 투자(내 자산의 앞으로의 범위 예측).
struct SimulatorView: View {
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]
    // 마지막으로 보던 계산 모드를 저장해 다시 와도 그대로.
    @AppStorage("sim.mode") private var mode: SimMode = .lifecycle

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var totalNet: Double { assets.reduce(0) { $0 + $1.netValue } }
    // 지금 자산이 만드는 월 패시브 인컴(배당·월세·이자 + 수동 입력 배당).
    private var monthlyPassive: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
    }

    enum SimMode: String, CaseIterable, Identifiable {
        case lifecycle = "생애주기"
        case loan = "대출"
        case savings = "저축"
        case invest = "투자"
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
                    case .loan:
                        MortgageSimSection()
                    case .savings:
                        SavingsSimSection()
                    case .invest:
                        InvestForecastSection()
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

// 라벨 왼쪽 · 입력 오른쪽 한 줄 행. 금액 칸은 아래에 "= 6억원"처럼
// 한글 단위 읽기를 실시간으로 달아 큰 숫자도 한눈에 읽히게 한다.
private func simInputRow(_ label: String, text: Binding<String>, suffix: String,
                         money: Bool = false, decimal: Bool = false) -> some View {
    // 금액은 설정값(억/만 단위 ↔ 숫자만)을 따라 한글 단위를 주 표기로 띄운다.
    // '숫자만' 모드면 콤마 숫자가 곧 표기이므로 입력칸을 그대로 주 표기로 쓴다.
    let showKoUnit = money && !Fmt.numbersOnly
    return VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
            Spacer()
            if showKoUnit {
                // 주 표기 — 한글 단위(예: "2,300만원"). 값이 없으면 "0원".
                let v = Double(text.wrappedValue) ?? 0
                Text("\(Fmt.krw(v))\(suffix)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            } else {
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
        // 한글 단위 모드의 금액 — 실제 편집용 콤마 숫자를 작게 보조로 둔다.
        if showKoUnit {
            HStack(spacing: 8) {
                Spacer()
                TextField("0", text: text.commaGrouped)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
                    .frame(maxWidth: 150)
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        }
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

// 계산 결과를 자산/설정으로 보내는 큰 액션 버튼 — 확인 다이얼로그 포함.
private func simActionButton(title: String, done: Bool,
                            confirmTitle: String, confirmMessage: String,
                            isPresented: Binding<Bool>,
                            action: @escaping () -> Void) -> some View {
    Button { isPresented.wrappedValue = true } label: {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "plus.circle.fill")
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if !done { Image(systemName: "arrow.right") }
        }
        .foregroundStyle(done ? Theme.positive : Color.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(done ? Theme.surfaceHigh : Theme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(done)
    .confirmationDialog(confirmTitle, isPresented: isPresented, titleVisibility: .visible) {
        Button("추가하기") { action() }
        Button("취소", role: .cancel) {}
    } message: { Text(confirmMessage) }
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
    // C — 수익률이 해마다 출렁이는 폭(변동성). 밴드의 넓이를 정한다.
    @AppStorage("sim.life.volatilityPct") private var volatilityPct = "12"
    // B — 규모별 수익률 가정. 켜면 자산이 클수록 연 수익률을 조금씩 더해준다.
    // Fagereng(2020)·Piketty 근거이되 '낙관 가정'이므로 기본은 꺼둔다.
    @AppStorage("sim.life.scaleReturns") private var scaleReturns = false
    @AppStorage("sim.life.seeded")       private var seeded = false

    @Environment(\.modelContext) private var context
    @State private var showReflectConfirm = false
    @State private var reflected = false

    // 4단계 "충분의 거울" 성찰 팁 — 쓰는 흐름 속에서 질문을 던진다.
    private let vanityMirrorTip = VanityMirrorTip()   // 1단계 — 월 생활비
    private let bucketListTip = BucketListTip()        // 2단계 — 희망 월수령액
    private let enoughAnchorTip = EnoughAnchorTip()    // 3단계 — 판정 카드

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

    // B — 규모별 수익률. 자산이 클수록 연 수익률을 단계적으로 더한다(낙관 가정).
    // 근거: 큰 자산일수록 리스크 감내·대체투자 접근·낮은 수수료로 평균 수익이 높다
    // (Fagereng 2020; Piketty 기금 사례 — 규모 클수록 실질수익 ~2%p 높음).
    private func scaledReturn(base r: Double, asset: Double) -> Double {
        guard scaleReturns else { return r }
        let bump: Double
        switch asset {
        case ..<300_000_000:    bump = 0       // 3억 미만
        case ..<1_000_000_000:  bump = 0.005   // 3~10억  +0.5%p
        case ..<5_000_000_000:  bump = 0.010   // 10~50억 +1.0%p
        default:                bump = 0.015   // 50억+   +1.5%p
        }
        return r + bump
    }

    private var ages: (cur: Int, retire: Int, end: Int) {
        let cur = max(15, Int(currentAge) ?? 30)
        let retire = max(cur + 1, Int(retireAge) ?? 60)
        let end = max(retire + 1, Int(endAge) ?? 90)
        return (cur, retire, end)
    }

    // 연 단위 시뮬레이션: 일할 땐 (세후소득 − 생활비)를 모으고, 은퇴 후엔
    // 희망 월수령액(물가 반영)을 꺼내 쓴다. 자산엔 매년 수익률이 붙는다.
    private var sim: (points: [LifePoint], peak: Double, end: Double, depletionAge: Int?, crossoverAge: Int?) {
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
        // 분기점 — 한 해 투자수익(자산×수익률)이 그 해 순저축을 넘어서는 첫 나이.
        // 이때부터 곡선이 직선(저축 주도)에서 지수(수익 주도)로 휘기 시작한다.
        var crossover: Int? = nil
        for age in (a.cur + 1)...a.end {
            let working = age <= a.retire
            let yearsOut = Double(age - a.cur)
            let rEff = scaledReturn(base: r, asset: asset)  // B — 규모 반영 수익률
            // 성장 적용 전에, 이 해의 수익과 순저축을 비교해 분기점을 잡는다.
            if working, crossover == nil {
                let yearReturn = asset * rEff
                let yearSavings = netAnnual(salary) - living
                if yearSavings > 0, yearReturn >= yearSavings { crossover = age }
            }
            asset *= (1 + rEff)
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
        return (pts, peak, asset, depletion, crossover)
    }

    // MARK: - 변동성 밴드 (C — 단일 선의 거짓 정밀함을 부채꼴로)
    //
    // 단일 수익률 선은 "딱 이렇게 된다"는 환상을 준다. 실제 수익은 해마다 출렁이고,
    // 그 불확실성은 시간이 갈수록 벌어진다(sequence-of-returns risk). 그래서 같은
    // 모델을 수익률만 정규분포로 흔들어 여러 번 돌리고(몬테카를로), 가운데 50%
    // 구간(p25~p75)을 띠로 그린다. 시드를 고정해 입력이 같으면 띠도 흔들리지 않는다.

    private struct BandPoint: Identifiable { let id = UUID(); let age: Int; let low: Double; let high: Double }

    // 입력이 같으면 결과도 같은 시드 고정 난수기(xorshift64 + Box–Muller).
    private struct SeededGen {
        var state: UInt64
        mutating func uniform() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)  // [0,1)
        }
        mutating func normal() -> Double {  // 표준정규 한 표본
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    private var band: [BandPoint] {
        let a = ages
        let r = (Double(returnPct) ?? 0) / 100
        let infl = (Double(inflationPct) ?? 0) / 100
        let raise = (Double(raisePct) ?? 0) / 100
        let sigma = (Double(volatilityPct) ?? 0) / 100
        let start = Double(startAsset) ?? 0
        let salary0 = Double(grossSalary) ?? 0
        let living0 = (Double(monthlyLiving) ?? 0) * 12
        let wantYear = (Double(retireMonthly) ?? 0) * 12
        let pensionYear = (Double(retirePension) ?? 0) * 12
        let passiveYear = (Double(passiveMonthly) ?? 0) * 12
        let span = a.end - a.cur
        guard span > 0 else { return [] }

        let trials = 400
        var samples = Array(repeating: [Double](), count: span + 1)
        var gen = SeededGen(state: 0x9E37_79B9_7F4A_7C15)  // 고정 시드

        for _ in 0..<trials {
            var asset = start, salary = salary0, living = living0
            samples[0].append(asset)
            for (i, age) in ((a.cur + 1)...a.end).enumerated() {
                let yearsOut = Double(age - a.cur)
                let rEff = scaledReturn(base: r, asset: asset)  // B — 규모 반영
                asset *= (1 + rEff + sigma * gen.normal())  // 수익률만 흔든다
                asset += passiveYear * pow(1 + infl, yearsOut)
                if age <= a.retire {
                    asset += netAnnual(salary) - living
                    salary *= (1 + raise); living *= (1 + infl)
                } else {
                    asset += pensionYear - wantYear * pow(1 + infl, yearsOut)
                }
                asset = max(0, asset)
                samples[i + 1].append(asset)
            }
        }

        return samples.enumerated().map { idx, vals in
            let s = vals.sorted()
            return BandPoint(age: a.cur + idx, low: pct(s, 0.25), high: pct(s, 0.75))
        }
    }

    private func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(i, 0), sorted.count - 1)]
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

                // 결과 판정 — 은퇴 가능한 전략인지 한눈에.
                let want = Double(retireMonthly) ?? 0
                let feasible = result.depletionAge == nil
                let comfy = feasible && result.end >= result.peak
                let tint: Color = feasible ? Theme.positive : Theme.negative
                let icon = feasible
                    ? (comfy ? "checkmark.seal.fill" : "checkmark.circle.fill")
                    : "exclamationmark.triangle.fill"
                let verdict = feasible
                    ? (comfy ? "여유로운 은퇴 전략이에요" : "은퇴 가능한 전략이에요")
                    : "은퇴하기엔 아직 부족한 전략이에요"
                let reason: String = {
                    if let dep = result.depletionAge {
                        return "은퇴 후 \(dep)세에 자산이 바닥나요. 희망 월수령액을 줄이거나, 은퇴를 늦추거나, 수익률·저축을 높여보세요."
                    } else if comfy {
                        return "은퇴(\(a.retire)세) 후 월 \(Fmt.krw(want))원을 써도 \(a.end)세에 \(Fmt.krw(result.end))원이 남아요."
                    } else {
                        return "은퇴(\(a.retire)세) 후 월 \(Fmt.krw(want))원으로 \(a.end)세까지 버틸 수 있어요."
                    }
                }()
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdict)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(tint)
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // 3단계 — 닻: '충분한 삶'의 값을 마주하되 매일 쫓지 말라고 짚는다.
                .popoverTip(enoughAnchorTip)

                HStack(spacing: 0) {
                    simStat("은퇴(\(a.retire)세) 자산", "\(Fmt.krw(result.peak))원", tint: .blue)
                    if let dep = result.depletionAge {
                        simStat("자산 고갈", "\(dep)세", tint: Theme.negative)
                    } else {
                        simStat("\(a.end)세 잔액", "\(Fmt.krw(result.end))원", tint: .orange)
                    }
                }

                let bandPts = band
                Chart {
                    // C — 변동성 밴드(가운데 50% 구간). 선 뒤에 깔아 부채꼴로 보이게.
                    ForEach(bandPts) { b in
                        AreaMark(x: .value("나이", b.age),
                                 yStart: .value("하한", b.low),
                                 yEnd: .value("상한", b.high))
                            .foregroundStyle(Theme.accent.opacity(0.13))
                            .interpolationMethod(.catmullRom)
                    }
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
                    // A — 분기점: 수익이 저축을 앞서는 나이. "돈이 일하기 시작하는" 지점.
                    if let cross = result.crossoverAge, cross < a.retire {
                        RuleMark(x: .value("분기점", cross))
                            .foregroundStyle(Theme.positive.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                            .annotation(position: .bottom, alignment: .center) {
                                Text("돈이 일함")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.positive)
                            }
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

                // A — 분기점 설명: 곡선이 왜 휘는지.
                if let cross = result.crossoverAge, cross < a.retire {
                    Text("\(cross)세부터는 한 해 투자수익이 저축보다 커져요 — 여기서부터 돈이 당신 대신 법니다. 곡선이 직선에서 지수로 휘는 지점이에요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.positive)
                }
                // C — 밴드 설명: 단일 선은 환상, 띠가 현실.
                Text("음영은 수익률이 해마다 출렁일 때의 ‘가운데 50%’ 범위예요(연 변동성 \(volatilityPct.isEmpty ? "0" : volatilityPct)% 가정). 미래는 선 하나가 아니라 이 폭 안에서 움직여요 — 시간이 갈수록 넓어지죠.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                if scaleReturns {
                    Text("‘규모별 수익률’ 가정이 켜져 있어요 — 자산이 클수록 연 수익률을 +0.5~1.5%p 더해 계산한 낙관 시나리오예요(Fagereng 2020·Piketty). 실제로 그 초과수익엔 더 큰 리스크가 따라요.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

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

            // 계산값을 그대로 목표·설정으로 — 따로 설정 탭에서 다시 입력할 필요 없이.
            reflectButton

            // 목표 — 은퇴 후 얼마나 쓰고 싶은지.
            VStack(alignment: .leading, spacing: 12) {
                Text("목표")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                simInputRow("희망 월수령액", text: $retireMonthly, suffix: "원", money: true)
                    // 2단계 — 버킷: 이 돈으로 무엇을 누리고 싶은가(빼기 다음 더하기).
                    .popoverTip(bucketListTip)
                simMoneyChips($retireMonthly, steps: [("+10만", 100_000), ("+100만", 1_000_000), ("−10만", -100_000)])
                simInputRow("시뮬레이션 종료 나이", text: $endAge, suffix: "세")
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
                    // 1단계 — 거울: 허영을 덜어낸 '진짜 나의 만족점'은 얼마인가.
                    .popoverTip(vanityMirrorTip)
                simInputRow("월 패시브 인컴(배당·월세)", text: $passiveMonthly, suffix: "원", money: true)
                simMoneyChips($passiveMonthly, steps: [("+10만", 100_000), ("+50만", 500_000), ("−10만", -100_000)])
                simInputRow("은퇴 후 월 소득(연금 등)", text: $retirePension, suffix: "원", money: true)
                Text("세후 소득은 사회보험료·누진세 근사값이고, 패시브 인컴은 등록한 자산의 현재 값으로 미리 채워져요. 일할 때도 은퇴 후에도 들어오며 물가만큼 자란다고 가정합니다.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // 기본 — 나이와 가정. 앱 정보로 자동 채워지므로 맨 아래에 둔다.
            VStack(alignment: .leading, spacing: 12) {
                Text("기본 설정")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                simInputRow("현재 나이", text: $currentAge, suffix: "세")
                simInputRow("은퇴 나이", text: $retireAge, suffix: "세")
                simInputRow("현재 자산", text: $startAsset, suffix: "원", money: true)
                simInputRow("연 수익률", text: $returnPct, suffix: "%", decimal: true)
                simInputRow("물가상승률", text: $inflationPct, suffix: "%", decimal: true)
                // C — 변동성: 밴드 폭을 정하는 가정. 프리셋으로 빠르게.
                simInputRow("수익률 변동성", text: $volatilityPct, suffix: "%", decimal: true)
                volatilityPresets
                // B — 규모별 수익률 토글(낙관 가정).
                Toggle(isOn: $scaleReturns) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("규모별 수익률 가정")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("자산이 클수록 연 수익률 +0.5~1.5%p (낙관)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
                .tint(Theme.accent)
                Text("나이·자산·수익률은 설정과 등록한 자산에서 자동으로 채워져요. 바꾸면 이 계산에만 반영됩니다.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .onAppear {
            seedIfNeeded()
            // 1단계 거울은 이 화면에 있을 때만 묻는다. 3단계 닻은 계산이 성립할 때.
            VanityMirrorTip.onLifecycleScreen = true
            EnoughAnchorTip.hasFeasibleResult = (sim.depletionAge == nil)
        }
        .onDisappear { VanityMirrorTip.onLifecycleScreen = false }
        // 값이 바뀌면 다시 반영할 수 있게 버튼 상태를 되돌린다.
        .onChange(of: [currentAge, retireAge, retireMonthly, returnPct, monthlyLiving, grossSalary]) { _, _ in
            reflected = false
            // 결과가 성립(은퇴 가능)할 때만 3단계 닻을 깨운다.
            EnoughAnchorTip.hasFeasibleResult = (sim.depletionAge == nil)
        }
        // 1단계(월 생활비)를 실제로 만지면 거울을 닫고, 2단계 버킷을 깨운다 — 빼기 다음 더하기.
        .onChange(of: monthlyLiving) { _, _ in
            vanityMirrorTip.invalidate(reason: .actionPerformed)
            BucketListTip.mirrorDone = true
        }
        // 2단계(희망 월수령액)를 만지면 버킷 질문은 역할을 다한 것.
        .onChange(of: retireMonthly) { _, _ in
            bucketListTip.invalidate(reason: .actionPerformed)
        }
        // B 토글은 곡선 자체를 바꾸므로 판정도 다시 계산.
        .onChange(of: scaleReturns) { _, _ in
            reflected = false
            EnoughAnchorTip.hasFeasibleResult = (sim.depletionAge == nil)
        }
    }

    // 변동성 빠른 프리셋 — 보수(8)/균형(12)/공격(18)으로 한 탭 세팅.
    private var volatilityPresets: some View {
        HStack(spacing: 8) {
            ForEach([("보수 8%", "8"), ("균형 12%", "12"), ("공격 18%", "18")], id: \.0) { label, value in
                Button { volatilityPct = value } label: {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(volatilityPct == value ? Theme.accent.opacity(0.25) : Theme.surfaceHigh)
                        .foregroundStyle(Theme.textPrimary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(volatilityPct == value ? Theme.accent : Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // 계산값을 그대로 목표·설정(설정 탭)으로 보내는 버튼.
    private var reflectButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showReflectConfirm = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: reflected ? "checkmark.circle.fill" : "target")
                    Text(reflected ? "목표·설정에 반영됨" : "이 값을 목표·설정에 반영")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !reflected { Image(systemName: "arrow.right") }
                }
                .foregroundStyle(reflected ? Theme.positive : Color.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .background(reflected ? Theme.surfaceHigh : Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .confirmationDialog("현재 목표·설정을 이 계산값으로 덮어쓸까요?",
                                isPresented: $showReflectConfirm, titleVisibility: .visible) {
                Button("반영하기") { reflectToSettings() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("나이·은퇴 나이·연 수익률, 은퇴 후 월 지출(희망 월수령액), 월 생활비, 세후 월급이 설정 탭과 대시보드 목표에 저장됩니다. (현재 패시브 인컴은 보유 자산에서 자동 계산되므로 바꾸지 않아요.)")
            }
            if reflected {
                Text("설정 탭과 대시보드 목표(FIRE 목표·은퇴 시점)에 반영됐어요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }

    // 계산 입력값을 FireSettings에 기록 — 설정 탭과 대시보드 목표가 같은 값을 쓰게 한다.
    private func reflectToSettings() {
        // 설정 레코드가 아직 컨텍스트에 없으면(드묾) 먼저 넣어 반영이 저장되게 한다.
        if settings.modelContext == nil { context.insert(settings) }
        if let v = Int(currentAge), v > 0 { settings.currentAge = v }
        if let v = Int(retireAge), v > 0 { settings.targetRetireAge = v }
        if let v = Double(returnPct), v > 0 { settings.expectedAnnualReturn = v / 100 }
        // 희망 월수령액 = 은퇴 후 월 지출 → FIRE 목표·목표 패시브 인컴의 기준.
        if let v = Double(retireMonthly), v > 0 { settings.targetAnnualExpense = v * 12 }
        if let v = Double(monthlyLiving), v > 0 { settings.plannedMonthlyExpense = v }
        if let g = Double(grossSalary), g > 0 { settings.monthlyTakeHome = (netAnnual(g) / 12).rounded() }
        // 월 패시브 인컴은 계산용 입력(자산에서 미리 채운 값)이라 반영하지 않는다.
        // 현재 패시브 인컴은 실제 보유 자산(주식 배당 등)에서만 나와야 한다.
        try? context.save()
        reflected = true
        // 만족점을 다시 확정한 순간 — 4단계 재점검 타이머를 리셋하고 닻 질문은 닫는다.
        ReflectionState.markReviewed()
        enoughAnchorTip.invalidate(reason: .actionPerformed)
    }
}

// MARK: - 주담대 상환 시뮬레이션

private struct MortgageSimSection: View {
    @AppStorage("sim.mtg.principal") private var principal = "300000000"
    @AppStorage("sim.mtg.ratePct")   private var ratePct = "4.2"
    @AppStorage("sim.mtg.years")     private var years = "30"
    @AppStorage("sim.mtg.method")    private var method: RepayMethod = .equalPayment
    // 대출 종류 — 고르면 원금·금리·기간·상환방식이 그 대출의 일반적인 조건으로 채워진다.
    @AppStorage("sim.mtg.kind")      private var loanKind: LoanKind = .mortgage

    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @State private var added = false
    @State private var showAddConfirm = false

    enum RepayMethod: String, CaseIterable, Identifiable {
        case equalPayment = "원리금균등"
        case equalPrincipal = "원금균등"
        case bullet = "만기일시"
        var id: String { rawValue }
    }

    enum LoanKind: String, CaseIterable, Identifiable {
        case mortgage = "주담대"
        case jeonse   = "전세대출"
        case credit   = "신용대출"
        case car      = "자동차 할부"
        case minus    = "마이너스통장"
        var id: String { rawValue }

        // 자산 탭에 부채로 추가할 때 쓰는 정식 이름.
        var assetName: String {
            switch self {
            case .mortgage: return "주택담보대출"
            case .jeonse:   return "전세자금대출"
            case .credit:   return "신용대출"
            case .car:      return "자동차 할부"
            case .minus:    return "마이너스통장"
            }
        }
        // 종류별 일반적인 조건(2026 기준 근사) — 선택 시 입력칸에 시드된다.
        var defaults: (principal: String, rate: String, years: String, method: RepayMethod) {
            switch self {
            case .mortgage: return ("300000000", "4.2", "30", .equalPayment)
            case .jeonse:   return ("150000000", "3.8", "2",  .bullet)
            case .credit:   return ("50000000",  "5.5", "5",  .equalPayment)
            case .car:      return ("30000000",  "5.2", "5",  .equalPayment)
            case .minus:    return ("30000000",  "6.0", "1",  .bullet)
            }
        }
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
                loanKindChips
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
                            simStat("월 상환액", "\(Fmt.krw(first.payment)) → \(Fmt.krw(last.payment))원")
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

                // 이 대출을 자산 목록에 부채로 추가 — 따로 입력할 필요 없이.
                simActionButton(
                    title: added ? "부채로 추가됨" : "이 대출을 자산에 부채로 추가",
                    done: added,
                    confirmTitle: "이 대출을 부채로 추가할까요?",
                    confirmMessage: "남은 대출 잔액 \(Fmt.krw(p))원과 연 이자율 \(ratePct)%가 자산 탭에 ‘부채’로 등록됩니다.",
                    isPresented: $showAddConfirm,
                    action: addAsDebt
                )
            }
        }
    }

    // 대출 종류 선택 칩 — 고르면 그 대출의 일반적인 조건으로 입력칸을 채운다.
    private var loanKindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LoanKind.allCases) { k in
                    let selected = loanKind == k
                    Button {
                        loanKind = k
                        let d = k.defaults
                        principal = d.principal
                        ratePct = d.rate
                        years = d.years
                        method = d.method
                        added = false
                    } label: {
                        Text(k.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? Theme.accent.opacity(0.2) : Theme.surfaceHigh)
                            .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(selected ? Theme.accent.opacity(0.6) : Theme.hairline,
                                                 lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // 대출 조건을 부채 자산으로 만들어 카탈로그에 넣는다.
    private func addAsDebt() {
        let asset = Asset(name: loanKind.assetName, assetClass: .debt,
                          amount: Double(principal) ?? 0,
                          incomeKind: .interest,
                          annualYieldPct: Double(ratePct) ?? 0,
                          sortOrder: assets.count)
        context.insert(asset)
        try? context.save()
        added = true
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
    @AppStorage("sim.sav.goal")      private var goal = ""

    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @State private var added = false
    @State private var showAddConfirm = false

    enum SavingKind: String, CaseIterable, Identifiable {
        case deposit = "정기예금"
        case installment = "적금"
        case parking = "파킹·CMA"
        var id: String { rawValue }

        // 종류별 일반적인 금리 시드 — 선택 시 이자율 칸에 채워진다.
        var defaultRate: String {
            switch self {
            case .deposit:     return "3.5"
            case .installment: return "4.0"
            case .parking:     return "3.0"
            }
        }
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
        case .parking:
            // 자유 입출금(파킹·CMA) — 원금 + 매달 자유 입금, 월 복리로 근사.
            let p = Double(principal) ?? 0
            let d = Double(monthly) ?? 0
            var value = p
            for _ in 0..<m { value = value * (1 + i) + d }
            let total = p + d * Double(m)
            return (total, max(0, value - total))
        }
    }

    private struct SavPoint: Identifiable { let id = UUID(); let month: Int; let value: Double }

    // 월별 누적 잔액(세후 이자 반영) — 0개월부터 만기까지. 그래프용.
    private var series: [SavPoint] {
        let m = max(1, Int(months) ?? 12)
        let r = (Double(ratePct) ?? 0) / 100
        let i = r / 12
        let taxFactor = taxed ? (1 - 0.154) : 1.0
        var pts: [SavPoint] = []
        switch kind {
        case .deposit:
            let p = Double(principal) ?? 0
            for k in 0...m {
                let interest = compound == .simple ? p * r * Double(k) / 12
                                                   : p * (pow(1 + i, Double(k)) - 1)
                pts.append(SavPoint(month: k, value: p + interest * taxFactor))
            }
        case .installment:
            let d = Double(monthly) ?? 0
            for k in 0...m {
                let contributed = d * Double(k)
                let interest: Double
                if compound == .simple {
                    interest = d * r * Double(k * (k - 1)) / 2 / 12
                } else {
                    interest = i > 0 ? d * ((pow(1 + i, Double(k)) - 1) / i) - contributed : 0
                }
                pts.append(SavPoint(month: k, value: contributed + interest * taxFactor))
            }
        case .parking:
            let p = Double(principal) ?? 0
            let d = Double(monthly) ?? 0
            var value = p
            pts.append(SavPoint(month: 0, value: p))
            for k in 1...m {
                value = value * (1 + i) + d
                let contributed = p + d * Double(k)
                pts.append(SavPoint(month: k, value: contributed + max(0, value - contributed) * taxFactor))
            }
        }
        return pts
    }

    private var goalValue: Double { Double(goal) ?? 0 }

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
                .onChange(of: kind) { _, newValue in
                    ratePct = newValue.defaultRate
                    added = false
                }

                switch kind {
                case .deposit:
                    simInputRow("원금", text: $principal, suffix: "원", money: true)
                    simMoneyChips($principal, steps: [("+100만", 1_000_000), ("+1,000만", 10_000_000), ("−100만", -1_000_000)])
                case .installment:
                    simInputRow("월 납입액", text: $monthly, suffix: "원", money: true)
                    simMoneyChips($monthly, steps: [("+10만", 100_000), ("+50만", 500_000), ("−10만", -100_000)])
                case .parking:
                    simInputRow("현재 잔액", text: $principal, suffix: "원", money: true)
                    simMoneyChips($principal, steps: [("+100만", 1_000_000), ("+1,000만", 10_000_000), ("−100만", -1_000_000)])
                    simInputRow("월 추가 입금 (선택)", text: $monthly, suffix: "원", money: true)
                    simMoneyChips($monthly, steps: [("+10만", 100_000), ("+50만", 500_000), ("−10만", -100_000)])
                }
                simInputRow("기간", text: $months, suffix: "개월")
                simInputRow("연 이자율", text: $ratePct, suffix: "%", decimal: true)
                if kind == .parking {
                    Text("파킹·CMA는 매일 이자가 붙어 월 복리로 근사해서 계산해요.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                } else {
                    Picker("", selection: $compound) {
                        ForEach(CompoundKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(isOn: $taxed) {
                    Text("이자과세 15.4%")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .tint(Theme.accent)
                simInputRow("목표 금액 (선택)", text: $goal, suffix: "원", money: true)
                simMoneyChips($goal, steps: [("+100만", 1_000_000), ("+1,000만", 10_000_000), ("−100만", -1_000_000)])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // 목표까지 모이는 흐름 — 월별 누적 잔액 곡선 + 목표선.
            if series.count > 1 {
                savingsGrowthCard(maturity: maturity)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("만기 수령액")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(Fmt.krw(maturity))원")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.positive)
                // 한글 단위 모드에서만 전체 숫자를 보조로. ('숫자만' 모드면 위와 중복이라 생략)
                if !Fmt.numbersOnly {
                    Text("= \(Fmt.won(maturity))원")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

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

            // 예금·파킹은 지금 넣어둔 원금이 곧 현재 자산 → 현금·예금으로 바로 추가.
            if kind != .installment, (Double(principal) ?? 0) > 0 {
                simActionButton(
                    title: added ? "현금·예금에 추가됨" : "이 \(kind == .deposit ? "예금" : "잔액")을 자산에 추가",
                    done: added,
                    confirmTitle: "자산에 추가할까요?",
                    confirmMessage: "\(kind == .deposit ? "원금" : "잔액") \(Fmt.krw(Double(principal) ?? 0))원이 ‘현금·예금’으로 등록되고, 연 \(ratePct)% 이자가 패시브 인컴에 반영됩니다.",
                    isPresented: $showAddConfirm,
                    action: addAsCash
                )
            }
        }
    }

    // 예금·파킹 원금을 현금·예금 자산으로 만들어 카탈로그에 넣는다.
    private func addAsCash() {
        let asset = Asset(name: kind == .deposit ? "정기예금" : "파킹통장", assetClass: .cash,
                          amount: Double(principal) ?? 0,
                          incomeKind: .interest,
                          annualYieldPct: Double(ratePct) ?? 0,
                          sortOrder: assets.count)
        context.insert(asset)
        try? context.save()
        added = true
    }

    // 월별 누적 잔액 곡선 + 목표선. 목표 대비 달성도도 함께.
    private func savingsGrowthCard(maturity: Double) -> some View {
        let pts = series
        let m = pts.last?.month ?? 1
        let byYear = m > 18
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("목표까지 모이는 흐름")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if goalValue > 0 {
                    let pct = min(maturity / goalValue, 1)
                    Text(maturity >= goalValue ? "목표 달성 🎉" : "목표의 \(Fmt.percent(pct, fraction: 0))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(maturity >= goalValue ? Theme.positive : Theme.accent)
                }
            }
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("개월", p.month), y: .value("잔액", p.value))
                        .foregroundStyle(LinearGradient(
                            colors: [Theme.positive.opacity(0.28), Theme.positive.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("개월", p.month), y: .value("잔액", p.value))
                        .foregroundStyle(Theme.positive)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if goalValue > 0 {
                    RuleMark(y: .value("목표", goalValue))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("목표 \(Fmt.krw(goalValue))원")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Fmt.krw(v))원").font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    if let mm = value.as(Int.self) {
                        AxisValueLabel {
                            Text(byYear ? "\(mm / 12)년" : "\(mm)개월")
                                .font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .frame(height: 200)
            if goalValue > 0, maturity < goalValue {
                Text("만기에 목표까지 \(Fmt.krw(goalValue - maturity))원 부족해요. 기간·납입액·이자율을 올려보세요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 투자 예측 (내 자산이 앞으로 어떻게 될까)

// 보유 자산의 과거 기록(스냅샷)과 자산 종류별 일반 변동성을 함께 써서, 앞으로의
// 자산 흐름을 몬테카를로로 추정한다. 정확한 예언이 아니라 '이 정도 범위' 감각용 —
// 변동성이 큰 자산(코인·주식)이 많을수록 범위 밴드가 넓게 벌어진다.
private struct InvestForecastSection: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]

    @AppStorage("sim.invest.years")   private var yearsText = "5"
    @AppStorage("sim.invest.monthly") private var monthlyAdd = "0"

    // 예측에 쓰는 자산 종류 하나 — 현재액 + 가정한 연 수익률·변동성.
    private struct ClassAssumption: Identifiable {
        let id = UUID()
        let assetClass: AssetClass
        let current: Double
        let mu: Double          // 연 기대수익률
        let sigma: Double       // 연 변동성
        let fromHistory: Bool   // 과거 기록으로 보정했는지
    }

    private struct BandPoint: Identifiable {
        let id = UUID()
        let month: Int
        let low: Double     // 보수적 (하위 10%)
        let mid: Double     // 중앙값
        let high: Double    // 낙관적 (상위 10%)
    }

    // xorshift 고정 시드 난수 — 입력이 같으면 그래프도 같게(리렌더 안정).
    private struct RNG {
        var state: UInt64
        mutating func uniform() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
        mutating func normal() -> Double {
            let u1 = max(uniform(), 1e-9), u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }

    // 자산 종류별 일반적인 연 수익률·변동성 (장기 통계 근사).
    private static func prior(for ac: AssetClass) -> (mu: Double, sigma: Double) {
        switch ac {
        case .stocks:     return (0.07,  0.15)
        case .fund:       return (0.06,  0.12)
        case .crypto:     return (0.15,  0.60)
        case .bond:       return (0.035, 0.05)
        case .cash:       return (0.03,  0.005)
        case .realEstate: return (0.04,  0.08)
        case .pension:    return (0.04,  0.06)
        case .jeonse:     return (0.0,   0.0)
        case .deposit:    return (0.025, 0.01)
        case .insurance:  return (0.03,  0.03)
        default:          return (0.03,  0.05)
        }
    }

    private var years: Int { min(30, max(1, Int(yearsText) ?? 5)) }

    // 부채를 뺀, 값이 있는 자산 종류별 현재 합계.
    private var currentByClass: [(ac: AssetClass, value: Double)] {
        AssetClass.allCases.compactMap { ac in
            guard ac != .debt else { return nil }
            let v = assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
            return v > 0 ? (ac, v) : nil
        }
    }

    private var currentTotal: Double { currentByClass.reduce(0) { $0 + $1.value } }

    // 과거 스냅샷에서 이 종류의 월 수익률을 추정해 일반값과 반반 섞는다.
    // 기록엔 저축 입금도 섞여 있어 수익률이 부풀 수 있으니 상한을 함께 둔다.
    private func estimate(for ac: AssetClass) -> (mu: Double, sigma: Double, fromHistory: Bool) {
        let prior = Self.prior(for: ac)
        let series = snapshots.compactMap { s -> (date: Date, value: Double)? in
            let v = s.total(for: ac)
            return v > 0 ? (s.date, v) : nil
        }
        var rets: [Double] = []
        for k in 1..<max(1, series.count) {
            let dtMonths = series[k].date.timeIntervalSince(series[k - 1].date) / 86_400 / 30.44
            guard dtMonths > 0.25 else { continue }
            let r = log(series[k].value / series[k - 1].value) / dtMonths
            if r.isFinite { rets.append(max(-0.5, min(0.5, r))) }
        }
        guard rets.count >= 4 else { return (prior.mu, prior.sigma, false) }
        let meanM = rets.reduce(0, +) / Double(rets.count)
        let varM = rets.reduce(0) { $0 + pow($1 - meanM, 2) } / Double(max(1, rets.count - 1))
        // 기록이 쌓일수록 과거 데이터의 가중치를 올린다 — 4개(1/3 남짓)부터 시작해
        // 2년치(24개)면 70%까지. 입금이 섞인 왜곡은 상한 클램프로 계속 막는다.
        let w = min(0.7, Double(rets.count) / 24)
        let mu = max(-0.10, min(0.20, meanM * 12 * w + prior.mu * (1 - w)))
        let sigma = max(0.005, min(0.80, sqrt(varM * 12) * w + prior.sigma * (1 - w)))
        return (mu, sigma, true)
    }

    // 시장 공통 충격에 대한 민감도 — 주식·펀드는 거의 같이 움직이고, 코인·부동산도
    // 어느 정도 따라간다. 위험자산이 동시에 빠지는 현실을 밴드에 반영한다.
    private static func marketBeta(for ac: AssetClass) -> Double {
        switch ac {
        case .stocks, .fund: return 0.85
        case .crypto:        return 0.5
        case .realEstate:    return 0.3
        case .bond:          return 0.15
        default:             return 0.05
        }
    }

    private var assumptions: [ClassAssumption] {
        currentByClass.map { item in
            let e = estimate(for: item.ac)
            return ClassAssumption(assetClass: item.ac, current: item.value,
                                   mu: e.mu, sigma: e.sigma, fromHistory: e.fromHistory)
        }
    }

    // 비율(0.07)을 %로 바꿔 소수 둘째 자리까지 반올림 — 부동소수점 꼬리
    // (7.000000000001%) 가 그대로 노출되지 않게 한다.
    private func pct2(_ ratio: Double) -> String {
        Fmt.trimNumber((ratio * 10_000).rounded() / 100)
    }

    private func pctile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }

    // 몬테카를로 — 종류별로 매달 (μ, σ) 로그정규 성장을 굴려 합산, 분위수 밴드로.
    private func makeBand(_ asm: [ClassAssumption]) -> [BandPoint] {
        guard !asm.isEmpty else { return [] }
        let months = years * 12
        let add = Double(monthlyAdd) ?? 0
        let total = asm.reduce(0) { $0 + $1.current }
        let weights = asm.map { $0.current / max(total, 1) }
        let paths = 200
        var totalsByMonth = Array(repeating: [Double](), count: months + 1)
        var rng = RNG(state: 88_172_645_463_325_252)
        for _ in 0..<paths {
            var values = asm.map(\.current)
            totalsByMonth[0].append(values.reduce(0, +))
            for mIdx in 1...months {
                // 이번 달의 시장 공통 충격 — 각 자산은 베타만큼 함께 흔들리고,
                // 나머지는 자기만의 충격으로 움직인다.
                let zMarket = rng.normal()
                for c in asm.indices {
                    let muM = asm[c].mu / 12
                    let sigM = asm[c].sigma / sqrt(12)
                    let beta = Self.marketBeta(for: asm[c].assetClass)
                    let z = beta * zMarket + sqrt(max(0, 1 - beta * beta)) * rng.normal()
                    let growth = exp(muM - sigM * sigM / 2 + sigM * z)
                    values[c] = values[c] * growth + add * weights[c]
                }
                totalsByMonth[mIdx].append(values.reduce(0, +))
            }
        }
        let step = max(1, months / 60)
        return (0...months).compactMap { mIdx in
            guard mIdx % step == 0 || mIdx == months else { return nil }
            let sortedVals = totalsByMonth[mIdx].sorted()
            return BandPoint(month: mIdx,
                             low: pctile(sortedVals, 0.10),
                             mid: pctile(sortedVals, 0.50),
                             high: pctile(sortedVals, 0.90))
        }
    }

    var body: some View {
        let asm = assumptions
        let band = makeBand(asm)
        VStack(spacing: 20) {
            if asm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(.largeTitle))
                        .foregroundStyle(Theme.textSecond)
                    Text("자산 탭에 자산을 등록하면\n앞으로의 흐름을 예측해드려요.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
                .cardStyle()
            } else {
                inputCard
                forecastCard(band)
                assumptionCard(asm)
                // 온디바이스 파운데이션 모델 해석 — 숫자 예측은 몬테카를로가 하고,
                // 모델은 그 결과의 '읽기'(리스크 구성·조언)만 맡는다.
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *),
                   case .available = SystemLanguageModel.default.availability {
                    ForecastAICard(prompt: aiPrompt(asm, band: band))
                }
                #endif
            }
        }
    }

    // 모델에게 넘길 요약 — 구성·가정·예측 범위를 짧은 한국어 프롬프트로.
    private func aiPrompt(_ asm: [ClassAssumption], band: [BandPoint]) -> String {
        let comp = asm.map {
            "\($0.assetClass.label) \(Fmt.krw($0.current))원(연 \(pct2($0.mu))%±\(pct2($0.sigma))%)"
        }.joined(separator: ", ")
        let tail = band.last.map {
            "\(years)년 뒤 중앙값 \(Fmt.krw($0.mid))원, 보수적 \(Fmt.krw($0.low))원 ~ 낙관적 \(Fmt.krw($0.high))원"
        } ?? ""
        return """
        다음은 한 개인 투자자의 자산 구성과 몬테카를로 예측 결과다.
        구성: \(comp).
        예측: \(tail).
        위 숫자를 바탕으로, 포트폴리오의 변동성 구성이 예측 범위에 어떤 영향을 주는지와 \
        범위를 좁히고 싶을 때 고려할 점을 한국어 존댓말 3문장 이내로 설명하라. \
        새로운 숫자를 지어내지 말고, 특정 종목 추천은 하지 마라.
        """
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("예측 조건")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                ForEach([1, 3, 5, 10], id: \.self) { y in
                    let selected = years == y
                    Button {
                        yearsText = String(y)
                    } label: {
                        Text("\(y)년")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selected ? Theme.accent.opacity(0.2) : Theme.surfaceHigh)
                            .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(selected ? Theme.accent.opacity(0.6) : Theme.hairline,
                                                 lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            simInputRow("월 추가 투자 (선택)", text: $monthlyAdd, suffix: "원", money: true)
            simMoneyChips($monthlyAdd, steps: [("+50만", 500_000), ("+100만", 1_000_000), ("−50만", -500_000)])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func forecastCard(_ band: [BandPoint]) -> some View {
        let last = band.last
        let year1 = band.first { $0.month >= 12 }
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(years)년 뒤 내 자산은")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if let last {
                Text("\(Fmt.krw(last.mid))원")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("보수적 \(Fmt.krw(last.low))원 ~ 낙관적 \(Fmt.krw(last.high))원")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }

            Chart {
                ForEach(band) { p in
                    AreaMark(x: .value("개월", p.month),
                             yStart: .value("보수적", p.low),
                             yEnd: .value("낙관적", p.high))
                        .foregroundStyle(Theme.accent.opacity(0.14))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("개월", p.month), y: .value("중앙값", p.mid))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                RuleMark(y: .value("지금", currentTotal))
                    .foregroundStyle(Theme.hairline)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("지금 \(Fmt.krw(currentTotal))원")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Fmt.krw(v))").font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    if let mm = value.as(Int.self) {
                        AxisValueLabel {
                            Text(mm >= 12 ? "\(mm / 12)년" : "지금")
                                .font(.caption2).foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .frame(height: 220)

            HStack(spacing: 0) {
                if let year1 {
                    simStat("1년 후 (중앙값)", "\(Fmt.krw(year1.mid))원")
                }
                if let last {
                    simStat("\(years)년 후 범위", "\(Fmt.krw(last.low)) ~ \(Fmt.krw(last.high))원", tint: Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func assumptionCard(_ asm: [ClassAssumption]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("종류별 가정")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(asm) { a in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hexCode: a.assetClass.colorHex))
                        .frame(width: 8, height: 8)
                    Text(a.assetClass.label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    if a.fromHistory {
                        Text("기록 기반")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.15))
                            .foregroundStyle(Theme.accent)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Fmt.krw(a.current))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("연 \(pct2(a.mu))% ± \(pct2(a.sigma))%")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
            }
            Text("‘기록 기반’은 추이 기록으로 수익률을 보정한 종류예요. 기록에는 저축 입금도 섞여 있어 실제 수익률보다 높게 잡힐 수 있고, 그래서 종류별 일반값과 반반 섞어 계산합니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 파운데이션 모델 해석 카드 (iOS 26 + Apple Intelligence 기기 전용)

#if canImport(FoundationModels)
// 예측 결과를 온디바이스 모델이 자연어로 풀어주는 카드 — 수치는 건드리지 않고
// '읽는 법'만 돕는다. 버튼을 눌렀을 때만 생성하고, 결과는 참고용임을 명시한다.
@available(iOS 26.0, *)
private struct ForecastAICard: View {
    let prompt: String

    @State private var summary: String?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 해석", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if loading { ProgressView() }
            }
            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !loading {
                Button {
                    generate()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                        Text(failed ? "다시 시도" : "이 예측, 어떻게 읽어야 할까?")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
            }
            Text("기기 안에서 동작하는 애플 파운데이션 모델의 참고용 해석이에요. 투자 조언이 아닙니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        // 기간·구성이 바뀌어 프롬프트가 달라지면 이전 해석은 비운다.
        .onChange(of: prompt) { _, _ in summary = nil; failed = false }
    }

    private func generate() {
        loading = true
        failed = false
        let request = prompt
        Task { @MainActor in
            defer { loading = false }
            do {
                let session = LanguageModelSession()
                summary = try await session.respond(to: request).content
            } catch {
                failed = true
            }
        }
    }
}
#endif
