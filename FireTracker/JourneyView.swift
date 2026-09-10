//
//  JourneyView.swift
//  FireTracker
//
//  여정 탭 — 어디서 와서 어디로 가나.
//
//  예전엔 "추이"였고 지나온 기록만 그렸다. 그런데 "언제 그만둘 수 있나"라는 질문의
//  답은 대시보드·설정·추이 세 곳에 흩어져 있었다. 목표를 넣는 곳(설정), 목표까지
//  얼마나 왔는지 보는 곳(대시보드), 지금까지 어떻게 왔는지 보는 곳(추이)이 전부 달랐다.
//  세 개를 한 탭으로 모았다 — 목표를 세우고, 지나온 길을 보고, 남은 길을 본다.
//
//  기록(스냅샷) 편집도 여기로 왔다. 이 탭이 그리는 데이터를 이 탭에서 고친다.
//

import SwiftUI
import SwiftData
import Charts
import TipKit

// 궤적 위의 한 점 — 그 시점에 있어야 할 자리.
struct TrajPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let label: String
}

struct JourneyGoalsSection: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]

    @State private var milestoneMetric: FireGoalType = .assets
    // 기간별 목표 그래프에서 보고 있는 구간(이번 달/올해/5년/은퇴). 전체를 한 번에
    // 펼치지 않고 고른 구간만 확대해 본다.
    @State private var milestoneHorizonLabel: String = "올해"

    private let milestoneSetupTip = MilestoneSetupTip()

    var body: some View {
        if settings.monthsToRetire != nil {
            milestoneGoalsCard
            requiredSavingsCard
        } else {
            goalPrompt
        }
    }

    // 나이를 아직 안 넣었으면, 넣으러 가는 길을 바로 준다.
    private var goalPrompt: some View {
        NavigationLink {
            GoalSettingsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("기간별 목표를 켜보세요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("현재 나이와 목표 은퇴 나이를 넣으면 은퇴까지 필요한 속도로 이번달·올해·5년·은퇴 목표를 나눠서 보여드려요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 대시보드에서 옮겨 온 파생값

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var latest: NetWorthSnapshot? { snapshots.max { $0.date < $1.date } }
    private var hasCatalog: Bool { !assets.isEmpty }
    private var catalogTotal: Double { assets.reduce(0) { $0 + $1.netValue } }
    /// 등록한 자산이 있으면 그것이 "지금"이고, 없을 때만 마지막 기록으로 대신한다.
    private var netWorth: Double { hasCatalog ? catalogTotal : (latest?.netWorth ?? 0) }
    private var monthlyPassiveIncome: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
    }
    private var fireNumber: Double { settings.fireNumber }
    private var goalRemaining: Double { max(0, fireNumber - netWorth) }
    private var monthsLeftInYear: Int { FireEngine.monthsLeftInYear(asOf: Date()) }
    /// 지금 읽을 월 저축 — 최근 기록이 있으면 그것, 없으면 계획값.
    private var monthlySavingsNow: Double {
        if let s = latest, s.monthlyIncome > 0 || s.monthlyExpense > 0 || s.monthlyNetSavings > 0 {
            return s.monthlySavings
        }
        return settings.plannedMonthlySavings
    }

    // "지난 기록"의 정체 — 비교 대상 스냅샷의 날짜.
    private func recordDateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: date)
    }

    // Horizons to slice the retirement goal into. Only those nearer than
    // retirement get their own row; the final row is always 은퇴.
    private var milestoneHorizons: [(label: String, months: Int)] {
        guard let m = settings.monthsToRetire else { return [] }
        var out: [(String, Int)] = []
        for (label, mo) in [("이번 달", 1), ("올해", max(1, monthsLeftInYear)), ("5년", 60)] where mo < m {
            out.append((label, mo))
        }
        out.append(("은퇴", m))
        return out
    }

    private func milestoneRow(label: String, months: Int, metric: FireGoalType) -> some View {
        let isAsset = metric == .assets
        let current = isAsset ? netWorth : monthlyPassiveIncome
        let goal = isAsset ? fireNumber : settings.incomeGoalMonthly
        let target = FireEngine.milestoneTarget(current: current, goal: goal,
                                                monthsToRetire: settings.monthsToRetire ?? 0,
                                                horizonMonths: months)
        let progress = target > 0 ? min(current / target, 1) : 0
        let gap = max(0, target - current)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(isAsset ? "\(Fmt.krw(target))원" : "월 \(Fmt.krw(target))원")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(progress >= 1 ? Theme.positive : Theme.accent)
                        .frame(width: max(2, geo.size.width * progress))
                }
            }
            .frame(height: 7)
            Text(gap < 1
                 ? "이미 달성 🎉 · 현재 \(isAsset ? "" : "월 ")\(Fmt.krw(current))원 (목표 \(isAsset ? "" : "월 ")\(Fmt.krw(target))원)"
                 : "\(Fmt.percent(progress, fraction: 0)) · 현재 \(isAsset ? "" : "월 ")\(Fmt.krw(current))원 · \(isAsset ? "" : "월 ")\(Fmt.krw(gap))원 더 필요")
                .font(.caption2)
                .foregroundStyle(gap < 1 ? Theme.positive : Theme.textSecond)
        }
    }

    // 선택한 구간의 달력 경계. 이번 달=1일~말일, 올해=1월 1일~12월 31일,
    // 5년·은퇴=이번 달 1일~N개월 뒤. X축을 이 범위로 고정한다.
    private func periodBounds(label: String, months: Int) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        switch label {
        case "이번 달":
            let next = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now
            let end = cal.date(byAdding: .second, value: -1, to: next) ?? next
            return (monthStart, end)
        case "올해":
            let y = cal.component(.year, from: now)
            let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? monthStart
            let end = cal.date(from: DateComponents(year: y, month: 12, day: 31, hour: 23, minute: 59, second: 59)) ?? now
            return (start, end)
        default: // 5년·은퇴 — 이번 달 1일부터 N개월 뒤까지.
            let end = cal.date(byAdding: .month, value: months, to: now) ?? now
            return (monthStart, end)
        }
    }

    // 한 구간의 궤도 분석: 실제 기록·지금·기간 끝 목표 + 과거 추세 예상.
    private struct TrajModel {
        let start: Date
        let end: Date
        let now: Date
        let current: Double
        let goalEnd: Double          // 기간 끝에 도달해야 할 목표치
        let actual: [TrajPoint]      // 기간 내 기록 + 지금 (시간순)
        let spanDays: Double
    }

    private func trajectoryModel(metric: FireGoalType, label: String, months: Int) -> TrajModel? {
        guard let m = settings.monthsToRetire else { return nil }
        let isAsset = metric == .assets
        let current = isAsset ? netWorth : monthlyPassiveIncome
        let goal = isAsset ? fireNumber : settings.incomeGoalMonthly
        let now = Date()
        let (start, end) = periodBounds(label: label, months: months)
        func value(_ s: NetWorthSnapshot) -> Double { isAsset ? s.netWorth : s.monthlyPassiveIncome }

        // 선형 은퇴 경로에서 특정 시점의 목표치(현재→목표 사이를 시간 비례로).
        func target(at date: Date) -> Double {
            guard m > 0, goal > current else { return goal }
            let monthsAhead = max(0, date.timeIntervalSince(now) / (30.4375 * 86_400))
            return current + (goal - current) * min(1, monthsAhead / Double(m))
        }
        let goalEnd = target(at: end)

        var actual: [TrajPoint] = snapshots
            .filter { $0.date >= start && $0.date <= now }
            .map { TrajPoint(date: $0.date, value: value($0), label: "기록") }
            .sorted { $0.date < $1.date }
        actual.append(TrajPoint(date: now, value: current, label: "지금"))

        return TrajModel(start: start, end: end, now: now, current: current,
                         goalEnd: goalEnd, actual: actual,
                         spanDays: end.timeIntervalSince(start) / 86_400)
    }

    // 궤적 차트에서 탭으로 고른 시점 — 가장 가까운 기록 점의 정보를 보여준다.
    @State private var trajSel: Date?
    private let recordDotTip = RecordDotTip()

    @ViewBuilder
    private func trajectoryChart(metric: FireGoalType, label: String, months: Int) -> some View {
        if let mdl = trajectoryModel(metric: metric, label: label, months: months) {
            let goalPt = TrajPoint(date: mdl.end, value: mdl.goalEnd, label: "목표")
            let nowPt = TrajPoint(date: mdl.now, value: mdl.current, label: "지금")
            let records = mdl.actual.filter { $0.label == "기록" }
            VStack(alignment: .leading, spacing: 8) {
            Chart {
                // 과거 기록 → 지금까지는 실선으로 이어 실제 흐름을 보여주고,
                // 지금 → 목표는 점선으로 — 아직 오지 않은 '필요한 페이스'라서.
                ForEach(mdl.actual) { p in
                    LineMark(x: .value("시점", p.date), y: .value("값", p.value),
                             series: .value("계열", "실제"))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                // 지금 → 목표 (지금부터 필요한 페이스).
                ForEach([nowPt, goalPt]) { p in
                    LineMark(x: .value("시점", p.date), y: .value("값", p.value),
                             series: .value("계열", "지금→목표"))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }
                // 기록 점 + 지금·목표 강조.
                ForEach(mdl.actual.filter { $0.label == "기록" }) { p in
                    PointMark(x: .value("시점", p.date), y: .value("값", p.value))
                        .foregroundStyle(Theme.accent.opacity(0.4))
                        .symbolSize(20)
                }
                PointMark(x: .value("시점", mdl.now), y: .value("값", mdl.current))
                    .foregroundStyle(Theme.positive)
                    .symbolSize(90)
                    .annotation(position: .top, spacing: 3) {
                        Text("지금").font(.caption2.weight(.semibold)).foregroundStyle(Theme.positive)
                    }
                PointMark(x: .value("시점", mdl.end), y: .value("값", mdl.goalEnd))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(90)
                    .annotation(position: .top, spacing: 3) {
                        Text("목표").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
            }
            .chartXScale(domain: mdl.start...mdl.end)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Fmt.krw(v))원")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                }
            }
            .chartXAxis {
                // 이번 달=일 단위, 1년 안=월 단위, 그 이상=연 단위 눈금.
                if mdl.spanDays <= 45 {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: .dateTime.day())
                    }
                } else if mdl.spanDays <= 550 {
                    AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                } else {
                    AxisMarks(values: .stride(by: .year, count: 1)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: .dateTime.year())
                    }
                }
            }
            .chartXSelection(value: $trajSel)
            .onChange(of: trajSel) { _, new in
                // 점을 탭하는 순간부터 팁이 뜰 자격을 얻는다(닫기 전까지).
                if new != nil { RecordDotTip.dotTapped = true }
            }
            .frame(height: 190)
            .animation(.smooth(duration: 0.5), value: months)

            // 점 안내 — 탭하면 그 기록의 날짜·값, 평소엔 점이 뭔지 한 줄 설명.
            if let sel = trajSel,
               let hit = records.min(by: {
                   abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel))
               }) {
                Text("\(recordDateText(hit.date)) 기록 · \(metric == .assets ? "" : "월 ")\(Fmt.krw(hit.value))원")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            } else if !records.isEmpty {
                Text("옅은 점은 그 시점에 저장된 기록이에요. 점 근처를 탭하면 날짜와 값이 보여요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            // 수정·삭제 경로 안내는 팁킷으로 — 점을 탭한 뒤 한 번만 보여주고,
            // 닫으면 다시 나타나지 않는다.
            TipView(recordDotTip)
                .tipBackground(Theme.surface)
            }
        }
    }

    // The retirement goal, sliced into 이번달·올해·5년·은퇴 so progress isn't only
    // measured against the far-off finish line.
    private var milestoneGoalsCard: some View {
        let metric = settings.fireGoalType == .both ? milestoneMetric : settings.fireGoalType
        let horizons = milestoneHorizons
        // 선택한 구간 — 저장된 라벨이 목록에 없으면 가장 가까운 구간으로.
        let sel = horizons.first { $0.label == milestoneHorizonLabel } ?? horizons.first ?? ("은퇴", settings.monthsToRetire ?? 0)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("기간별 목표")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if settings.fireGoalType == .both {
                    Picker("", selection: $milestoneMetric) {
                        Text("자산").tag(FireGoalType.assets)
                        Text("패시브 인컴").tag(FireGoalType.income)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            // 구간 선택 — 고른 구간만 확대해서 본다(전체 은퇴까지 한 번에 X).
            if horizons.count > 1 {
                Picker("", selection: $milestoneHorizonLabel.animation(.smooth(duration: 0.5))) {
                    ForEach(horizons, id: \.label) { h in Text(h.label).tag(h.label) }
                }
                .pickerStyle(.segmented)
            }

            // 선택한 구간을 달력 범위로 — 이번 달 1일~말일, 올해 1월~12월.
            // 실제 기록(지금까지) + 지금→목표 안내선만 — 현재 대비 목표는 아래 진행도에서.
            trajectoryChart(metric: metric, label: sel.label, months: sel.months)
            Text("\(sel.label) 목표까지 · \(horizonRemainText(sel.months))")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            Divider().overlay(Theme.hairline)
            // 선택한 구간의 진행도만 — 다른 구간은 위 선택기로 전환.
            milestoneRow(label: sel.label, months: sel.months, metric: metric)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 목표(FIRE 자산)까지 은퇴 시점에 도달하려면 하루/주/월 얼마를 모아야 하는지.
    @ViewBuilder
    private var requiredSavingsCard: some View {
        if let months = settings.monthsToRetire, months > 0, fireNumber > 0, goalRemaining > 0 {
            let monthly = goalRemaining / Double(months)
            let weekly = monthly * 12 / 52
            let daily = monthly * 12 / 365
            VStack(alignment: .leading, spacing: 12) {
                Text("목표까지 필요 저축")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("FIRE 목표 \(Fmt.krw(fireNumber))원까지 \(months / 12)년 \(months % 12)개월 · 남은 \(Fmt.krw(goalRemaining))원")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                HStack(spacing: 0) {
                    paceStat("하루", daily)
                    paceStat("주", weekly)
                    paceStat("월", monthly)
                }
                if monthlySavingsNow > 0 {
                    let ratio = monthlySavingsNow / monthly
                    Text(ratio >= 1
                         ? "지금 월 저축 \(Fmt.krw(monthlySavingsNow))원 — 목표 페이스를 넘었어요 🎉"
                         : "지금 월 저축 \(Fmt.krw(monthlySavingsNow))원 · 목표 페이스의 \(Fmt.percent(ratio, fraction: 0))")
                        .font(.caption2)
                        .foregroundStyle(ratio >= 1 ? Theme.positive : Theme.textSecond)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func paceStat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(Theme.textSecond)
            Text("\(Fmt.krw(value))원")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "3개월"·"2년 4개월"·"오늘" 같은 남은 기간 텍스트.
    private func horizonRemainText(_ months: Int) -> String {
        if months <= 0 { return "이번 달" }
        let y = months / 12, mo = months % 12
        if y > 0 && mo > 0 { return "\(y)년 \(mo)개월 뒤" }
        if y > 0 { return "\(y)년 뒤" }
        return "\(mo)개월 뒤"
    }
}
