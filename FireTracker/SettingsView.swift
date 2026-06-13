import SwiftUI
import SwiftData
import LocalAuthentication
import UniformTypeIdentifiers

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

    // 금액 표기 모드 — 끄면 억/만 단위(기본), 켜면 숫자(콤마)만.
    @AppStorage("amountNumbersOnly") private var amountNumbersOnly = false

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

    // 데이터 백업 · 복원
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var showImporter = false
    @State private var pendingRestoreURL: URL?
    @State private var showRestoreConfirm = false
    @State private var resultMessage: String?
    @State private var showResultAlert = false
    // load() 중에는 onChange→persist 연쇄 저장을 막는 가드.
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            displaySection
            securitySection
            goalSection
            netSavingsSection
            incomeExpenseSection
            passiveIncomeSection
            apiSection
            backupSection
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
        .modifier(BackupRestoreModifiers(
            showShareSheet: $showShareSheet,
            shareURL: shareURL,
            showImporter: $showImporter,
            showRestoreConfirm: $showRestoreConfirm,
            showResultAlert: $showResultAlert,
            resultMessage: resultMessage,
            onImport: { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        pendingRestoreURL = url
                        showRestoreConfirm = true
                    }
                case .failure(let error):
                    show(message: "파일을 열지 못했어요: \(error.localizedDescription)")
                }
            },
            onRestore: { performRestore() },
            onCancelRestore: { pendingRestoreURL = nil }
        ))
    }

    @ViewBuilder
    private var displaySection: some View {
        Section {
            Toggle(isOn: $amountNumbersOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("금액을 숫자로만 표시")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(amountNumbersOnly ? "예: 600,000,000원" : "예: 6억원 (억·만 단위)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .tint(Theme.accent)
        } header: {
            Text("표시")
        } footer: {
            Text("끄면 ‘6억원’처럼 억·만 단위로, 켜면 ‘600,000,000원’처럼 숫자로만 표시합니다. 앱 전체에 적용돼요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    @ViewBuilder
    private var securitySection: some View {
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
    }

    // MARK: - 목표·예측 섹션 (타입 체크 부담을 줄이려 분리)

    // 목표 설정 — 한 줄짜리 행들로 깔끔하게. 설명은 푸터 한 줄만.
    @ViewBuilder
    private var goalSection: some View {
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
    }

    @ViewBuilder
    private var netSavingsSection: some View {
        Section {
            moneyField(title: "월 저축 (수입 − 지출)", hint: "차액만 입력", text: $netSavingsPlan)
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
    }

    @ViewBuilder
    private var passiveIncomeSection: some View {
        Section {
            moneyField(title: "목표 연간 패시브 인컴", hint: "예: 12,000,000", text: $annualDividend)
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
            Text("은퇴 후 받고 싶은 ‘목표’ 패시브 인컴(배당·월세·이자 등)이에요. 대시보드 ‘패시브 인컴 목표 달성률’의 기준이 됩니다. 비워두면 ‘월간 목표 지출’에서 자동으로 계산해요. 지금 실제로 받는 패시브 인컴은 자산 탭에 등록한 배당주·월세 부동산 등에서 자동 합산됩니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    @ViewBuilder
    private var apiSection: some View {
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

    // MARK: - 백업 · 복원 UI

    @ViewBuilder
    private var backupSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label("백업 파일 내보내기", systemImage: "square.and.arrow.up")
                    .foregroundStyle(Theme.accent)
            }

            Button {
                showImporter = true
            } label: {
                Label("백업 파일에서 복원", systemImage: "square.and.arrow.down")
                    .foregroundStyle(Theme.accent)
            }

            NavigationLink {
                AutoBackupListView(onRestore: { url in
                    pendingRestoreURL = url
                    showRestoreConfirm = true
                })
            } label: {
                Label("자동 백업에서 복원", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.textPrimary)
            }
        } header: {
            Text("데이터 백업 · 복원")
        } footer: {
            Text("‘내보내기’로 만든 백업 파일을 파일 앱·iCloud Drive에 저장하거나 메일로 보내두면 기기를 바꿔도 그대로 복원할 수 있어요. 앱은 켜질 때마다 자동으로 최근 \(BackupManager.maxAutoBackups)개의 백업을 기기에 보관합니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }

    private func exportBackup() {
        do {
            shareURL = try BackupManager.exportFileURL(context: context)
            showShareSheet = true
        } catch {
            show(message: "백업 파일을 만들지 못했어요: \(error.localizedDescription)")
        }
    }

    private func performRestore() {
        guard let url = pendingRestoreURL else { return }
        defer { pendingRestoreURL = nil }
        // 보안 스코프 리소스(파일 앱에서 고른 파일)는 접근 권한을 열어야 한다.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try BackupManager.restore(fromFileAt: url, context: context)
            load()   // 화면의 입력칸도 복원된 설정값으로 새로고침.
            show(message: "복원을 완료했어요. 모든 자산·기록·설정이 백업 시점으로 돌아왔습니다.")
        } catch {
            show(message: "복원에 실패했어요: \(error.localizedDescription)")
        }
    }

    private func show(message: String) {
        resultMessage = message
        showResultAlert = true
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
        // load()가 @State를 채우면 onChange→persist()가 연쇄로 불린다. 로딩 중에는
        // 저장을 막아, 복원 직후 막 지워진 설정 객체에 되쓰는 사고를 방지.
        isLoading = true
        defer { DispatchQueue.main.async { isLoading = false } }
        // @Query는 복원 직후 갱신이 한 박자 늦을 수 있어, 스토어에서 직접 최신값을 읽는다.
        let settings = (try? context.fetch(FetchDescriptor<FireSettings>()))?.first ?? settingsList.first ?? FireSettings()
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
        // load()로 인한 @State 변경에는 저장하지 않는다(복원 안전).
        guard !isLoading else { return }
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

// 백업·복원 관련 시트/임포터/다이얼로그/알림을 한 묶음으로 — body 타입 체크 분리.
private struct BackupRestoreModifiers: ViewModifier {
    @Binding var showShareSheet: Bool
    let shareURL: URL?
    @Binding var showImporter: Bool
    @Binding var showRestoreConfirm: Bool
    @Binding var showResultAlert: Bool
    let resultMessage: String?
    let onImport: (Result<[URL], Error>) -> Void
    let onRestore: () -> Void
    let onCancelRestore: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showShareSheet) {
                if let shareURL { ShareSheet(items: [shareURL]) }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false,
                          onCompletion: onImport)
            .confirmationDialog("이 백업으로 복원할까요?",
                                isPresented: $showRestoreConfirm,
                                titleVisibility: .visible) {
                Button("복원하기", role: .destructive, action: onRestore)
                Button("취소", role: .cancel, action: onCancelRestore)
            } message: {
                Text("지금 입력된 모든 자산·기록·설정이 백업 시점으로 교체됩니다. 이 작업은 되돌릴 수 없어요.")
            }
            .alert("백업 · 복원", isPresented: $showResultAlert) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
    }
}

// 시스템 공유 시트 — 백업 파일을 파일 앱·iCloud·메일 등 어디로든 저장/전송.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// 기기에 보관된 자동 백업 목록 — 날짜를 골라 그 시점으로 복원.
private struct AutoBackupListView: View {
    let onRestore: (URL) -> Void
    @State private var files: [BackupManager.BackupFile] = []

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E) a h:mm"
        return f
    }

    var body: some View {
        List {
            if files.isEmpty {
                Text("아직 자동 백업이 없어요. 앱을 켤 때마다 자동으로 백업이 쌓입니다.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
            } else {
                Section {
                    ForEach(files) { file in
                        Button {
                            onRestore(file.url)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dateFormatter.string(from: file.createdAt))
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(file.url.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecond)
                                }
                                Spacer()
                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                } footer: {
                    Text("가장 최근 백업이 맨 위예요. 복원하면 현재 데이터가 그 시점으로 교체됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
            }
        }
        .navigationTitle("자동 백업")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { files = BackupManager.listBackups() }
    }
}
