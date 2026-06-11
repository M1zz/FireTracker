import SwiftUI
import SwiftData
import LocalAuthentication

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    // Two-way bridge: edits the same annual target, just shown per month
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

    // Biometric app lock (stored in UserDefaults, not synced asset data).
    @AppStorage("appLockEnabled") private var lockEnabled = false

    @State private var annualExpense: String = ""
    @State private var swr: Double = 0.04
    @State private var expectedReturn: Double = 0.05

    // 목표 측정 기준 & 은퇴 시점
    @State private var goalType: FireGoalType = .both
    @State private var currentAge: String = ""
    @State private var retireAge: String = ""

    // Projection (올해 말 예측)
    @State private var netSavingsPlan: String = ""
    @State private var monthlyTakeHome: String = ""
    @State private var plannedExpense: String = ""

    // Rough manual annual dividend / passive income
    @State private var annualDividend: String = ""

    // Live-pricing API credentials (Finnhub은 앱 내장 키 사용 — 입력칸 없음)
    @State private var kisAppKey: String = ""
    @State private var kisAppSecret: String = ""
    @State private var dataGoKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $lockEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("앱 잠금")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(biometryLabel)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    .tint(Theme.accent)
                } header: {
                    Text("보안")
                } footer: {
                    Text("켜면 앱을 열거나 다시 돌아올 때마다 \(biometryName)(또는 기기 암호)로 인증해야 자산이 보입니다. 앱을 전환할 때도 화면이 가려져요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                // 목표 설정 — 한 줄짜리 행들로 깔끔하게. 설명은 푸터 한 줄만.
                Section {
                    compactMoneyRow(title: "월간 목표 지출", placeholder: "3,000,000",
                                    text: monthlyExpenseBinding)

                    sliderRow(title: "안전 인출률", value: $swr,
                              range: 0.02...0.06, step: 0.005)
                    sliderRow(title: "예상 연 수익률", value: $expectedReturn,
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

                    compactAgeRow(title: "현재 나이", text: $currentAge)
                    compactAgeRow(title: "목표 은퇴 나이", text: $retireAge)
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
                    Text("월간 목표 지출은 은퇴 후 한 달 생활비예요. 목표 금액 = 연간 지출(월×12) ÷ 안전 인출률. 나이를 넣으면 대시보드에 기간별 목표가 표시돼요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
                    moneyField(title: "월 저축 (수입 − 지출)", hint: "차액만 입력", text: $netSavingsPlan)
                } header: {
                    Text("올해 말 예측 — 월 저축")
                } footer: {
                    Text("매달 얼마를 모으는지(수입 − 지출)를 직접 넣으면 올해 말 자산을 예측합니다. 수입·지출을 따로 관리하려면 아래에 적으세요. 직접 넣은 월 저축이 우선합니다.")
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
                    Text("수입 · 지출 따로 (선택)")
                } footer: {
                    Text("세후 월급에서 월 지출을 뺀 값으로 월 저축을 계산해요(위 칸을 비워둔 경우). 기록 저장 시 수입·지출에 자동으로 채워집니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
                    moneyField(title: "연간 배당수익 (대략)", hint: "예: 1,200,000", text: $annualDividend)
                    if let v = Double(annualDividend), v > 0 {
                        HStack {
                            Text("월 환산")
                            Spacer()
                            Text("\(Fmt.krw(v / 12))원")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.positive)
                        }
                    }
                } header: {
                    Text("패시브 인컴 (배당 등)")
                } footer: {
                    Text("종목마다 배당을 넣기 번거로우면, 연간 배당 총액을 여기에 대략 입력하세요. 12로 나눈 월 패시브 인컴이 대시보드에 반영되고, 기록을 저장할 때마다 추이로 쌓여 월 인컴이 어떻게 느는지 볼 수 있어요. 종목별로 입력한 배당과는 합산되니 한쪽만 쓰는 걸 권장해요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
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
                    Text("미국 주식(Finnhub)·암호화폐(업비트)·환율은 키 없이 자동으로 불러옵니다. 위 키는 국내 주식·부동산에서 ‘시세 자동’을 켰을 때만 사용됩니다.")
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
            .onChange(of: kisAppKey) { persist() }
            .onChange(of: kisAppSecret) { persist() }
            .onChange(of: dataGoKey) { persist() }
            .onChange(of: netSavingsPlan) { persist() }
            .onChange(of: monthlyTakeHome) { persist() }
            .onChange(of: plannedExpense) { persist() }
            .onChange(of: annualDividend) { persist() }
            .onChange(of: goalType) { persist() }
            .onChange(of: currentAge) { persist() }
            .onChange(of: retireAge) { persist() }
        }
    }

    // 한 줄짜리 금액 행 — 라벨 왼쪽, 입력은 오른쪽 정렬.
    private func compactMoneyRow(title: String, placeholder: String,
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
    private func compactAgeRow(title: String, text: Binding<String>) -> some View {
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

    // A labelled slider with the current value shown as an accent pill, plus an
    // optional one-line explanation of what the value is used for.
    @ViewBuilder
    private func sliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           hint: String = "") -> some View {
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
            if !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
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

    // The biometry available on this device, for accurate labels.
    private var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return ctx.biometryType
    }
    private var biometryName: String {
        switch biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "기기 암호"
        }
    }
    private var biometryLabel: String {
        switch biometryType {
        case .faceID:  return "Face ID로 자산 정보를 보호합니다"
        case .touchID: return "Touch ID로 자산 정보를 보호합니다"
        default:       return "기기 암호로 자산 정보를 보호합니다"
        }
    }

    private func load() {
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
        target.plannedNetSavings = Double(netSavingsPlan) ?? 0
        target.monthlyTakeHome = Double(monthlyTakeHome) ?? 0
        target.plannedMonthlyExpense = Double(plannedExpense) ?? 0
        target.manualAnnualDividend = Double(annualDividend) ?? 0
        target.fireGoalType = goalType
        target.currentAge = Int(currentAge) ?? 0
        target.targetRetireAge = Int(retireAge) ?? 0
        target.kisAppKey = kisAppKey
        target.kisAppSecret = kisAppSecret
        target.dataGoKey = dataGoKey
        try? context.save()
    }
}
