//
//  ProPaywallView.swift
//  FireTracker
//
//  퇴사각 프로 구매 화면. 결제 코어는 LeeoStore, 화면은 앱 테마로 직접 그린다
//  (LeeoKit 기본 페이월은 작은 글씨를 써서 이 앱의 글자 크기 기준에 맞지 않는다).
//

import SwiftUI
import StoreKit
import LeeoKit

struct ProPaywallView: View {
    /// 방금 부딪힌 기능 — 맨 위에 앞세운다. nil 이면 일반 소개.
    let lead: ProFeature?

    @EnvironmentObject private var store: LeeoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchaseAction

    /// 혜택 목록 — 방금 부딪힌 기능을 맨 앞에.
    private var benefits: [ProFeature] {
        guard let lead else { return ProFeature.allCases }
        return [lead] + ProFeature.allCases.filter { $0 != lead }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if store.hasPro {
                        ownedCard
                    } else {
                        benefitList
                        purchaseSection
                    }
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
            .task { await store.loadProducts() }
            .onChange(of: store.hasPro) { _, owned in
                // 다른 기기 구매·가족 공유·복원으로 권한이 들어오면 바로 닫는다.
                if owned { dismiss() }
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
            Text("퇴사각 프로")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(lead.map { String(localized: "\($0.leeoTitle) 기능은 프로에서 열려요.") }
                 ?? String(localized: "퇴사 날짜를 더 깊이 계산하는 도구를 엽니다."))
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: 혜택

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(benefits) { f in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: f.leeoIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.leeoTitle)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(f.leeoDetail)
                            .font(.body)
                            .foregroundStyle(Theme.textSecond)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Label("자산 기록, 여정, 대시보드, 생애주기 계산, 백업은 계속 무료예요.", systemImage: "checkmark.seal")
                .font(.body)
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 구매

    @ViewBuilder
    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if let product = store.products.first {
                Button {
                    Task {
                        let ok = await store.purchase(product) { try await purchaseAction($0) }
                        if ok {
                            AppUsage.log(.proPurchased)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if store.purchasingProductID == product.id {
                            ProgressView().tint(.black)
                        }
                        Text("\(product.displayPrice) · 한 번 결제로 평생")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accent)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.purchasingProductID != nil)

                Text("구독이 아니에요. 다시 결제할 일이 없어요.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
            } else if store.isLoadingProducts {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                Button {
                    Task { await store.loadProducts() }
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

            if let error = store.lastError {
                Text(error)
                    .font(.body)
                    .foregroundStyle(Theme.negative)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var ownedCard: some View {
        Label("퇴사각 프로를 쓰고 있어요. 모든 기능이 열려 있어요.", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(Theme.positive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    // MARK: 아래 — 복원 · 방침

    private var footer: some View {
        VStack(spacing: 14) {
            if !store.hasPro {
                Button {
                    Task {
                        await store.restore()
                        if store.hasPro { dismiss() }
                    }
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
            }
            Link(destination: FireTrackerSpec.legal.privacyURL) {
                Text("개인정보처리방침")
                    .font(.body)
                    .foregroundStyle(Theme.textSecond)
                    .underline()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
