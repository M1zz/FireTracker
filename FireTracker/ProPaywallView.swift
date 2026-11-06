//
//  ProPaywallView.swift
//  FireTracker
//
//  퇴사각 Plus · Pro 구매 화면 — 세 칸 카드, 고른 칸의 연 · 평생(주 · 월은 펼쳐서), 비교표.
//  결제 코어는 LeeoStore, 화면은 앱 테마로 직접 그린다
//  (LeeoKit 기본 페이월은 작은 글씨를 써서 이 앱의 글자 크기 기준에 맞지 않는다).
//  스토어에서 아직 오지 않은 상품의 줄은 서지 않는다.
//

import SwiftUI
import StoreKit
import LeeoKit

struct ProPaywallView: View {
    /// 방금 부딪힌 기능 — 그 기능을 여는 칸을 먼저 고른다. nil 이면 일반 소개.
    let lead: ProFeature?

    @EnvironmentObject private var store: LeeoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchaseAction

    @State private var tier: ProTier
    @State private var term: ProTerm = .yearly
    @State private var showsShortTerms = false
    @State private var introEligible = false

    init(lead: ProFeature?) {
        self.lead = lead
        _tier = State(initialValue: lead?.tier ?? .plus)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if store.ownedTier == .pro {
                        ownedCard
                    } else {
                        tierCards
                        termSection
                    }
                    comparison
                    footer
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.textSecond)
                    }
                    .accessibilityLabel(Text("닫기"))
                }
            }
            .task { await ProAccess.loadProducts(store) }
            .task(id: tier) {
                introEligible = await store.product(tier.yearlyID)?.subscription?.isEligibleForIntroOffer ?? false
            }
            .onAppear {
                if let owned = store.ownedTier, owned >= tier { tier = .pro }
            }
            .onChange(of: store.ownedTier) { _, owned in
                // 다른 기기 구매·가족 공유·복원으로 필요한 칸이 들어오면 바로 닫는다.
                if let owned, owned >= (lead?.tier ?? .pro) { dismiss() }
            }
        }
    }

    // MARK: 머리

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: lead?.leeoIcon ?? "flame.fill")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 84, height: 84)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)
            Text("퇴사각 Plus · Pro")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(lead.map { String(localized: "\($0.leeoTitle) 기능은 \($0.tier.fullName)에서 열려요.") }
                 ?? String(localized: "내 퇴사 날짜는 무료로. 더 깊이 파고들 도구를 연 구독이나 평생으로 고르세요."))
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: 세 칸

    private var tierCards: some View {
        VStack(spacing: 10) {
            tierCard(name: String(localized: "무료"),
                     tagline: String(localized: "내 자산을 다 넣고 퇴사할 수 있는 날을 보는 것까지 전부 무료."),
                     price: nil, current: store.ownedTier == nil, selected: false, action: nil)
            ForEach(ProTier.allCases) { t in
                let owned = store.ownedTier.map { $0 >= t } ?? false
                tierCard(name: t.fullName, tagline: t.tagline,
                         price: store.product(t.yearlyID).map { String(format: LeeoLadderText.perYearFormat, $0.displayPrice) },
                         current: owned, selected: tier == t && !owned,
                         action: owned ? nil : { withAnimation(.snappy) { tier = t } })
            }
        }
    }

    private func tierCard(name: String, tagline: String, price: String?, current: Bool, selected: Bool,
                          action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : (current ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(selected || current ? Theme.accentText : Theme.textSecond)
                    .opacity(action == nil && !current ? 0 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        if current {
                            Text("지금 쓰는 중")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.positive)
                        } else if let price {
                            Text(price)
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    Text(tagline)
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(action != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 기간 · 결제

    /// Plus 평생을 산 사람은 Pro 평생을 올리기 값으로 산다.
    private var upgrades: Bool { tier == .pro && store.lifetimeTier == .plus }

    private func product(_ t: ProTerm) -> Product? {
        if t == .lifetime, upgrades, let upgrade = store.product(ProAccess.upgradeID) { return upgrade }
        return store.product(t.productID(tier))
    }

    private var shownTerms: [ProTerm] {
        (showsShortTerms ? ProTerm.allCases : [.yearly, .lifetime]).filter { product($0) != nil }
    }

    private var hasShortTerms: Bool { product(.monthly) != nil || product(.weekly) != nil }

    @ViewBuilder
    private var termSection: some View {
        VStack(spacing: 10) {
            if shownTerms.isEmpty {
                if store.isLoadingProducts {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    Button {
                        Task { await ProAccess.loadProducts(store) }
                    } label: {
                        Label("상품 다시 불러오기", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.surfaceHigh)
                            .foregroundStyle(Theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(shownTerms, id: \.self) { t in termRow(t) }
                if hasShortTerms && !showsShortTerms {
                    Button {
                        withAnimation(.snappy) { showsShortTerms = true }
                    } label: {
                        Text("주 · 월 구독도 보기")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                buyButton
            }

            if let error = store.lastError {
                Text(error)
                    .font(.body)
                    .foregroundStyle(Theme.negative)
                    .multilineTextAlignment(.center)
            }
        }
        .onChange(of: tier) { _, _ in
            if product(term) == nil { term = .yearly }
        }
    }

    private func termRow(_ t: ProTerm) -> some View {
        let selected = term == t
        return Button {
            term = t
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accentText : Theme.textSecond)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(termTitle(t))
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let note = termNote(t) {
                        Text(note)
                            .font(.body)
                            .foregroundStyle(Theme.textSecond)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(termPrice(t))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(14)
            .background(selected ? Theme.accentSoft : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func termTitle(_ t: ProTerm) -> String {
        switch t {
        case .yearly:   return LeeoLadderText.yearly
        case .lifetime: return upgrades ? String(localized: "Pro 평생으로 올리기") : LeeoLadderText.lifetime
        case .monthly:  return String(localized: "월 구독")
        case .weekly:   return String(localized: "주 구독")
        }
    }

    private func termPrice(_ t: ProTerm) -> String {
        guard let p = product(t) else { return "" }
        switch t {
        case .yearly:   return String(format: LeeoLadderText.perYearFormat, p.displayPrice)
        case .lifetime: return p.displayPrice
        case .monthly:  return String(localized: "\(p.displayPrice) / 월")
        case .weekly:   return String(localized: "\(p.displayPrice) / 주")
        }
    }

    private func termNote(_ t: ProTerm) -> String? {
        switch t {
        case .yearly:
            guard introEligible, let offer = product(.yearly)?.subscription?.introductoryOffer,
                  offer.paymentMode == .payUpFront || offer.paymentMode == .payAsYouGo else { return nil }
            return String(format: LeeoLadderText.introFormat, offer.displayPrice)
        case .lifetime:
            if upgrades { return String(localized: "Plus 평생을 산 분께만, 차액만 내면 돼요.") }
            guard let yearly = product(.yearly)?.price, yearly > 0, let lifetime = product(.lifetime)?.price else { return nil }
            let years = Int(NSDecimalNumber(decimal: lifetime / yearly).doubleValue.rounded(.down))
            return years >= 2 ? String(format: LeeoLadderText.lifetimeWorthFormat, years) : nil
        case .monthly, .weekly:
            return nil
        }
    }

    private var buyButton: some View {
        let selected = product(term) ?? product(.yearly)
        return Button {
            guard let selected else { return }
            Task {
                let ok = await store.purchase(selected) { try await purchaseAction($0) }
                if ok, let owned = store.ownedTier, owned >= tier {
                    AppUsage.log(.proPurchased)
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if store.purchasingProductID != nil {
                    ProgressView().tint(.black)
                }
                Text("\(tier.fullName) 열기")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selected == nil || store.purchasingProductID != nil)
    }

    private var ownedCard: some View {
        Label("퇴사각 Pro를 쓰고 있어요. 모든 기능이 열려 있어요.", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(Theme.positive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    // MARK: 비교표

    private enum Cell {
        case yes, no, text(String)
    }

    private var rows: [(String, Cell, Cell, Cell)] {
        let unlimited = String(localized: "무제한")
        return [
            (String(localized: "자산 기록"), .text(unlimited), .text(unlimited), .text(unlimited)),
            (String(localized: "대시보드 · 여정 · 달성 시점"), .yes, .yes, .yes),
            (String(localized: "생애주기 · 대출 · 예적금 계산기"), .yes, .yes, .yes),
            (String(localized: "백업 · 복원 · 앱 잠금"), .yes, .yes, .yes),
            (String(localized: "계산 저장"), .text(String(localized: "\(ProFeature.freeSaveLimit)개")), .text(unlimited), .text(unlimited)),
            (String(localized: "투자 예측 · 빚 vs 투자"), .no, .yes, .yes),
            (String(localized: "월급 구매력 · 돈과 시간"), .no, .yes, .yes),
            (String(localized: "매매 원장"), .no, .yes, .yes),
            (String(localized: "그날의 나 미리보기"), .no, .no, .yes),
            (String(localized: "분기 리포트"), .no, .no, .yes),
            (String(localized: "iCloud 동기화"), .no, .no, .yes),
            (String(localized: "스크린샷으로 한 번에 추가"), .no, .no, .yes),
            (String(localized: "위젯"), .no, .no, .yes),
        ]
    }

    private var comparison: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
            GridRow {
                Text("한눈에 비교")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                columnHead(String(localized: "무료"))
                columnHead(ProTier.plus.name)
                columnHead(ProTier.pro.name)
            }
            Divider()
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                GridRow {
                    Text(r.0)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    cell(r.1)
                    cell(r.2)
                    cell(r.3)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func columnHead(_ s: String) -> some View {
        Text(s)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.textSecond)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: 52)
            .gridColumnAlignment(.center)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cell(_ c: Cell) -> some View {
        switch c {
        case .yes:
            Image(systemName: "checkmark")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.positive)
                .accessibilityLabel(Text("포함"))
        case .no:
            Text(verbatim: "–")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .accessibilityLabel(Text("없음"))
        case .text(let s):
            Text(s)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: 아래 — 복원 · 약관 · 방침

    private var footer: some View {
        VStack(spacing: 14) {
            if store.ownedTier != .pro {
                Button {
                    Task { await store.restore() }
                } label: {
                    if store.isRestoring {
                        ProgressView()
                    } else {
                        Text("구매 복원")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                }
                .disabled(store.isRestoring)
                Text("구독은 기간이 끝나기 24시간 전까지 해지하지 않으면 같은 값으로 자동 갱신되고, App Store 계정으로 청구돼요. 구독 관리에서 언제든 해지할 수 있어요.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 20) {
                Link(destination: ProAccess.termsURL) {
                    Text("이용약관")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .underline()
                }
                Link(destination: FireTrackerSpec.legal.privacyURL) {
                    Text("개인정보처리방침")
                        .font(.body)
                        .foregroundStyle(Theme.textSecond)
                        .underline()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
