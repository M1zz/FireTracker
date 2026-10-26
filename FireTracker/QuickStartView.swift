//
//  QuickStartView.swift
//  FireTracker
//
//  30초 시작 — 질문 네 개로 "언제 그만둘 수 있나"를 바로 보여 준다.
//
//  예전 첫 화면은 "자산을 하나씩 등록하세요"였다. 그러면 답(퇴사일)을 보기 전에
//  주식·예금·부동산을 다 적어야 했고, 목표는 기본값(월 300만 원)이라 처음 보는
//  숫자가 내 것이 아니었다. 앱 이름이 약속하는 답을 먼저 주고, 자세히 적는 건 그다음.
//

import SwiftUI
import SwiftData

struct QuickStartView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [FireSettings]
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @AppStorage("appLockEnabled") private var lockEnabled = false

    @State private var monthlyLiving = ""
    @State private var age = ""
    @State private var retireAge = ""
    @State private var netWorth = ""
    @State private var monthlySaving = ""
    @State private var result: FireOutlook?
    @State private var reminderOn = MonthlyReminder.isEnabled

    /// 이미 자산을 적어 둔 사람에겐 순자산을 다시 묻지 않는다 — 적어 둔 게 정답이다.
    private var asksNetWorth: Bool { assets.isEmpty }

    private var canSubmit: Bool {
        (Double(monthlyLiving) ?? 0) > 0 && (Int(age) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    resultView(result)
                } else {
                    form
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .onAppear(perform: prefill)
    }

    // MARK: 질문

    private var form: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("언제 그만둘 수 있을까요?")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("대략적인 숫자면 충분해요. 나중에 언제든 고칠 수 있어요.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                moneyField(String(localized: "은퇴 후 한 달 생활비"), hint: "3,000,000", text: $monthlyLiving)
            } footer: {
                Text("일을 그만둔 뒤 매달 쓰고 싶은 돈이에요. 지금 생활비를 떠올리면 쉬워요.")
            }

            Section {
                ageField(String(localized: "지금 나이"), text: $age)
                ageField(String(localized: "그만두고 싶은 나이 (선택)"), text: $retireAge)
            }

            Section {
                if asksNetWorth {
                    moneyField(String(localized: "지금 순자산 (대략)"), hint: "50,000,000", text: $netWorth)
                }
                moneyField(String(localized: "매달 모으는 돈"), hint: "1,500,000", text: $monthlySaving)
            } footer: {
                Text(asksNetWorth
                     ? "순자산은 예금·주식·집 같은 자산에서 빚을 뺀 금액이에요. 매달 모으는 돈은 월급에서 생활비를 쓰고 남는 돈이에요."
                     : "순자산은 자산 탭에 적어 둔 값을 그대로 써요. 매달 모으는 돈은 월급에서 생활비를 쓰고 남는 돈이에요.")
            }

            Section {
                Button(action: submit) {
                    Text("내 퇴사일 보기")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Color.black)
                .disabled(!canSubmit)
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .keyboardDismissable()
    }

    // MARK: 결과

    private func resultView(_ o: FireOutlook) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "flame.fill")
                        .font(.system(.largeTitle))
                        .foregroundStyle(Theme.accent)
                    Text("지금 속도라면")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                    if let date = o.date {
                        Text(Self.monthText(date))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(o.ageAtFire.map { "\(Fmt.years(o.years)) 뒤, \($0)세에 그만둘 수 있어요" }
                             ?? "\(Fmt.years(o.years)) 뒤에 그만둘 수 있어요")
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.center)
                        if let gap = retireGapText(o) {
                            Text(gap)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecond)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        Text("아직 닿지 않아요")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("지금 모으는 속도로는 80년 안에 목표에 닿지 않아요. 매달 모으는 돈을 늘리거나 생활비 목표를 줄여 보세요.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecond)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    row(String(localized: "목표 금액"), String(localized: "\(Fmt.krw(o.fireNumber))원"))
                    row(String(localized: "지금 순자산"), String(localized: "\(Fmt.krw(o.netWorth))원"))
                    row(String(localized: "매달 모으는 돈"), String(localized: "\(Fmt.krw(o.monthlySavings))원"))
                    Text("목표 금액은 한 해 생활비를 \(Fmt.percent(settingsList.first?.safeWithdrawalRate ?? 0.04, fraction: 1))로 나눈 값이에요(해마다 이만큼 꺼내 써도 원금이 오래 버티는 수준). 모은 돈은 연 \(Fmt.percent(o.annualReturn, fraction: 0))로 불어난다고 가정했어요. 여정 탭 ‘내 목표’에서 바꿀 수 있어요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
                .cardStyle()

                VStack(spacing: 10) {
                    if !reminderOn {
                        Button {
                            Task {
                                let summary = o.summary(goalConfigured: true, locked: lockEnabled)
                                reminderOn = await MonthlyReminder.enable(summary: summary)
                            }
                        } label: {
                            Label("매달 1일에 퇴사각 알려 주기", systemImage: "bell.badge")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.surfaceHigh)
                                .foregroundStyle(Theme.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    } else {
                        Label("매달 1일에 알려 드릴게요", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.positive)
                    }

                    Button {
                        AppRouter.shared.selectedTab = AppRouter.Tab.assets
                        dismiss()
                    } label: {
                        Text("자산을 하나씩 적어 더 정확하게")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent)
                            .foregroundStyle(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button("대시보드에서 보기") { dismiss() }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecond)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ title: String, _ value: String) -> some View {
        AdaptiveRow {
            Text(title).font(.subheadline).foregroundStyle(Theme.textSecond)
        } trailing: {
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func retireGapText(_ o: FireOutlook) -> String? {
        guard let target = Int(retireAge), target > 0, let at = o.ageAtFire else { return nil }
        if at < target { return String(localized: "원하던 \(target)세보다 \(target - at)년 빨라요") }
        if at > target { return String(localized: "원하던 \(target)세보다 \(at - target)년 늦어요") }
        return String(localized: "원하던 \(target)세에 딱 맞아요")
    }

    static func monthText(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return f.string(from: date)
    }

    // MARK: 읽기 · 쓰기

    /// 이미 넣어 둔 값이 있으면 채워서 연다(다시 계산하러 온 사람).
    private func prefill() {
        guard let s = settingsList.first, s.goalConfigured else { return }
        monthlyLiving = String(Int(s.targetAnnualExpense / 12))
        if s.currentAge > 0 { age = String(s.currentAge) }
        if s.targetRetireAge > 0 { retireAge = String(s.targetRetireAge) }
        if s.plannedMonthlySavings > 0 { monthlySaving = String(Int(s.plannedMonthlySavings)) }
    }

    private func submit() {
        let settings: FireSettings
        if let existing = settingsList.first {
            settings = existing
        } else {
            settings = FireSettings()
            context.insert(settings)
        }
        settings.targetAnnualExpense = (Double(monthlyLiving) ?? 0) * 12
        settings.currentAge = Int(age) ?? 0
        let target = Int(retireAge) ?? 0
        settings.targetRetireAge = target > settings.currentAge ? target : 0
        settings.plannedNetSavings = Double(monthlySaving) ?? 0

        // 자산이 하나도 없으면 대략적인 순자산을 한 줄로 넣어 둔다. 자산 탭에서
        // 종류별로 나눠 적으면 이 줄을 지우면 된다(이름이 그렇게 말한다).
        var catalogNet = assets.reduce(0) { $0 + $1.netValue }
        if asksNetWorth, let nw = Double(netWorth), nw > 0 {
            context.insert(Asset(name: String(localized: "대략적인 순자산 (나눠 적으면 지우세요)"),
                                 assetClass: .other, amount: nw))
            catalogNet = nw
            AppUsage.log(.assetAdded)
        }
        guard context.saveReporting(String(localized: "목표")) else { return }
        FireSettings.markGoalConfigured()

        withAnimation { result = FireOutlook(netWorth: catalogNet, settings: settings) }
    }

    private func moneyField(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let v = Double(text.wrappedValue), v > 0 {
                    Text("= \(Fmt.wonKo(v))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            HStack(spacing: 6) {
                TextField(hint, text: text.commaGrouped)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .rounded))
                Text("원").foregroundStyle(Theme.textSecond)
            }
            .inputBox()
        }
        .padding(.vertical, 2)
    }

    private func ageField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded))
                .frame(maxWidth: 60)
            Text("세").foregroundStyle(Theme.textSecond)
        }
    }
}
