import SwiftUI
import SwiftData
import LocalAuthentication

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    // Biometric app lock (stored in UserDefaults, not synced asset data).
    @AppStorage("appLockEnabled") private var lockEnabled = false

    @State private var annualExpense: String = ""
    @State private var swr: Double = 0.04
    @State private var expectedReturn: Double = 0.05

    // Projection (올해 말 예측)
    @State private var monthlyTakeHome: String = ""
    @State private var plannedExpense: String = ""

    // Rough manual annual dividend / passive income
    @State private var annualDividend: String = ""

    // Live-pricing API credentials
    @State private var finnhubKey: String = ""
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

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("연간 목표 지출")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("은퇴 후 1년 동안 쓸 생활비예요 (수입이 아닙니다)")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
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
                              range: 0.02...0.06, step: 0.005,
                              hint: "모은 자산을 매년 이만큼씩 꺼내 써도 평생 안 마른다고 보는 비율. 보통 4%(30년+ 기준). 낮출수록 더 안전하지만 목표 금액이 커져요.")
                    sliderRow(title: "예상 연 수익률", value: $expectedReturn,
                              range: 0...0.12, step: 0.005,
                              hint: "투자 자산이 매년 이만큼 불어난다고 가정하는 값. ‘예상 달성 시점’ 계산에 쓰여요.")
                } header: {
                    Text("FIRE 목표")
                } footer: {
                    Text("은퇴 후 매년 쓸 생활비(지출)를 넣으면 목표 자산을 역산합니다 — 목표 자산 = 연간 목표 지출 ÷ 안전 인출률 (4% 룰이면 연 지출의 25배). 매달 버는 수입은 ‘올해 말 예측’의 세후 월급 칸에 넣어요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
                    let annualExp = Double(annualExpense) ?? 0
                    let target = annualExp / max(swr, 0.0001)
                    HStack {
                        Text("FIRE 목표 금액")
                        Spacer()
                        Text("\(Fmt.krw(target))원")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if target > 0 {
                        Text("이만큼 모으면, 다 쓰지 않고도 매달 \(Fmt.krw(annualExp / 12))원(연 \(Fmt.krw(annualExp))원)을 평생 꺼내 쓸 수 있어요.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                } header: {
                    Text("계산 결과")
                } footer: {
                    Text("목표 금액은 위 ‘연간 목표 지출 ÷ 안전 인출률’로 자동 계산돼요(직접 수정 불가). 금액을 바꾸려면 목표 지출이나 인출률을 조절하세요. 예) 매달 300만원 쓰려면 연 3,600만 ÷ 4% = 9억.")
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
                    Text("종목마다 배당을 넣기 번거로우면, 연간 배당 총액을 여기에 대략 입력하세요. 12로 나눈 월 수입이 대시보드에 반영되고, 기록을 저장할 때마다 추이로 쌓여 월 인컴이 어떻게 느는지 볼 수 있어요. 종목별로 입력한 배당과는 합산되니 한쪽만 쓰는 걸 권장해요.")
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
            .onChange(of: annualDividend) { persist() }
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
        monthlyTakeHome = settings.monthlyTakeHome > 0 ? String(Int(settings.monthlyTakeHome)) : ""
        plannedExpense = settings.plannedMonthlyExpense > 0 ? String(Int(settings.plannedMonthlyExpense)) : ""
        annualDividend = settings.manualAnnualDividend > 0 ? String(Int(settings.manualAnnualDividend)) : ""
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
        target.manualAnnualDividend = Double(annualDividend) ?? 0
        target.finnhubKey = finnhubKey
        target.kisAppKey = kisAppKey
        target.kisAppSecret = kisAppSecret
        target.dataGoKey = dataGoKey
        try? context.save()
    }
}
