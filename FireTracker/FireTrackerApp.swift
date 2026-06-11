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
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
