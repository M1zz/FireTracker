//
//  AppSupport.swift
//  FireTracker
//
//  여러 화면이 함께 쓰는 작은 장치들.
//    · 저장 실패 알림 — `try? context.save()` 로 삼키면 사용자는 저장된 줄 안다.
//    · 퇴사각 계산(FireOutlook) — 대시보드·위젯·알림이 같은 숫자를 말하게.
//    · 매달 알림(MonthlyReminder)
//

import SwiftUI
import SwiftData
import UserNotifications
import WidgetKit

// MARK: - 저장 실패 알림

/// 앱 어디서든 사용자에게 띄울 오류 한 건. RootView 가 알림창으로 보여 준다.
@MainActor
@Observable
final class AppAlerts {
    static let shared = AppAlerts()
    var message: String?

    func show(_ message: String) { self.message = message }
}

extension ModelContext {
    /// 저장하고, 실패하면 사용자에게 알린다. 성공 여부를 돌려준다 —
    /// "저장했어요" 같은 확인 표시는 true 일 때만 띄울 것.
    @MainActor
    @discardableResult
    func saveReporting(_ what: String = "변경 내용") -> Bool {
        do {
            try save()
            return true
        } catch {
            AppAlerts.shared.show("\(what) 저장에 실패했어요. 기기 저장 공간을 확인한 뒤 다시 시도해 주세요.")
            return false
        }
    }
}

// MARK: - 탭 이동

/// 시트·카드 안에서 다른 탭으로 보내야 할 때(예: 첫 화면 → 자산 탭).
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var selectedTab = 0

    enum Tab { static let dashboard = 0, assets = 1, journey = 2, calc = 3, settings = 4 }
}

// MARK: - 목표를 직접 정했는가

extension FireSettings {
    /// 기본값(월 300만 원·4%)을 그대로 두고 아무것도 넣지 않았다면 false.
    /// 이때 대시보드는 9억 목표를 '내 목표'처럼 보여 주지 않고 정하라고 권한다.
    var goalConfigured: Bool {
        UserDefaults.standard.bool(forKey: "goalConfigured")
            || targetAnnualExpense != 36_000_000
            || safeWithdrawalRate != 0.04
            || currentAge > 0
            || plannedMonthlySavings != 0
    }

    static func markGoalConfigured() {
        UserDefaults.standard.set(true, forKey: "goalConfigured")
    }
}

// MARK: - 퇴사각 (예상 FIRE 달성 시점)

/// 대시보드 맨 위 카드, 위젯, 매달 알림이 모두 이 계산 하나를 쓴다.
/// 기준: 순자산이 FIRE 목표 금액(연 지출 ÷ 인출률)에 닿는 때.
/// 매달 '계획한 월 저축'을 더하고 '예상 연 수익률'로 굴린다.
struct FireOutlook {
    let netWorth: Double
    let fireNumber: Double
    let monthlySavings: Double
    let annualReturn: Double
    let currentAge: Int

    init(netWorth: Double, settings: FireSettings) {
        self.netWorth = netWorth
        self.fireNumber = settings.fireNumber
        self.monthlySavings = settings.plannedMonthlySavings
        self.annualReturn = settings.expectedAnnualReturn
        self.currentAge = settings.currentAge
    }

    var progress: Double { fireNumber > 0 ? max(0, netWorth) / fireNumber : 0 }

    var years: Double? {
        guard fireNumber > 0 else { return nil }
        return FireEngine.yearsToFire(currentNetWorth: netWorth,
                                      fireNumber: fireNumber,
                                      monthlySavings: monthlySavings,
                                      annualReturn: annualReturn)
    }

    var date: Date? {
        guard let years else { return nil }
        return Calendar.current.date(byAdding: .month, value: Int((years * 12).rounded()), to: Date())
    }

    var ageAtFire: Int? {
        guard currentAge > 0, let years else { return nil }
        return currentAge + Int(years)
    }

    func summary(goalConfigured: Bool, locked: Bool) -> FireSummary {
        FireSummary(fireDate: date, ageAtFire: ageAtFire, progress: progress,
                    goalConfigured: goalConfigured, locked: locked, updatedAt: Date())
    }
}

extension FireSummary {
    /// 앱이 계산한 요약을 위젯에 넘긴다. 바뀌었을 때만 위젯을 다시 그린다.
    static func publish(_ summary: FireSummary) {
        if summary.save() {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

// MARK: - 매달 알림

/// 매달 1일 아침, 지금 속도면 언제 그만둘 수 있는지 알려 준다.
/// 다시 열게 만드는 장치 — 자산 앱은 꾸준히 볼 때만 쓸모가 생긴다.
/// 문구는 앱을 열 때마다 최신 숫자로 다시 적어 둔다.
enum MonthlyReminder {
    static let enabledKey = "monthlyReminderEnabled"
    private static let id = "monthly-fire-reminder"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 권한을 묻고 켠다. 거절하면 false.
    static func enable(summary: FireSummary) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        if granted { schedule(summary: summary) }
        return granted
    }

    static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// 켜져 있을 때만 다음 알림 문구를 새 숫자로 바꿔 건다.
    static func reschedule(summary: FireSummary) {
        guard isEnabled else { return }
        schedule(summary: summary)
    }

    private static func schedule(summary: FireSummary) {
        let content = UNMutableNotificationContent()
        content.title = "이번 달 퇴사각"
        content.body = body(for: summary)
        content.sound = .default

        var when = DateComponents()
        when.day = 1
        when.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private static func body(for s: FireSummary) -> String {
        if s.locked {
            return "새 달이 시작됐어요. 이번 달 자산을 확인해 보세요."
        }
        guard s.goalConfigured, let when = s.fireDateText else {
            return "새 달이 시작됐어요. 목표를 정하면 언제 그만둘 수 있는지 알려 드릴게요."
        }
        let pct = Int((min(s.progress, 1) * 100).rounded())
        return "지난번 계산으로는 \(when)에 그만둘 수 있어요(목표의 \(pct)%). 이번 달 자산을 확인해 보세요."
    }
}
