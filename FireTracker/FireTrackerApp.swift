import SwiftUI
import SwiftData
import TipKit
import LeeoKit

@main
struct FireTrackerApp: App {
    init() {
        LeeoEngagement.shared.registerLaunch()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FireSettings.self,
            NetWorthSnapshot.self,
            AssetEntry.self,
            Asset.self,
            AssetDetail.self
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
    }
}
