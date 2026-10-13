//
//  ProAccess.swift
//  FireTracker
//
//  부분 유료화 — 퇴사각 프로 (1회 구매, 평생).
//
//  원칙: "언제 퇴사할 수 있나"라는 앱의 질문에 답하는 데 필요한 것은 전부 무료다.
//  자산 기록·여정·대시보드·생애주기 계산·백업·앱 잠금은 잠그지 않는다. 자산 개수도
//  제한하지 않는다 — 자산을 다 못 넣으면 답 자체가 틀려지기 때문이다.
//  프로는 그 답을 더 깊이 파고드는 도구다: 더 정교한 계산기, 계산 무제한 저장,
//  매매 원장, 스크린샷 일괄 입력.
//
//  결제 코어(상품 로드·구매·복원·권한 캐시)는 LeeoKit 의 LeeoStore 가 맡고,
//  여기서는 "무엇을 잠그나"와 "기존 사용자 보호"만 정한다.
//

import SwiftUI
import StoreKit
import LeeoKit

// MARK: - 프로 기능

/// 프로로 열리는 기능. rawValue 는 LeeoGatePolicy 의 기능 키다.
enum ProFeature: String, CaseIterable, Identifiable, LeeoProFeature {
    case investForecast   = "calc.invest"
    case debtVsInvest     = "calc.debtVsInvest"
    case purchasingPower  = "calc.wage"
    case timeValue        = "calc.time"
    case unlimitedSaves   = "calc.saved"
    case tradeLedger      = "assets.tradeLedger"
    case screenshotImport = "assets.screenshotImport"

    var id: String { rawValue }

    var leeoTitle: String {
        switch self {
        case .investForecast:   return String(localized: "투자 예측")
        case .debtVsInvest:     return String(localized: "빚 갚기 vs 투자하기")
        case .purchasingPower:  return String(localized: "월급 구매력")
        case .timeValue:        return String(localized: "돈과 시간")
        case .unlimitedSaves:   return String(localized: "계산 무제한 저장")
        case .tradeLedger:      return String(localized: "매매 원장")
        case .screenshotImport: return String(localized: "스크린샷으로 한 번에 추가")
        }
    }

    var leeoDetail: String {
        switch self {
        case .investForecast:
            return String(localized: "지금 자산이 앞으로 어디까지 갈지 좋을 때와 나쁠 때의 범위로 보여줘요.")
        case .debtVsInvest:
            return String(localized: "같은 돈으로 빚을 갚을지 투자할지, 어느 쪽이 퇴사를 앞당기는지 비교해요.")
        case .purchasingPower:
            return String(localized: "지난 월급을 물가로 나눠 내 실질 구매력이 늘었는지 알려줘요.")
        case .timeValue:
            return String(localized: "내 시급으로 돈을 시간으로 바꿔 보고, 저축이 시급을 넘는 시점을 찾아요.")
        case .unlimitedSaves:
            return String(localized: "무료로는 3개까지 저장할 수 있어요. 프로는 제한 없이 저장해요.")
        case .tradeLedger:
            return String(localized: "언제 몇 주를 얼마에 샀는지 남기면 평단과 실현 손익이 자동으로 계산돼요.")
        case .screenshotImport:
            return String(localized: "증권사 앱 화면을 캡처하면 종목과 평가액을 한 번에 불러와요.")
        }
    }

    var leeoIcon: String {
        switch self {
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

    /// 계약(FireTrackerSpec)에 선언하는 게이트 정책.
    static var gatePolicy: LeeoGatePolicy {
        LeeoGatePolicy(
            freeLimits: [ProFeature.unlimitedSaves.rawValue: freeSaveLimit],
            proOnly: Set(allCases.filter { $0 != .unlimitedSaves }.map(\.rawValue)),
            warnWhenRemaining: 1
        )
    }
}

// MARK: - 스토어 구성

@MainActor
enum ProAccess {
    /// 판매 상품 — 비소모성 1회 구매.
    static let productID = "com.devkoan.FireTracker.pro"

    /// 유료화 전 마지막 빌드 번호(CFBundleVersion). 이 빌드 이하로 처음 내려받은
    /// 사람은 원래 무료로 쓰던 기능을 그대로 쓴다(그랜드파더링).
    /// 유료화가 들어간 첫 출시 빌드는 반드시 이 값보다 커야 한다.
    static let lastFreeBuild = 5

    /// 개발자 모드에서 권한을 강제하는 키. "unlock" / "lock" / 없음(정상 판정).
    static let overrideKey = "dev.proOverride"

    static func makeStore() -> LeeoStore {
        LeeoStore(
            config: FireTrackerSpec.paywall ?? LeeoPaywallConfig(productIDs: [productID]),
            unlockOverride: { override },
            grandfather: { await isLegacyInstall() }
        )
    }

    static var override: Bool? {
        switch UserDefaults.standard.string(forKey: overrideKey) {
        case "unlock": return true
        case "lock":   return false
        default:       return nil
        }
    }

    /// 유료화 전에 받은 설치인지. App Store 영수증(AppTransaction)의 최초 구매 빌드로 판단한다.
    /// iOS 에서 originalAppVersion 은 CFBundleVersion(빌드 번호)이다.
    /// 샌드박스·TestFlight·Xcode 에서는 이 값이 늘 "1.0" 이라 모두 기존 사용자로 잡히므로
    /// 실제 App Store 설치에서만 판정한다 — 그래야 테스트 때 페이월이 보인다.
    static func isLegacyInstall() async -> Bool {
        guard let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result,
              transaction.environment == .production,
              let build = Double(transaction.originalAppVersion)
        else { return false }
        return build <= Double(lastFreeBuild)
    }
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
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .background(Theme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Label("프로", systemImage: "lock.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
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
                Text("퇴사각 프로로 열기")
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

// MARK: - 페이월 띄우기

extension View {
    /// `feature` 에 값이 들어오면 그 기능을 앞세운 페이월을 시트로 띄운다.
    func proPaywall(_ feature: Binding<ProFeature?>) -> some View {
        modifier(ProPaywallPresenter(feature: feature))
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
