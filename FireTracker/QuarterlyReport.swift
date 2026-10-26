//
//  QuarterlyReport.swift
//  FireTracker
//
//  분기 퇴사각 리포트 — 석 달에 한 번, 퇴사 날짜가 얼마나 당겨졌는지 돌아본다.
//
//  매일 보는 숫자는 시장 따라 흔들려 의미를 잃는다. 석 달 단위로 묶으면 "내가 한 일"
//  (저축)과 "시장이 한 일"이 구분되고, 퇴사 날짜가 실제로 움직였는지가 보인다.
//  리포트는 저장된 기록(스냅샷)만으로 만든다 — 따로 쌓는 데이터가 없다.
//

import SwiftUI
import SwiftData
import UserNotifications
import LeeoKit

// MARK: - 계산

struct QuarterKey: Hashable, Comparable, Identifiable {
    let year: Int
    let quarter: Int   // 1...4
    var id: String { "\(year)Q\(quarter)" }

    static func < (a: QuarterKey, b: QuarterKey) -> Bool {
        (a.year, a.quarter) < (b.year, b.quarter)
    }

    init(year: Int, quarter: Int) { self.year = year; self.quarter = quarter }

    init(date: Date, calendar: Calendar = .current) {
        year = calendar.component(.year, from: date)
        quarter = (calendar.component(.month, from: date) - 1) / 3 + 1
    }

    var start: Date {
        Calendar.current.date(from: DateComponents(year: year, month: (quarter - 1) * 3 + 1, day: 1)) ?? .now
    }
    var end: Date {
        Calendar.current.date(byAdding: .month, value: 3, to: start) ?? .now
    }
    var previous: QuarterKey {
        quarter == 1 ? QuarterKey(year: year - 1, quarter: 4) : QuarterKey(year: year, quarter: quarter - 1)
    }
    var title: String { String(localized: "\(String(year))년 \(quarter)분기") }
}

struct QuarterlyReport {
    struct Mover: Identifiable {
        let id: String
        let name: String
        let change: Double
    }

    let quarter: QuarterKey
    let isInProgress: Bool
    let startNetWorth: Double
    let endNetWorth: Double
    let startDate: Date
    let endDate: Date
    let quitYearsStart: Double?
    let quitYearsEnd: Double?
    let savedByMe: Double         // 석 달 저축 합(기록된 월 저축)
    let avgSavingsRate: Double
    let passiveStart: Double
    let passiveEnd: Double
    let movers: [Mover]

    var change: Double { endNetWorth - startNetWorth }
    /// 시장(평가액 변화) 몫 = 전체 변화 − 내가 저축한 몫.
    var byMarket: Double { change - savedByMe }

    /// 퇴사 날짜가 당겨진 개월 수. 석 달이 흐른 것까지 감안해 "달력"이 아니라 "남은 기간" 기준.
    var quitMonthsPulled: Double? {
        guard let a = quitYearsStart, let b = quitYearsEnd, a.isFinite, b.isFinite else { return nil }
        let elapsedMonths = endDate.timeIntervalSince(startDate) / (86_400 * 30.44)
        // 남은 기간이 흐른 시간보다 더 줄었으면 그만큼 당겨진 것.
        return (a - b) * 12 - elapsedMonths
    }

    static func availableQuarters(_ snapshots: [NetWorthSnapshot]) -> [QuarterKey] {
        Set(snapshots.map { QuarterKey(date: $0.date) }).sorted(by: >)
    }

    static func make(for q: QuarterKey, snapshots: [NetWorthSnapshot], settings: FireSettings) -> QuarterlyReport? {
        let sorted = snapshots.sorted { $0.date < $1.date }
        let inQuarter = sorted.filter { $0.date >= q.start && $0.date < q.end }
        guard let last = inQuarter.last else { return nil }
        // 시작점: 분기 직전의 마지막 기록, 없으면 분기 첫 기록.
        let first = sorted.last(where: { $0.date < q.start }) ?? inQuarter.first!
        let savings = inQuarter.reduce(0) { $0 + $1.monthlySavings }
        let rates = inQuarter.map(\.savingsRate).filter { $0 != 0 }
        let monthly = settings.plannedMonthlySavings != 0
            ? settings.plannedMonthlySavings
            : FireEngine.averageMonthlySavings(snapshots: sorted)

        func years(_ nw: Double) -> Double? {
            FireEngine.yearsToFire(currentNetWorth: nw, fireNumber: settings.fireNumber,
                                   monthlySavings: monthly, annualReturn: settings.expectedAnnualReturn)
        }

        // 가장 많이 움직인 자산 — 같은 자산(catalogKey 또는 이름)끼리 처음과 끝을 비교.
        func keyed(_ s: NetWorthSnapshot) -> [String: (String, Double)] {
            var d: [String: (String, Double)] = [:]
            for e in s.entryList {
                let k = e.catalogKey?.uuidString ?? e.name
                d[k] = (e.name, (d[k]?.1 ?? 0) + e.amount)
            }
            return d
        }
        let a = keyed(first), b = keyed(last)
        let movers = Set(a.keys).union(b.keys).compactMap { k -> Mover? in
            let change = (b[k]?.1 ?? 0) - (a[k]?.1 ?? 0)
            guard abs(change) >= 1 else { return nil }
            return Mover(id: k, name: b[k]?.0 ?? a[k]?.0 ?? "", change: change)
        }
        .sorted { abs($0.change) > abs($1.change) }

        return QuarterlyReport(
            quarter: q,
            isInProgress: Date() < q.end,
            startNetWorth: first.netWorth, endNetWorth: last.netWorth,
            startDate: first.date, endDate: last.date,
            quitYearsStart: years(first.netWorth), quitYearsEnd: years(last.netWorth),
            savedByMe: savings,
            avgSavingsRate: rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count),
            passiveStart: first.monthlyPassiveIncome, passiveEnd: last.monthlyPassiveIncome,
            movers: Array(movers.prefix(5))
        )
    }
}

// MARK: - 분기 알림

enum QuarterlyReminder {
    static let enabledKey = "future.quarterlyReminder"
    private static let ids = (1...4).map { "quarterly-report-\($0)" }

    /// 1·4·7·10월 1일 오전 9시에 알린다.
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for (i, month) in [1, 4, 7, 10].enumerated() {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "새 분기가 시작됐어요")
            content.body = String(localized: "지난 석 달 동안 퇴사 날짜가 얼마나 당겨졌는지 확인해 보세요.")
            content.sound = .default
            var dc = DateComponents()
            dc.month = month; dc.day = 1; dc.hour = 9
            let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
            try? await center.add(UNNotificationRequest(identifier: ids[i], content: content, trigger: trigger))
        }
        return true
    }

    static func disable() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - 화면

struct QuarterlyReportView: View {
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query private var settingsList: [FireSettings]
    @AppStorage(QuarterlyReminder.enabledKey) private var reminderOn = false
    @State private var selected: QuarterKey?

    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var quarters: [QuarterKey] { QuarterlyReport.availableQuarters(snapshots) }
    private var current: QuarterKey? { selected ?? quarters.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if quarters.isEmpty {
                    Text("기록이 쌓이면 분기마다 리포트가 만들어져요. 자산을 바꾸면 그날 기록이 자동으로 남아요.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                } else {
                    quarterPicker
                    if let q = current,
                       let r = QuarterlyReport.make(for: q, snapshots: snapshots, settings: settings) {
                        headline(r)
                        breakdown(r)
                        if !r.movers.isEmpty { movers(r) }
                    }
                }
                reminderCard
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("분기 리포트")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { AppUsage.log(.quarterlyReportOpened) }
    }

    private var quarterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quarters) { q in
                    Button { selected = q } label: {
                        Text(q.title)
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(current == q ? Theme.accent : Theme.surfaceHigh)
                            .foregroundStyle(current == q ? Color.black : Theme.textSecond)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func headline(_ r: QuarterlyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.isInProgress ? LocalizedStringKey("이번 분기 지금까지") : LocalizedStringKey("\(r.quarter.title) 결산"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if let m = r.quitMonthsPulled {
                let months = Int(abs(m).rounded())
                Text(months == 0 ? LocalizedStringKey("퇴사 날짜는 그대로예요")
                     : m > 0 ? LocalizedStringKey("퇴사 날짜가 \(months)개월 당겨졌어요")
                     : LocalizedStringKey("퇴사 날짜가 \(months)개월 밀렸어요"))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(m >= 0 ? Theme.positive : Theme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("순자산 \(Fmt.krw(r.startNetWorth))원 → \(Fmt.krw(r.endNetWorth))원")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
            Text("\(r.change >= 0 ? "▲" : "▼") \(Fmt.krw(abs(r.change)))원")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(r.change >= 0 ? Theme.rise : Theme.fall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func breakdown(_ r: QuarterlyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("누가 움직였나")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            row(String(localized: "내가 모은 돈"), r.savedByMe)
            row(String(localized: "시장이 움직인 돈"), r.byMarket)
            if r.avgSavingsRate != 0 {
                AdaptiveRow {
                    Text("평균 저축률")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                } trailing: {
                    Text(Fmt.percent(r.avgSavingsRate, fraction: 0))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            if r.passiveEnd != r.passiveStart {
                row(String(localized: "월 패시브 인컴 변화"), r.passiveEnd - r.passiveStart)
            }
            Text("시장 몫은 석 달 뒤면 뒤집힐 수 있지만, 내가 모은 돈은 남아요.")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func movers(_ r: QuarterlyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("가장 많이 움직인 자산")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(r.movers) { m in
                row(m.name, m.change)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row(_ label: String, _ value: Double) -> some View {
        AdaptiveRow {
            Text(label)
                .font(.body)
                .foregroundStyle(Theme.textSecond)
        } trailing: {
            Text("\(value >= 0 ? "▲" : "▼") \(Fmt.krw(abs(value)))원")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(value >= 0 ? Theme.rise : Theme.fall)
        }
    }

    private var reminderCard: some View {
        Toggle(isOn: Binding(
            get: { reminderOn },
            set: { on in
                if on {
                    Task { reminderOn = await QuarterlyReminder.enable() }
                } else {
                    QuarterlyReminder.disable()
                    reminderOn = false
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("분기가 시작되면 알려 주기")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("1·4·7·10월 1일 아침 9시")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .tint(Theme.accent)
        .cardStyle()
    }
}

/// 여정 탭에서 리포트로 들어가는 줄. 프로가 아니면 페이월.
struct QuarterlyReportEntry: View {
    @EnvironmentObject private var pro: LeeoStore
    @State private var paywallFeature: ProFeature?

    private var unlocked: Bool { pro.gate.allows(ProFeature.quarterlyReport.rawValue) }

    var body: some View {
        Group {
            if unlocked {
                NavigationLink { QuarterlyReportView() } label: { label }
            } else {
                Button {
                    AppUsage.log(.paywallShown)
                    paywallFeature = .quarterlyReport
                } label: { label }
            }
        }
        .buttonStyle(.plain)
        .proPaywall($paywallFeature)
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: unlocked ? "doc.text.magnifyingglass" : "lock.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("분기 퇴사각 리포트")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("석 달 동안 퇴사 날짜가 얼마나 당겨졌나")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
