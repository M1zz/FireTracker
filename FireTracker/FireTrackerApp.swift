import SwiftUI
import SwiftData
import TipKit
import LeeoKit
import UserNotifications

@main
struct FireTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // 퇴사각 프로 권한 — 앱 전역에서 하나. 구매·복원·환불이 어느 화면에서든 바로 반영된다.
    @StateObject private var proStore = ProAccess.makeStore()

    init() {
        // 계약(FireTrackerSpec)에 선언한 것들을 실제로 켠다 — 사용량 기록, 크래시·행 진단,
        // DEBUG 프리플라이트. 사용현황 스냅샷만 여기서 끄고 앱이 직접 보낸다(AppUsage):
        // 이 앱만의 지표(자산 수·기록 수 등)를 함께 실어야 해서다.
        LeeoKit.bootstrap(FireTrackerSpec.self, usageReporting: false)
        // 앱을 보는 중에 매도 알림이 와도 배너로 보이게.
        UNUserNotificationCenter.current().delegate = ForegroundNotificationPresenter.shared
        // 세그먼트 폭을 글자 길이에 맞춰 나눈다 — 긴 언어에서 한 칸만 '…'로 잘리지 않게.
        UISegmentedControl.appearance().apportionsSegmentWidthsByContent = true
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FireSettings.self,
            NetWorthSnapshot.self,
            AssetEntry.self,
            Asset.self,
            AssetDetail.self,
            AssetTrade.self,
            SavedCalc.self
        ])
        // 기기 저장소가 기본이고, 퇴사각 프로의 iCloud 동기화를 켜면 앱 전용 CloudKit 컨테이너로
        // 미러링한다. 실패하면 기기 저장소로 돌아가 앱이 죽지 않는다(SyncManager).
        return SyncManager.makeContainer(schema: schema)
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    // Show occasional tips (e.g. "다른 자산은 없나요?"), at most weekly.
                    try? Tips.configure([
                        .displayFrequency(.weekly),
                        .datastoreLocation(.applicationDefault)
                    ])
                    // 4단계 — 마지막으로 만족점을 점검한 지 1년이 지났으면 재점검 팁을 깨운다.
                    ReflectionState.refreshReviewDue()
                    // 앱이 켜질 때마다 로컬 자동 백업을 남긴다 — 실수로 데이터를
                    // 지워도 직전 상태로 복구할 수 있는 안전망.
                    BackupManager.autoBackup(context: sharedModelContainer.mainContext)
                }
                .leeoSatisfactionCheck(FireTrackerSpec.self)
                .environmentObject(proStore)
        }
        .modelContainer(sharedModelContainer)
        // 포그라운드로 돌아올 때마다 사용 스냅샷을 다시 시도한다.
        //
        // 콜드 런치 때 한 번만 보내면, 그 순간 iCloud가 준비 안 된 사람(로그인 전,
        // 비행기 모드, 네트워크 없음)은 그 세션이 통째로 유실되고 다음 콜드 런치까지
        // 기다린다. 앱을 백그라운드에 두고 며칠씩 쓰는 사람은 그동안 허브에서
        // 활성으로 잡히지 않는다 — lastActiveAt 이 곧 활성 사용자 기준이기 때문.
        // 전송량은 LeeoKit이 12시간 쓰로틀로 막아 주므로 여기선 부담 없이 부른다.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                AppUsage.reportSnapshot()
                // 돌아올 때마다(15분 쓰로틀) 매도 원칙을 건 종목의 시세를 확인한다.
                Task { await SellWatch.checkPrices(container: sharedModelContainer) }
            }
            // 쉬는 동안에도 확인하도록 다음 백그라운드 갱신을 부탁해 둔다.
            if phase == .background { SellWatch.scheduleBackgroundCheck() }
        }
        // iOS 가 깨워 주면 시세를 확인하고, 다음 번을 다시 부탁한다.
        .backgroundTask(.appRefresh(SellWatch.taskID)) {
            await SellWatch.checkPrices(container: sharedModelContainer, force: true)
            SellWatch.scheduleBackgroundCheck()
        }
    }
}
