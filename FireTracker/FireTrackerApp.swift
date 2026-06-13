import SwiftUI
import SwiftData
import TipKit

@main
struct FireTrackerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FireSettings.self,
            NetWorthSnapshot.self,
            AssetEntry.self,
            Asset.self,
            AssetDetail.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
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
        }
        .modelContainer(sharedModelContainer)
    }
}
