import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("대시보드", systemImage: "flame.fill") }
                .tag(0)

            TrendView()
                .tabItem { Label("추이", systemImage: "chart.xyaxis.line") }
                .tag(1)

            AssetsView()
                .tabItem { Label("자산", systemImage: "wonsign.circle.fill") }
                .tag(2)

            SnapshotsView()
                .tabItem { Label("기록", systemImage: "list.bullet.rectangle") }
                .tag(3)

            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        // Dismiss the keyboard when switching tabs (e.g. leaving 설정 mid-edit).
        .onChange(of: selectedTab) { _, _ in
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        .onAppear { bootstrapSettings() }
    }

    // Ensure exactly one settings record exists.
    private func bootstrapSettings() {
        if settingsList.isEmpty {
            context.insert(FireSettings())
            try? context.save()
        }
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Theme.surface)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        // Opaque nav bar when scrolled so content doesn't bleed through the
        // title. Leave the scroll-edge (top) appearance at its transparent
        // default so the large title still shows.
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Theme.bg)
        navAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }
}
