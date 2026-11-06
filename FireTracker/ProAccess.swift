//
//  ProAccess.swift
//  FireTracker
//
//  부분 유료화 — 무료 · 퇴사각 Plus · 퇴사각 Pro.
//
//  원칙: "언제 퇴사할 수 있나"라는 앱의 질문에 답하는 데 필요한 것은 전부 무료다.
//  자산 기록·여정·대시보드·생애주기 계산·백업·앱 잠금은 잠그지 않는다. 자산 개수도
//  제한하지 않는다 — 자산을 다 못 넣으면 답 자체가 틀려지기 때문이다.
//   · Plus: 날짜를 본 다음 "어떻게 당기지"를 계산하는 도구 (계산기 넷, 계산 무제한 저장, 매매 원장)
//   · Pro : 퇴사 그날을 미리 살아 보고, 기록이 알아서 따라오게 (미리보기, 분기 리포트, 동기화, 가져오기, 위젯)
//  칸마다 주 · 월 · 연 자동 갱신 구독(한 구독 그룹, Pro 가 위 단계)과 평생을 판다.
//
//  결제 코어(상품 로드·구매·복원·권한 캐시·칸 판정)는 LeeoKit 의 LeeoStore 가 맡고,
//  여기서는 "무엇을 어느 칸에 두나"와 "이미 산 사람 보호"만 정한다.
//

import SwiftUI
import SwiftData
import StoreKit
import Security
import LeeoKit

// MARK: - 칸

/// 유료 칸. 위 칸은 아래 칸 기능을 모두 연다. rawValue 는 `LeeoGatePolicy.tiers` 의 순번이다.
enum ProTier: Int, CaseIterable, Comparable, Identifiable {
    case plus
    case pro

    var id: Int { rawValue }
    static func < (a: ProTier, b: ProTier) -> Bool { a.rawValue < b.rawValue }

    /// 칸 이름 — 모든 언어에서 그대로 쓴다.
    var name: String {
        switch self {
        case .plus: return "Plus"
        case .pro:  return "Pro"
        }
    }

    var fullName: String {
        switch self {
        case .plus: return String(localized: "퇴사각 Plus")
        case .pro:  return String(localized: "퇴사각 Pro")
        }
    }

    var tagline: String {
        switch self {
        case .plus: return String(localized: "날짜를 본 다음, 어떻게 당길지 계산하기")
        case .pro:  return String(localized: "퇴사 그날을 미리 살아 보고, 기록은 알아서 따라오게")
        }
    }

    var weeklyID: String { "\(ProAccess.bundleID).\(slug).weekly" }
    var monthlyID: String { "\(ProAccess.bundleID).\(slug).monthly" }
    var yearlyID: String { "\(ProAccess.bundleID).\(slug).yearly" }
    /// 평생. Pro 평생은 유료 다운로드 시절부터 있던 `…FireTracker.pro` 를 그대로 쓴다.
    var lifetimeID: String { "\(ProAccess.bundleID).\(slug)" }

    /// 이 칸을 여는 상품 전부. Pro 는 올리기 · 졸업도 Pro 평생이다.
    var productIDs: [String] {
        let base = [yearlyID, lifetimeID, monthlyID, weeklyID]
        return self == .pro ? base + [ProAccess.upgradeID, ProAccess.graduateID] : base
    }

    var features: [ProFeature] { ProFeature.allCases.filter { $0.tier == self } }

    private var slug: String { self == .plus ? "plus" : "pro" }
}

/// 유료 칸을 사는 길. 연이 기본이고 주 · 월은 펼쳐 보인다.
enum ProTerm: CaseIterable {
    case yearly, lifetime, monthly, weekly

    func productID(_ tier: ProTier) -> String {
        switch self {
        case .yearly:   return tier.yearlyID
        case .lifetime: return tier.lifetimeID
        case .monthly:  return tier.monthlyID
        case .weekly:   return tier.weeklyID
        }
    }
}

// MARK: - 잠긴 기능

/// 칸으로 열리는 기능. rawValue 는 LeeoGatePolicy 의 기능 키다.
enum ProFeature: String, CaseIterable, Identifiable, LeeoProFeature {
    case futurePreview    = "future.preview"
    case quarterlyReport  = "future.quarterlyReport"
    case iCloudSync       = "sync.iCloud"
    case widget           = "widget"
    case investForecast   = "calc.invest"
    case debtVsInvest     = "calc.debtVsInvest"
    case purchasingPower  = "calc.wage"
    case timeValue        = "calc.time"
    case unlimitedSaves   = "calc.saved"
    case tradeLedger      = "assets.tradeLedger"
    case screenshotImport = "assets.screenshotImport"

    var id: String { rawValue }

    /// 이 기능을 여는 가장 낮은 칸.
    var tier: ProTier {
        switch self {
        case .investForecast, .debtVsInvest, .purchasingPower, .timeValue, .unlimitedSaves, .tradeLedger:
            return .plus
        case .futurePreview, .quarterlyReport, .iCloudSync, .widget, .screenshotImport:
            return .pro
        }
    }

    var leeoTitle: String {
        switch self {
        case .futurePreview:    return String(localized: "퇴사 그날 미리보기")
        case .quarterlyReport:  return String(localized: "분기 퇴사각 리포트")
        case .iCloudSync:       return String(localized: "iCloud 동기화")
        case .widget:           return String(localized: "홈 화면 · 잠금화면 위젯")
        case .investForecast:   return String(localized: "투자 예측")
        case .debtVsInvest:     return String(localized: "빚 갚기 vs 투자하기")
        case .purchasingPower:  return String(localized: "월급 구매력")
        case .timeValue:        return String(localized: "돈과 시간")
        case .unlimitedSaves:   return String(localized: "계산 무제한 저장")
        case .tradeLedger:      return String(localized: "매매 원장")
        case .screenshotImport: return String(localized: "보유 종목 한 번에 가져오기")
        }
    }

    var leeoDetail: String {
        switch self {
        case .futurePreview:
            return String(localized: "퇴사하는 날의 나를 미리 봐요. 건강보험료·국민연금까지 넣은 진짜 생활비, 그 돈이 몇 살까지 버틸 확률, 세금이 가장 적은 인출 순서, 다른 선택을 했을 때의 미래까지.")
        case .quarterlyReport:
            return String(localized: "석 달마다 퇴사 날짜가 얼마나 당겨졌는지, 무엇이 움직였는지 정리해 알려줘요.")
        case .iCloudSync:
            return String(localized: "아이폰과 아이패드에서 같은 자산과 기록을 봐요.")
        case .widget:
            return String(localized: "예상 퇴사 시점과 달성률을 앱을 열지 않고 홈 화면과 잠금화면에서 봐요.")
        case .investForecast:
            return String(localized: "지금 자산이 앞으로 어디까지 갈지 좋을 때와 나쁠 때의 범위로 보여줘요.")
        case .debtVsInvest:
            return String(localized: "같은 돈으로 빚을 갚을지 투자할지, 어느 쪽이 퇴사를 앞당기는지 비교해요.")
        case .purchasingPower:
            return String(localized: "지난 월급을 물가로 나눠 내 실질 구매력이 늘었는지 알려줘요.")
        case .timeValue:
            return String(localized: "내 시급으로 돈을 시간으로 바꿔 보고, 저축이 시급을 넘는 시점을 찾아요.")
        case .unlimitedSaves:
            return String(localized: "무료로는 3개까지 저장할 수 있어요. Plus부터 제한 없이 저장해요.")
        case .tradeLedger:
            return String(localized: "언제 몇 주를 얼마에 샀는지 남기면 평단과 실현 손익이 자동으로 계산돼요.")
        case .screenshotImport:
            return String(localized: "증권사 앱 캡처, CSV 파일이나 복사한 표, 한국투자증권 계좌로 종목과 수량을 한 번에 불러와요.")
        }
    }

    var leeoIcon: String {
        switch self {
        case .futurePreview:    return "sunrise.fill"
        case .quarterlyReport:  return "doc.text.magnifyingglass"
        case .iCloudSync:       return "icloud.fill"
        case .widget:           return "rectangle.on.rectangle"
        case .investForecast:   return "chart.line.uptrend.xyaxis"
        case .debtVsInvest:     return "arrow.triangle.branch"
        case .purchasingPower:  return "cart"
        case .timeValue:        return "hourglass"
        case .unlimitedSaves:   return "bookmark.fill"
        case .tradeLedger:      return "list.bullet.rectangle"
        case .screenshotImport: return "text.viewfinder"
        }
    }

    /// 무료 사용 한도 (개수형 기능만).
    static let freeSaveLimit = 3

    /// 계약(FireTrackerSpec)에 선언하는 게이트 정책. 무엇이 잠기는지만 말하고,
    /// 어느 칸이 여는지는 `tier` 가 정한다(`ProGate`).
    static var gatePolicy: LeeoGatePolicy {
        LeeoGatePolicy(
            freeLimits: [ProFeature.unlimitedSaves.rawValue: freeSaveLimit],
            proOnly: Set(allCases.filter { $0 != .unlimitedSaves }.map(\.rawValue)),
            warnWhenRemaining: 1
        )
    }
}

// MARK: - 칸 게이트

/// 칸까지 보는 게이트 — "지금 이 기능을 써도 되나". 기능마다 그 칸 이상이면 열린다.
/// 판정(무료 한도 · 남은 개수)은 LeeoKit 의 `LeeoGate` 에 맡긴다.
struct ProGate {
    /// 지금 열린 칸. 무료면 nil.
    let tier: ProTier?

    private func gate(_ key: String) -> LeeoGate {
        let needed = ProFeature(rawValue: key)?.tier ?? .pro
        return LeeoGate(policy: ProFeature.gatePolicy, hasPro: tier.map { $0 >= needed } ?? false,
                        isTrialActive: false)
    }

    func evaluate(_ key: String, current: Int = 0, adding: Int = 1) -> LeeoGateDecision {
        gate(key).evaluate(key, current: current, adding: adding)
    }

    func allows(_ key: String) -> Bool { gate(key).allows(key) }

    func remaining(_ key: String, current: Int) -> Int? { gate(key).remaining(key, current: current) }
}

// MARK: - 스토어 구성

enum ProAccess {
    static let bundleID = "com.devkoan.FireTracker"

    /// Plus 평생을 산 사람이 Pro 평생으로 올리는 값(비소모성). 열면 Pro 평생과 같다.
    static let upgradeID = "\(bundleID).pro.upgrade"
    /// 구독 졸업: 연 구독 중인 사람만 보는 Pro 평생(비소모성, `LeeoGraduation`).
    static let graduateID = "\(bundleID).pro.graduate"

    /// 페이월이 불러올 상품, 화면 순서대로. 이 중 무엇이든 권한이다.
    /// ⚠️ 선물 · 팁 · 언제나 평생 패스는 넣지 않는다. 넣으면 그것을 산 사람이 Pro 가 된다.
    static let saleProductIDs = ProTier.allCases.flatMap(\.productIDs)

    /// 구독 졸업을 제안할 구독. 주 · 월 구독에 졸업가를 주면 한 주 값으로 평생이 싸진다.
    static let yearlyIDs: Set<String> = Set(ProTier.allCases.map(\.yearlyID))
    /// 자동 갱신 구독 전부 (설정의 '구독 관리' 줄).
    static let subscriptionIDs: Set<String> = Set(ProTier.allCases.flatMap { [$0.yearlyID, $0.monthlyID, $0.weeklyID] })

    /// 자동 갱신 구독의 이용약관 — Apple 표준 EULA.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// 프로 선물 — 소모성 상품. 받는 사람은 Pro 평생을 산 것과 같아진다(`FireTrackerSpec.monetization`).
    /// ⚠️ `saleProductIDs` 에 넣지 않는다. 넣으면 선물을 산 사람 자신이 Pro 가 된다.
    static let giftProductID = "\(bundleID).gift.pro"

    /// 개발자 응원하기(팁) — 소모성 세 가지, 작은 것부터. 아무것도 열지 않는다.
    /// ⚠️ 선물처럼 `saleProductIDs` 에 넣지 않는다. 넣으면 팁을 낸 사람이 Pro 가 된다.
    static let tipProductIDs = [
        "\(bundleID).tip.small",
        "\(bundleID).tip.medium",
        "\(bundleID).tip.large",
    ]

    /// 유료 다운로드로 낸 마지막 빌드 번호(CFBundleVersion, 1.2.4 빌드 12).
    /// App Store 에서 이 빌드 이하로 처음 받은 사람은 앱값을 낸 사람이다 — Pro 평생.
    /// ⚠️ 무료 전환 빌드는 반드시 이 값보다 커야 하고, 앱 가격을 무료로 내리는 날과 같은 날 낸다.
    static let lastPaidBuild = 12

    /// 개발자 모드에서 권한을 강제하는 키. "unlock" / "lock" / 없음(정상 판정).
    static let overrideKey = "dev.proOverride"

    @MainActor
    static func makeStore() -> LeeoStore {
        LeeoStore(
            config: FireTrackerSpec.paywall ?? LeeoPaywallConfig(productIDs: saleProductIDs),
            unlockOverride: { override },
            grandfather: { await isLegacyInstall() }
        )
    }

    static var override: Bool? {
        switch UserDefaults.standard.string(forKey: overrideKey) {
        case "unlock": return true
        case "lock":   return false
        // 유료 칸 상품을 한 번도 불러오지 못한 기기는 막지 않는다 — 상품을 만들기 전에 빌드가 나가도
        // 살 수 없는데 막히는 사람이 없게. 한 번 불러온 기기는 네트워크가 끊겨도 다시 막는다.
        default:       return storeReady ? nil : true
        }
    }

    // MARK: 상품 준비

    private static let storeReadyKey = "pro.storeReady"
    static var storeReady: Bool { UserDefaults.standard.bool(forKey: storeReadyKey) }

    /// 상품을 불러오고, 유료 칸 상품이 하나라도 오면 이 기기에서 게이트를 켠다.
    @MainActor
    static func loadProducts(_ store: LeeoStore) async {
        await store.loadProducts()
        guard !storeReady, store.products.contains(where: { saleProductIDs.contains($0.id) }) else { return }
        UserDefaults.standard.set(true, forKey: storeReadyKey)
        store.objectWillChange.send()
    }

    // MARK: 이미 산 사람

    /// 앱값을 낸 설치인가. 한 번 맞으면 키체인에 남긴다(앱을 지웠다 깔아도, 오프라인이어도 그대로).
    /// 1. App Store 영수증(AppTransaction)의 최초 구매 빌드가 `lastPaidBuild` 이하.
    ///    iOS 에서 originalAppVersion 은 CFBundleVersion(빌드 번호)이다.
    ///    샌드박스·TestFlight·Xcode 에서는 이 값이 늘 "1.0" 이라 실제 App Store 설치에서만 본다.
    /// 2. 영수증을 못 읽으면(오프라인 첫 실행) 무료 전환 빌드를 처음 켤 때 이미 자산이 있었는가.
    static func isLegacyInstall() async -> Bool {
        if LegacyLatch.isSet { return true }
        var legacy = false
        if let result = try? await AppTransaction.shared,
           case .verified(let transaction) = result,
           transaction.environment == .production,
           let build = Double(transaction.originalAppVersion) {
            legacy = build <= Double(lastPaidBuild)
        } else {
            legacy = UserDefaults.standard.bool(forKey: hadDataKey)
        }
        if legacy { LegacyLatch.set() }
        return legacy
    }

    private static let hadDataKey = "pro.hadDataAtFreeLaunch"

    /// 무료 전환 빌드를 처음 켤 때 한 번 — 이미 쌓인 자산 · 기록이 있었는지 적어 둔다.
    /// 새로 받은 사람은 여기서 false 로 굳고 나중에 자산을 넣어도 바뀌지 않는다.
    static func noteExistingData(_ container: ModelContainer) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: hadDataKey) == nil else { return }
        #if DEBUG
        defaults.set(false, forKey: hadDataKey)   // 개발 기기의 기록으로 Pro 가 열리지 않게
        #else
        let context = ModelContext(container)
        let assets = (try? context.fetchCount(FetchDescriptor<Asset>())) ?? 0
        let snapshots = (try? context.fetchCount(FetchDescriptor<NetWorthSnapshot>())) ?? 0
        defaults.set(assets + snapshots > 0, forKey: hadDataKey)
        #endif
    }
}

/// 이미 산 사람 표시 — 키체인에 둔다.
private enum LegacyLatch {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "\(ProAccess.bundleID).legacy",
        kSecAttrAccount as String: "paidDownload",
    ]

    static var isSet: Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func set() {
        guard !isSet else { return }
        var add = query
        add[kSecValueData as String] = Data("1".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension LeeoStore {
    /// 칸까지 보는 게이트. 잠그는 곳은 모두 이것으로 묻는다.
    var access: ProGate { ProGate(tier: openTier) }

    /// 지금 열린 칸 — 가진 칸에 개발자 강제와 '상품 준비 전에는 열어 둠'(`ProAccess.override`)을 더한다.
    var openTier: ProTier? {
        switch ProAccess.override {
        case true?:  return .pro
        case false?: return nil
        case nil:    return ownedTier
        }
    }

    /// 실제로 가진 칸 — 산 것 · 받은 선물 · 이미 산 사람. 상품 준비 전에 열어 둔 것과 개발자 강제는 빼고.
    var ownedTier: ProTier? {
        if isGrandfathered { return .pro }
        return ProTier.allCases.last { !purchasedProductIDs.isDisjoint(with: $0.productIDs) }
    }

    /// 평생으로 가진 칸.
    var lifetimeTier: ProTier? {
        if isGrandfathered { return .pro }
        if !purchasedProductIDs.isDisjoint(with: ProTier.pro.productIDs.filter { !ProAccess.subscriptionIDs.contains($0) }) {
            return .pro
        }
        return purchasedProductIDs.contains(ProTier.plus.lifetimeID) ? .plus : nil
    }

    /// 지금 자동 갱신 구독으로 칸을 쓰는가 (평생이 없을 때).
    var subscribedOnly: Bool {
        lifetimeTier == nil && !purchasedProductIDs.isDisjoint(with: ProAccess.subscriptionIDs)
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }
}

// MARK: - 잠금 안내 카드

/// 잠긴 기능 자리에 놓는 카드. 무엇이 열리는지 보여주고 페이월로 잇는다.
struct ProLockedCard: View {
    let feature: ProFeature
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: feature.leeoIcon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 48, height: 48)
                    .background(Theme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Label(feature.tier.name, systemImage: "lock.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                    Text(feature.leeoTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Text(feature.leeoDetail)
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onUnlock) {
                Text(feature.tier == .plus ? LocalizedStringKey("퇴사각 Plus로 열기") : LocalizedStringKey("퇴사각 Pro로 열기"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 그날의 나 미리보기 진입점

/// 대시보드·계산 탭에서 미리보기로 들어가는 줄. Pro 가 아니면 페이월을 연다.
struct FuturePreviewEntry: View {
    @EnvironmentObject private var pro: LeeoStore
    @State private var paywallFeature: ProFeature?
    var compact = false

    private var unlocked: Bool { pro.access.allows(ProFeature.futurePreview.rawValue) }

    var body: some View {
        Group {
            if unlocked {
                NavigationLink { FuturePreviewView() } label: { label }
            } else {
                Button {
                    AppUsage.log(.paywallShown)
                    paywallFeature = .futurePreview
                } label: { label }
            }
        }
        .buttonStyle(.plain)
        .proPaywall($paywallFeature)
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: unlocked ? "sunrise.fill" : "lock.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("그날의 나 미리보기")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("건보료·연금·세금까지 넣은 퇴사 후의 삶")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(EntryBackground(compact: compact))
    }
}

private struct EntryBackground: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content } else { content.cardStyle() }
    }
}

// MARK: - 페이월 띄우기

extension View {
    /// `feature` 에 값이 들어오면 그 기능을 앞세운 페이월을 시트로 띄운다.
    func proPaywall(_ feature: Binding<ProFeature?>) -> some View {
        modifier(ProPaywallPresenter(feature: feature))
    }

    /// 앱 전체에 한 번: 이미 산 분께 드리는 안내, 구독 졸업 제안, 위젯의 'Pro로 열기'.
    func proMoments() -> some View {
        modifier(ProMoments())
    }
}

private struct ProPaywallPresenter: ViewModifier {
    @Binding var feature: ProFeature?
    @EnvironmentObject private var store: LeeoStore

    func body(content: Content) -> some View {
        content.sheet(item: $feature) { f in
            ProPaywallView(lead: f)
                .environmentObject(store)
        }
    }
}

/// 위젯이 여는 주소. 잠긴 위젯을 누르면 이것으로 앱이 열린다.
enum ProLink {
    static let widget = URL(string: "firetracker://pro/widget")!
}

private struct ProMoments: ViewModifier {
    @EnvironmentObject private var store: LeeoStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pro.legacyNoticeShown") private var legacyNoticeShown = false
    @State private var legacyNotice = false
    @State private var graduation = false
    @State private var paywallFeature: ProFeature?

    func body(content: Content) -> some View {
        content
            .task { await ProAccess.loadProducts(store) }
            // 앱값을 내신 분께 한 번 — 무료로 바뀌어도 잃는 것이 없다고 알린다.
            .onChange(of: store.isGrandfathered, initial: true) { _, legacy in
                if legacy, !legacyNoticeShown {
                    legacyNoticeShown = true
                    legacyNotice = true
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await offerGraduationIfDue() } }
            }
            .onOpenURL { url in
                if url == ProLink.widget, !store.access.allows(ProFeature.widget.rawValue) {
                    AppUsage.log(.paywallShown)
                    paywallFeature = .widget
                }
            }
            .alert("이미 퇴사각 Pro예요", isPresented: $legacyNotice) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("퇴사각을 먼저 사 주셔서 고마워요. Plus와 Pro의 모든 기능을 추가 결제 없이 평생 쓰세요.")
            }
            .sheet(isPresented: $graduation) {
                LeeoGraduationOfferView(graduate: store.product(ProAccess.graduateID)) {
                    await store.refreshEntitlements()
                }
                .leeoStyle(ProAccess.style)
                .onAppear { LeeoGraduation.markOffered() }
            }
            .proPaywall($paywallFeature)
    }

    /// 연 구독 6개월째 · 갱신 7일 전에 한 번씩 졸업가를 보인다.
    private func offerGraduationIfDue() async {
        guard !legacyNotice, paywallFeature == nil,
              store.lifetimeTier == nil,
              store.product(ProAccess.graduateID) != nil,
              let sub = await LeeoGraduation.currentSubscription(among: ProAccess.yearlyIDs),
              LeeoGraduation.isDue(sub, lastOffered: LeeoGraduation.lastOffered())
        else { return }
        graduation = true
    }
}

extension ProAccess {
    /// LeeoKit 부품(졸업 제안 등)을 앱 색으로.
    static var style: LeeoStyle {
        LeeoStyle(accent: Theme.accentText, bg: Theme.bg, surface: Theme.surface, surfaceAlt: Theme.surfaceHigh,
                  text: Theme.textPrimary, textMuted: Theme.textSecond)
    }
}
