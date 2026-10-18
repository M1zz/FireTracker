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
import BackgroundTasks
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

// MARK: - 매도 알림 (투자 원칙)

/// 사 둔 종목이 정해 둔 원칙에 닿으면 "지금 파세요" 라고 알린다. 오를 땐 알리지 않고 고점만 기억한다.
///  · 고점 대비 하락 — 갖고 있는 동안 본 가장 높은 값에서 N%(기본 10%) 빠지면
///  · 목표 매도가 — 살 때 정해 둔 값에 닿으면
/// 시세는 서버 없이 기기에서 받으므로, 앱이 쉬는 동안엔 iOS 가 백그라운드 갱신을
/// 허락할 때(보통 몇 시간 간격)만 확인된다 — 실시간 감시가 아니다.
enum SellWatch {
    static let taskID = "com.devkoan.FireTracker.sellWatch"
    static let stopChoices: [Double] = [0, 5, 10, 15, 20, 25, 30]
    private static let lastCheckKey = "sellWatch.lastCheck"
    private static let throttle: TimeInterval = 15 * 60

    static func supports(_ cls: AssetClass) -> Bool {
        cls == .stocks || cls == .fund || cls == .crypto
    }

    /// 시세를 받을 수 있고, 갖고 있고, 원칙이 하나라도 켜진 종목.
    static func isWatched(_ a: Asset) -> Bool {
        supports(a.assetClass) && a.autoPriced && a.quantity > 0
            && !a.symbol.trimmingCharacters(in: .whitespaces).isEmpty
            && (a.trailingStopPct > 0 || a.sellTargetPrice > 0)
    }

    /// 고점 대비 하락 알림이 울리는 값.
    static func stopPrice(_ a: Asset) -> Double? {
        guard a.trailingStopPct > 0, a.peakUnitPrice > 0 else { return nil }
        return a.peakUnitPrice * (1 - a.trailingStopPct / 100)
    }

    /// 화면에 보일 지금 상태. 알림과 같은 기준으로 '팔 때 · 준비 · 지켜보는 중'을 가른다.
    enum Signal: Int, Comparable {
        case stopHit = 0, targetHit, nearStop, nearTarget, holding
        static func < (l: Signal, r: Signal) -> Bool { l.rawValue < r.rawValue }
        var label: String {
            switch self {
            case .stopHit:    return "지금 팔 때"
            case .targetHit:  return "목표가 도달"
            case .nearStop:   return "팔 준비"
            case .nearTarget: return "목표가 근처"
            case .holding:    return "지켜보는 중"
            }
        }
        var urgent: Bool { self == .stopHit || self == .targetHit }
    }

    struct Status {
        let signal: Signal
        let price: Double
        let peak: Double
        let floor: Double?
        let target: Double?
        /// 고점 대비 지금 몇 % 빠졌나(0.06 = −6%).
        var drawdown: Double { peak > 0 ? max(0, 1 - price / peak) : 0 }
        /// 하락 기준선까지 남은 폭(0.03 = 3% 더 빠지면 기준선).
        var roomToFloor: Double? { floor.map { price > 0 ? max(0, 1 - $0 / price) : 0 } }
        /// 목표가까지 남은 상승 폭.
        var toTarget: Double? { target.map { price > 0 ? $0 / price - 1 : 0 } }
    }

    /// 기준선 3% 안으로 들어오면 '준비', 목표가 5% 안이면 '근처'.
    static let nearStopBand = 0.03
    static let nearTargetBand = 0.05

    static func status(_ a: Asset) -> Status? {
        guard isWatched(a), a.unitPriceKRW > 0 else { return nil }
        let price = a.unitPriceKRW
        // 아직 한 번도 확인 전이면 evaluate 와 같은 규칙으로 고점을 어림한다.
        let avg = a.quantity > 0 ? a.averagePrice : 0
        let peak = a.peakUnitPrice > 0 ? max(a.peakUnitPrice, price) : max(price, avg)
        let floor = a.trailingStopPct > 0 ? peak * (1 - a.trailingStopPct / 100) : nil
        let target = a.sellTargetPrice > 0 ? a.sellTargetPrice : nil
        let signal: Signal
        if let floor, price <= floor { signal = .stopHit }
        else if let target, price >= target { signal = .targetHit }
        else if let floor, price <= floor * (1 + nearStopBand) { signal = .nearStop }
        else if let target, price >= target * (1 - nearTargetBand) { signal = .nearTarget }
        else { signal = .holding }
        return Status(signal: signal, price: price, peak: peak, floor: floor, target: target)
    }

    /// 주식·펀드·코인을 갖고 있지만 시세를 못 받아 원칙을 지켜보지 못하는 종목.
    static func isUnwatchable(_ a: Asset) -> Bool {
        supports(a.assetClass) && a.amount > 0 && !isWatched(a)
            && (a.trailingStopPct > 0 || a.sellTargetPrice > 0)
    }

    /// 새 시세(unitPriceKRW)를 넣은 뒤 부른다. 고점을 갱신하고, 원칙에 닿았으면 알린다.
    static func evaluate(_ a: Asset) {
        guard isWatched(a), a.unitPriceKRW > 0 else { return }
        let price = a.unitPriceKRW
        // 처음 볼 땐 평단과 지금 값 중 큰 쪽을 고점으로 — 산 값에서 빠져도 알린다.
        if a.peakUnitPrice <= 0 {
            let avg = a.costBasis > 0 ? a.costBasis / a.quantity : 0
            a.peakUnitPrice = max(price, avg)
        }
        // 오를 땐 조용히 고점만 올린다. 새 고점이면 하락 알림도 다시 켜진다.
        if price > a.peakUnitPrice { a.peakUnitPrice = price }

        if let floor = stopPrice(a), price <= floor, a.stopAlertedPeak != a.peakUnitPrice {
            a.stopAlertedPeak = a.peakUnitPrice
            notify(a, id: "stop", title: "\(a.name) — 지금 팔 때예요",
                   body: "고점 \(Fmt.krw(a.peakUnitPrice))원에서 \(Fmt.trimNumber(a.trailingStopPct))% 넘게 빠졌어요(지금 \(Fmt.krw(price))원). 정해 둔 원칙대로 팔아 주세요.")
        }
        if a.sellTargetPrice > 0, price >= a.sellTargetPrice, a.targetAlertedFor != a.sellTargetPrice {
            a.targetAlertedFor = a.sellTargetPrice
            notify(a, id: "target", title: "\(a.name) — 목표가에 닿았어요",
                   body: "살 때 정한 \(Fmt.krw(a.sellTargetPrice))원에 닿았어요(지금 \(Fmt.krw(price))원). 팔기로 한 가격이에요.")
        }
    }

    private static func notify(_ a: Asset, id: String, title: String, body: String) {
        // 데모 종목으로는 알리지 않는다.
        guard !DemoData.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        // 앱 잠금을 켰으면 잠금 화면에 금액을 내보이지 않는다.
        content.body = UserDefaults.standard.bool(forKey: "appLockEnabled")
            ? "정해 둔 매도 원칙에 닿았어요. 앱에서 확인해 주세요." : body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sell-\(id)-\(a.key.uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 알림 권한을 묻는다(이미 정했으면 조용히 지나감). 원칙을 처음 정할 때 부른다.
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// 지켜보는 종목만 시세를 새로 받아 원칙을 확인한다. 앱 복귀·백그라운드 갱신에서 부른다.
    @MainActor
    static func checkPrices(container: ModelContainer, force: Bool = false) async {
        let context = container.mainContext
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastCheckKey)
        if !force, last > 0, Date().timeIntervalSince1970 - last < throttle { return }
        guard !DemoData.isActive else { return }

        let assets = ((try? context.fetch(FetchDescriptor<Asset>())) ?? []).filter(isWatched)
        guard !assets.isEmpty else { return }
        let settings = (try? context.fetch(FetchDescriptor<FireSettings>()))?.first ?? FireSettings()
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        for a in assets {
            guard let r = try? await PriceService.autoValue(
                assetClass: a.assetClass, symbol: a.symbol, name: a.name,
                quantity: a.quantity, currency: a.currency, date: Date(),
                finnhubKey: settings.finnhubKey, kisAppKey: settings.kisAppKey,
                kisAppSecret: settings.kisAppSecret, dataGoKey: settings.dataGoKey
            ), r.unit > 0 else { continue }
            a.amount = r.amount.rounded()
            a.unitPriceKRW = r.unit
            a.lastPriced = Date()
            evaluate(a)
        }
        try? context.save()
    }

    /// 다음 백그라운드 확인을 iOS 에 부탁한다. 언제 깨울지는 iOS 가 정한다(빨라야 1시간 뒤).
    static func scheduleBackgroundCheck() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// 앱을 보고 있을 때도 매도 알림을 배너로 띄운다(기본은 앱이 켜져 있으면 숨김).
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
