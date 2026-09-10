//
//  GoalSettingsView.swift
//  FireTracker
//
//  내 목표 — 언제 얼마를 들고 그만둘 것인가.
//
//  예전엔 설정 탭에 있었다. 하지만 이 네 가지(목표 지출·인출률·나이, 월 저축,
//  수입/지출, 패시브 인컴 목표)는 환경설정이 아니라 앱의 핵심 입력이다.
//  여정 탭의 목표 카드 전부가 이 값에 기대는데 값은 가장 안 들어가는 탭에 있어서,
//  결과 화면마다 "설정에서 넣어주세요"를 안내해야 했다. 결과 옆으로 옮겼다.
//

import SwiftUI
import SwiftData

struct GoalSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]

    // FIRE 목표
    @State private var annualExpense: String = ""
    @State private var swr: Double = 0.04
    @State private var expectedReturn: Double = 0.05

    // 목표 측정 기준 & 은퇴 시점
    @State private var goalType: FireGoalType = .both
    @State private var currentAge: String = ""
    @State private var retireAge: String = ""

    // 올해 말 예측
    @State private var netSavingsPlan: String = ""
    @State private var monthlyTakeHome: String = ""
    @State private var plannedExpense: String = ""

    // 목표 패시브 인컴
    @State private var annualDividend: String = ""

    // load()가 @State를 채우면 onChange→persist가 연쇄로 불린다. 로딩 중엔 저장을 막는다.
    @State private var isLoading = false

    // 같은 연간 목표를 월 단위로 보여주는 양방향 다리
    // (월 입력 → 연간 = 월×12, 연간 입력 → 월 = 연간÷12).
    private var monthlyExpenseBinding: Binding<String> {
        Binding(
            get: {
                let annual = Double(annualExpense) ?? 0
                return annual > 0 ? String(Int((annual / 12).rounded())) : ""
            },
            set: { newValue in
                let monthly = Double(newValue.filter(\.isNumber)) ?? 0
                annualExpense = monthly > 0 ? String(Int(monthly * 12)) : ""
            }
        )
    }

    var body: some View {
        Form {
            goalSection
            netSavingsSection
            incomeExpenseSection
            passiveIncomeSection
        }
        .navigationTitle("내 목표")
        .navigationBarTitleDisplayMode(.inline)
        .scrollIndicators(.hidden)
        .keyboardDismissable()
        .onAppear(perform: load)
        .onChange(of: annualExpense) { persist() }
        .onChange(of: swr) { persist() }
        .onChange(of: expectedReturn) { persist() }
        .onChange(of: netSavingsPlan) { persist() }
        .onChange(of: monthlyTakeHome) { persist() }
        .onChange(of: plannedExpense) { persist() }
        .onChange(of: annualDividend) { persist() }
        .onChange(of: goalType) { persist() }
        .onChange(of: currentAge) { persist() }
        .onChange(of: retireAge) { persist() }
    }

    // MARK: 목표

    private var goalSection: some View {
        Section {
            goalMoneyRow(title: "월간 목표 지출", placeholder: "3,000,000",
                         text: monthlyExpenseBinding)

            goalSliderRow(title: "안전 인출률", value: $swr,
                          range: 0.02...0.06, step: 0.005)
            goalSliderRow(title: "예상 연 수익률", value: $expectedReturn,
                          range: 0...0.12, step: 0.005)

            // 자동 계산되는 목표 금액 — 같은 자리에서 바로 확인.
            let annualExp = Double(annualExpense) ?? 0
            let target = annualExp / max(swr, 0.0001)
            HStack {
                Text("FIRE 목표 금액")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Fmt.krw(target))원")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            Picker("달성률 기준", selection: $goalType) {
                ForEach(FireGoalType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            goalAgeRow(title: "현재 나이", text: $currentAge)
            goalAgeRow(title: "목표 은퇴 나이", text: $retireAge)
            if let cur = Int(currentAge), let ret = Int(retireAge), ret > cur {
                HStack {
                    Text("은퇴까지")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(ret - cur)년")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("FIRE 목표")
        } footer: {
            Text("월간 목표 지출은 은퇴 후 한 달 생활비예요. 목표 금액 = 연간 지출(월×12) ÷ 안전 인출률. 나이를 넣으면 여정 탭에 기간별 목표가 표시돼요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    @ViewBuilder
    private var netSavingsSection: some View {
        Section {
            goalMoneyField(title: "월 저축 (수입 − 지출)", hint: "차액만 입력", text: $netSavingsPlan)
        } header: {
            Text("올해 말 예측 — 월 저축")
        } footer: {
            Text("매달 얼마를 모으는지(수입 − 지출)를 직접 넣으면 올해 말 자산을 예측합니다. 수입·지출을 따로 관리하려면 아래에 적으세요. 직접 넣은 월 저축이 우선합니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    @ViewBuilder
    private var incomeExpenseSection: some View {
        Section {
            goalMoneyField(title: "세후 월급", hint: "연봉이면 ÷12", text: $monthlyTakeHome)
            goalMoneyField(title: "월 지출", hint: "매달 평균 지출", text: $plannedExpense)
            let income = Double(monthlyTakeHome) ?? 0
            let expense = Double(plannedExpense) ?? 0
            if income > 0 || expense > 0 {
                HStack {
                    Text("월 저축")
                    Spacer()
                    Text("\(Fmt.krw(income - expense))원")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(income - expense >= 0 ? Theme.positive : Theme.negative)
                }
            }
        } header: {
            Text("수입 · 지출 따로 (선택)")
        } footer: {
            Text("세후 월급에서 월 지출을 뺀 값으로 월 저축을 계산해요(위 칸을 비워둔 경우). 기록 저장 시 수입·지출에 자동으로 채워집니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    @ViewBuilder
    private var passiveIncomeSection: some View {
        Section {
            goalMoneyField(title: "목표 연간 패시브 인컴", hint: "예: 12,000,000", text: $annualDividend)
            if let v = Double(annualDividend), v > 0 {
                HStack {
                    Text("월 목표")
                    Spacer()
                    Text("\(Fmt.krw(v / 12))원")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("패시브 인컴 목표")
        } footer: {
            Text("은퇴 후 받고 싶은 ‘목표’ 패시브 인컴(배당·월세·이자 등)이에요. 여정 탭 ‘패시브 인컴 목표 달성률’의 기준이 됩니다. 비워두면 ‘월간 목표 지출’에서 자동으로 계산해요. 지금 실제로 받는 패시브 인컴은 자산 탭에 등록한 배당주·월세 부동산 등에서 자동 합산됩니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    // MARK: 읽기 · 쓰기

    private func load() {
        isLoading = true
        defer { DispatchQueue.main.async { isLoading = false } }
        // @Query는 복원 직후 갱신이 한 박자 늦을 수 있어, 스토어에서 직접 최신값을 읽는다.
        let settings = (try? context.fetch(FetchDescriptor<FireSettings>()))?.first
            ?? settingsList.first ?? FireSettings()
        annualExpense = String(Int(settings.targetAnnualExpense))
        swr = settings.safeWithdrawalRate
        expectedReturn = settings.expectedAnnualReturn
        netSavingsPlan = settings.plannedNetSavings > 0 ? String(Int(settings.plannedNetSavings)) : ""
        monthlyTakeHome = settings.monthlyTakeHome > 0 ? String(Int(settings.monthlyTakeHome)) : ""
        plannedExpense = settings.plannedMonthlyExpense > 0 ? String(Int(settings.plannedMonthlyExpense)) : ""
        annualDividend = settings.manualAnnualDividend > 0 ? String(Int(settings.manualAnnualDividend)) : ""
        goalType = settings.fireGoalType
        currentAge = settings.currentAge > 0 ? String(settings.currentAge) : ""
        retireAge = settings.targetRetireAge > 0 ? String(settings.targetRetireAge) : ""
    }

    private func persist() {
        guard !isLoading else { return }
        let target: FireSettings
        if let existing = settingsList.first {
            target = existing
        } else {
            target = FireSettings()
            context.insert(target)
        }
        target.targetAnnualExpense = Double(annualExpense) ?? 0
        target.safeWithdrawalRate = swr
        target.expectedAnnualReturn = expectedReturn
        target.plannedNetSavings = Double(netSavingsPlan) ?? 0
        target.monthlyTakeHome = Double(monthlyTakeHome) ?? 0
        target.plannedMonthlyExpense = Double(plannedExpense) ?? 0
        target.manualAnnualDividend = Double(annualDividend) ?? 0
        target.fireGoalType = goalType
        target.currentAge = Int(currentAge) ?? 0
        target.targetRetireAge = Int(retireAge) ?? 0
        try? context.save()
    }
}

// MARK: - 입력 행 (목표 화면 전용)

// 라벨 왼쪽, 금액 오른쪽 한 줄.
private func goalMoneyRow(title: String, placeholder: String,
                          text: Binding<String>) -> some View {
    HStack(spacing: 6) {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)
        Spacer()
        TextField(placeholder, text: text.commaGrouped)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .rounded))
            .frame(maxWidth: 150)
        Text("원").foregroundStyle(Theme.textSecond)
    }
}

// 한 줄짜리 나이 행 — 라벨 왼쪽, 입력은 오른쪽 정렬.
private func goalAgeRow(title: String, text: Binding<String>) -> some View {
    HStack(spacing: 6) {
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

// 금액 입력 상자 — 한글 단위 읽기를 옆에 달아 자릿수를 눈으로 확인시킨다.
@ViewBuilder
private func goalMoneyField(title: String, hint: String, text: Binding<String>) -> some View {
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
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(Theme.accent)
        }
        .inputBox()
    }
    .padding(.vertical, 2)
}

// 퍼센트 슬라이더 — 현재 값을 강조 알약으로 함께 보여준다.
@ViewBuilder
private func goalSliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(Fmt.percent(value.wrappedValue, fraction: 1))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.accentSoft)
                .clipShape(Capsule())
        }
        Slider(value: value, in: range, step: step)
            .tint(Theme.accent)
    }
    .padding(.vertical, 4)
}
