//
//  Usage.swift
//  FireTracker
//
//  익명 사용 통계 — 피드백과 같은 CloudKit 허브(iCloud.com.Ysoup.FeedbackHub)로 보낸다.
//  외부 분석 SDK 없이, 앱이 실제로 쓰이는지만 알기 위한 최소한의 계측이다.
//
//  보내는 것:
//    · 설치당 스냅샷 1개 (UsageSnapshot, LeeoKit 이 12시간에 한 번으로 제한)
//      — 실행 횟수·설치 후 경과일·앱 버전·OS·로케일 + 아래 metrics
//    · 주요 행동 이벤트 (UsageEvent) — 자산 추가·시세 갱신·백업·계산 모드 등
//
//  보내지 않는 것: 금액. 이 앱이 다루는 값은 전부 남의 재산이라 **숫자 자체는 절대
//  나가지 않는다**. 나가는 건 "자산을 몇 개 넣었나", "시세 자동을 쓰나" 같은 개수·on/off 뿐이다.
//  설치 식별은 기기·계정과 무관한 무작위 UUID(LeeoKit 이 만든다)라 재설치하면 새 사람이 된다.
//

import Foundation
import LeeoKit

enum AppUsage {

    /// 이 앱이 남기는 이벤트 이름.
    /// 호출부마다 문자열을 적으면 오타 하나가 대시보드에서 별개 이벤트가 되므로 여기서만 정의한다.
    enum Event: String {
        /// 자산을 새로 하나 넣었다 (앱을 실제로 쓰기 시작하는 순간)
        case assetAdded = "asset_added"
        /// 매매 원장에 거래를 기록했다
        case tradeLogged = "trade_logged"
        /// 시세를 수동으로 새로고침했다 (= API 키를 넣고 자동 시세를 쓰고 있다)
        case priceRefreshed = "price_refreshed"
        /// 순자산 기록을 남겼다 (추이가 쌓이기 시작한다)
        case snapshotSaved = "snapshot_saved"
        /// 백업 파일을 내보냈다
        case backupExported = "backup_exported"
        /// 백업 파일에서 복원했다
        case backupRestored = "backup_restored"
        /// 계산 결과를 저장했다 (계산기를 한 번 쓰고 버리지 않았다)
        case calcSaved = "calc_saved"
        /// 데모 데이터를 켜 봤다 (온보딩 대신 쓰는 길)
        case demoOn = "demo_on"
    }

    private static var reporter: LeeoUsageReporter {
        LeeoUsageReporter(spec: FireTrackerSpec.self)
    }

    /// 앱 시작 시 1회. 설치당 스냅샷 하나를 갱신한다(LeeoKit 이 12시간 간격으로 제한한다).
    static func reportSnapshot() {
        reporter.reportInBackground(metrics: cachedMetrics())
    }

    /// 같은 이벤트를 다시 보내기까지의 최소 간격.
    /// 새로고침 버튼처럼 한 자리에서 여러 번 눌리는 행동이 CloudKit 쓰기로 그대로 나가면
    /// 레코드가 폭발하고 "몇 번 눌렸나" 라는, 어차피 판단에 못 쓰는 숫자만 쌓인다.
    /// 보고 싶은 건 "이 설치가 이 행동을 하는가" 라서 하루 몇 건이면 충분하다.
    /// (LeeoUsageReporter 는 스냅샷만 쓰로틀하고 이벤트는 부르는 대로 보낸다 — 앱이 건다.)
    private static let eventInterval: TimeInterval = 6 * 3600

    /// 의미 있는 행동 1건.
    /// LeeoEngagement 카운트도 함께 올린다 — 만족도 프롬프트(`.leeoSatisfactionCheck`)와
    /// 리뷰 게이트가 이 수치를 보고 '충분히 써 본 사용자'인지 판단한다.
    /// 카운트는 매번 올리고, CloudKit 전송만 이벤트별로 6시간에 한 번으로 줄인다.
    static func log(_ event: Event) {
        log(name: event.rawValue)
    }

    /// 계산 탭에서 어느 모드를 실제로 쓰는지. 모드가 6개인데 어느 걸 쓰는지 모르면
    /// 다음에 무엇을 다듬어야 할지 정할 근거가 없다. `calc_time` 처럼 나간다.
    static func logCalc(_ modeKey: String) {
        log(name: "calc_\(modeKey)")
    }

    private static func log(name: String) {
        _ = LeeoEngagement.shared.registerSignificantEvent()

        let key = "leeo.usage.lastEventAt.\(name)"
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard last <= 0 || now - last >= eventInterval else { return }
        defaults.set(now, forKey: key)

        reporter.logEventInBackground(name)
    }

    // MARK: - 지표 (개수·on/off 만, 금액은 절대 아님)

    /// 스냅샷에 실어 보낼 지표의 캐시 키. 지표는 SwiftData 를 읽어야 나오는데
    /// 스냅샷 전송은 앱 시작 직후 백그라운드에서 일어난다. 통계 때문에
    /// 백그라운드에서 ModelContext 를 건드리지 않으려고, 화면이 이미 들고 있는 값을
    /// 메인 액터에서 여기 적어 두고 전송 때는 그것만 읽는다.
    private static let metricsKey = "usage.metrics.fireTracker"

    /// 대시보드가 보는 이 앱만의 지표. 화면에서 자산·기록이 바뀔 때마다 갱신한다.
    ///
    /// - Parameters:
    ///   - assetCount: 등록한 자산 수 (0이면 설치만 하고 안 쓴 사람)
    ///   - debtCount: 그중 부채
    ///   - autoPricedCount: 시세 자동으로 돌고 있는 자산 수
    ///   - tradeCount: 매매 원장에 쌓인 거래 수
    ///   - snapshotCount: 남긴 순자산 기록 수 (추이를 쓰는가)
    ///   - hasGoal: FIRE 목표(은퇴 나이)를 채워 넣었는가
    ///   - hasPriceKey: 시세 API 키를 하나라도 넣었는가
    @MainActor
    static func updateMetrics(assetCount: Int,
                              debtCount: Int,
                              autoPricedCount: Int,
                              tradeCount: Int,
                              snapshotCount: Int,
                              hasGoal: Bool,
                              hasPriceKey: Bool) {
        let metrics: [String: Double] = [
            "assets": Double(assetCount),
            "debts": Double(debtCount),
            "autoPriced": Double(autoPricedCount),
            "trades": Double(tradeCount),
            "snapshots": Double(snapshotCount),
            "goal": hasGoal ? 1 : 0,
            "priceKey": hasPriceKey ? 1 : 0,
        ]
        UserDefaults.standard.set(metrics, forKey: metricsKey)
    }

    private static func cachedMetrics() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: metricsKey) as? [String: Double] ?? [:]
    }
}
