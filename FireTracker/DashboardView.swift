import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]

    @State private var showingAddAsset = false

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var latest: NetWorthSnapshot? {
        snapshots.sorted { $0.date > $1.date }.first
    }
    // Sum of the live catalog — used before the first record is saved so the
    // dashboard reflects registered assets immediately.
    private var hasCatalog: Bool { !assets.isEmpty }
    private var catalogTotal: Double { assets.reduce(0) { $0 + $1.netValue } }
    private func catalogTotal(for ac: AssetClass) -> Double {
        assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
    }
    // Live catalog is the source of truth for "current"; fall back to the last
    // recorded snapshot only when no assets are registered.
    private var netWorth: Double { hasCatalog ? catalogTotal : (latest?.netWorth ?? 0) }

    // Spendable (liquid) net worth — the figure that actually matters for FIRE.
    private var catalogLiquid: Double { assets.reduce(0) { $0 + $1.liquidValue } }
    private var liquidNetWorth: Double { hasCatalog ? catalogLiquid : (latest?.liquidNetWorth ?? 0) }
    private var lockedNetWorth: Double { netWorth - liquidNetWorth }

    // Passive cash flow the catalog produces, and how much of the FIRE target
    // expense it already covers — the real measure of financial independence.
    private var monthlyPassiveIncome: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
    }
    private var incomeCoverage: Double {
        let target = settings.targetAnnualExpense
        guard target > 0 else { return 0 }
        return (monthlyPassiveIncome * 12) / target
    }
    // Nothing registered and nothing recorded yet → show onboarding.
    private var isEmpty: Bool { assets.isEmpty && snapshots.isEmpty }
    private var fireNumber: Double { settings.fireNumber }
    private var avgSavings: Double {
        FireEngine.averageMonthlySavings(snapshots: snapshots)
    }

    // --- Year-end projection ---
    // Use the planned salary-based savings; fall back to the recorded average.
    private var plannedSavings: Double {
        settings.plannedMonthlySavings != 0 ? settings.plannedMonthlySavings : avgSavings
    }
    private var monthsLeftInYear: Int { FireEngine.monthsLeftInYear(asOf: Date()) }
    private var projectedYearEnd: Double {
        FireEngine.projectedYearEnd(currentNetWorth: netWorth,
                                    monthlySavings: plannedSavings,
                                    annualReturn: settings.expectedAnnualReturn,
                                    asOf: Date())
    }
    private var yearEndLabel: String {
        let year = Calendar.current.component(.year, from: Date())
        return "\(year)년 말 예상 자산"
    }
    private var yearsToFire: Double? {
        FireEngine.yearsToFire(
            currentNetWorth: netWorth,
            fireNumber: fireNumber,
            monthlySavings: avgSavings,
            annualReturn: settings.expectedAnnualReturn
        )
    }
    private var delta: Double? {
        FireEngine.latestDelta(snapshots: snapshots)
    }

    // --- Recent momentum (the dashboard hero) ---
    // Progress since the last record, counting ONLY the value change of assets
    // that already existed in that record. Newly-registered assets are excluded
    // so that registering something doesn't masquerade as growth.
    private var periodDelta: Double? {
        if hasCatalog, let last = latest {
            var recorded: [UUID: Double] = [:]
            for entry in last.entries {
                if let key = entry.catalogKey {
                    recorded[key, default: 0] += entry.amount
                }
            }
            // No catalog linkage in the old record → fall back to total delta.
            guard !recorded.isEmpty else { return netWorth - last.netWorth }
            var change = 0.0
            for asset in assets {
                if let prior = recorded[asset.key] {
                    change += asset.netValue - prior
                }
            }
            return change
        }
        return delta
    }
    private var periodLabel: String {
        if hasCatalog, let last = latest {
            let days = Calendar.current.dateComponents([.day], from: last.date, to: Date()).day ?? 0
            return "지난 기록 이후 \(days)일"
        }
        if periodDelta != nil { return "지난 기록 대비" }
        return ""
    }
    private var remaining: Double { max(0, fireNumber - netWorth) }
    // Percentage points of the goal gained this period.
    private var periodProgressPP: Double {
        guard fireNumber > 0, let d = periodDelta else { return 0 }
        return d / fireNumber
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    onboarding
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            momentumCard
                            NavigationLink {
                                ProjectionDetailView(netWorth: netWorth,
                                                     monthlyTakeHome: settings.monthlyTakeHome,
                                                     plannedExpense: settings.plannedMonthlyExpense,
                                                     monthlySavings: plannedSavings,
                                                     annualReturn: settings.expectedAnnualReturn)
                            } label: {
                                projectionCard
                            }
                            .buttonStyle(.plain)
                            liquidityCard
                            metricsGrid
                            if monthlyPassiveIncome > 0 {
                                passiveIncomeCard
                            }
                            allocationCard
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddAsset) {
                AssetEditor(asset: nil, nextSortOrder: 0)
            }
        }
    }

    // First-run guidance: walk the user through registering assets instead of
    // showing an empty 0% ring.
    private var onboarding: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.accent)
                    Text("FIRE 여정을 시작해볼까요?")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("보유한 자산을 등록하면 목표까지의\n달성률과 예상 시점을 추적해드립니다.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .padding(.top, 24)

                VStack(spacing: 14) {
                    stepRow(number: 1,
                            title: "보유 자산 등록",
                            detail: "주식·코인·부동산·전세·현금 등을 목록으로",
                            symbol: "wonsign.circle.fill")
                    stepRow(number: 2,
                            title: "FIRE 목표 설정",
                            detail: "설정 탭에서 연 목표 지출·인출률 입력",
                            symbol: "target")
                    stepRow(number: 3,
                            title: "매달 기록 저장",
                            detail: "자산 탭에서 한 번씩 저장하면 추이가 쌓여요",
                            symbol: "chart.xyaxis.line")
                }

                Button { showingAddAsset = true } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("자산 등록하기")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accent)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func stepRow(number: Int, title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 36, height: 36)
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Hero: how much closer you got recently — momentum beats a static total.
    private var momentumCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("이번 달 진척")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if !periodLabel.isEmpty {
                    Text(periodLabel)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let d = periodDelta, latest != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(d >= 0 ? "+" : "-")\(Fmt.krw(abs(d)))원")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(d >= 0 ? Theme.positive : Theme.negative)
                    Text("\(d >= 0 ? "+" : "-")\(Fmt.won(abs(d)))원")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    if fireNumber > 0 {
                        Text("목표에 \(d >= 0 ? "+" : "")\(Fmt.percent(periodProgressPP, fraction: 1)) 가까워졌어요")
                            .font(.subheadline)
                            .foregroundStyle(d >= 0 ? Theme.positive : Theme.negative)
                    }
                }
            } else {
                // No prior record to compare against — registering assets isn't
                // progress, so show a neutral prompt instead of a big number.
                VStack(alignment: .leading, spacing: 6) {
                    Text("아직 변화를 잴 기록이 없어요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("‘이번 달 기록 저장’을 누르면 다음 기록부터 변화가 여기 표시됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
            }

            Text("목표 \(Fmt.krw(fireNumber))원까지 \(Fmt.krw(remaining))원 남음")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            MetricCard(
                title: "예상 달성 시점",
                value: Fmt.years(yearsToFire),
                symbol: "calendar",
                tint: Theme.accent
            )
            MetricCard(
                title: "월 평균 저축",
                value: "\(Fmt.krw(avgSavings))원",
                symbol: "arrow.up.forward",
                tint: Theme.positive
            )
            MetricCard(
                title: "전월 대비",
                value: delta != nil ? "\(delta! >= 0 ? "+" : "")\(Fmt.krw(delta!))원" : "—",
                symbol: delta ?? 0 >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                tint: (delta ?? 0) >= 0 ? Theme.positive : Theme.negative
            )
            MetricCard(
                title: "최근 저축률",
                value: Fmt.percent(latest?.savingsRate ?? 0, fraction: 0),
                symbol: "percent",
                tint: Theme.accent
            )
        }
    }

    // Projects net worth to year-end from salary-based monthly savings.
    private var projectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(yearEndLabel)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                HStack(spacing: 2) {
                    Text("근거 보기")
                    Image(systemName: "chevron.right")
                }
                .font(.caption)
                .foregroundStyle(Theme.accent)
            }
            Text("\(Fmt.krw(projectedYearEnd))원")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text("= \(Fmt.won(projectedYearEnd))원")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)

            if plannedSavings != 0 {
                Text("현재 \(Fmt.krw(netWorth))원 + 월 저축 \(Fmt.krw(plannedSavings))원 × 남은 \(monthsLeftInYear)개월"
                     + (settings.expectedAnnualReturn > 0 ? " (수익률 \(Fmt.percent(settings.expectedAnnualReturn, fraction: 1)) 반영)" : ""))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            } else {
                Text("설정에서 세후 월급·월 지출을 입력하면 올해 말 자산을 예측합니다.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Spendable vs. locked — FIRE is about usable money, not total net worth.
    private var liquidityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("쓸 수 있는 돈 (유동)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("\(Fmt.krw(liquidNetWorth))원")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.positive)
                }
                Spacer()
                if lockedNetWorth > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("묶인 돈", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                        Text("\(Fmt.krw(lockedNetWorth))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.textSecond)
                    }
                }
            }

            GeometryReader { geo in
                HStack(spacing: 2) {
                    if liquidNetWorth > 0 {
                        Capsule().fill(Theme.positive)
                            .frame(width: max(2, geo.size.width * (netWorth > 0 ? liquidNetWorth / netWorth : 0)))
                    }
                    if lockedNetWorth > 0 {
                        Capsule().fill(Theme.textSecond.opacity(0.4))
                            .frame(width: max(2, geo.size.width * (netWorth > 0 ? lockedNetWorth / netWorth : 0)))
                    }
                }
            }
            .frame(height: 10)

            Text("순자산 \(Fmt.krw(netWorth))원 중 실제 쓸 수 있는 돈입니다. 실거주 부동산·전세보증금·연금·부채는 묶인 돈으로 빠집니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // Passive income vs. target spending — "is my cash flow covering my life?"
    private var passiveIncomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("패시브 인컴")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("월 \(Fmt.krw(monthlyPassiveIncome))원")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.positive)
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule()
                            .fill(Theme.positive)
                            .frame(width: geo.size.width * min(incomeCoverage, 1))
                    }
                }
                .frame(height: 10)
                Text("연 \(Fmt.krw(monthlyPassiveIncome * 12))원 · 목표 지출의 \(Fmt.percent(incomeCoverage, fraction: 0)) 커버")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("자산 구성")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            let entries = AssetClass.allCases.compactMap { ac -> (AssetClass, Double)? in
                let total = latest?.total(for: ac) ?? catalogTotal(for: ac)
                return total > 0 ? (ac, total) : nil
            }

            if entries.isEmpty {
                Text("기록된 자산이 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
            } else {
                Chart(entries, id: \.0) { item in
                    SectorMark(
                        angle: .value("금액", item.1),
                        innerRadius: .ratio(0.6),
                        angularInset: 2
                    )
                    .foregroundStyle(Color(hex: item.0.colorHex))
                    .cornerRadius(4)
                }
                .frame(height: 180)

                VStack(spacing: 8) {
                    ForEach(entries, id: \.0) { item in
                        HStack {
                            Circle()
                                .fill(Color(hex: item.0.colorHex))
                                .frame(width: 10, height: 10)
                            Text(item.0.label)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(Fmt.krw(item.1))원")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// Detailed basis for the year-end projection: assumptions + month-by-month sim.
struct ProjectionDetailView: View {
    let netWorth: Double
    let monthlyTakeHome: Double
    let plannedExpense: Double
    let monthlySavings: Double
    let annualReturn: Double

    private var steps: [FireEngine.ProjectionStep] {
        FireEngine.projectionSteps(currentNetWorth: netWorth,
                                   monthlySavings: monthlySavings,
                                   annualReturn: annualReturn,
                                   asOf: Date())
    }
    private var projected: Double { steps.last?.end ?? netWorth }
    private var totalSavings: Double { steps.reduce(0) { $0 + $1.savings } }
    private var totalGain: Double { steps.reduce(0) { $0 + $1.gain } }

    var body: some View {
        Form {
            Section {
                resultRow("올해 말 예상 자산", projected, tint: Theme.accent, big: true)
            } footer: {
                Text("아래 가정으로 매달 저축과 투자 수익을 더해 계산한 값입니다.")
                    .font(.caption)
            }

            Section("계산 가정") {
                assumptionRow("현재 순자산", Fmt.krwBoth(netWorth))
                if monthlyTakeHome > 0 {
                    assumptionRow("세후 월급", Fmt.krwBoth(monthlyTakeHome))
                }
                if plannedExpense > 0 {
                    assumptionRow("월 지출", Fmt.krwBoth(plannedExpense))
                }
                assumptionRow("월 저축", Fmt.krwBoth(monthlySavings),
                              tint: monthlySavings >= 0 ? Theme.positive : Theme.negative)
                assumptionRow("예상 연 수익률", Fmt.percent(annualReturn, fraction: 1))
                assumptionRow("올해 남은 개월", "\(steps.count)개월")
            }

            Section("기간 합계") {
                resultRow("저축 누적", totalSavings, tint: Theme.positive)
                resultRow("투자 수익 누적", totalGain, tint: Theme.accent)
            }

            Section("월별 시뮬레이션") {
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(monthName(step.date))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(Fmt.krw(step.end))원")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text("시작 \(Fmt.krw(step.start)) + 저축 \(Fmt.krw(step.savings))"
                             + (step.gain >= 1 ? " + 수익 \(Fmt.krw(step.gain))" : ""))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("예상 근거")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func assumptionRow(_ title: String, _ value: String, tint: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecond)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(tint)
        }
    }

    private func resultRow(_ title: String, _ value: Double, tint: Color, big: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Fmt.krw(value))원")
                    .font(.system(big ? .title3 : .body, design: .rounded).weight(.bold))
                    .foregroundStyle(tint)
                Text("\(Fmt.won(value))원")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
    }

    private func monthName(_ date: Date) -> String {
        let m = Calendar.current.component(.month, from: date)
        return "\(m)월"
    }
}
