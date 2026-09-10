import SwiftUI
import SwiftData
import TipKit
import LeeoKit

@main
struct FireTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 계약(FireTrackerSpec)에 선언한 것들을 실제로 켠다 — 사용량 기록, 크래시·행 진단,
        // DEBUG 프리플라이트. 사용현황 스냅샷만 여기서 끄고 앱이 직접 보낸다(AppUsage):
        // 이 앱만의 지표(자산 수·기록 수 등)를 함께 실어야 해서다.
        LeeoKit.bootstrap(FireTrackerSpec.self, usageReporting: false)
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
        // 이 앱의 SwiftData 저장소는 기기 안에만 둔다(백업은 BackupManager가 파일로 담당).
        // cloudKitDatabase를 지정하지 않으면, entitlements에 있는 iCloud 권한
        // (피드백 허브 LeeoKit용 컨테이너)을 보고 SwiftData가 CloudKit 동기화를 자동으로 켠다.
        // 그러면 "모든 속성은 optional이거나 기본값이 있어야 하고 관계도 optional이어야 한다"는
        // CloudKit 요구를 모델이 못 맞춰 스토어 로드가 실패하고 실행 즉시 죽는다.
        // 나중에 진짜 iCloud 동기화를 붙일 땐 이 앱 전용 컨테이너를 만들고
        // 모델 속성에 전부 기본값(관계는 optional)을 주는 작업이 먼저다.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                        cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
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
            if phase == .active { AppUsage.reportSnapshot() }
        }
    }
}
