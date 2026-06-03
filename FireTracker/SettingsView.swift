import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    @State private var annualExpense: String = ""
    @State private var swr: Double = 0.04
    @State private var expectedReturn: Double = 0.05

    // Projection (올해 말 예측)
    @State private var monthlyTakeHome: String = ""
    @State private var plannedExpense: String = ""

    // Live-pricing API credentials
    @State private var finnhubKey: String = ""
    @State private var kisAppKey: String = ""
    @State private var kisAppSecret: String = ""
    @State private var dataGoKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("연간 목표 지출")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 6) {
                            TextField("36,000,000", text: $annualExpense.commaGrouped)
                                .keyboardType(.numberPad)
                                .font(.system(.body, design: .rounded))
                            Text("원")
                                .foregroundStyle(Theme.textSecond)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .inputBox()
                        if let v = Double(annualExpense), v > 0 {
                            Text("= \(Fmt.krwBoth(v))")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    .padding(.vertical, 4)

                    sliderRow(title: "안전 인출률", value: $swr,
                              range: 0.02...0.06, step: 0.005)
                    sliderRow(title: "예상 연 수익률", value: $expectedReturn,
                              range: 0...0.12, step: 0.005)
                } header: {
                    Text("FIRE 목표")
                } footer: {
                    Text("탭하거나 슬라이더를 움직여 값을 수정하세요. 변경은 자동 저장됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section("계산 결과") {
                    HStack {
                        Text("FIRE 목표 금액")
                        Spacer()
                        Text("\(Fmt.krw((Double(annualExpense) ?? 0) / max(swr, 0.0001)))원")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text("연 지출을 안전 인출률로 나눈 값입니다. 4% 룰 기준이라면 연 지출의 25배.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
                    moneyField(title: "세후 월급", hint: "연봉이면 ÷12", text: $monthlyTakeHome)
                    moneyField(title: "월 지출", hint: "매달 평균 지출", text: $plannedExpense)
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
                    Text("올해 말 예측 (월 저축)")
                } footer: {
                    Text("세후 월급에서 월 지출을 뺀 월 저축으로 올해 말 자산을 예측합니다. 기록 저장 시 이 값이 수입·지출에 자동으로 채워집니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
                    apiField(title: "Finnhub (미국주식)",
                             hint: "finnhub.io 무료 가입 후 API Key",
                             text: $finnhubKey)
                    apiField(title: "한국투자증권 App Key (국내주식)",
                             hint: "KIS Developers에서 발급",
                             text: $kisAppKey)
                    apiField(title: "한국투자증권 App Secret",
                             hint: "App Key와 함께 발급되는 시크릿",
                             text: $kisAppSecret)
                    apiField(title: "공공데이터포털 서비스키 (부동산)",
                             hint: "국토부 아파트 실거래가 · Decoding 키 사용",
                             text: $dataGoKey)
                } header: {
                    Text("자동 시세 API 키")
                } footer: {
                    Text("암호화폐(업비트)와 환율은 키 없이 자동으로 불러옵니다. 위 키는 해당 자산에서 ‘시세 자동’을 켰을 때만 사용됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .navigationTitle("설정")
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .onAppear(perform: load)
            .onChange(of: annualExpense) { persist() }
            .onChange(of: swr) { persist() }
            .onChange(of: expectedReturn) { persist() }
            .onChange(of: finnhubKey) { persist() }
            .onChange(of: kisAppKey) { persist() }
            .onChange(of: kisAppSecret) { persist() }
            .onChange(of: dataGoKey) { persist() }
            .onChange(of: monthlyTakeHome) { persist() }
            .onChange(of: plannedExpense) { persist() }
        }
        .preferredColorScheme(.dark)
    }

    // A labelled numeric input box with the exact amount shown alongside.
    @ViewBuilder
    private func moneyField(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let v = Double(text.wrappedValue), v > 0 {
                    Text("= \(Fmt.won(v))원")
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

    // A labelled slider with the current value shown as an accent pill.
    @ViewBuilder
    private func sliderRow(title: String, value: Binding<Double>,
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

    // A labelled secure entry styled as an obvious input box.
    @ViewBuilder
    private func apiField(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !text.wrappedValue.isEmpty {
                    Label("입력됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                        .font(.caption2)
                }
            }
            HStack(spacing: 6) {
                SecureField(hint, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            .inputBox()
        }
        .padding(.vertical, 4)
    }

    private func load() {
        annualExpense = String(Int(settings.targetAnnualExpense))
        swr = settings.safeWithdrawalRate
        expectedReturn = settings.expectedAnnualReturn
        monthlyTakeHome = settings.monthlyTakeHome > 0 ? String(Int(settings.monthlyTakeHome)) : ""
        plannedExpense = settings.plannedMonthlyExpense > 0 ? String(Int(settings.plannedMonthlyExpense)) : ""
        finnhubKey = settings.finnhubKey
        kisAppKey = settings.kisAppKey
        kisAppSecret = settings.kisAppSecret
        dataGoKey = settings.dataGoKey
    }

    private func persist() {
        // Materialize the settings row on first edit so keys survive relaunch.
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
        target.monthlyTakeHome = Double(monthlyTakeHome) ?? 0
        target.plannedMonthlyExpense = Double(plannedExpense) ?? 0
        target.finnhubKey = finnhubKey
        target.kisAppKey = kisAppKey
        target.kisAppSecret = kisAppSecret
        target.dataGoKey = dataGoKey
        try? context.save()
    }
}
