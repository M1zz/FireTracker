import SwiftUI
import SwiftData
import LocalAuthentication
import UniformTypeIdentifiers
import LeeoKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    // Biometric app lock (stored in UserDefaults, not synced asset data).
    @AppStorage("appLockEnabled") private var lockEnabled = false

    // 금액 표기 모드 — 끄면 억/만 단위(기본), 켜면 숫자(콤마)만.
    @AppStorage("amountNumbersOnly") private var amountNumbersOnly = false


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

    // 데모 데이터 토글 상태 — 내 데이터와 데모 데이터를 오간다.
    @AppStorage(DemoData.activeKey) private var demoActive = false
    /// 켜져 있을 때만 사용 통계 진입점이 보인다. 키 이름은 LeeoKit 과 같아야 한다.
    @AppStorage("dev.masterMode") private var isMasterMode = false

    var body: some View {
        NavigationStack {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            displaySection
            securitySection
            apiSection
            backupSection
            demoSection
            Section {
                LeeoSupportSection<FireTrackerSpec>()
                if isMasterMode {
                    NavigationLink {
                        LeeoUsageStatsView<FireTrackerSpec>()
                    } label: {
                        Label("사용 통계 (개발자)", systemImage: "chart.bar.xaxis")
                    }
                }
            } header: {
                Text("지원")
            }
            if isMasterMode {
                UsageDiagnosticsSection()
            }
            DeveloperContactSection()
        }
        .navigationTitle("설정")
        .scrollIndicators(.hidden)
        .keyboardDismissable()
        .onAppear(perform: load)
        .onChange(of: kisAppKey) { persist() }
        .onChange(of: kisAppSecret) { persist() }
        .onChange(of: dataGoKey) { persist() }
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

    // MARK: - 데모 데이터

    // 가상 인물(36세 직장인)의 데이터와 내 데이터를 토글로 오간다. 켜면 지금
    // 데이터가 스태시 파일에 보관되고, 끄면 그대로 돌아오므로 확인이 필요 없다.
    private var demoSection: some View {
        Section {
            Toggle(isOn: demoToggleBinding) {
                Label("데모 데이터", systemImage: "sparkles")
            }
            .tint(Theme.accent)
        } header: {
            Text("테스트")
        } footer: {
            Text(demoActive
                 ? "끄면 원래 내 데이터로 그대로 돌아갑니다. 데모에서 바꾼 내용은 저장되지 않아요."
                 : "켜면 내 데이터는 안전하게 보관되고, 가상 인물(36세 직장인, 55세 은퇴 목표)의 자산·9개월 기록으로 자산·추이·계산·대시보드를 둘러볼 수 있어요. 끄면 내 데이터가 그대로 돌아옵니다.")
        }
    }

    private var demoToggleBinding: Binding<Bool> {
        Binding(
            get: { demoActive },
            set: { on in
                if on { enableDemo() } else { disableDemo() }
            }
        )
    }

    private func enableDemo() {
        do {
            try DemoData.enable(context: context)
            load()   // 화면 입력칸도 데모 설정값으로 새로고침.
            show(message: "데모 데이터로 전환했어요. 자산·추이·계산 탭을 확인해보세요. 토글을 끄면 내 데이터가 그대로 돌아옵니다.")
        } catch {
            show(message: "데모 데이터를 넣지 못했어요: \(error.localizedDescription)")
        }
    }

    private func disableDemo() {
        do {
            try DemoData.disable(context: context)
            load()
            show(message: "내 데이터로 돌아왔어요.")
        } catch {
            show(message: "데이터를 되돌리지 못했어요: \(error.localizedDescription)")
        }
    }

    private func exportBackup() {
        do {
            shareURL = try BackupManager.exportFileURL(context: context)
            showShareSheet = true
            AppUsage.log(.backupExported)
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
            AppUsage.log(.backupRestored)
            show(message: "복원을 완료했어요. 모든 자산·기록·설정이 백업 시점으로 돌아왔습니다.")
        } catch {
            show(message: "복원에 실패했어요: \(error.localizedDescription)")
        }
    }

    private func show(message: String) {
        resultMessage = message
        showResultAlert = true
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
        target.kisAppKey = kisAppKey
        target.kisAppSecret = kisAppSecret
        target.dataGoKey = dataGoKey
        try? context.save()
    }
}

// MARK: - 개발자 문의
struct DeveloperContactSection: View {
    var body: some View {
        Section {
            Link(destination: URL(string: "mailto:leeo@kakao.com")!) {
                Label("이메일로 문의하기", systemImage: "envelope")
                    .foregroundStyle(Theme.accent)
            }
            Link(destination: URL(string: "https://instagram.com/lee25_ios")!) {
                Label("인스타그램 DM (@lee25_ios)", systemImage: "paperplane")
                    .foregroundStyle(Theme.accent)
            }
        } header: {
            Text("개발자에게 문의")
        } footer: {
            Text("버그 제보와 기능 제안을 환영합니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
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
