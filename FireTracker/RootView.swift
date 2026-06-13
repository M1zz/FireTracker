import SwiftUI
import SwiftData
import LocalAuthentication

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @StateObject private var refresher = RefreshManager()
    @AppStorage("amountNumbersOnly") private var amountNumbersOnly = false
    @State private var selectedTab = 0

    var body: some View {
        // 금액 표기 모드를 전역 포매터에 반영. 이 값을 읽으므로 토글이 바뀌면
        // RootView가 다시 그려지고, 그 안에서 만들어진 모든 탭도 새 표기로 갱신된다.
        let _ = (Fmt.numbersOnly = amountNumbersOnly)
        AppLockGate {
            TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("대시보드", systemImage: "flame.fill") }
                .tag(0)

            AssetsView()
                .tabItem { Label("자산", systemImage: "wonsign.circle.fill") }
                .tag(1)

            TrendView()
                .tabItem { Label("추이", systemImage: "chart.xyaxis.line") }
                .tag(2)

            SimulatorView()
                .tabItem { Label("계산", systemImage: "plus.forwardslash.minus") }
                .tag(3)

            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(Theme.accent)
        // Bigger baseline text, but still scales with the system text-size
        // setting (floor at xLarge, capped before the extreme accessibility
        // sizes that would break the dense card layouts).
        .dynamicTypeSize(.xLarge ... .accessibility1)
        // Dismiss the keyboard when switching tabs (e.g. leaving 설정 mid-edit).
        .onChange(of: selectedTab) { _, _ in
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        .onAppear { bootstrapSettings() }
        .environmentObject(refresher)
        // 앱 시작 시 — 마지막 갱신이 7일 이상 지났으면 시세·배당을 자동 갱신하고,
        // 이번 달 기록이 없으면 최신 평가액으로 월 1회 자동 스냅샷을 남긴다.
        .task {
            let s = settingsList.first ?? FireSettings()
            await refresher.refreshIfStale(
                assets: assets, settings: s, context: context, maxAge: RefreshManager.weekly
            )
            refresher.autoRecordIfNeeded(
                assets: assets, settings: s, snapshots: snapshots, context: context
            )
        }
        }
    }

    // Ensure exactly one settings record exists.
    private func bootstrapSettings() {
        if settingsList.isEmpty {
            context.insert(FireSettings())
            try? context.save()
        }

        // Bars use dynamic colors so they adapt to light/dark automatically.
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = Theme.surfaceUI
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        // Opaque nav bar when scrolled so content doesn't bleed through the
        // title. Leave the scroll-edge (top) appearance at its transparent
        // default so the large title still shows.
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = Theme.bgUI
        navAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }
}

// Hides the app content behind a biometric lock. When 설정 > 보안 > 앱 잠금 is on,
// content stays covered until Face ID / Touch ID (or the device passcode)
// succeeds, and is re-covered whenever the app leaves the foreground — so a
// glance at launch, or the app-switcher snapshot, never reveals balances.
struct AppLockGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @AppStorage("appLockEnabled") private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked = false
    @State private var authenticating = false

    var body: some View {
        ZStack {
            content()
                .blur(radius: covered ? 30 : 0)
                .allowsHitTesting(!covered)

            if covered {
                lockScreen
            }
        }
        .onAppear(perform: syncLockState)
        .onChange(of: lockEnabled) { _, _ in syncLockState() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if lockEnabled && !isUnlocked { authenticate() }
            case .background:
                // Re-arm the lock so returning to the app requires auth again.
                if lockEnabled { isUnlocked = false }
            default:
                break
            }
        }
    }

    // Cover the content while locked, or any time the app isn't active (app
    // switcher, incoming call) so balances never flash in a snapshot.
    private var covered: Bool {
        guard lockEnabled else { return false }
        return !isUnlocked || scenePhase != .active
    }

    private func syncLockState() {
        if lockEnabled {
            if !isUnlocked { authenticate() }
        } else {
            isUnlocked = true
        }
    }

    private func authenticate() {
        guard lockEnabled, !isUnlocked, !authenticating else { return }
        let context = LAContext()
        context.localizedFallbackTitle = "기기 암호 입력"
        var error: NSError?
        // Biometrics with passcode fallback, so a failed Face ID can still
        // unlock via the device passcode.
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            // No biometrics or passcode set → never lock the owner out of their
            // own data; treat as unlocked.
            isUnlocked = true
            return
        }
        authenticating = true
        context.evaluatePolicy(policy,
                               localizedReason: "자산 정보를 보려면 인증이 필요합니다.") { success, _ in
            Task { @MainActor in
                authenticating = false
                if success { isUnlocked = true }
            }
        }
    }

    private var lockScreen: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.accent)
                VStack(spacing: 6) {
                    Text("자산 정보 보호 중")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("인증 후 자산이 표시됩니다.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                // Only offer the unlock button while the app is actually active;
                // hidden in the app-switcher snapshot.
                if scenePhase == .active {
                    Button(action: authenticate) {
                        HStack(spacing: 8) {
                            Image(systemName: "faceid")
                            Text("잠금 해제")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(Theme.accent)
                        .foregroundStyle(Color.black)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 8)
                }
            }
            .padding(40)
        }
    }
}
