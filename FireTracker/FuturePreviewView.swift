//
//  FuturePreviewView.swift
//  FireTracker
//
//  퇴사 그날 미리보기 — 퇴사각 프로의 중심 화면.
//
//  "몇 살에 그만둘 수 있나"까지는 대시보드가 무료로 답한다. 이 화면은 그 다음 질문,
//  "그날 가면 어떤 삶이 있나"에 답한다: 그날 내 자산, 매달 나가는 돈(건보료·국민연금까지),
//  그 돈이 몇 살까지 버틸 확률, 어느 계좌부터 꺼내야 세금이 적은지, 선택을 바꾸면 어떻게 달라지는지.
//
//  입력은 FutureProfile 하나에 모이고(자산·목표에서 기본값을 채운다), 계산은 FutureEngine 이 한다.
//

import SwiftUI
import SwiftData
import Charts

// MARK: - 자산·설정에서 미래 계산 입력 만들기

/// 등록된 자산과 목표에서 미리보기의 기본값을 뽑고, 프로필의 직접 입력으로 덮어쓴다.
struct FutureContext {
    let profile: FutureProfile
    let settings: FireSettings
    let assets: [Asset]
    let snapshots: [NetWorthSnapshot]
    /// 진짜 퇴사 나이 — 몬테카를로를 여러 번 돌려야 해서 만들 때 한 번만 구해 둔다.
    private(set) var realQuitAge: Int?

    init(profile: FutureProfile, settings: FireSettings, assets: [Asset], snapshots: [NetWorthSnapshot]) {
        self.profile = profile
        self.settings = settings
        self.assets = assets
        self.snapshots = snapshots
        self.realQuitAge = nil
        if profile.quitAge == 0, settings.currentAge > 0 { self.realQuitAge = searchRealQuitAge() }
    }

    // 굴릴 수 있는 돈 — 실거주 집·보증금·차처럼 살면서 쓰는 자산은 빼고,
    // 빚은 집·보증금으로 먼저 갚는다고 보고 그걸 넘는 몫만 뺀다(주담대가 집값 안이면 영향 없음).
    static let investableClasses: Set<AssetClass> = [
        .cash, .stocks, .fund, .bond, .crypto, .pension, .insurance, .receivable, .valuables, .other, .custom,
    ]
    var investable: Double {
        let pos = assets.filter { Self.investableClasses.contains($0.assetClass) }.reduce(0) { $0 + $1.amount }
        let debt = assets.filter(\.isDebt).reduce(0) { $0 + $1.amount }
        let secured = assets.filter { $0.assetClass == .realEstate || $0.assetClass == .jeonse || $0.assetClass == .deposit }
            .reduce(0) { $0 + $1.amount }
        return max(0, pos - max(0, debt - secured))
    }
    var pensionAssets: Double {
        assets.filter { $0.assetClass == .pension }.reduce(0) { $0 + $1.amount }
    }
    var residenceValue: Double {
        assets.filter { $0.assetClass == .realEstate && $0.realEstateUse == .residence }
            .reduce(0) { $0 + $1.amount }
    }
    /// 임대 부동산이 내는 월세 — 자산을 팔지 않고 계속 들어오는 수입(연).
    var annualRent: Double {
        assets.filter { $0.assetClass == .realEstate }.reduce(0) { $0 + $1.annualIncome }
    }
    /// 이자·배당(연) — 부동산 외 자산이 내는 수입.
    var annualFinancial: Double {
        assets.filter { !$0.isDebt && $0.assetClass != .realEstate }.reduce(0) { $0 + $1.annualIncome }
    }
    var rentDepositPaid: Double {
        assets.filter { $0.assetClass == .jeonse || $0.assetClass == .deposit }.reduce(0) { $0 + $1.amount }
    }

    var currentAge: Int { settings.currentAge }
    var hasAge: Bool { settings.currentAge > 0 }

    var monthlySavings: Double {
        settings.plannedMonthlySavings != 0
            ? settings.plannedMonthlySavings
            : FireEngine.averageMonthlySavings(snapshots: snapshots)
    }
    var monthlySpend: Double {
        profile.monthlySpend > 0 ? profile.monthlySpend : settings.targetAnnualExpense / 12
    }
    var realReturn: Double { profile.realReturnPct / 100 }

    /// 대시보드 퇴사각 나이 — 순자산(집·보증금 포함)이 목표 자산에 닿는 나이.
    var assetQuitAge: Int {
        let netWorth = assets.reduce(0) { $0 + $1.netValue }
        let years = FireEngine.yearsToFire(currentNetWorth: netWorth, fireNumber: settings.fireNumber,
                                           monthlySavings: monthlySavings,
                                           annualReturn: settings.expectedAnnualReturn)
        guard let y = years, y.isFinite else {
            return settings.targetRetireAge > currentAge ? settings.targetRetireAge : currentAge + 10
        }
        return currentAge + Int(y.rounded(.up))
    }
    /// 진짜 퇴사 나이 — 꺼내 쓸 수 있는 돈만으로 끝 나이까지 버틸 확률이 85%를 넘는 가장 이른 나이.
    /// 집값을 목표 자산에 세는 대시보드 숫자보다 늦을 수 있다. 계산 범위 안에 없으면 nil.
    static let safeThreshold = 0.85
    private func searchRealQuitAge() -> Int? {
        let safeThreshold = Self.safeThreshold
        let endAge = effectiveProfile.endAge
        guard currentAge < endAge - 1 else { return nil }
        var lo = currentAge, hi = min(endAge - 1, currentAge + 45)
        // 늦게 그만둘수록 확률이 오르므로 이분 탐색.
        guard monteCarlo(quitAge: hi, paths: 400).successRate >= safeThreshold else { return nil }
        while lo < hi {
            let mid = (lo + hi) / 2
            if monteCarlo(quitAge: mid, paths: 400).successRate >= safeThreshold { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// 미리보기가 그리는 퇴사 나이 — 직접 정했으면 그 나이, 아니면 진짜 퇴사 나이(없으면 대시보드 나이).
    var quitAge: Int {
        if profile.quitAge > 0 { return max(currentAge, profile.quitAge) }
        return realQuitAge ?? assetQuitAge
    }
    func year(at age: Int) -> Int { Calendar.current.component(.year, from: Date()) + max(0, age - currentAge) }
    var quitYear: Int { year(at: quitAge) }

    /// 퇴사 때 굴릴 수 있는 돈(오늘 돈 기준, 평균 수익률로 단순 계산).
    func investableAt(age: Int, savingsFactor: Double = 1) -> Double {
        var a = investable
        for _ in currentAge..<max(currentAge, age) {
            a = a * (1 + realReturn) + monthlySavings * 12 * savingsFactor
        }
        return a
    }

    /// 프로필 빈칸을 자산에서 채운 실제 계산 입력.
    var effectiveProfile: FutureProfile {
        var p = profile
        if p.housePublicPrice <= 0 { p.housePublicPrice = residenceValue * 0.69 }
        if p.annualFinancialIncome <= 0 { p.annualFinancialIncome = annualFinancial }
        if p.annualOtherIncome <= 0 { p.annualOtherIncome = annualRent }
        if p.rentDepositPaid <= 0 { p.rentDepositPaid = rentDepositPaid }
        if p.lastMonthlySalary <= 0, settings.monthlyTakeHome > 0 {
            // 세후 → 세전 어림(공제율 약 20%).
            p.lastMonthlySalary = settings.monthlyTakeHome / 0.8
        }
        if p.averageDailyWage <= 0 { p.averageDailyWage = p.lastMonthlySalary * 12 / 365 }
        if p.pensionAccountShare <= 0, investable > 0 {
            p.pensionAccountShare = min(100, pensionAssets / investable * 100)
        }
        return p
    }

    var costs: PostQuitCosts { costs(at: quitAge) }
    func costs(at age: Int) -> PostQuitCosts {
        PostQuitCosts.compute(effectiveProfile, quitAge: age, quitYear: year(at: age))
    }

    /// 퇴사 후 한 해에 나가는 돈 — 생활비 + 새로 생기는 고정비 − 월세처럼 계속 들어오는 돈.
    var annualSpendAfterQuit: Double { annualSpend(at: quitAge) }
    func annualSpend(at age: Int) -> Double {
        max(0, (monthlySpend + costs(at: age).monthlyFixed) * 12 - annualRent)
    }

    func monteCarlo(quitAge q: Int? = nil, savingsFactor: Double = 1, spendFactor: Double = 1,
                    paths: Int = 2000) -> MonteCarloResult {
        let p = effectiveProfile
        let qa = q ?? quitAge
        let c = costs(at: qa)
        return MonteCarlo.run(.init(
            startAssets: investable,
            currentAge: currentAge,
            quitAge: qa,
            endAge: max(qa + 1, p.endAge),
            annualSavingsUntilQuit: monthlySavings * 12 * savingsFactor,
            annualSpendAfterQuit: annualSpend(at: qa) * spendFactor,
            publicPensionAnnual: p.publicPensionMonthly * 12,
            publicPensionStart: p.publicPensionStartAge,
            oneTimeAtQuit: c.unemploymentTotal,
            realReturn: realReturn,
            volatility: p.volatilityPct / 100,
            paths: paths
        ))
    }

    func withdrawal(_ s: WithdrawalPlan.Strategy) -> WithdrawalPlan {
        let p = effectiveProfile
        let total = investableAt(age: quitAge)
        let pension = total * p.pensionAccountShare / 100
        let isa = total * p.isaShare / 100
        return WithdrawalPlan.simulate(
            strategy: s,
            taxable: max(0, total - pension - isa), isa: isa, pension: pension,
            isaGainRatio: p.isaGainRatio, isaTaxFreeLimit: p.isaTaxFreeLimit,
            annualSpend: annualSpendAfterQuit,
            publicPension: p.publicPensionMonthly * 12, publicPensionStart: p.publicPensionStartAge,
            quitAge: quitAge, endAge: max(quitAge + 1, p.endAge), realReturn: realReturn)
    }
}

/// 미리보기 화면들이 함께 쓰는 데이터 묶음.
@MainActor
final class FutureModel: ObservableObject {
    @Published var profile: FutureProfile = .load() {
        didSet { if profile != oldValue { profile.save() } }
    }
    @Published var scenarios: [FutureScenario] = FutureScenario.load() {
        didSet { if scenarios != oldValue { FutureScenario.save(scenarios) } }
    }
}

// MARK: - 미리보기 본 화면

struct FuturePreviewView: View {
    @Query private var settingsList: [FireSettings]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @StateObject private var model = FutureModel()

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var ctx: FutureContext {
        FutureContext(profile: model.profile, settings: settings, assets: assets, snapshots: snapshots)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !ctx.hasAge {
                    needAgeCard
                } else {
                    let c = ctx
                    let costs = c.costs
                    let mc = c.monteCarlo()
                    header(c)
                    monthlyCard(c, costs)
                    survivalCard(c, mc)
                    withdrawalCard(c)
                    scenarioCard(c)
                    if costs.unemploymentTotal > 0 { unemploymentCard(costs) }
                    assumptionsCard
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("그날의 나")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { AppUsage.log(.futurePreviewOpened) }
    }

    private var needAgeCard: some View {
        NavigationLink {
            GoalSettingsView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("지금 나이를 알려 주세요")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("나이를 알아야 퇴사하는 날의 내 모습을 그릴 수 있어요. 내 목표에서 넣을 수 있어요.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
                Label("내 목표 열기", systemImage: "target")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // 1) 그날
    private func header(_ c: FutureContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(String(c.quitYear))년, \(c.quitAge)세")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.accentText)
            Text(c.quitAge <= c.currentAge ? LocalizedStringKey("오늘 회사를 그만둔다면") : LocalizedStringKey("회사를 그만두는 날"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("그날 굴릴 수 있는 돈 \(Fmt.krw(c.investableAt(age: c.quitAge)))원 (오늘 돈 기준)")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
            realQuitNote(c)
            NavigationLink {
                FutureTimingEditor(model: model, ctx: c)
            } label: {
                Label("퇴사 나이·생활비 바꾸기", systemImage: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 대시보드 퇴사각과 진짜 퇴사 나이가 다를 때 — 왜 다른지가 이 화면의 핵심 통찰이다.
    @ViewBuilder
    private func realQuitNote(_ c: FutureContext) -> some View {
        if model.profile.quitAge == 0 {
            if let real = c.realQuitAge {
                if real > c.assetQuitAge {
                    Text("대시보드의 \(c.assetQuitAge)세는 집과 보증금까지 목표 자산에 센 나이예요. 꺼내 쓸 수 있는 돈만으로 \(c.effectiveProfile.endAge)세까지 버틸 확률이 85%를 넘는 건 \(real)세부터예요.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.negative)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("꺼내 쓸 수 있는 돈만으로 \(c.effectiveProfile.endAge)세까지 버틸 확률이 85%를 넘는 가장 이른 나이예요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("지금 계획으로는 \(c.currentAge + 45)세 전에 버틸 확률 85%에 닿지 않아요. 저축을 늘리거나 생활비를 줄이는 시나리오를 아래에서 비교해 보세요.")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // 2) 매달 나가는 돈
    private func monthlyCard(_ c: FutureContext, _ costs: PostQuitCosts) -> some View {
        NavigationLink {
            PostQuitCostView(model: model, ctx: c)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("매달 나가는 돈", trailing: true)
                Text("\(Fmt.krw(c.monthlySpend + costs.monthlyFixed))원")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                lineItem(String(localized: "생활비"), c.monthlySpend)
                lineItem(String(localized: "건강보험료 · \(costs.bestHealthLabel)"), costs.bestHealthMonthly)
                if costs.voluntaryPensionMonthly > 0 {
                    lineItem(String(localized: "국민연금 임의가입"), costs.voluntaryPensionMonthly)
                }
                if costs.monthlyFixed > 0 {
                    Text("회사가 반을 내 주던 보험료를 이제 혼자 내요. 이 돈까지 쳐야 진짜 생활비예요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // 3) 버틸 확률
    private func survivalCard(_ c: FutureContext, _ mc: MonteCarloResult) -> some View {
        NavigationLink {
            SurvivalDetailView(model: model, ctx: c)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("이 돈이 버틸 확률", trailing: true)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.percent(mc.successRate, fraction: 0))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(survivalColor(mc.successRate))
                    Text("\(c.effectiveProfile.endAge)세까지")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                }
                SurvivalChart(bands: mc.bands, quitAge: c.quitAge)
                    .frame(height: 180)
                Text(survivalLine(mc))
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
                if c.effectiveProfile.publicPensionMonthly <= 0 {
                    Label("예상 국민연금을 넣지 않아 연금 없이 계산했어요. 매달 나가는 돈에서 넣을 수 있어요.", systemImage: "exclamationmark.circle")
                        .font(.body)
                        .foregroundStyle(Theme.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func survivalLine(_ mc: MonteCarloResult) -> String {
        if let bad = mc.badCaseDepletionAge {
            return String(localized: "시장이 나쁘게 흘러가는 10번 중 1번은 \(bad)세쯤 돈이 바닥나요.")
        }
        return String(localized: "2,000가지 시장 흐름 중 나쁜 쪽 10%에서도 끝까지 버텨요.")
    }

    // 4) 어느 계좌부터
    private func withdrawalCard(_ c: FutureContext) -> some View {
        let smart = c.withdrawal(.smart)
        let naive = c.withdrawal(.naive)
        let saved = naive.totalTax - smart.totalTax
        return NavigationLink {
            WithdrawalDetailView(model: model, ctx: c)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("어느 계좌부터 꺼낼까", trailing: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(withdrawalSteps(c).enumerated()), id: \.offset) { i, text in
                        stepLine(i + 1, text)
                    }
                }
                if saved > 0 {
                    Text("필요할 때 연금부터 한꺼번에 꺼내는 것보다 세금이 \(Fmt.krw(saved))원 줄어요.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.positive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func withdrawalSteps(_ c: FutureContext) -> [String] {
        let start = KoreaRules2026.pensionStartAge
        let nps = c.effectiveProfile.publicPensionStartAge
        var steps: [String] = []
        if c.quitAge < start {
            steps.append(String(localized: "\(c.quitAge)~\(start - 1)세: 일반계좌와 ISA에서 꺼내 써요"))
            steps.append(String(localized: "\(start)세부터: 연금계좌에서 해마다 1,500만원까지 먼저, 모자란 몫은 일반계좌에서"))
        } else {
            steps.append(String(localized: "\(c.quitAge)세부터: 연금계좌에서 해마다 1,500만원까지 먼저"))
            steps.append(String(localized: "모자란 몫은 일반계좌, 그다음 ISA에서"))
        }
        if c.effectiveProfile.publicPensionMonthly > 0 {
            steps.append(String(localized: "\(nps)세부터: 국민연금이 들어와 꺼낼 돈이 줄어요"))
        }
        return steps
    }

    // 5) 다른 선택이라면
    private func scenarioCard(_ c: FutureContext) -> some View {
        NavigationLink {
            ScenarioCompareView(model: model, ctx: c)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("다른 선택이라면", trailing: true)
                ForEach(model.scenarios.prefix(4)) { s in
                    let r = ScenarioOutcome.compute(s, ctx: c, paths: 600)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(r.quitAge)세 퇴사")
                                .font(.body)
                                .foregroundStyle(Theme.textSecond)
                        }
                        Spacer()
                        Text(Fmt.percent(r.success, fraction: 0))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(survivalColor(r.success))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func unemploymentCard(_ costs: PostQuitCosts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("실업급여", trailing: false)
            Text("\(Fmt.krw(costs.unemploymentTotal))원")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.positive)
            Text("하루 \(Fmt.won(costs.unemploymentDaily))원 × \(costs.unemploymentDays)일. 비자발적 퇴사일 때만 받을 수 있어요.")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var assumptionsCard: some View {
        Text("2026년 제도(건강보험료율 7.19%, 재산 점수당 211.5원, 국민연금 9.5%에서 해마다 0.5%p 인상, 사적연금 연 1,500만원 저율과세)와 입력한 가정으로 계산한 추정이에요. 금액은 모두 오늘 돈 기준이고, 실제 보험료와 세금은 공단과 국세청에서 확인하세요.")
            .font(.body)
            .foregroundStyle(Theme.textSecond)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 작은 조각

    private func cardTitle(_ title: LocalizedStringKey, trailing: Bool) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if trailing {
                Image(systemName: "chevron.right")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }

    private func lineItem(_ label: String, _ value: Double) -> some View {
        AdaptiveRow {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.textSecond)
        } trailing: {
            Text("\(Fmt.krw(value))원")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func stepLine(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.accentText)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

func survivalColor(_ rate: Double) -> Color {
    rate >= 0.85 ? Theme.positive : rate >= 0.6 ? Theme.accent : Theme.negative
}

// MARK: - 확률 밴드 차트

struct SurvivalChart: View {
    let bands: [MonteCarloResult.Band]
    let quitAge: Int

    var body: some View {
        Chart {
            ForEach(bands) { b in
                AreaMark(x: .value("나이", b.age),
                         yStart: .value("나쁠 때", b.p10),
                         yEnd: .value("좋을 때", b.p90))
                    .foregroundStyle(Theme.accent.opacity(0.18))
                LineMark(x: .value("나이", b.age), y: .value("보통", b.p50))
                    .foregroundStyle(Theme.accentText)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            RuleMark(x: .value("퇴사", quitAge))
                .foregroundStyle(Theme.textSecond.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .chartXScale(domain: (bands.first?.age ?? 0)...(bands.last?.age ?? 100))
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(Fmt.krw(d)).font(.body) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let a = v.as(Int.self) { Text("\(a)세").font(.body) }
                }
            }
        }
    }
}

// MARK: - 공용 입력 행

struct FutureMoneyRow: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    var placeholder: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            HStack {
                TextField(placeholder > 0 ? Fmt.won(placeholder) : "0",
                          value: $value, format: .number.grouping(.automatic))
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .fixedSize()   // '원' 이 금액 바로 옆에 붙게
                Text("원")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
                Spacer(minLength: 0)
            }
            if value > 0 {
                Text("= \(Fmt.krw(value))원")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            } else if placeholder > 0 {
                Text("비워 두면 자산에서 추정한 \(Fmt.krw(placeholder))원을 써요")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }
}

struct FutureNumberRow: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let suffix: LocalizedStringKey

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            TextField("0", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .accessibilityLabel(label)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(maxWidth: 110)
            Text(suffix)
                .font(.body)
                .foregroundStyle(Theme.textSecond)
        }
    }
}

struct FutureAgeRow: View {
    let label: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int> = 20...100

    var body: some View {
        Stepper(value: $value, in: range) {
            AdaptiveRow {
                Text(label)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
            } trailing: {
                Text("\(value)세")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

// MARK: - 퇴사 나이·생활비

struct FutureTimingEditor: View {
    @ObservedObject var model: FutureModel
    let ctx: FutureContext

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.profile.quitAge == 0 },
                    set: { model.profile.quitAge = $0 ? 0 : ctx.quitAge }
                )) {
                    Text("퇴사각 나이 그대로 쓰기")
                        .font(.body)
                }
                .tint(Theme.accent)
                if model.profile.quitAge > 0 {
                    FutureAgeRow(label: "퇴사 나이", value: $model.profile.quitAge,
                                 range: max(ctx.currentAge, 20)...80)
                }
                FutureAgeRow(label: "언제까지 계산할까", value: $model.profile.endAge, range: 70...110)
            } header: {
                Text("시점")
            } footer: {
                Text("퇴사각 나이는 대시보드에서 목표 자산에 닿는 나이예요.")
                    .font(.body)
            }

            Section {
                FutureMoneyRow(label: "퇴사 후 한 달 생활비", value: $model.profile.monthlySpend,
                               placeholder: ctx.settings.targetAnnualExpense / 12)
            } header: {
                Text("생활비")
            } footer: {
                Text("건강보험료·국민연금은 따로 계산해 더해요. 여기엔 먹고 사는 돈만 넣어 주세요.")
                    .font(.body)
            }

            Section {
                FutureNumberRow(label: "물가를 뺀 연 수익률", value: $model.profile.realReturnPct, suffix: "%")
                FutureNumberRow(label: "한 해 출렁임(변동성)", value: $model.profile.volatilityPct, suffix: "%")
            } header: {
                Text("시장 가정")
            } footer: {
                Text("주식과 채권을 섞은 포트폴리오는 보통 실질 수익률 3~5%, 변동성 8~15% 정도로 봐요.")
                    .font(.body)
            }
        }
        .navigationTitle("시점과 생활비")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
    }
}

// MARK: - 퇴사 후 고정비 상세

struct PostQuitCostView: View {
    @ObservedObject var model: FutureModel
    let ctx: FutureContext

    private var live: FutureContext {
        FutureContext(profile: model.profile, settings: ctx.settings, assets: ctx.assets, snapshots: ctx.snapshots)
    }

    var body: some View {
        let c = live
        let costs = c.costs
        let eff = c.effectiveProfile
        Form {
            Section {
                resultRow(String(localized: "지역가입자"), costs.regional.total,
                          best: costs.bestHealthLabel == String(localized: "지역가입자"))
                if let cont = costs.continued {
                    resultRow(String(localized: "임의계속가입(최대 3년)"), cont,
                              best: costs.bestHealthLabel == String(localized: "임의계속가입(최대 3년)"))
                } else {
                    Text("임의계속가입: 퇴사 전 18개월 안에 직장가입 1년 이상이어야 해요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                }
                if model.profile.hasFamilyEmployee {
                    Text(costs.dependentPossible
                         ? LocalizedStringKey("가족의 피부양자로 올라갈 수 있어 보여요. 보험료 0원.")
                         : LocalizedStringKey("피부양자 기준(연소득 2,000만원, 재산 과표 5.4억원)을 넘어 피부양자는 어려워요."))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(costs.dependentPossible ? Theme.positive : Theme.negative)
                }
            } header: {
                Text("건강보험료 (한 달, 장기요양 포함)")
            } footer: {
                Text("지역가입자 = 소득 \(Fmt.krw(costs.regional.incomeMonthly))원 × 7.19% + 재산 \(Int(costs.regional.propertyScore))점 × 211.5원. 임의계속가입은 퇴사 후 첫 지역 고지서 납부기한에서 2개월 안에 신청해야 해요.")
                    .font(.body)
            }

            Section {
                FutureMoneyRow(label: "퇴사 직전 세전 월급", value: $model.profile.lastMonthlySalary,
                               placeholder: eff.lastMonthlySalary)
                FutureNumberRow(label: "직장 다닌 기간", value: $model.profile.yearsEmployed, suffix: "년")
                FutureMoneyRow(label: "집 공시가격", value: $model.profile.housePublicPrice,
                               placeholder: eff.housePublicPrice)
                FutureNumberRow(label: "공시가격 중 과표 비율", value: $model.profile.housePriceRatio, suffix: "%")
                FutureMoneyRow(label: "다른 재산 과표(토지·건물)", value: $model.profile.otherPropertyBase)
                FutureMoneyRow(label: "내가 낸 전월세 보증금", value: $model.profile.rentDepositPaid,
                               placeholder: eff.rentDepositPaid)
                FutureMoneyRow(label: "이자·배당 (연)", value: $model.profile.annualFinancialIncome,
                               placeholder: eff.annualFinancialIncome)
                FutureMoneyRow(label: "월세·사업 등 다른 소득 (연)", value: $model.profile.annualOtherIncome,
                               placeholder: eff.annualOtherIncome)
                Toggle(isOn: $model.profile.hasFamilyEmployee) {
                    Text("직장에 다니는 가족이 있어요")
                        .font(.body)
                }
                .tint(Theme.accent)
            } header: {
                Text("건강보험료 계산에 쓰는 것")
            } footer: {
                Text("이자·배당은 연 1,000만원을 넘으면 전액이 소득으로 잡혀요. 연금저축·IRP에서 받는 사적연금은 넣지 않았어요. 주택 과표 비율 60%는 어림이라 재산세 고지서의 과세표준을 넣으면 더 정확해요.")
                    .font(.body)
            }

            Section {
                Toggle(isOn: $model.profile.voluntaryPension) {
                    Text("60세까지 국민연금 임의가입")
                        .font(.body)
                }
                .tint(Theme.accent)
                if model.profile.voluntaryPension {
                    FutureMoneyRow(label: "기준소득월액", value: $model.profile.voluntaryBaseIncome)
                    Text("한 달 \(Fmt.krw(costs.voluntaryPensionMonthly))원 (\(String(c.quitYear))년 보험료율 기준)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                FutureMoneyRow(label: "예상 국민연금 (월, 오늘 돈)", value: $model.profile.publicPensionMonthly)
                FutureAgeRow(label: "국민연금 받는 나이", value: $model.profile.publicPensionStartAge, range: 60...70)
            } header: {
                Text("국민연금")
            } footer: {
                Text("예상 연금액은 국민연금공단 '내 곁에 국민연금'에서 볼 수 있어요. 임의가입을 하면 가입 기간이 늘어 나중에 받는 돈도 늘어요.")
                    .font(.body)
            }

            Section {
                Toggle(isOn: $model.profile.involuntaryQuit) {
                    Text("권고사직·계약만료 같은 비자발적 퇴사")
                        .font(.body)
                }
                .tint(Theme.accent)
                if model.profile.involuntaryQuit {
                    FutureMoneyRow(label: "퇴사 전 3개월 평균임금 (하루)", value: $model.profile.averageDailyWage,
                                   placeholder: eff.averageDailyWage)
                    Text(costs.unemploymentTotal > 0
                         ? LocalizedStringKey("하루 \(Fmt.won(costs.unemploymentDaily))원 × \(costs.unemploymentDays)일 = \(Fmt.krw(costs.unemploymentTotal))원")
                         : LocalizedStringKey("고용보험 가입 기간이 180일 이상이어야 받을 수 있어요."))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            } header: {
                Text("실업급여")
            } footer: {
                Text("스스로 그만두면 원칙적으로 받을 수 없어요. 2026년 하루 66,048원~68,100원, 나이와 가입 기간에 따라 120~270일.")
                    .font(.body)
            }
        }
        .navigationTitle("퇴사 후 고정비")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
    }

    private func resultRow(_ label: String, _ value: Double, best: Bool) -> some View {
        HStack {
            Text(label)
                .font(.body.weight(best ? .semibold : .regular))
                .foregroundStyle(Theme.textPrimary)
            if best {
                Text("가장 적음")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.positive)
            }
            Spacer()
            Text("\(Fmt.krw(value))원")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(best ? Theme.positive : Theme.textPrimary)
        }
    }
}

// MARK: - 버틸 확률 상세

struct SurvivalDetailView: View {
    @ObservedObject var model: FutureModel
    let ctx: FutureContext

    var body: some View {
        let c = FutureContext(profile: model.profile, settings: ctx.settings, assets: ctx.assets, snapshots: ctx.snapshots)
        let mc = c.monteCarlo()
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(c.effectiveProfile.endAge)세까지 버틸 확률")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(Fmt.percent(mc.successRate, fraction: 0))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(survivalColor(mc.successRate))
                    SurvivalChart(bands: mc.bands, quitAge: c.quitAge)
                        .frame(height: 240)
                    Text("가운데 선은 보통의 경우, 색칠한 띠는 좋을 때(상위 10%)와 나쁠 때(하위 10%) 사이예요. 점선이 퇴사하는 해예요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("어떻게 계산했나")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("지금 굴릴 수 있는 돈 \(Fmt.krw(c.investable))원에서 시작해, 퇴사 전엔 해마다 \(Fmt.krw(c.monthlySavings * 12))원을 모으고, 퇴사 후엔 해마다 \(Fmt.krw(c.annualSpendAfterQuit))원을 써요. 해마다 수익률이 평균 \(Fmt.trimNumber(model.profile.realReturnPct))%, 출렁임 \(Fmt.trimNumber(model.profile.volatilityPct))%로 무작위로 정해지는 2,000가지 인생을 돌려, 끝까지 돈이 남은 비율을 셌어요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("실거주 집, 보증금, 차는 살면서 쓰는 자산이라 뺐어요. 빚은 집과 보증금으로 먼저 갚는다고 보고, 그걸 넘는 몫만 뺐어요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink {
                        FutureTimingEditor(model: model, ctx: c)
                    } label: {
                        Label("가정 바꾸기", systemImage: "slider.horizontal.3")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("버틸 확률")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 인출 순서 상세

struct WithdrawalDetailView: View {
    @ObservedObject var model: FutureModel
    let ctx: FutureContext

    var body: some View {
        let c = FutureContext(profile: model.profile, settings: ctx.settings, assets: ctx.assets, snapshots: ctx.snapshots)
        let smart = c.withdrawal(.smart)
        let naive = c.withdrawal(.naive)
        Form {
            Section {
                compareRow(String(localized: "절세 순서"), smart, highlight: true)
                compareRow(String(localized: "연금부터 한꺼번에"), naive, highlight: false)
            } header: {
                Text("평생 내는 세금")
            } footer: {
                Text("55세 전에는 일반계좌·ISA로 버티고, 55세부터는 연금계좌에서 해마다 1,500만원(저율 3.3~5.5%) 안쪽만 꺼낸 뒤 모자란 몫을 일반계좌에서 채우는 순서예요.")
                    .font(.body)
            }

            Section {
                WithdrawalChart(plan: smart)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("해마다 어디서 꺼내나 (절세 순서)")
            }

            Section {
                FutureNumberRow(label: "연금저축·IRP 비중", value: $model.profile.pensionAccountShare, suffix: "%")
                FutureNumberRow(label: "ISA 비중", value: $model.profile.isaShare, suffix: "%")
                FutureNumberRow(label: "ISA 중 수익 비율", value: $model.profile.isaGainRatio, suffix: "%")
                FutureMoneyRow(label: "ISA 비과세 한도", value: $model.profile.isaTaxFreeLimit)
            } header: {
                Text("퇴사 때 계좌 나눔")
            } footer: {
                Text("비워 두면 자산 탭의 '연금' 비중을 써요. ISA 비과세 한도는 일반형 200만원(서민형 400만원) 기준이며 개편되면 바꿔 주세요. 국내 상장주식 매매차익은 비과세로 봤어요.")
                    .font(.body)
            }
        }
        .navigationTitle("인출 순서")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
    }

    private func compareRow(_ label: String, _ plan: WithdrawalPlan, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            } trailing: {
                Text("\(Fmt.krw(plan.totalTax))원")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(highlight ? Theme.positive : Theme.textPrimary)
            }
            Text(plan.depletionAge.map { String(localized: "\($0)세에 돈이 바닥나요") }
                 ?? String(localized: "끝까지 버텨요 · 남는 돈 \(Fmt.krw(plan.years.last?.remaining ?? 0))원"))
                .font(.body)
                .foregroundStyle(Theme.textSecond)
        }
    }
}

struct WithdrawalChart: View {
    let plan: WithdrawalPlan

    private struct Bar: Identifiable {
        let id = UUID()
        let age: Int
        let kind: String
        let amount: Double
    }

    private var bars: [Bar] {
        plan.years.flatMap { y in
            [Bar(age: y.age, kind: String(localized: "일반계좌"), amount: y.taxable),
             Bar(age: y.age, kind: String(localized: "ISA"), amount: y.isa),
             Bar(age: y.age, kind: String(localized: "연금계좌"), amount: y.pension)]
        }
        .filter { $0.amount > 0 }
    }

    var body: some View {
        Chart(bars) { b in
            BarMark(x: .value("나이", b.age), y: .value("금액", b.amount))
                .foregroundStyle(by: .value("계좌", b.kind))
        }
        .chartForegroundStyleScale([
            String(localized: "일반계좌"): Theme.accent,
            String(localized: "ISA"): Theme.fall,
            String(localized: "연금계좌"): Theme.positive,
        ])
        .chartLegend(position: .bottom) {
            HStack(spacing: 14) {
                legend(String(localized: "일반계좌"), Theme.accent)
                legend(String(localized: "ISA"), Theme.fall)
                legend(String(localized: "연금계좌"), Theme.positive)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(Fmt.krw(d)).font(.body) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisValueLabel {
                    if let a = v.as(Int.self) { Text("\(a)세").font(.body) }
                }
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.body).foregroundStyle(Theme.textSecond)
        }
    }
}

// MARK: - 시나리오 비교

struct ScenarioOutcome {
    let quitAge: Int
    let assetsAtQuit: Double
    let success: Double
    let badDepletion: Int?

    static func compute(_ s: FutureScenario, ctx: FutureContext, paths: Int = 1000) -> ScenarioOutcome {
        let q = s.quitNow ? ctx.currentAge : max(ctx.currentAge, ctx.quitAge + s.quitAgeOffset)
        let sf = 1 + s.savingsChangePct / 100
        let mc = ctx.monteCarlo(quitAge: q, savingsFactor: sf, spendFactor: 1 + s.spendChangePct / 100, paths: paths)
        return ScenarioOutcome(quitAge: q, assetsAtQuit: ctx.investableAt(age: q, savingsFactor: sf),
                               success: mc.successRate, badDepletion: mc.badCaseDepletionAge)
    }
}

struct ScenarioCompareView: View {
    @ObservedObject var model: FutureModel
    let ctx: FutureContext
    @State private var editing: FutureScenario?

    var body: some View {
        let c = FutureContext(profile: model.profile, settings: ctx.settings, assets: ctx.assets, snapshots: ctx.snapshots)
        List {
            Section {
                ForEach(model.scenarios) { s in
                    let r = ScenarioOutcome.compute(s, ctx: c)
                    Button { editing = s } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AdaptiveRow {
                                Text(s.name)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                            } trailing: {
                                Text(Fmt.percent(r.success, fraction: 0))
                                    .font(.system(.title3, design: .rounded, weight: .bold))
                                    .foregroundStyle(survivalColor(r.success))
                            }
                            Text("\(r.quitAge)세 퇴사 · 그때 \(Fmt.krw(r.assetsAtQuit))원")
                                .font(.body)
                                .foregroundStyle(Theme.textSecond)
                            if let bad = r.badDepletion {
                                Text("나쁜 경우 \(bad)세에 바닥")
                                    .font(.body)
                                    .foregroundStyle(Theme.negative)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { model.scenarios.remove(atOffsets: $0) }
            } header: {
                Text("\(c.effectiveProfile.endAge)세까지 버틸 확률")
            } footer: {
                Text("탭하면 조건을 바꿀 수 있어요. 확률은 같은 시장 가정으로 계산해 서로 비교할 수 있어요.")
                    .font(.body)
            }

            Section {
                Button {
                    let s = FutureScenario(name: String(localized: "새 시나리오"), quitAgeOffset: 0,
                                           savingsChangePct: 0, spendChangePct: 0)
                    model.scenarios.append(s)
                    editing = s
                } label: {
                    Label("시나리오 추가", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                }
                Button {
                    model.scenarios = FutureScenario.defaults
                } label: {
                    Text("기본 시나리오로 되돌리기")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
        .navigationTitle("다른 선택이라면")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { s in
            ScenarioEditor(scenario: s) { updated in
                if let i = model.scenarios.firstIndex(where: { $0.id == updated.id }) {
                    model.scenarios[i] = updated
                }
            }
        }
    }
}

struct ScenarioEditor: View {
    @State var scenario: FutureScenario
    let onSave: (FutureScenario) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름", text: $scenario.name)
                        .font(.body)
                }
                Section {
                    Toggle(isOn: $scenario.quitNow) {
                        Text("오늘 그만두기")
                            .font(.body)
                    }
                    .tint(Theme.accent)
                    if !scenario.quitNow {
                        Stepper(value: $scenario.quitAgeOffset, in: -20...20) {
                            HStack {
                                Text("퇴사각 나이보다")
                                    .font(.body)
                                Spacer()
                                Text(scenario.quitAgeOffset == 0 ? LocalizedStringKey("그대로")
                                     : scenario.quitAgeOffset > 0 ? LocalizedStringKey("\(scenario.quitAgeOffset)년 늦게")
                                     : LocalizedStringKey("\(-scenario.quitAgeOffset)년 일찍"))
                                    .font(.body.weight(.semibold))
                            }
                        }
                    }
                } header: {
                    Text("퇴사 시점")
                }
                Section {
                    FutureNumberRow(label: "월 저축 변화", value: $scenario.savingsChangePct, suffix: "%")
                    FutureNumberRow(label: "퇴사 후 생활비 변화", value: $scenario.spendChangePct, suffix: "%")
                } header: {
                    Text("돈")
                } footer: {
                    Text("예: 이직으로 연봉이 올라 저축이 늘면 +30%, 지방으로 옮겨 생활비가 줄면 −20%.")
                        .font(.body)
                }
            }
            .navigationTitle("시나리오")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", systemImage: "checkmark") { onSave(scenario); dismiss() }
                }
            }
        }
    }
}
