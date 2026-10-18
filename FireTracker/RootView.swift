import SwiftUI
import SwiftData
import LocalAuthentication
import CoreData
import WidgetKit
import LeeoKit

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @StateObject private var refresher = RefreshManager()
    @EnvironmentObject private var pro: LeeoStore
    @AppStorage("amountNumbersOnly") private var amountNumbersOnly = false
    @AppStorage(DemoData.activeKey) private var demoActive = false
    @AppStorage("appLockEnabled") private var lockEnabled = false
    // 시트·카드에서도 탭을 옮길 수 있게 공용 라우터에 둔다.
    @Bindable private var router = AppRouter.shared
    @Bindable private var alerts = AppAlerts.shared

    // 온보딩 대신 — 아무 데이터도 없는 첫 사용자거나, 데모를 보는 중일 때만
    // 최상단에 데모 토글 배너를 띄운다.
    private var showDemoBanner: Bool {
        // 동기화 중에 데모를 켜면 다른 기기의 실데이터까지 지워지므로 아예 띄우지 않는다.
        guard !SyncManager.activeThisLaunch || demoActive else { return false }
        return demoActive || (assets.isEmpty && snapshots.isEmpty)
    }

    // 자산 상태 지문 — 어느 탭에서든 자산이 추가·수정·삭제되거나 시세가 갱신되면
    // 값이 바뀐다. 바뀔 때마다 오늘 기록을 자동 갱신해, 저장 버튼 없이도
    // 변동이 생긴 날의 기록과 변화량이 앱에 그대로 남는다.
    private var assetsFingerprint: Int {
        var h = Hasher()
        for a in assets {
            h.combine(a.key)
            h.combine(a.amount)
            h.combine(a.quantity)
            h.combine(a.costBasis)
            h.combine(a.assetClassRaw)
        }
        return h.finalize()
    }

    var body: some View {
        // 금액 표기 모드를 전역 포매터에 반영. 이 값을 읽으므로 토글이 바뀌면
        // RootView가 다시 그려지고, 그 안에서 만들어진 모든 탭도 새 표기로 갱신된다.
        let _ = (Fmt.numbersOnly = amountNumbersOnly)
        AppLockGate {
            VStack(spacing: 0) {
            if showDemoBanner { demoBanner }
            TabView(selection: $router.selectedTab) {
            DashboardView()
                .tabItem { Label("대시보드", systemImage: "flame.fill") }
                .tag(0)

            AssetsView()
                .tabItem { Label("자산", systemImage: "wonsign.circle.fill") }
                .tag(1)

            TrendView()
                .tabItem { Label("여정", systemImage: "chart.xyaxis.line") }
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
        .onChange(of: router.selectedTab) { _, _ in
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        .onAppear {
            bootstrapSettings()
            // 익명 사용 스냅샷 — 지표를 먼저 채운 다음 보낸다(첫 실행에도 값이 실리도록).
            reportUsage()
            publishSummary()
            if SyncManager.activeThisLaunch { SyncManager.dedupe(context: context) }
        }
        // 자산에 변동이 생기면(어느 탭이든) 오늘 기록을 자동 갱신 — 수동 저장 불필요.
        .onChange(of: assetsFingerprint) { _, _ in
            let s = settingsList.first ?? FireSettings()
            refresher.upsertCurrentPeriodSnapshot(
                assets: assets, settings: s, snapshots: snapshots, context: context
            )
            updateUsageMetrics()
            publishSummary()
        }
        // 목표가 바뀌어도 위젯·알림 문구를 새 숫자로.
        .onChange(of: settingsFingerprint) { _, _ in publishSummary() }
        .onChange(of: lockEnabled) { _, _ in publishSummary() }
        .alert("저장하지 못했어요",
               isPresented: Binding(get: { alerts.message != nil },
                                    set: { if !$0 { alerts.message = nil } })) {
            Button("확인", role: .cancel) { alerts.message = nil }
        } message: {
            Text(alerts.message ?? "")
        }
        // 다른 기기의 변경이 내려오면 같은 날 기록·설정이 둘이 될 수 있다 — 하나만 남긴다.
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            guard SyncManager.activeThisLaunch else { return }
            SyncManager.dedupe(context: context)
        }
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
    }

    // 최상단 데모 토글 배너 — 온보딩 대신, 스위치 하나로 데모 데이터를 넣었다 뺐다.
    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(demoActive ? "데모 데이터로 보는 중" : "처음이신가요?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(demoActive
                     ? "데모 중에 넣은 내용은 끄면 사라져요. 끄면 내 데이터로 돌아가요."
                     : "켜면 가상 인물의 자산으로 앱을 둘러볼 수 있어요.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
            Toggle("", isOn: demoToggleBinding)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }

    // 켜면 지금 데이터를 스태시에 보관하고 데모로, 끄면 스태시에서 그대로 복귀 —
    // 데이터가 사라지지 않으니 확인 없이 바로 토글한다.
    private var demoToggleBinding: Binding<Bool> {
        Binding(
            get: { demoActive },
            set: { on in
                withAnimation {
                    if on {
                        try? DemoData.enable(context: context)
                        AppUsage.log(.demoOn)
                    }
                    else { try? DemoData.disable(context: context) }
                }
            }
        )
    }

    // 목표 입력이 바뀌면 값이 바뀐다 — 위젯·알림 갱신 신호.
    private var settingsFingerprint: Int {
        guard let s = settingsList.first else { return 0 }
        var h = Hasher()
        h.combine(s.targetAnnualExpense)
        h.combine(s.safeWithdrawalRate)
        h.combine(s.expectedAnnualReturn)
        h.combine(s.plannedMonthlySavings)
        h.combine(s.currentAge)
        return h.finalize()
    }

    // 퇴사각 요약을 위젯에 넘기고, 매달 알림 문구도 새 숫자로 다시 건다.
    // 데모를 보는 중엔 남의 숫자라 내보내지 않는다.
    private func publishSummary() {
        guard !demoActive, let s = settingsList.first else { return }
        let net = assets.isEmpty
            ? (snapshots.last?.netWorth ?? 0)
            : assets.reduce(0) { $0 + $1.netValue }
        let summary = FireOutlook(netWorth: net, settings: s)
            .summary(goalConfigured: s.goalConfigured, locked: lockEnabled)
        FireSummary.publish(summary)
        MonthlyReminder.reschedule(summary: summary)
    }

    // 대시보드에 실어 보낼 이 앱만의 지표 — 개수와 on/off 뿐, 금액은 나가지 않는다.
    private func updateUsageMetrics() {
        let s = settingsList.first
        AppUsage.updateMetrics(
            assetCount: assets.count,
            debtCount: assets.filter(\.isDebt).count,
            autoPricedCount: assets.filter(\.autoPriced).count,
            tradeCount: assets.reduce(0) { $0 + $1.tradeList.count },
            snapshotCount: snapshots.count,
            hasGoal: (s?.monthsToRetire) != nil,
            hasPriceKey: !(s?.dataGoKey.isEmpty ?? true)
        )
    }

    private func reportUsage() {
        updateUsageMetrics()
        AppUsage.reportSnapshot()
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
