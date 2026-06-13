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
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
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
    @AppStorage("sim.life.seeded")       private var seeded = false

    @Environment(\.modelContext) private var context
    @State private var showReflectConfirm = false
    @State private var reflected = false

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

                HStack(spacing: 0) {
                    simStat("은퇴(\(a.retire)세) 자산", "\(Fmt.krw(result.peak))원", tint: .blue)
                    if let dep = result.depletionAge {
                        simStat("자산 고갈", "\(dep)세", tint: Theme.negative)
                    } else {
                        simStat("\(a.end)세 잔액", "\(Fmt.krw(result.end))원", tint: .orange)
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

            // 계산값을 그대로 목표·설정으로 — 따로 설정 탭에서 다시 입력할 필요 없이.
            reflectButton

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
                Text("나이·자산·수익률은 설정과 등록한 자산에서 자동으로 채워져요. 바꾸면 이 계산에만 반영됩니다.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .onAppear { seedIfNeeded() }
        // 값이 바뀌면 다시 반영할 수 있게 버튼 상태를 되돌린다.
        .onChange(of: [currentAge, retireAge, retireMonthly, returnPct, monthlyLiving, grossSalary]) { _, _ in
            reflected = false
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
    }
}

// MARK: - 주담대 상환 시뮬레이션

private struct MortgageSimSection: View {
    @AppStorage("sim.mtg.principal") private var principal = "300000000"
    @AppStorage("sim.mtg.ratePct")   private var ratePct = "4.2"
    @AppStorage("sim.mtg.years")     private var years = "30"
    @AppStorage("sim.mtg.method")    private var method: RepayMethod = .equalPayment

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

    // 대출 조건을 부채 자산으로 만들어 카탈로그에 넣는다.
    private func addAsDebt() {
        let asset = Asset(name: "주택담보대출", assetClass: .debt,
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

            // 정기예금은 지금 넣어둔 원금이 곧 현재 자산 → 현금·예금으로 바로 추가.
            if kind == .deposit, (Double(principal) ?? 0) > 0 {
                simActionButton(
                    title: added ? "현금·예금에 추가됨" : "이 예금을 자산에 추가",
                    done: added,
                    confirmTitle: "이 예금을 자산에 추가할까요?",
                    confirmMessage: "원금 \(Fmt.krw(Double(principal) ?? 0))원이 ‘현금·예금’으로 등록되고, 연 \(ratePct)% 이자가 패시브 인컴에 반영됩니다.",
                    isPresented: $showAddConfirm,
                    action: addAsCash
                )
            }
        }
    }

    // 정기예금 원금을 현금·예금 자산으로 만들어 카탈로그에 넣는다.
    private func addAsCash() {
        let asset = Asset(name: "정기예금", assetClass: .cash,
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
