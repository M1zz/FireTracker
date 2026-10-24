import SwiftUI
import SwiftData
import Charts
import TipKit
import PhotosUI
import Vision
import LeeoKit

// Occasional nudge to capture assets the user may have forgotten.
struct OtherAssetsTip: Tip {
    var title: Text { Text("다른 자산은 없나요?") }
    var message: Text? {
        Text("연금·자동차·비상금·코인·보험·전세보증금 등 빠뜨린 자산이 있다면 추가해보세요.")
    }
    var image: Image? { Image(systemName: "lightbulb.fill") }
}

// The asset catalog — the user first lists up what they own here, then enters
// the scale of each holding in detail. Recording the catalog at a point in
// time produces a NetWorthSnapshot, which the dashboard/trend screens chart.
struct AssetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]
    @Query private var snapshots: [NetWorthSnapshot]
    @EnvironmentObject private var refresher: RefreshManager
    @EnvironmentObject private var pro: LeeoStore
    @State private var paywallFeature: ProFeature?
    @State private var editing: Asset?
    // 스와이프로 지우기 전에 한 번 묻는다 — 지운 자산은 되돌릴 수 없다.
    @State private var pendingDelete: [Asset] = []
    @State private var showingNew = false
    @State private var showingImport = false
    @State private var showingBreakdown = false
    @State private var totalMode: AssetTotalMode = .gross
    // 자산 구성 도넛에서 탭으로 선택된 조각(각도값).
    @State private var selectedSlice: Double?
    // 새 자산을 어떤 카테고리로 추가할지 — 카테고리별 ‘+ 종목 추가’가 미리 채운다.
    @State private var newClass: AssetClass = .stocks
    @State private var newCustomLabel = ""
    @State private var newLockedClass = false
    @State private var newClassTotal: Double = 0
    // 카테고리 선택 시트 → 닫힌 뒤 그 카테고리 고정 에디터로 이어줌.
    @State private var showingCategoryPicker = false
    @State private var pendingCategory: (cls: AssetClass, label: String)?
    // 접힌 카테고리 그룹 id들. 비어 있으면 전부 펼침(기본).
    @State private var collapsedGroups: Set<String> = []

    private let otherAssetsTip = OtherAssetsTip()

    private var total: Double { assets.reduce(0) { $0 + $1.netValue } }
    private var liquidTotal: Double { assets.reduce(0) { $0 + $1.liquidValue } }
    private var lockedTotal: Double { total - liquidTotal }
    private var settings: FireSettings { settingsList.first ?? FireSettings() }
    private var monthlyIncome: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome }
    }
    private var totalDebtCost: Double { assets.reduce(0) { $0 + $1.monthlyDebtCost } }
    private var totalGain: Double { assets.reduce(0) { $0 + $1.gain } }

    // 수동 새로고침 — 자동 시세 자산의 평가액과 주식·ETF 배당률을 즉시 최신화.
    private func refreshNow() {
        AppUsage.log(.priceRefreshed)
        Task { await refresher.refresh(assets: assets, settings: settings, context: context) }
    }

    // 패시브 인컴 한 줄 — 어떤 자산이 어떤 종류(배당·월세·이자…)로 월 얼마를 내는지.
    private struct IncomeLine: Identifiable {
        let id: String
        let name: String
        let kind: String
        let symbol: String      // SF Symbol
        let monthly: Double
        let note: String        // 배당률·근거 설명
    }

    // 수입을 내는 자산 + 설정의 수동 배당을, 월 금액 큰 순으로.
    private var incomeLines: [IncomeLine] {
        var lines: [IncomeLine] = assets
            .filter { !$0.isDebt && $0.effectiveMonthlyIncome > 0 }
            .map { a in
                let note: String
                if a.monthlyIncome > 0 {
                    note = String(localized: "직접 입력")
                } else if a.annualYieldPct > 0 {
                    note = String(localized: "연 \(Fmt.trimNumber(a.annualYieldPct))% · 평가액 기준")
                } else {
                    note = ""
                }
                return IncomeLine(
                    id: a.key.uuidString,
                    name: a.name.isEmpty ? a.displayClassLabel : a.name,
                    kind: a.incomeKind == .none ? String(localized: "현금흐름") : a.incomeKind.label,
                    symbol: incomeIcon(a.incomeKind),
                    monthly: a.effectiveMonthlyIncome,
                    note: note
                )
            }
            .sorted { $0.monthly > $1.monthly }
        return lines
    }

    // 종류별 합계 — 칩으로 한눈에(배당 월 50만 · 월세 월 80만 …).
    private var incomeByKind: [(kind: String, monthly: Double)] {
        var dict: [String: Double] = [:]
        for line in incomeLines { dict[line.kind, default: 0] += line.monthly }
        return dict.map { (kind: $0.key, monthly: $0.value) }
            .sorted { $0.monthly > $1.monthly }
    }

    private func incomeIcon(_ kind: IncomeKind) -> String {
        switch kind {
        case .dividend: return "chart.pie.fill"
        case .rent:     return "house.fill"
        case .interest: return "banknote.fill"
        case .pension:  return "figure.walk"
        case .staking:  return "bitcoinsign.circle.fill"
        case .other, .none: return "wonsign.circle.fill"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    emptyState
                } else {
                    catalogList
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            // 자산 탭에 들어올 때마다 최신화(15분 쓰로틀로 과도한 호출 방지).
            .task {
                await refresher.refreshIfStale(
                    assets: assets, settings: settings, context: context,
                    maxAge: RefreshManager.tabThrottle
                )
            }
            // 자산 변동 자동 기록은 RootView가 앱 전역에서 감지한다.
            .navigationTitle("자산")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { refreshNow() } label: {
                        if refresher.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(refresher.isRefreshing || assets.isEmpty)
                    .accessibilityLabel("시세·배당 새로고침")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingCategoryPicker = true } label: {
                            Label("카테고리 추가", systemImage: "folder.badge.plus")
                        }
                        Button { startNewAsset() } label: {
                            Label("직접 추가", systemImage: "square.and.pencil")
                        }
                        Button {
                            if pro.gate.allows(ProFeature.screenshotImport.rawValue) {
                                showingImport = true
                            } else {
                                AppUsage.log(.paywallShown)
                                paywallFeature = .screenshotImport
                            }
                        } label: {
                            Label("캡처로 가져오기·맞추기",
                                  systemImage: pro.gate.allows(ProFeature.screenshotImport.rawValue)
                                      ? "text.viewfinder" : "lock.fill")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingNew) {
                AssetEditor(asset: nil, nextSortOrder: assets.count,
                            initialClass: newClass, initialCustomLabel: newCustomLabel,
                            lockedClass: newLockedClass,
                            classTotal: newLockedClass ? newClassTotal : nil)
            }
            .confirmationDialog(
                pendingDelete.count == 1
                    ? "‘\(pendingDelete[0].name.isEmpty ? pendingDelete[0].displayClassLabel : pendingDelete[0].name)’을(를) 지울까요?"
                    : "자산 \(pendingDelete.count)개를 지울까요?",
                isPresented: Binding(get: { !pendingDelete.isEmpty },
                                     set: { if !$0 { pendingDelete = [] } }),
                titleVisibility: .visible
            ) {
                Button("자산 삭제", role: .destructive) { deletePending() }
                Button("취소", role: .cancel) { pendingDelete = [] }
            } message: {
                Text("매매 내역도 함께 지워져요. 지난 기록은 남습니다. 되돌릴 수 없어요.")
            }
            .sheet(item: $editing) { asset in
                AssetEditor(asset: asset, nextSortOrder: assets.count)
            }
            // 카테고리 먼저 고르는 흐름 — 고르면 닫히고, 그 카테고리 고정 에디터로.
            // (세부 종목을 저장해야 카테고리가 실제로 생긴다 = 빈 카테고리 없음)
            .sheet(isPresented: $showingCategoryPicker, onDismiss: {
                if let p = pendingCategory {
                    pendingCategory = nil
                    let subtotal = assets
                        .filter { $0.assetClass == p.cls && (p.cls != .custom || $0.customLabel == p.label) }
                        .reduce(0) { $0 + $1.netValue }
                    startNewAsset(p.cls, customLabel: p.label, lock: true, classTotal: subtotal)
                }
            }) {
                CategoryPickerSheet(assets: assets) { cls, label in
                    pendingCategory = (cls, label)
                    showingCategoryPicker = false
                }
            }
            .sheet(isPresented: $showingImport) {
                ScreenshotImportView(startingSortOrder: assets.count)
            }
            .sheet(isPresented: $showingBreakdown) { NetWorthBreakdownView() }
            .proPaywall($paywallFeature)
        }
    }

    private var catalogList: some View {
        List {
            // 1) 자산 구성 — 먼저.
            if !compositionEntries.isEmpty {
                Section {
                    compositionCard
                        .padding(.top, 8)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            // 1.5) 매도 원칙 — 지금 눈여겨볼 종목이 있는지 한 줄로.
            if SellWatchCard.hasContent(assets) {
                Section {
                    SellWatchCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            // 2) 내 자산 — 종류(카테고리)별로 묶어, 접고 펼치며 종목을 관리.
            ForEach(assetGroups) { group in
                Section {
                    if !collapsedGroups.contains(group.id) {
                        ForEach(group.assets) { asset in
                            Button { editing = asset } label: { row(asset) }
                                .listRowBackground(Theme.surface)
                        }
                        .onDelete { offsets in pendingDelete = offsets.map { group.assets[$0] } }
                        Button {
                            startNewAsset(group.assetClass, customLabel: group.customLabel,
                                          lock: true, classTotal: group.subtotal)
                        } label: {
                            Label("\(group.title) 종목 추가", systemImage: "plus.circle")
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                        }
                        .listRowBackground(Theme.surface)
                    }
                } header: {
                    groupHeader(group)
                }
                .textCase(nil)
            }
            // 2.5) 자산 도감 — 우표첩처럼 자산 종류를 수집하는 재미.
            Section {
                collectionCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            // 3) 그 다음 — 쓸 수 있는 돈/순자산 요약.
            Section {
                totalCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            // 3.5) 패시브 인컴 상세 — 월 현금흐름이 있을 때만.
            if monthlyIncome > 0 {
                Section {
                    passiveIncomeCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            // 3.6) 패시브 인컴 만들기 — 방법 안내 + 놓친 수입원 원탭 추가.
            Section {
                passiveIncomeGuideCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            // 4) 팁 + 추가.
            Section {
                TipView(otherAssetsTip)
                    .tipBackground(Theme.surface)
                    .listRowBackground(Theme.surface)
                Button { startNewAsset() } label: {
                    Label("자산 추가", systemImage: "plus.circle")
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("쓸 수 있는 돈 (유동)")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            Text("\(Fmt.krw(liquidTotal))원")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.positive)
            Text("지금 바로 현금화해 쓸 수 있는 자산(현금·주식·코인 등)이에요. 실거주 부동산·전세보증금·연금처럼 묶인 돈과 부채는 빠집니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            liquidityBar
            HStack(spacing: 10) {
                legendDot(String(localized: "유동 \(Fmt.krw(liquidTotal))원"), Theme.positive)
                if lockedTotal > 0 {
                    legendDot(String(localized: "묶임 \(Fmt.krw(lockedTotal))원"), Theme.textSecond.opacity(0.5))
                }
            }
            .font(.caption2)

            Button { showingBreakdown = true } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("순자산 \(Fmt.krw(total))원")
                            .font(.caption)
                        Text("\(Fmt.wonKo(total)) · 내역 보기")
                            .font(.caption2)
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                    Spacer()
                }
                .foregroundStyle(Theme.textSecond)
            }
            .buttonStyle(.plain)

            if monthlyIncome > 0 || totalDebtCost > 0 || totalGain != 0 {
                Divider().overlay(Theme.hairline)
                HStack(spacing: 0) {
                    if monthlyIncome > 0 {
                        flowStat(title: String(localized: "월 현금흐름"),
                                 value: String(localized: "+\(Fmt.krw(monthlyIncome))원"),
                                 tint: Theme.positive)
                    }
                    if totalDebtCost > 0 {
                        flowStat(title: String(localized: "부채가 가져가는 돈"),
                                 value: String(localized: "−\(Fmt.krw(totalDebtCost))원"),
                                 tint: Theme.negative)
                    }
                    if totalGain != 0 {
                        flowStat(title: String(localized: "총 평가 차익"),
                                 value: String(localized: "\(totalGain >= 0 ? "+" : "-")\(Fmt.krw(abs(totalGain)))원"),
                                 tint: totalGain >= 0 ? Theme.positive : Theme.negative)
                    }
                }
                if monthlyIncome > 0 {
                    Text("연 예상 배당·현금흐름 \(Fmt.krw(monthlyIncome * 12))원 (배당·이자·월세 등 합산)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
                if monthlyIncome > 0 && totalDebtCost > 0 {
                    let net = monthlyIncome - totalDebtCost
                    Text("월 순현금흐름 \(net >= 0 ? "+" : "−")\(Fmt.krw(abs(net)))원 (현금흐름 − 부채)")
                        .font(.caption2)
                        .foregroundStyle(net >= 0 ? Theme.positive : Theme.negative)
                }
            }
            refreshStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 시세·배당 마지막 갱신 시각 + 탭하면 즉시 새로고침.
    @ViewBuilder private var refreshStatus: some View {
        Divider().overlay(Theme.hairline)
        Button { refreshNow() } label: {
            HStack(spacing: 6) {
                if refresher.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text(refresher.statusMessage ?? String(localized: "갱신 중…"))
                } else {
                    Image(systemName: "arrow.clockwise")
                    if let when = refresher.lastRefreshText {
                        Text("시세·배당 \(when) 갱신 · 탭하면 새로고침")
                    } else {
                        Text("시세·배당 새로고침")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecond)
        }
        .buttonStyle(.plain)
        .disabled(refresher.isRefreshing)
    }

    // 패시브 인컴 상세 — 월 현금흐름이 '어디서 얼마' 나오는지 펼쳐 보여준다.
    private var passiveIncomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("패시브 인컴 상세")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("월 +\(Fmt.krw(monthlyIncome))원")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.positive)
            }
            Text("일하지 않아도 들어오는 돈이에요 — 어떤 자산이 어떤 방식으로 얼마씩 만드는지.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            // 종류별 합계 칩.
            if incomeByKind.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(incomeByKind, id: \.kind) { g in
                            Text("\(g.kind) 월 \(Fmt.krw(g.monthly))원")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.surfaceHigh)
                                .foregroundStyle(Theme.textPrimary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Divider().overlay(Theme.hairline)

            // 자산별 한 줄 — 큰 금액부터.
            ForEach(incomeLines) { line in
                HStack(spacing: 10) {
                    Image(systemName: line.symbol)
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(line.note.isEmpty ? line.kind : "\(line.kind) · \(line.note)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("월 \(Fmt.krw(line.monthly))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.positive)
                        Text("연 \(Fmt.krw(line.monthly * 12))원")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                    .lineLimit(1)
                    .layoutPriority(1)
                }
            }

            Text("연 합계 \(Fmt.krw(monthlyIncome * 12))원 (배당·이자·월세·연금·스테이킹 등)")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 패시브 인컴을 만드는 대표 경로 — 누르면 그 종류의 자산을 바로 추가.
    private struct IncomeRoute { let title: String; let cls: AssetClass; let desc: String }
    private var incomeRoutes: [IncomeRoute] {
        [
            .init(title: String(localized: "배당주"), cls: .stocks, desc: String(localized: "주식 배당금 · 코스피 ~2%, S&P500 ~1.5%")),
            .init(title: String(localized: "고배당 ETF·펀드"), cls: .fund, desc: String(localized: "고배당 ETF ~4.5% · 자동 분산")),
            .init(title: String(localized: "월세 부동산"), cls: .realEstate, desc: String(localized: "오피스텔 ~5%, 아파트 ~2.4%")),
            .init(title: String(localized: "예금·적금 이자"), cls: .cash, desc: String(localized: "예금 ~3% · 가장 안전")),
            .init(title: String(localized: "채권 이자"), cls: .bond, desc: String(localized: "국채·회사채 표면이자")),
            .init(title: String(localized: "연금"), cls: .pension, desc: String(localized: "연금저축·IRP 운용수익 ~3~5%")),
            .init(title: String(localized: "코인 스테이킹"), cls: .crypto, desc: String(localized: "ETH 스테이킹 ~3~4%")),
        ]
    }

    // "패시브 인컴 만들기" — 방법별 설명 + 원탭 추가. 놓친 수입원을 한눈에.
    private var passiveIncomeGuideCard: some View {
        let owned = collectedClasses
        return VStack(alignment: .leading, spacing: 12) {
            Text("패시브 인컴 만들기")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("일하지 않아도 돈이 들어오게 하는 대표적인 방법이에요. 누르면 바로 그 자산을 추가할 수 있어요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
            ForEach(incomeRoutes, id: \.title) { route in
                Button { startNewAsset(route.cls, lock: true) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hexCode: route.cls.colorHex))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(route.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                if owned.contains(route.cls) {
                                    Text("보유 중")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.positive.opacity(0.18))
                                        .foregroundStyle(Theme.positive)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(route.desc)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func flowStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(Theme.textSecond)
        }
    }

    // Split bar: spendable (유동) vs locked (묶임).
    private var liquidityBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                if liquidTotal > 0 {
                    Theme.positive
                        .frame(width: max(2, geo.size.width * (total > 0 ? liquidTotal / total : 0)))
                }
                if lockedTotal > 0 {
                    Theme.textSecond.opacity(0.4)
                        .frame(width: max(2, geo.size.width * (total > 0 ? lockedTotal / total : 0)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    // Positive net value per asset class, for the composition chart.
    // 비율(금액)이 큰 종류부터 — 도넛·범례가 큰 순서로 보이게 정렬.
    private var compositionEntries: [(assetClass: AssetClass, amount: Double)] {
        AssetClass.allCases.compactMap { ac -> (assetClass: AssetClass, amount: Double)? in
            guard ac != .debt else { return nil }
            let sum = assets.filter { $0.assetClass == ac }
                .reduce(0) { $0 + max(0, $1.netValue) }
            return sum > 0 ? (ac, sum) : nil
        }
        .sorted { $0.amount > $1.amount }
    }
    // Debt magnitude, gross assets, and the toggle's effective mode — mirror the
    // dashboard so 총자산/순자산 behaves the same on both screens.
    private var debtTotal: Double { abs(assets.filter { $0.isDebt }.reduce(0) { $0 + $1.netValue }) }
    private var grossAssets: Double { compositionEntries.reduce(0) { $0 + $1.amount } }
    private var hasDebt: Bool { debtTotal > 0 }
    // 부채 비율 = 부채 ÷ 보유 자산. 자산 대비 빚이 얼마나 되는지.
    private var debtRatio: Double { grossAssets > 0 ? debtTotal / grossAssets : 0 }
    private var effectiveMode: AssetTotalMode { hasDebt ? totalMode : .gross }
    // Chart/legend rows: assets always; 순자산 mode adds a debt slice.
    private var compositionRows: [(assetClass: AssetClass, amount: Double)] {
        var rows = compositionEntries
        if effectiveMode == .net && debtTotal > 0 {
            rows.append((assetClass: .debt, amount: debtTotal))
        }
        return rows
    }

    // 탭으로 선택된 도넛 조각 → 해당 카테고리. selectedSlice(누적 각도값)를 행 누적합과 대조.
    private var selectedCompRow: (assetClass: AssetClass, amount: Double)? {
        guard let sel = selectedSlice else { return nil }
        var cum = 0.0
        for r in compositionRows {
            if sel >= cum && sel < cum + r.amount { return r }
            cum += r.amount
        }
        return nil
    }
    // 범례 탭 시 그 카테고리 조각의 중앙 각도값 — 도넛 선택과 연동.
    private func sliceMidAngle(for ac: AssetClass) -> Double? {
        var cum = 0.0
        for r in compositionRows {
            if r.assetClass == ac { return cum + r.amount / 2 }
            cum += r.amount
        }
        return nil
    }

    private var compositionTitle: some View {
        Text("자산 구성")
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
    }

    private var totalModePicker: some View {
        Picker("", selection: $totalMode) {
            ForEach(AssetTotalMode.allCases) { mode in
                Text(LocalizedStringKey(mode.rawValue)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var assetCountLabel: some View {
        Text("\(assets.count)개 자산")
            .font(.caption)
            .foregroundStyle(Theme.textSecond)
    }

    // Donut chart + legend showing how net worth breaks down by class.
    private var compositionCard: some View {
        let rows = compositionRows
        let sum = rows.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 16) {
            // 말이 긴 언어(그리스어 등)에선 제목 옆에 안 들어가므로 아래 줄로 내린다.
            ViewThatFits(in: .horizontal) {
                HStack {
                    compositionTitle
                    Spacer()
                    if hasDebt { totalModePicker.fixedSize() } else { assetCountLabel }
                }
                VStack(alignment: .leading, spacing: 10) {
                    compositionTitle
                    if hasDebt { totalModePicker } else { assetCountLabel }
                }
            }

            if hasDebt {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Fmt.krw(effectiveMode == .gross ? grossAssets : total))원")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(effectiveMode == .gross ? Theme.textPrimary : Theme.accent)

                    // 부채 비율 — 자산 대비 빚의 크기를 한 줄 바로.
                    HStack(spacing: 8) {
                        Text("부채 비율")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hairline)
                                Capsule().fill(Theme.negative.opacity(0.8))
                                    .frame(width: max(2, geo.size.width * min(debtRatio, 1)))
                            }
                        }
                        .frame(height: 6)
                        Text(Fmt.percent(debtRatio, fraction: 1))
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.negative)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let selSlice = selectedCompRow
            Chart(rows, id: \.assetClass) { item in
                SectorMark(
                    angle: .value("금액", item.amount),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .foregroundStyle(Color(hexCode: item.assetClass.colorHex))
                .cornerRadius(4)
                .opacity(selSlice == nil || selSlice?.assetClass == item.assetClass ? 1 : 0.3)
            }
            .chartAngleSelection(value: $selectedSlice)
            // 중앙 라벨은 차트 위(overlay)에 — 배경에 두면 긴 금액이 도넛 링에
            // 가려진다. 구멍 폭 안에서만 그리고 길면 자동 축소해 항상 보이게.
            .chartOverlay { _ in
                GeometryReader { geo in
                    // 도넛 구멍 지름 ≈ 차트 짧은 변 × innerRadius(0.62), 여유 8pt.
                    let hole = min(geo.size.width, geo.size.height) * 0.62 - 8
                    VStack(spacing: 2) {
                        Text(selSlice?.assetClass.label ?? String(localized: "전체"))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                        Text("\(Fmt.krw(selSlice?.amount ?? sum))원")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(selSlice.map { Color(hexCode: $0.assetClass.colorHex) } ?? Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let selSlice, sum > 0 {
                            Text(Fmt.percent(selSlice.amount / sum, fraction: 0))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    .frame(maxWidth: hole)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)   // 도넛 조각 탭 선택은 그대로 동작.
                }
            }
            .frame(height: 170)
            .animation(.easeInOut(duration: 0.3), value: selectedSlice)
            .animation(.easeInOut(duration: 0.45), value: rows.map(\.amount))

            VStack(spacing: 4) {
                ForEach(rows, id: \.assetClass) { item in
                    let isDebt = item.assetClass == .debt
                    let selected = selSlice?.assetClass == item.assetClass
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hexCode: item.assetClass.colorHex))
                            .frame(width: 10, height: 10)
                        Text(item.assetClass.label)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(isDebt ? "-" : "")\(Fmt.krw(item.amount))원")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(isDebt ? Theme.negative : Theme.textSecond)
                        Text(Fmt.percent(sum > 0 ? item.amount / sum : 0, fraction: 0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecond)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(selected ? Color(hexCode: item.assetClass.colorHex).opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            // 범례를 탭해도 선택/해제 — 도넛과 연동.
                            selectedSlice = selected ? nil : sliceMidAngle(for: item.assetClass)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: selectedSlice)
            .animation(.easeInOut(duration: 0.45), value: rows.map(\.assetClass))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 도감 대상 종류 — 직접 입력·부채는 수집 개념에서 제외.
    private var collectibleClasses: [AssetClass] {
        AssetClass.allCases.filter { $0 != .custom && $0 != .debt }
    }
    private var collectedClasses: Set<AssetClass> {
        Set(assets.map(\.assetClass))
    }

    // 자산 도감 — 보유한 종류는 색으로 채워지고, 미보유 칸을 누르면 바로 그
    // 종류의 자산 추가로 이어진다.
    private var collectionCard: some View {
        let collected = collectedClasses
        let total = collectibleClasses.count
        let count = collectibleClasses.filter { collected.contains($0) }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("자산 도감")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)/\(total) 수집")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(count == total ? Theme.accent : Theme.textSecond)
                    .contentTransition(.numericText(value: Double(count)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(collectibleClasses) { ac in
                    let owned = collected.contains(ac)
                    Button { if !owned { startNewAsset(ac, lock: true) } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: owned ? ac.symbolName : "plus")
                                .font(.subheadline)
                                .foregroundStyle(owned ? Color(hexCode: ac.colorHex) : Theme.textSecond.opacity(0.5))
                                .frame(height: 18)
                            Text(ac.label)
                                .font(.caption2)
                                .foregroundStyle(owned ? Theme.textPrimary : Theme.textSecond.opacity(0.6))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(owned ? Color(hexCode: ac.colorHex).opacity(0.13) : Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(owned ? Color(hexCode: ac.colorHex).opacity(0.45) : Theme.hairline,
                                        style: owned ? StrokeStyle(lineWidth: 1)
                                                     : StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(owned)
                    // 도장 찍기 — 칸이 채워지는 순간 크게 나타나 쾅 눌리듯 안착.
                    // owned가 바뀌면 id가 바뀌어 새 뷰로 취급 → 삽입 트랜지션 실행.
                    .id("\(ac.rawValue)-\(owned)")
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1.6).combined(with: .opacity),
                        removal: .identity))
                }
            }
            Text(count == total
                 ? "모든 자산 종류를 수집했어요! 🎉"
                 : "빈 칸을 누르면 그 종류의 자산을 바로 추가할 수 있어요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 저장 직후(시트 닫히며 목록 갱신) 찍히자마자 스프링으로 움직이게.
        .animation(.spring(duration: 0.55, bounce: 0.45), value: collected)
        .sensoryFeedback(.success, trigger: count) { old, new in new > old }
        .cardStyle()
    }

    private func row(_ asset: Asset) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hexCode: asset.assetClass.colorHex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name.isEmpty ? asset.displayClassLabel : asset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if asset.assetClass == .realEstate {
                        Text(asset.realEstateUse.label)
                            .foregroundStyle(Color(hexCode: asset.assetClass.colorHex))
                    } else {
                        Text(asset.displayClassLabel)
                            .foregroundStyle(Theme.textSecond)
                    }
                    if asset.liquidity == .locked {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Theme.textSecond)
                    }
                    if asset.autoPriced {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(Theme.accent)
                    }
                    // 매도 원칙에 닿았거나 가까우면 목록에서도 바로 보이게.
                    if let st = SellWatch.status(asset), st.signal != .holding {
                        SellSignalChip(signal: st.signal)
                    }
                    if asset.effectiveMonthlyIncome > 0 {
                        Text("월 \(Fmt.wonKo(asset.effectiveMonthlyIncome))")
                            .foregroundStyle(Theme.positive)
                    }
                    if asset.monthlyDebtCost > 0 {
                        Text("월 −\(Fmt.wonKo(asset.monthlyDebtCost))")
                            .foregroundStyle(Theme.negative)
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                // 보유 수량 한 줄 — 예) 32주 · 평단 387,500원. 목록에서 바로 몇 주인지 보이게.
                if asset.quantity > 0,
                   asset.assetClass == .stocks || asset.assetClass == .fund || asset.assetClass == .crypto {
                    let unit = asset.assetClass == .crypto ? String(localized: "개") : String(localized: "shares.unit", defaultValue: "주")
                    let avg = asset.averagePrice
                    Text(avg > 0
                         ? "\(Fmt.trimNumber(asset.quantity))\(unit) · 평단 \(Fmt.krw(avg))원"
                         : "\(Fmt.trimNumber(asset.quantity))\(unit)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .lineLimit(1)
                }
                // 세부 종목 한 줄 요약 — 예) 삼성전자 1,000만 · 애플 2,000만
                if !asset.detailList.isEmpty {
                    Text(asset.sortedDetails.map { "\($0.name) \(Fmt.krw($0.amount))" }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .lineLimit(1)
                }
                // 전세 보증금 구성 — 오른쪽 금액 열에 붙이면 이름·부제목이
                // 다 잘리므로, 왼쪽 전체 폭에서 축약 표기(억/만)로 보여준다.
                if asset.depositReceived > 0 {
                    Text("현금 \(Fmt.wonKo(asset.depositCash)) + 지분 \(Fmt.wonKo(asset.equityValue))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 오른쪽엔 합계 한 줄만 — 억 단위 금액도 이름을 누르지 않게,
            // 넘치면 살짝 줄여서 한 줄에 맞춘다.
            Text("\(Fmt.krw(asset.netValue))원")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(asset.netValue < 0 ? Theme.negative : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.full")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.textSecond)
            Text("내 자산을 먼저 등록해보세요.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("주식·코인·부동산·전세·현금 등\n보유한 자산을 목록으로 만들어 추적합니다.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
            Button { startNewAsset() } label: {
                Text("자산 추가")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .foregroundStyle(Color.black)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Theme.bg)
    }

    private func deletePending() {
        for a in pendingDelete { context.delete(a) }
        pendingDelete = []
        context.saveReporting(String(localized: "삭제"))
    }

    // Open the editor for a brand-new holding, pre-set to a category so the
    // user only fills in the name + amount. `lock`이면 종류 변경 불가(그룹의
    // '종목 추가') — 그 종류 합계를 컨텍스트로 함께 넘긴다.
    private func startNewAsset(_ cls: AssetClass = .stocks, customLabel: String = "",
                               lock: Bool = false, classTotal: Double = 0) {
        newClass = cls
        newCustomLabel = customLabel
        newLockedClass = lock
        newClassTotal = classTotal
        showingNew = true
    }

    private func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) }
        else { collapsedGroups.insert(id) }
    }

    // 카탈로그를 종류별 그룹으로. AssetClass.allCases 순서를 유지하고, 직접 입력은
    // 사용자가 붙인 라벨별로 갈라 별도 그룹이 되게 한다.
    private var assetGroups: [AssetGroup] {
        var groups: [AssetGroup] = []
        for ac in AssetClass.allCases {
            // 그룹 안에서는 금액(절댓값) 큰 종목부터.
            let members = assets.filter { $0.assetClass == ac }
                .sorted { abs($0.netValue) > abs($1.netValue) }
            guard !members.isEmpty else { continue }
            if ac == .custom {
                var labels: [String] = []
                for m in members where !labels.contains(m.customLabel) { labels.append(m.customLabel) }
                for label in labels {
                    let sub = members.filter { $0.customLabel == label }
                    groups.append(AssetGroup(id: "custom:\(label)",
                                             assetClass: ac,
                                             title: label.isEmpty ? ac.label : label,
                                             customLabel: label,
                                             assets: sub))
                }
            } else {
                groups.append(AssetGroup(id: ac.rawValue,
                                         assetClass: ac,
                                         title: ac.label,
                                         customLabel: "",
                                         assets: members))
            }
        }
        // 카테고리도 금액(소계) 큰 순으로 — 부채는 음수라 자연스레 맨 아래.
        return groups.sorted { $0.subtotal > $1.subtotal }
    }

    // Tappable category header: chevron + icon + name + count, and the group's
    // net subtotal on the right (red & negative for the debt group).
    private func groupHeader(_ group: AssetGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        let subtotal = group.subtotal
        return Button { toggleGroup(group.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecond)
                    .frame(width: 10)
                Circle()
                    .fill(Color(hexCode: group.assetClass.colorHex))
                    .frame(width: 8, height: 8)
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(group.assets.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecond)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.surfaceHigh)
                    .clipShape(Capsule())
                Spacer()
                Text("\(subtotal < 0 ? "−" : "")\(Fmt.krw(abs(subtotal)))원")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(subtotal < 0 ? Theme.negative : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// One category section in the catalog: a group of holdings sharing an asset
// class (custom holdings split further by their user-typed label).
struct AssetGroup: Identifiable {
    let id: String
    let assetClass: AssetClass
    let title: String
    let customLabel: String
    let assets: [Asset]
    // Net contribution of the group (debts subtract).
    var subtotal: Double { assets.reduce(0) { $0 + $1.netValue } }
}

// 카테고리(자산 종류)를 먼저 고르는 시트. 고르면 그 카테고리가 고정된 종목
// 입력으로 이어진다. 이미 자산이 있는 카테고리는 현재 합계를 함께 표시.
struct CategoryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let assets: [Asset]
    let onPick: (AssetClass, String) -> Void

    @State private var customLabel = ""

    private func subtotal(for ac: AssetClass) -> Double {
        assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AssetClass.allCases.filter { $0 != .custom }) { ac in
                        Button { onPick(ac, "") } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color(hexCode: ac.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(ac.label)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                let t = subtotal(for: ac)
                                if t != 0 {
                                    Text("\(t < 0 ? "−" : "")\(Fmt.krw(abs(t)))원")
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundStyle(t < 0 ? Theme.negative : Theme.textSecond)
                                }
                            }
                        }
                    }
                } header: {
                    Text("카테고리 선택")
                } footer: {
                    Text("고르면 바로 그 카테고리의 종목 입력으로 이어져요. 종목을 저장하면 목록에 카테고리가 생깁니다.")
                        .font(.caption)
                }

                Section("직접 입력") {
                    HStack(spacing: 6) {
                        TextField("카테고리 이름 (예: 회원권, 사업 지분)", text: $customLabel)
                        Button {
                            onPick(.custom, customLabel.trimmingCharacters(in: .whitespaces))
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(customLabel.trimmingCharacters(in: .whitespaces).isEmpty
                                                 ? Theme.textSecond.opacity(0.4) : Theme.accent)
                        }
                        .buttonStyle(.borderless)
                        .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("카테고리 추가")
            .navigationBarTitleDisplayMode(.inline)
            .scrollIndicators(.hidden)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            }
        }
    }
}

// Detailed editor for a single holding: define it, enter its scale (manually
// or via live quote), and see how its value has tracked over past records.
struct AssetEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [FireSettings]
    @Query(sort: \NetWorthSnapshot.date) private var snapshots: [NetWorthSnapshot]
    @Query(sort: \Asset.sortOrder) private var allAssets: [Asset]
    @EnvironmentObject private var pro: LeeoStore
    @State private var paywallFeature: ProFeature?

    let asset: Asset?
    let nextSortOrder: Int
    @AppStorage(DemoData.activeKey) private var demoActive = false
    @State private var confirmingDelete = false
    // 그룹의 '종목 추가'로 열렸을 때 — 종류를 고정하고 세부 정보만 입력받는다.
    let lockedClass: Bool
    // 고정된 종류의 현재 합계(그룹 소계) — 컨텍스트로 보여줌.
    let classTotal: Double?

    @State private var name = ""
    @State private var assetClass: AssetClass = .stocks
    @State private var customLabel = ""
    @State private var amount = ""
    @State private var symbol = ""
    @State private var quantity = ""
    @State private var currency = "KRW"
    @State private var auto = false
    @State private var unitPriceKRW: Double = 0
    @State private var lastPriced: Date?
    @State private var fetching = false
    @State private var status = ""
    @State private var failed = false
    // 티커·종목코드 칸 포커스 — 칸을 떠나면 API로 이름을 자동 조회한다.
    @FocusState private var tickerFocused: Bool
    @State private var lookingUpName = false

    // Cash flow / yield
    @State private var incomeKind: IncomeKind = .none
    @State private var monthlyIncome = ""
    @State private var annualYieldPct = ""
    @State private var depositReceived = ""
    @State private var depositLiquid = true
    @State private var costBasis = ""
    @State private var realEstateUse: RealEstateUse = .residence

    // Liquidity
    @State private var liquidity: Liquidity = .liquid

    // 새 자산은 간단 입력(종류·이름·금액)으로 시작 — 세부 설정은 펼쳐서.
    // 기존 자산 편집은 저장된 값이 보이도록 전체 폼.
    @State private var showAdvanced: Bool

    // 세부 종목 드래프트 — 저장 시점에 Asset.details로 동기화.
    private struct DetailDraft: Identifiable {
        let id = UUID()
        var name: String
        var amount: String
    }
    @State private var detailDrafts: [DetailDraft] = []
    @State private var newDetailName = ""
    @State private var newDetailAmount = ""

    // 매매 원장 드래프트 — 저장 시점에 Asset.trades로 동기화한다.
    // 원장이 비어 있지 않으면 보유 수량·투자 원금은 여기서 계산한 값이 진실.
    @State private var tradeRows: [TradeRow] = []
    @State private var showTradeForm = false
    @State private var tradeKind: TradeKind = .buy
    @State private var tradeDate = Date()
    @State private var tradeQty = ""
    @State private var tradePrice = ""
    @State private var tradeAmountText = ""
    // 수정 중인 거래 — 비어 있으면 새 거래를 추가하는 중.
    @State private var editingTradeID: UUID?
    // 매도 원칙 — 목표 매도가(1주·개당, 원)와 고점 대비 하락 알림(%).
    @State private var sellTarget = ""
    @State private var stopPct: Double = 10

    // Seed all editor state directly from the asset so that opening the editor
    // does not mutate `assetClass` (which would trigger onChange and clobber the
    // stored liquidity/income with class-suggested defaults).
    init(asset: Asset?, nextSortOrder: Int,
         initialClass: AssetClass = .stocks, initialCustomLabel: String = "",
         lockedClass: Bool = false, classTotal: Double? = nil) {
        self.asset = asset
        self.nextSortOrder = nextSortOrder
        self.lockedClass = lockedClass
        self.classTotal = classTotal
        _showAdvanced = State(initialValue: asset != nil)
        let cls = asset?.assetClass ?? initialClass
        _name = State(initialValue: asset?.name ?? "")
        _assetClass = State(initialValue: cls)
        _customLabel = State(initialValue: asset?.customLabel ?? initialCustomLabel)
        _amount = State(initialValue: asset.map { $0.amount > 0 ? String(Int($0.amount)) : "" } ?? "")
        _symbol = State(initialValue: asset?.symbol ?? "")
        _quantity = State(initialValue: asset.map { $0.quantity > 0 ? Fmt.trimNumber($0.quantity) : "" } ?? "")
        _tradeRows = State(initialValue: asset?.recentTrades.map(TradeRow.init) ?? [])
        _currency = State(initialValue: asset?.currency ?? "KRW")
        _auto = State(initialValue: asset?.autoPriced ?? false)
        _unitPriceKRW = State(initialValue: asset?.unitPriceKRW ?? 0)
        _lastPriced = State(initialValue: asset?.lastPriced)
        _incomeKind = State(initialValue: asset?.incomeKind ?? IncomeKind.suggested(for: cls))
        _monthlyIncome = State(initialValue: asset.map { $0.monthlyIncome > 0 ? String(Int($0.monthlyIncome)) : "" } ?? "")
        _annualYieldPct = State(initialValue: asset.map { $0.annualYieldPct > 0 ? Fmt.trimNumber($0.annualYieldPct) : "" } ?? "")
        _depositReceived = State(initialValue: asset.map { $0.depositReceived > 0 ? String(Int($0.depositReceived)) : "" } ?? "")
        _depositLiquid = State(initialValue: asset?.depositLiquid ?? true)
        _costBasis = State(initialValue: asset.map { $0.costBasis > 0 ? String(Int($0.costBasis)) : "" } ?? "")
        _realEstateUse = State(initialValue: asset?.realEstateUse ?? .residence)
        _liquidity = State(initialValue: asset?.liquidity ?? Liquidity.suggested(for: cls))
        _sellTarget = State(initialValue: asset.map { $0.sellTargetPrice > 0 ? String(Int($0.sellTargetPrice)) : "" } ?? "")
        _stopPct = State(initialValue: asset?.trailingStopPct ?? 10)
        _detailDrafts = State(initialValue: (asset?.sortedDetails ?? []).map {
            DetailDraft(name: $0.name, amount: $0.amount > 0 ? String(Int($0.amount)) : "")
        })
    }

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    // This holding's value at each past record, stitched by catalog key.
    private var history: [(date: Date, amount: Double)] {
        guard let key = asset?.key else { return [] }
        return snapshots.compactMap { snap -> (Date, Double)? in
            guard let entry = snap.entryList.first(where: { $0.catalogKey == key }) else { return nil }
            return (snap.date, entry.amount)
        }
        .sorted { $0.0 < $1.0 }
        .map { (date: $0.0, amount: $0.1) }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 데모를 보는 중엔 여기 넣은 게 데모와 함께 사라진다 — 넣기 전에 알린다.
                if demoActive {
                    Section {
                        Label("지금은 데모 데이터를 보는 중이에요. 여기서 추가·수정한 내용은 데모를 끄면 사라져요. 내 자산은 맨 위 배너에서 데모를 끈 뒤 넣어 주세요.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.negative)
                    }
                }
                // 주식·코인·부동산은 티커·종목코드를 가장 먼저 입력 — 입력하면 이름이
                // 자동으로 채워지고 시세 자동도 켜진다. (그 외 종류는 아무것도 안 보임)
                tickerSection

                Section("기본 정보") {
                    if lockedClass {
                        // 그룹에서 들어옴 — 종류는 고정, 현재 그룹 합계를 컨텍스트로.
                        HStack {
                            Text(lockedTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(hexCode: assetClass.colorHex))
                            Spacer()
                            if let t = classTotal, t != 0 {
                                Text("현재 \(Fmt.krw(t))원")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    } else {
                        Picker("종류", selection: $assetClass) {
                            ForEach(AssetClass.allCases) { ac in Text(ac.label).tag(ac) }
                        }
                        .onChange(of: assetClass) { _, newValue in
                            if !newValue.supportsAutoPrice { auto = false }
                            liquidity = Liquidity.suggested(for: newValue)
                            // 종류가 바뀌면 그 종류에 맞는 소득 유형으로 정렬.
                            let kinds = newValue == .realEstate ? [IncomeKind.rent] : newValue.incomeKinds
                            if !kinds.contains(incomeKind) {
                                incomeKind = kinds.contains(IncomeKind.suggested(for: newValue))
                                    ? IncomeKind.suggested(for: newValue)
                                    : (kinds.first ?? .none)
                            }
                        }
                        if assetClass == .custom {
                            TextField("종류 직접 입력 (예: 회원권, 한정판, 사업 지분)", text: $customLabel)
                        }
                    }
                    TextField(namePlaceholder, text: $name)
                }

                // 세부 종목 — 평가액을 종목별로 쪼개 할당 (부채 제외).
                // 눈에 잘 띄도록 기본 정보 바로 다음, 최상단에 노출.
                if showAdvanced && !isDebt {
                    detailSection
                }

                if showAdvanced && assetClass == .realEstate {
                    Section {
                        Picker("이용 형태", selection: $realEstateUse) {
                            ForEach(RealEstateUse.allCases) { use in
                                Label(use.label, systemImage: use.icon).tag(use)
                            }
                        }
                        .onChange(of: realEstateUse) { _, newValue in
                            if newValue.hasRent { incomeKind = .rent }
                            // 전세·반전세는 지분이 묶이고 보증금만 유동 → 지분을 묶임으로.
                            if newValue.hasDeposit { liquidity = .locked }
                        }
                    } header: {
                        Text("이용 형태")
                    } footer: {
                        Text(realEstateUseHint)
                            .font(.caption)
                    }
                }

                // 유동성(쓸 수 있는 돈 ↔ 묶인 돈) 토글은 기본 노출 — 자주 바꾸는 값이라
                // 세부 설정을 펼치지 않아도 보이게 한다. 전세·반전세(보증금 자동 분리)만 숨김.
                if !isDebt && !(assetClass == .realEstate && realEstateUse.hasDeposit) {
                    Section {
                        Picker("유동성", selection: $liquidity) {
                            ForEach(Liquidity.allCases) { l in Text(l.label).tag(l) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("쓸 수 있는 돈인가요?")
                    } footer: {
                        Text(liquidity == .liquid
                             ? "현금화해서 바로 쓸 수 있는 자산입니다. ‘쓸 수 있는 돈’에 포함됩니다."
                             : "실거주 부동산·연금·보험처럼 당장 쓸 수 없는 자산입니다. 총자산엔 잡히지만 ‘쓸 수 있는 돈’에서는 빠집니다.")
                            .font(.caption)
                    }
                }

                // 티커를 넣었거나 세부 설정을 펼치면 시세 자동(수량·불러오기)을 노출.
                if assetClass.supportsAutoPrice && (showAdvanced || !symbol.isEmpty) {
                    Section {
                        Toggle(isOn: $auto) {
                            Label("시세 자동", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tint(Theme.accent)
                        if auto {
                            quantityInputs
                            fetchControls
                        }
                    } header: {
                        Text("시세")
                    } footer: {
                        if auto { Text(autoHint).font(.caption) }
                    }
                }

                Section(isDebt ? "남은 빚" : "평가액") {
                    if auto {
                        HStack {
                            Text("현재 평가액")
                            Spacer()
                            Text("\(Fmt.krw(Double(amount) ?? 0))원")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        if !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(failed ? Theme.negative : Theme.textSecond)
                        }
                    } else {
                        TextField(isDebt ? "남은 대출 잔액 (원)" : "금액 (원)", text: $amount.commaGrouped)
                            .keyboardType(.numberPad)
                        // 타이핑 대신 좌우 스와이프로 금액을 조절 — 5,000만 → 2,500만
                        // 같은 굵직한 변경을 몇 번 미는 걸로 끝낸다.
                        AmountScrubber(value: $amount)
                        if let v = Double(amount), v > 0 {
                            Text(isDebt ? "순자산에서 −\(Fmt.krwBoth(v)) 차감됩니다."
                                        : "= \(Fmt.krwBoth(v))")
                                .font(.caption)
                                .foregroundStyle(isDebt ? Theme.negative : Theme.textSecond)
                        }
                    }
                    portfolioShareReadout
                }

                // 투자 자산(주식·펀드·코인·부동산 등)은 구매가격(투자 원금)을 기본 노출.
                // 평가액과 따로 관리하고, 평가 손익을 자동 계산한다.
                if !isDebt && assetClass.tracksCostBasis {
                    costBasisSection
                }

                // 주식·펀드·코인은 매매 원장을 둔다 — 언제 몇 주를 얼마에 샀는지
                // 한 줄씩 남기면 보유 수량·투자 원금·평단이 거기서 계산된다.
                if asset != nil && supportsBuyMore {
                    tradeSection
                }

                // 살 때 정하는 매도 원칙 — 목표가·고점 대비 하락. 닿으면 팔라고 알린다.
                if SellWatch.supports(assetClass) {
                    sellRuleSection
                }

                // 간단 입력(새 자산 기본): 여기까지만 — 종류·이름·금액이면 끝.
                // 나머지는 종류별 기본값이 자동 적용되고, 펼치면 모두 입력 가능.
                if !showAdvanced {
                    Section {
                        Button {
                            withAnimation { showAdvanced = true }
                        } label: {
                            HStack {
                                Label("세부 설정 입력", systemImage: "slider.horizontal.3")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecond)
                            }
                        }
                    } footer: {
                        Text(isDebt
                             ? "월 이자·상환액은 ‘세부 설정’에서 입력할 수 있어요."
                             : "유동성·소득·시세 자동 등은 종류에 맞게 자동 설정돼요. 바꾸고 싶을 때만 펼치면 됩니다. 저장 후 자산을 눌러도 수정할 수 있어요.")
                            .font(.caption)
                    }
                } else if isDebt {
                    debtInterestSection
                } else if assetClass == .realEstate {
                    // 부동산은 이용형태에 따라 보증금/월세가 갈린다. (구매가격은 위에 노출됨)
                    if realEstateUse.hasDeposit { depositSection }
                    if realEstateUse.hasRent { incomeSection }
                } else {
                    // 소득/현금흐름만. (구매가격은 위에서 이미 노출됨)
                    if !availableIncomeKinds.isEmpty { incomeSection }
                }

                if !history.isEmpty {
                    Section("이 자산의 추이") {
                        historyChart
                    }
                }

                if asset != nil {
                    Section {
                        Button("이 자산 삭제", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("이 자산을 지울까요?", isPresented: $confirmingDelete,
                                                titleVisibility: .visible) {
                                Button("자산 삭제", role: .destructive) { deleteAsset() }
                                Button("취소", role: .cancel) {}
                            } message: {
                                Text("매매 내역도 함께 지워져요. 지난 기록은 남습니다. 되돌릴 수 없어요.")
                            }
                    }
                }
            }
            .navigationTitle(asset == nil
                             ? (lockedClass ? "\(lockedTitle) 추가" : "자산 추가")
                             : "자산 편집")
            .navigationBarTitleDisplayMode(.inline)
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .task { await autofillDividendIfNeeded() }
            .proPaywall($paywallFeature)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save() } }
            }
        }
    }

    // 티커가 있는 주식·ETF인데 배당이 아직 없으면, 편집기를 열 때 배당률을 자동 조회해
    // 채운다(저장하면 반영). 단가는 저장된 시세, 없으면 평가액÷수량으로 추정.
    private func autofillDividendIfNeeded() async {
        guard assetClass == .stocks || assetClass == .fund,
              !symbol.trimmingCharacters(in: .whitespaces).isEmpty,
              (Double(monthlyIncome) ?? 0) == 0,
              (Double(annualYieldPct) ?? 0) == 0 else { return }
        let qty = Double(quantity) ?? 0
        let unit = unitPriceKRW > 0 ? unitPriceKRW : (qty > 0 ? (Double(amount) ?? 0) / qty : 0)
        guard unit > 0,
              let perShare = try? await PriceService.annualDividendKRWPerShare(
                assetClass: assetClass, symbol: symbol, currency: currency),
              perShare > 0 else { return }
        let yieldPct = perShare / unit * 100
        guard yieldPct > 0 else { return }
        incomeKind = .dividend
        annualYieldPct = Fmt.trimNumber(yieldPct)
    }

    private var namePlaceholder: String {
        switch assetClass {
        case .stocks:     return String(localized: "이름 (예: 삼성전자, Apple)")
        case .fund:       return String(localized: "이름 (예: KODEX 200, SPY)")
        case .crypto:     return String(localized: "이름 (예: 비트코인)")
        case .realEstate: return String(localized: "아파트명 (예: 래미안)")
        case .jeonse:     return String(localized: "이름 (예: 우리집 전세)")
        case .pension:    return String(localized: "이름 (예: 국민연금, IRP)")
        case .debt:       return String(localized: "이름 (예: 주택담보대출, 신용대출)")
        default:          return String(localized: "이름")
        }
    }

    private var isDebt: Bool { assetClass == .debt }

    // 이 자산과 같은 편(자산/부채)에서, 편집 중인 자산을 뺀 나머지 합.
    private var otherSameSideTotal: Double {
        allAssets
            .filter { $0.isDebt == isDebt && $0.key != asset?.key }
            .reduce(0) { $0 + abs($1.netValue) }
    }

    // 입력 중인 금액이 전체(자산 또는 부채)에서 차지하는 금액·비중을 실시간 표시.
    @ViewBuilder
    private var portfolioShareReadout: some View {
        let thisAmount = abs(Double(amount) ?? 0)
        let others = otherSameSideTotal
        let total = others + thisAmount
        let pct = total > 0 ? thisAmount / total : 0
        let sideLabel = isDebt ? String(localized: "전체 부채") : String(localized: "전체 자산")
        let tint = isDebt ? Theme.negative : Theme.accent
        HStack {
            Text("현재 \(sideLabel)")
                .font(.caption).foregroundStyle(Theme.textSecond)
            Spacer()
            Text("\(Fmt.krw(others))원")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        if thisAmount > 0 {
            HStack {
                Text("이 자산 포함 시")
                    .font(.caption).foregroundStyle(Theme.textSecond)
                Spacer()
                Text("\(Fmt.krw(thisAmount))원 · \(sideLabel)의 \(Fmt.percent(pct, fraction: 1))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(tint)
                        .frame(width: max(2, geo.size.width * min(pct, 1)))
                }
            }
            .frame(height: 6)
        }
    }

    // 고정된 종류의 표시명 — 직접 입력이면 사용자 라벨.
    private var lockedTitle: String {
        assetClass == .custom && !customLabel.isEmpty ? customLabel : assetClass.label
    }

    private var realEstateUseHint: String {
        switch realEstateUse {
        case .residence:  return String(localized: "내가 사는 집입니다. 현금흐름 없이 평가액만 잡힙니다.")
        case .jeonse:     return String(localized: "전세를 줬습니다. 받은 보증금은 현금(유동)으로 인식됩니다.")
        case .wolse:      return String(localized: "월세를 줬습니다. 매달 월세가 현금흐름으로 잡힙니다.")
        case .semiJeonse: return String(localized: "반전세입니다. 보증금(현금) + 월세(현금흐름) 둘 다 입력하세요.")
        }
    }

    private var autoHint: String {
        switch assetClass {
        case .crypto:        return String(localized: "업비트 시세로 자동 계산됩니다 (키 불필요).")
        case .stocks, .fund: return currency == "USD" ? String(localized: "Finnhub 시세 + 실시간 환율로 환산합니다.") : String(localized: "Yahoo Finance 시세로 계산합니다 (키 불필요).")
        case .realEstate:    return String(localized: "법정동코드 + 아파트명으로 국토부 최근 실거래가를 조회합니다.")
        default:          return ""
        }
    }

    // Live preview of monthly cash flow from the editor's current inputs.
    private var previewMonthlyIncome: Double {
        let direct = Double(monthlyIncome) ?? 0
        if direct > 0 { return direct }
        let yield = Double(annualYieldPct) ?? 0
        let value = Double(amount) ?? 0
        if yield > 0 { return value * yield / 100 / 12 }
        return 0
    }

    // 부채가 매달 가져가는 돈 (이자/상환). 월 직접 입력 또는 연 이자율 × 잔액.
    private var debtInterestSection: some View {
        Section {
            TextField("월 이자/상환액 (원)", text: $monthlyIncome.commaGrouped)
                .keyboardType(.numberPad)
            TextField("또는 연 이자율 (%)", text: $annualYieldPct)
                .keyboardType(.decimalPad)
            if previewMonthlyIncome > 0 {
                HStack {
                    Text("매달 빠져나가는 돈")
                    Spacer()
                    Text("−\(Fmt.krw(previewMonthlyIncome))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.negative)
                }
                Text("연 −\(Fmt.wonKo(previewMonthlyIncome * 12))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        } header: {
            Text("이자 / 상환 (매달 나가는 돈)")
        } footer: {
            Text("매달 갚는 이자(또는 원리금)를 넣으면 ‘부채가 가져가는 돈’으로 현금흐름에 반영됩니다.")
                .font(.caption)
        }
    }

    // 취득가 대비 평가 차익 — 자산이 값이 올라서 만든 부가가치.
    private var costBasisSection: some View {
        Section {
            if hasTrades {
                // 매매 내역이 진실의 원천 — 원금은 거기서 나온 값이라 직접 수정 금지.
                HStack {
                    Text("투자 원금")
                    Spacer()
                    Text("\(Fmt.krw(Double(costBasis) ?? 0))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            } else {
                TextField("투자 원금 (산 가격, 원)", text: $costBasis.commaGrouped)
                    .keyboardType(.numberPad)
                MoneyReadout(amount: costBasis)
            }
            if let cb = Double(costBasis), cb > 0 {
                let cur = Double(amount) ?? 0
                HStack {
                    Text("현재 평가액")
                    Spacer()
                    Text("\(Fmt.krw(cur))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                let g = cur - cb
                HStack {
                    Text("평가 손익")
                    Spacer()
                    Text("\(g >= 0 ? "+" : "-")\(Fmt.krw(abs(g)))원 (\(g >= 0 ? "+" : "-")\(Fmt.percent(abs(g / cb), fraction: 1)))")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(g >= 0 ? Theme.positive : Theme.negative)
                }
            }
        } header: {
            Text("투자 원금 · 평가 손익")
        } footer: {
            Text(hasTrades
                 ? "투자 원금과 보유 수량은 아래 ‘매매 내역’에서 자동으로 계산돼요. 평가액은 시세나 위 ‘평가액’ 칸을 따르고, 둘의 차이가 평가 손익입니다."
                 : "투자 원금(산 가격)은 그대로 두고, 평가액은 시세에 따라 바뀝니다. 둘의 차이가 평가 손익이에요. 평가액은 위 ‘평가액’ 칸 또는 시세 자동으로 갱신돼요.")
                .font(.caption)
        }
    }

    // --- 매도 원칙 ---
    private var avgBuyPrice: Double {
        if hasTrades { return ledger.avgPrice }
        let q = Double(quantity) ?? 0
        let cb = Double(costBasis) ?? 0
        return q > 0 && cb > 0 ? cb / q : 0
    }

    private var sellRuleSection: some View {
        Section {
            TextField("이 가격이 되면 판다 (1\(buyUnitLabel)당, 원)", text: $sellTarget.commaGrouped)
                .keyboardType(.numberPad)
            if let t = Double(sellTarget), t > 0 {
                let avg = avgBuyPrice
                let cur = unitPriceKRW
                Text([avg > 0 ? String(localized: "평단보다 \(t >= avg ? "+" : "−")\(Fmt.percent(abs(t / avg - 1), fraction: 1))") : nil,
                      cur > 0 ? String(localized: "지금 \(Fmt.krw(cur))원") : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            Picker("고점에서 빠지면 팔기", selection: $stopPct) {
                ForEach(SellWatch.stopChoices, id: \.self) { p in
                    Text(p == 0 ? "알리지 않음" : "\(Fmt.trimNumber(p))% 빠지면").tag(p)
                }
            }
            if let a = asset, a.peakUnitPrice > 0, stopPct > 0 {
                HStack {
                    Text("지금까지 고점")
                    Spacer()
                    Text("\(Fmt.krw(a.peakUnitPrice))원 · \(Fmt.krw(a.peakUnitPrice * (1 - stopPct / 100)))원 아래면 알림")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                }
            }
            if !auto {
                Label("시세 자동을 켜야 알림이 와요. 위에서 종목코드·티커를 넣어 주세요.",
                      systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
            }
        } header: {
            Text("매도 원칙")
        } footer: {
            Text("오를 땐 알리지 않아요. 고점에서 정한 만큼 빠지거나 목표가에 닿으면 ‘지금 팔 때’라고 알려 드려요. 앱을 열 때와, 앱이 쉬는 동안 iOS가 허락할 때(보통 몇 시간 간격) 시세를 확인해요 — 실시간 감시는 아니에요.")
                .font(.caption)
        }
    }

    // --- 매매 원장 (언제 몇 주를 얼마에 샀는지) ---
    private var supportsBuyMore: Bool {
        assetClass == .stocks || assetClass == .fund || assetClass == .crypto
    }

    private var buyUnitLabel: String { assetClass == .crypto ? String(localized: "개") : String(localized: "shares.unit", defaultValue: "주") }

    // 편집 중인 원장을 재생한 결과 — 보유 수량·투자 원금·평단·실현손익.
    private var ledger: TradeLedger { TradeLedger.replay(tradeRows) }
    private var hasTrades: Bool { !tradeRows.isEmpty }

    // 입력 중인 거래의 금액 — 수량 × 단가가 있으면 그 곱, 없으면 직접 입력한 금액.
    private var tradeAmount: Double {
        let q = Double(tradeQty) ?? 0
        let p = Double(tradePrice) ?? 0
        if q > 0, p > 0 { return q * p }
        return Double(tradeAmountText) ?? 0
    }

    private var tradeSection: some View {
        Section {
            if hasTrades {
                let l = ledger
                HStack {
                    Text("지금 보유")
                    Spacer()
                    Text(l.quantity > 0
                         ? "\(Fmt.trimNumber(l.quantity))\(buyUnitLabel) · 평단 \(Fmt.krw(l.avgPrice))원"
                         : "없음 (전량 매도)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                HStack {
                    Text("투자 원금")
                    Spacer()
                    Text("\(Fmt.krw(l.costBasis))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                if l.realized != 0 {
                    HStack {
                        Text("실현 손익")
                        Spacer()
                        Text("\(l.realized >= 0 ? "+" : "−")\(Fmt.krw(abs(l.realized)))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(l.realized >= 0 ? Theme.positive : Theme.negative)
                    }
                }
            }

            // 최근 거래가 위로. 스와이프로 삭제.
            ForEach(tradeRows.sorted { $0.date > $1.date }) { row in
                Button { beginEditing(row) } label: { tradeRowView(row) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            tradeRows.removeAll { $0.id == row.id }
                        } label: { Label("삭제", systemImage: "trash") }
                    }
            }

            if !pro.gate.allows(ProFeature.tradeLedger.rawValue) {
                // 무료 — 이미 적힌 거래는 보고 지울 수 있지만, 새 거래는 프로에서.
                Button {
                    AppUsage.log(.paywallShown)
                    paywallFeature = .tradeLedger
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("매매 원장은 프로 기능이에요", systemImage: "lock.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(ProFeature.tradeLedger.leeoDetail)
                            .font(.body)
                            .foregroundStyle(Theme.textSecond)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if showTradeForm {
                tradeForm
            } else {
                Button {
                    tradeDate = Date()
                    withAnimation { showTradeForm = true }
                } label: {
                    Label("거래 추가", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            // 원장을 처음 쓰기 시작할 때 — 이미 들고 있던 몫을 한 줄로 옮겨 담는다.
            if pro.gate.allows(ProFeature.tradeLedger.rawValue),
               !hasTrades, openingQuantity > 0 || openingCost > 0 {
                Button {
                    seedOpeningTrade()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("지금 보유분을 ‘최초 매수’로 넣기", systemImage: "tray.and.arrow.down.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(openingSummary)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
            }
        } header: {
            Text("매매 내역")
        } footer: {
            if hasTrades {
                Text(currency == "USD"
                     ? "금액은 원화 환산으로 넣으세요. 보유 수량·투자 원금·평단은 이 내역에서 자동으로 계산됩니다(평균단가법)."
                     : "보유 수량·투자 원금·평단은 이 내역에서 자동으로 계산됩니다(평균단가법). 평가액은 시세나 위 ‘평가액’ 칸을 따릅니다.")
                    .font(.caption)
            } else {
                Text("살 때마다 한 줄씩 남겨두면 지금 몇 \(buyUnitLabel)인지, 언제 얼마에 샀는지 그대로 남아요.")
                    .font(.caption)
            }
        }
    }

    private func tradeRowView(_ row: TradeRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.tradeDateText(row.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(row.quantity > 0
                     ? "\(row.kind.label) \(Fmt.trimNumber(row.quantity))\(buyUnitLabel) · \(buyUnitLabel)당 \(Fmt.krw(row.unitPrice))원"
                     : "\(row.kind.label) · 금액만 기록")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
            Text("\(row.kind == .buy ? "+" : "−")\(Fmt.krw(row.amount))원")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(row.kind == .buy ? Theme.rise : Theme.fall)
        }
    }

    private var tradeForm: some View {
        Group {
            Picker("", selection: $tradeKind) {
                ForEach(TradeKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            DatePicker("날짜", selection: $tradeDate, displayedComponents: .date)
            TextField("수량 (\(buyUnitLabel))", text: $tradeQty)
                .keyboardType(.decimalPad)
            TextField("\(buyUnitLabel)당 단가 (원)", text: $tradePrice.commaGrouped)
                .keyboardType(.numberPad)
            // 수량·단가를 모르면 금액만 남겨도 된다(원금은 맞고 평단만 안 나옴).
            if (Double(tradeQty) ?? 0) <= 0 || (Double(tradePrice) ?? 0) <= 0 {
                TextField("또는 거래 금액만 (원)", text: $tradeAmountText.commaGrouped)
                    .keyboardType(.numberPad)
            }
            if tradeAmount > 0 {
                HStack {
                    Text("\(tradeKind.label) 금액")
                    Spacer()
                    Text("\(Fmt.krw(tradeAmount))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            HStack {
                Button {
                    withAnimation { resetTradeForm() }
                } label: {
                    Text("취소").font(.subheadline).foregroundStyle(Theme.textSecond)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    addTrade()
                } label: {
                    Label(editingTradeID == nil ? "기록" : "수정",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(tradeAmount <= 0)
            }
        }
    }

    private static func tradeDateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yyyyMMdd")
        return f.string(from: date)
    }

    // 원장을 쓰기 전부터 들고 있던 몫 — '최초 매수' 한 줄로 옮겨 담을 값.
    private var openingQuantity: Double { Double(quantity) ?? 0 }
    private var openingCost: Double {
        let cb = Double(costBasis) ?? 0
        return cb > 0 ? cb : (Double(amount) ?? 0)
    }
    private var openingSummary: String {
        let qty = openingQuantity > 0 ? "\(Fmt.trimNumber(openingQuantity))\(buyUnitLabel) · " : ""
        return String(localized: "\(qty)\(Fmt.krw(openingCost))원으로 시작한 걸로 남겨요 (날짜·금액은 나중에 고칠 수 있어요)")
    }

    private func seedOpeningTrade() {
        let cost = openingCost
        guard cost > 0 || openingQuantity > 0 else { return }
        withAnimation {
            tradeRows.append(TradeRow(date: asset?.createdAt ?? Date(), kind: .buy,
                                      quantity: openingQuantity, amount: cost))
        }
    }

    // 기존 거래를 눌렀을 때 — 그 값을 폼에 채워 수정 모드로 들어간다.
    private func beginEditing(_ row: TradeRow) {
        editingTradeID = row.id
        tradeKind = row.kind
        tradeDate = row.date
        tradeQty = row.quantity > 0 ? Fmt.trimNumber(row.quantity) : ""
        tradePrice = row.quantity > 0 ? String(Int(row.unitPrice.rounded())) : ""
        tradeAmountText = row.quantity > 0 ? "" : String(Int(row.amount.rounded()))
        withAnimation { showTradeForm = true }
    }

    // 거래 한 줄을 원장에 넣거나 고친다. 보유 수량·투자 원금은 원장을 다시 재생해 맞추고,
    // 평가액은 — 새 거래일 때만 — 시세 자동이면 수량 × 단가로, 아니면 거래 금액만큼 움직인다.
    // (지난 거래를 고칠 때 평가액까지 건드리면 지금 시세와 어긋나므로 그대로 둔다.)
    private func addTrade() {
        let cost = tradeAmount
        guard cost > 0 else { return }
        let qty = Double(tradeQty) ?? 0
        let isEditing = editingTradeID != nil
        withAnimation {
            if let id = editingTradeID, let idx = tradeRows.firstIndex(where: { $0.id == id }) {
                tradeRows[idx] = TradeRow(id: id, date: tradeDate, kind: tradeKind,
                                          quantity: qty, amount: cost)
            } else {
                tradeRows.append(TradeRow(date: tradeDate, kind: tradeKind,
                                          quantity: qty, amount: cost))
            }
        }

        let l = TradeLedger.replay(tradeRows)
        quantity = l.quantity > 0 ? Fmt.trimNumber(l.quantity) : ""
        costBasis = String(Int(l.costBasis.rounded()))
        if auto, unitPriceKRW > 0, l.quantity > 0 {
            amount = String(Int((l.quantity * unitPriceKRW).rounded()))
        } else if !isEditing {
            let delta = tradeKind == .buy ? cost : -cost
            amount = String(Int(max(0, (Double(amount) ?? 0) + delta).rounded()))
        }
        resetTradeForm()
    }

    private func resetTradeForm() {
        editingTradeID = nil
        tradeQty = ""
        tradePrice = ""
        tradeAmountText = ""
        tradeKind = .buy
        showTradeForm = false
    }

    // One-tap yield presets so dividends don't have to be entered won-by-won.
    // Selecting a chip sets the annual yield %, and the dividend is derived from
    // the (often auto-priced) value — no manual amount entry needed.
    private var yieldPresets: [(label: String, pct: Double)] {
        switch incomeKind {
        case .dividend:
            return [(String(localized: "코스피 2%"), 2), ("S&P500 1.5%", 1.5), (String(localized: "고배당 ETF 4.5%"), 4.5), (String(localized: "무배당 0%"), 0)]
        case .interest:
            return [(String(localized: "예금 3%"), 3), ("0%", 0)]
        case .staking:
            return [("ETH 3.5%", 3.5), ("0%", 0)]
        default:
            return []
        }
    }

    private func isSelectedPreset(_ pct: Double) -> Bool {
        (Double(monthlyIncome) ?? 0) == 0 && (Double(annualYieldPct) ?? -1) == pct
    }

    private var yieldPresetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(yieldPresets, id: \.label) { preset in
                    let selected = isSelectedPreset(preset.pct)
                    Button {
                        // Yield-driven: clear any direct amount so the % takes effect.
                        annualYieldPct = Fmt.trimNumber(preset.pct)
                        monthlyIncome = ""
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? Theme.accent.opacity(0.2) : Theme.surfaceHigh)
                            .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(selected ? Theme.accent.opacity(0.6) : Theme.hairline,
                                                 lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // 이 자산 종류가 만들 수 있는 소득 유형들. 부동산은 월세 전용.
    private var availableIncomeKinds: [IncomeKind] {
        assetClass == .realEstate ? [.rent] : assetClass.incomeKinds
    }

    // 소득 유형에 맞춘 입력 칸 이름.
    private var incomeAmountLabel: String {
        switch incomeKind {
        case .rent:     return String(localized: "월세 (원)")
        case .pension:  return String(localized: "월 연금 수령액 (원)")
        case .interest: return String(localized: "월 이자 (원)")
        case .dividend: return String(localized: "월 배당 (원)")
        case .staking:  return String(localized: "월 스테이킹 보상 (원)")
        default:        return String(localized: "월 소득 (원)")
        }
    }

    // 월세·배당·이자·연금·스테이킹 등 자산이 만들어내는 현금흐름.
    private var incomeSection: some View {
        Section {
            // 선택지가 둘 이상일 때만 유형 선택을 보여준다(연금·월세는 단일).
            if availableIncomeKinds.count > 1 {
                Picker("소득 유형", selection: $incomeKind) {
                    ForEach(availableIncomeKinds) { kind in Text(kind.label).tag(kind) }
                }
            }
            if incomeKind != .none {
                if !yieldPresets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(incomeKind == .interest ? "빠른 이자율 선택" : "빠른 배당률 선택")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecond)
                        yieldPresetChips
                    }
                }
                TextField(incomeAmountLabel, text: $monthlyIncome.commaGrouped)
                    .keyboardType(.numberPad)
                TextField("또는 연 수익률 (%)", text: $annualYieldPct)
                    .keyboardType(.decimalPad)
                if previewMonthlyIncome > 0 {
                    HStack {
                        Text("예상 현금흐름")
                        Spacer()
                        Text("월 \(Fmt.krw(previewMonthlyIncome))원 · 연 \(Fmt.krw(previewMonthlyIncome * 12))원")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.positive)
                    }
                }
            }
        } header: {
            Text("소득 / 현금흐름")
        } footer: {
            if incomeKind != .none, !incomeKind.yieldHint.isEmpty {
                Text("월 소득을 직접 넣거나 연 수익률(%)을 넣으면 평가액 기준으로 계산됩니다. 참고 수익률 — \(incomeKind.yieldHint)")
                    .font(.caption)
            }
        }
    }

    // --- 세부 종목 할당 ---
    private var detailAllocated: Double {
        detailDrafts.reduce(0) { $0 + (Double($1.amount) ?? 0) }
    }
    private var detailRemaining: Double { (Double(amount) ?? 0) - detailAllocated }

    // 평가액(예: 주식 3,000만원)을 종목별로 쪼개 할당하는 섹션. 합계와 남은
    // 금액을 보여줘서 3,000만 중 얼마가 어디에 들어가 있는지 한눈에 보인다.
    private var detailSection: some View {
        Section {
            ForEach($detailDrafts) { $d in
                HStack(spacing: 6) {
                    TextField("종목명", text: $d.name)
                    TextField("금액", text: $d.amount.commaGrouped)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .rounded))
                        .frame(maxWidth: 130)
                    Text("원").foregroundStyle(Theme.textSecond)
                }
            }
            .onDelete { detailDrafts.remove(atOffsets: $0) }

            // 새 종목 추가 행.
            HStack(spacing: 6) {
                TextField("종목 추가 (예: 삼성전자)", text: $newDetailName)
                TextField("금액", text: $newDetailAmount.commaGrouped)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .rounded))
                    .frame(maxWidth: 130)
                Button {
                    addDetailDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAddDetail ? Theme.accent : Theme.textSecond.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .disabled(!canAddDetail)
            }

            if !detailDrafts.isEmpty {
                HStack {
                    Text("할당 \(Fmt.krw(detailAllocated))원")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Spacer()
                    Text(detailRemaining >= 0
                         ? "남음 \(Fmt.krw(detailRemaining))원"
                         : "초과 \(Fmt.krw(-detailRemaining))원")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(detailRemaining >= 0 ? Theme.positive : Theme.negative)
                }
            }
        } header: {
            Text("세부 종목 (선택)")
        } footer: {
            if detailDrafts.isEmpty {
                Text("평가액을 종목별로 쪼개 관리할 수 있어요. 예) 주식 3,000만원 → 삼성전자 1,000만 + 애플 2,000만.")
                    .font(.caption)
            } else if detailRemaining < 0 {
                Text("종목 합계가 평가액보다 커요. 평가액을 올리거나 종목 금액을 줄여주세요.")
                    .font(.caption)
                    .foregroundStyle(Theme.negative)
            }
        }
    }

    private var canAddDetail: Bool {
        !newDetailName.trimmingCharacters(in: .whitespaces).isEmpty
            && (Double(newDetailAmount) ?? 0) > 0
    }

    private func addDetailDraft() {
        guard canAddDetail else { return }
        detailDrafts.append(DetailDraft(name: newDetailName.trimmingCharacters(in: .whitespaces),
                                        amount: newDetailAmount))
        newDetailName = ""
        newDetailAmount = ""
    }

    // 전세를 주고 받은 보증금 → 보유 현금(유동) + 부동산 지분(묶임)으로 분리 인식.
    private var depositSection: some View {
        Section {
            TextField("전세 보증금 (받은 금액, 원)", text: $depositReceived.commaGrouped)
                .keyboardType(.numberPad)
            if let dep = Double(depositReceived), dep > 0 {
                let value = Double(amount) ?? 0
                let cash = min(dep, value)
                let equity = value - cash
                Text("= \(Fmt.krwBoth(dep))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)

                Toggle("받은 보증금을 쓸 수 있는 돈(유동)에 포함", isOn: $depositLiquid)
                    .font(.subheadline)
                    .tint(Theme.accent)

                Text("이 자산의 구성")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                compositionRow(depositLiquid ? String(localized: "보유 현금 (유동)") : String(localized: "보유 현금 (묶임)"),
                               symbol: depositLiquid ? "banknote.fill" : "lock.fill",
                               value: cash,
                               tint: depositLiquid ? Theme.positive : Theme.textSecond)
                compositionRow(String(localized: "\(assetClass.label) 지분 (묶임)"),
                               symbol: "lock.fill", value: equity, tint: Theme.textSecond)
                HStack {
                    Text("총자산 기여")
                    Spacer()
                    Text("\(Fmt.krw(value))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("전세 보증금")
        } footer: {
            Text(depositLiquid
                 ? "받은 보증금은 언젠가 돌려줘야 하지만 지금은 현금으로 보유 중이라, 총자산은 평가액 그대로입니다. 단지 구성이 ‘현금 + 부동산 지분’으로 나뉘어, 실거주(전액 묶임)와 달리 쓸 수 있는 현금이 생깁니다."
                 : "보증금을 이미 다른 곳에 쓰셨다면 끄세요. 총자산(평가액)은 그대로지만, ‘쓸 수 있는 돈(유동)’에는 보증금이 포함되지 않습니다.")
                .font(.caption)
        }
    }

    private func compositionRow(_ title: String, symbol: String, value: Double, tint: Color) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.subheadline)
            Spacer()
            Text("\(Fmt.krw(value))원")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    // 티커·종목코드(선택) 섹션 — 넣으면 시세 자동을 켜고 현재가를 불러올 수 있다고 안내.
    @ViewBuilder
    private var tickerSection: some View {
        if assetClass.supportsAutoPrice {
            Section {
                switch assetClass {
                case .stocks, .fund:
                    Picker("시장", selection: $currency) {
                        Text("국내").tag("KRW")
                        Text("미국").tag("USD")
                    }
                    .pickerStyle(.segmented)
                    TextField(currency == "USD" ? "티커 (예: AAPL, SPY)" : "종목코드 6자리 (예: 005930, 069500)",
                              text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)   // 영문 티커·숫자 코드 모두 입력 가능
                        .focused($tickerFocused)
                case .crypto:
                    TextField("코인 심볼 (예: BTC)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .focused($tickerFocused)
                case .realEstate:
                    TextField("법정동코드 5자리 (예: 11680)", text: $symbol)
                        .keyboardType(.numberPad)
                default:
                    EmptyView()
                }
                if lookingUpName {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("이름 불러오는 중…").font(.caption).foregroundStyle(Theme.textSecond)
                    }
                }
            } header: {
                Text(assetClass == .realEstate ? "법정동코드 (선택)" : "티커 · 종목코드 (선택)")
            } footer: {
                Text(tickerHint).font(.caption)
            }
            .onChange(of: symbol) { _, new in
                // 코드가 채워지면 시세 자동을 켜서 현재가를 불러올 수 있게 한다.
                if !new.trimmingCharacters(in: .whitespaces).isEmpty { auto = true }
            }
            .onChange(of: tickerFocused) { _, focused in
                // 칸을 떠나면(blur) API로 종목 이름을 조회해 이름 칸을 채운다.
                if !focused { Task { await autofillName() } }
            }
        }
    }

    // 티커·종목코드로 이름을 조회해 이름 칸이 비어 있을 때만 채운다(사용자 입력은 보존).
    private func autofillName() async {
        let sym = symbol.trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty, name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lookingUpName = true
        defer { lookingUpName = false }
        if let n = try? await PriceService.lookupName(assetClass: assetClass, symbol: sym,
                                                      currency: currency,
                                                      finnhubKey: settings.finnhubKey),
           !n.isEmpty {
            name = n
        }
    }

    private var tickerHint: String {
        switch assetClass {
        case .stocks, .fund:
            return String(localized: "티커/종목코드(ETF 포함)를 먼저 넣고 칸을 벗어나면 이름이 자동으로 채워지고, ‘시세 자동’으로 현재가도 불러올 수 있어요. 미국=Finnhub, 국내=Yahoo. 비워두면 직접 입력합니다.")
        case .crypto:
            return String(localized: "코인 심볼을 넣고 칸을 벗어나면 이름이 자동으로 채워지고, 업비트 시세로 현재가를 자동 계산해요(키 불필요). 비워두면 직접 입력합니다.")
        case .realEstate:
            return String(localized: "법정동코드를 넣으면 국토부 최근 실거래가를 불러올 수 있어요. 비워두면 금액만 직접 입력합니다.")
        default:
            return ""
        }
    }

    // 시세 자동일 때 입력하는 수량(또는 부동산 안내). 티커·종목코드는 위 tickerSection.
    @ViewBuilder
    private var quantityInputs: some View {
        switch assetClass {
        case .crypto, .stocks, .fund:
            if hasTrades {
                // 매매 내역이 있으면 보유 수량은 그 합계다 — 직접 못 고치게 막고 근거를 보여준다.
                HStack {
                    Text(assetClass == .crypto ? "수량" : "보유 수량")
                    Spacer()
                    Text("\(quantity.isEmpty ? "0" : quantity)\(buyUnitLabel)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            } else if assetClass == .crypto {
                TextField("수량", text: $quantity)
                    .keyboardType(.decimalPad)
            } else {
                TextField("보유 수량 (주/좌)", text: $quantity)
                    .keyboardType(.decimalPad)
            }
        case .realEstate:
            Text("아파트명은 위 ‘이름’ 칸, 법정동코드는 위 칸을 사용합니다.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        default:
            EmptyView()
        }
    }

    private var fetchControls: some View {
        HStack {
            Button { Task { await fetch() } } label: {
                Label("시세 불러오기", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(fetching)
            Spacer()
            if fetching { ProgressView() }
        }
    }

    private var historyChart: some View {
        Chart(history, id: \.date) { point in
            LineMark(x: .value("월", point.date), y: .value("평가액", point.amount))
                .foregroundStyle(Theme.accent)
                .interpolationMethod(.catmullRom)
            AreaMark(x: .value("월", point.date), y: .value("평가액", point.amount))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
            PointMark(x: .value("월", point.date), y: .value("평가액", point.amount))
                .foregroundStyle(Theme.accent)
        }
        .chartYAxis(.hidden)
        .frame(height: 160)
    }

    private func fetch() async {
        fetching = true
        failed = false
        status = String(localized: "불러오는 중…")
        do {
            let qty = Double(quantity) ?? 0
            let result = try await PriceService.autoValue(
                assetClass: assetClass,
                symbol: symbol,
                name: name,
                quantity: qty,
                currency: currency,
                date: Date(),
                finnhubKey: settings.finnhubKey,
                kisAppKey: settings.kisAppKey,
                kisAppSecret: settings.kisAppSecret,
                dataGoKey: settings.dataGoKey
            )
            amount = String(Int(result.amount.rounded()))
            unitPriceKRW = result.unit
            lastPriced = Date()
            failed = false
            if assetClass == .realEstate {
                status = String(localized: "최근 실거래가 반영됨")
            } else {
                status = String(localized: "단가 \(Fmt.krw(result.unit))원 × \(quantity.isEmpty ? "0" : quantity)")
            }
            // 주식·ETF면 예상 배당을 '배당률'로 저장 — 평가액 기준으로 자동 계산되고
            // 평가액이 바뀌어도 따라간다. 사용자가 배당을 직접 안 넣었을 때만.
            if (assetClass == .stocks || assetClass == .fund), result.unit > 0,
               (Double(monthlyIncome) ?? 0) == 0 {
                if let perShare = try? await PriceService.annualDividendKRWPerShare(
                        assetClass: assetClass, symbol: symbol, currency: currency),
                   perShare > 0 {
                    let yieldPct = perShare / result.unit * 100
                    incomeKind = .dividend
                    annualYieldPct = Fmt.trimNumber(yieldPct)
                    status += String(localized: " · 예상 배당률 \(Fmt.trimNumber(yieldPct))% 반영")
                }
            }
        } catch {
            failed = true
            status = String(localized: "실패: \(error.localizedDescription)")
        }
        fetching = false
    }


    @discardableResult
    private func persist() -> Asset {
        // 저장 전에 갖고 있었나 — 다 팔았다가 다시 산 경우 고점을 새로 잡으려고.
        let heldBefore = (asset?.quantity ?? 0) > 0
        let target: Asset
        if let asset {
            target = asset
        } else {
            target = Asset(sortOrder: nextSortOrder)
            context.insert(target)
            AppUsage.log(.assetAdded)
        }
        target.name = name
        target.assetClass = assetClass
        // Keep the custom label only while 직접 입력 is the selected class.
        target.customLabel = assetClass == .custom ? customLabel : ""
        target.amount = Double(amount) ?? 0
        target.quantity = Double(quantity) ?? 0
        target.symbol = symbol
        target.currency = currency
        target.autoPriced = auto
        target.unitPriceKRW = unitPriceKRW
        target.lastPriced = lastPriced
        target.incomeKind = incomeKind
        target.monthlyIncome = Double(monthlyIncome) ?? 0
        target.annualYieldPct = Double(annualYieldPct) ?? 0
        target.depositReceived = Double(depositReceived) ?? 0
        target.depositLiquid = depositLiquid
        target.costBasis = Double(costBasis) ?? 0
        target.realEstateUse = realEstateUse
        target.liquidity = liquidity
        target.sellTargetPrice = SellWatch.supports(assetClass) ? (Double(sellTarget) ?? 0) : 0
        target.trailingStopPct = stopPct
        // For real estate, drop values that don't apply to the chosen use type
        // so a switched-away deposit/rent doesn't linger.
        if assetClass == .realEstate {
            if !realEstateUse.hasDeposit { target.depositReceived = 0 }
            if !realEstateUse.hasRent {
                target.monthlyIncome = 0
                target.annualYieldPct = 0
                target.incomeKind = .none
            }
        }
        // 세부 종목 동기화 — 드래프트를 통째로 다시 쓴다 (이름 있는 행만).
        // 입력칸에 적어두고 + 를 안 누른 채 저장해도 종목으로 들어가게 포함.
        var drafts = isDebt ? [] : detailDrafts
        if !isDebt, canAddDetail {
            drafts.append(DetailDraft(name: newDetailName.trimmingCharacters(in: .whitespaces),
                                      amount: newDetailAmount))
        }
        for old in target.detailList { context.delete(old) }
        target.details = drafts.enumerated().compactMap { idx, d in
            let nm = d.name.trimmingCharacters(in: .whitespaces)
            let amt = Double(d.amount) ?? 0
            guard !nm.isEmpty, amt > 0 else { return nil }
            return AssetDetail(name: nm, amount: amt, sortOrder: idx)
        }
        // 매매 원장 동기화 — 세부 종목과 같은 방식으로 통째로 다시 쓴다.
        for old in target.tradeList { context.delete(old) }
        target.trades = supportsBuyMore ? tradeRows.map { r in
            AssetTrade(date: r.date, kind: r.kind, quantity: r.quantity,
                       unitPrice: r.unitPrice, amount: r.amount)
        } : []
        if !target.tradeList.isEmpty { AppUsage.log(.tradeLogged) }
        // 원장이 있으면 보유 수량·투자 원금은 원장을 재생한 값이 진실.
        if supportsBuyMore, !tradeRows.isEmpty {
            let l = TradeLedger.replay(tradeRows)
            target.quantity = l.quantity
            target.costBasis = l.costBasis
        }
        // 다 팔았다가 다시 샀으면 예전 고점은 버리고 새로 잡는다.
        if !heldBefore && target.quantity > 0 {
            target.peakUnitPrice = 0
            target.stopAlertedPeak = 0
        }
        context.saveReporting(String(localized: "자산"))
        // 원칙을 걸었으면 알림 권한을 묻는다(이미 정했으면 조용히 지나감).
        if SellWatch.isWatched(target) {
            Task { await SellWatch.requestPermission() }
        }
        return target
    }

    private func save() {
        persist()
        dismiss()
    }

    private func deleteAsset() {
        if let asset { context.delete(asset) }
        context.saveReporting(String(localized: "자산"))
        dismiss()
    }
}

// 금액을 좌우 스와이프(드래그)로 조절하는 컨트롤 — 타이핑 없이 선택한 단위만큼
// 증감한다. 밀 때마다 값이 단위 배수로 스냅되어 5,000만 → 2,500만 같은 굵직한
// 변경이 몇 번의 스와이프로 끝난다.
struct AmountScrubber: View {
    @Binding var value: String   // 콤마 없는 숫자 문자열 (예: "50000000")

    private static let units: [(label: String, step: Double)] = [
        (String(localized: "1만"), 10_000), (String(localized: "10만"), 100_000), (String(localized: "100만"), 1_000_000), (String(localized: "1000만"), 10_000_000)
    ]
    // 사용자가 단위를 고르기 전엔 값 크기에 맞는 단위를 자동 선택.
    @State private var unitIndex: Int?
    // 룰러 상태 — 눈금의 시각적 오프셋과 드래그 증분·스텝 누적.
    @State private var phase: CGFloat = 0
    @State private var lastDragX: CGFloat = 0
    @State private var stepAccum: CGFloat = 0
    private let tickSpacing: CGFloat = 12

    private var numeric: Double { Double(value) ?? 0 }

    private var autoUnitIndex: Int {
        switch numeric {
        case ..<1_000_000:    return 0   // 100만 미만 → 1만
        case ..<30_000_000:   return 1   // 3천만 미만 → 10만
        case ..<300_000_000:  return 2   // 3억 미만 → 100만
        default:              return 3   // 그 이상 → 1000만
        }
    }
    private var currentUnitIndex: Int { unitIndex ?? autoUnitIndex }
    private var step: Double { Self.units[currentUnitIndex].step }

    var body: some View {
        VStack(spacing: 8) {
            ruler
            HStack(spacing: 6) {
                Text("단위")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                ForEach(Self.units.indices, id: \.self) { i in
                    let selected = currentUnitIndex == i
                    Button { unitIndex = i } label: {
                        Text(Self.units[i].label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Theme.accent.opacity(0.2) : Theme.surfaceHigh)
                            .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: value)
    }

    // 측정 테이프처럼 눈금이 손가락을 따라 흐르는 룰러 — 가운데 포인터가 기준점.
    // 오른쪽으로 밀면 증가, 왼쪽으로 밀면 감소. 눈금 한 칸에 한 단위씩, 칸마다 햅틱.
    private var ruler: some View {
        ZStack {
            Canvas { ctx, size in
                let mid = size.width / 2
                // 굵은 눈금(5칸 주기)이 이어져 보이도록 주기 단위로 오프셋을 순환.
                let period = tickSpacing * 5
                let shift = phase.truncatingRemainder(dividingBy: period)
                let count = Int(size.width / tickSpacing) + 12
                for k in (-count / 2)...(count / 2) {
                    let x = mid + CGFloat(k) * tickSpacing + shift
                    guard x >= 4, x <= size.width - 4 else { continue }
                    let isMajor = k % 5 == 0
                    let h: CGFloat = isMajor ? 18 : 10
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: (size.height - h) / 2))
                    line.addLine(to: CGPoint(x: x, y: (size.height + h) / 2))
                    // 가장자리로 갈수록 옅게 — 테이프가 계속 이어지는 느낌.
                    let edge = min(x, size.width - x) / (size.width / 2)
                    let alpha = 0.18 + 0.55 * Double(min(1, edge * 2.2))
                    ctx.stroke(line, with: .color(Theme.textSecond.opacity(alpha)),
                               lineWidth: isMajor ? 1.6 : 1)
                }
            }
            // 중앙 포인터 — 현재 값의 기준선.
            Capsule()
                .fill(Theme.accent)
                .frame(width: 3, height: 26)
                .shadow(color: Theme.accent.opacity(0.5), radius: 3)
            // 방향 힌트.
            HStack {
                Image(systemName: "chevron.compact.left")
                Spacer()
                Image(systemName: "chevron.compact.right")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecond.opacity(0.6))
            .padding(.horizontal, 8)
        }
        .frame(height: 46)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let delta = g.translation.width - lastDragX
                    lastDragX = g.translation.width
                    phase += delta
                    stepAccum += delta
                    while stepAccum >= tickSpacing { stepAccum -= tickSpacing; apply(deltaSteps: 1) }
                    while stepAccum <= -tickSpacing { stepAccum += tickSpacing; apply(deltaSteps: -1) }
                }
                .onEnded { _ in
                    lastDragX = 0
                    stepAccum = 0
                    // 눈금을 가장 가까운 칸에 스냅해 '딱' 멈춘 느낌으로.
                    withAnimation(.snappy(duration: 0.18)) {
                        phase = (phase / tickSpacing).rounded() * tickSpacing
                    }
                }
        )
    }

    // 현재 값을 단위 배수로 스냅한 뒤 스텝만큼 증감. 0 아래로는 내려가지 않는다.
    private func apply(deltaSteps: Int) {
        let snapped = (numeric / step).rounded() * step
        let next = max(0, snapped + Double(deltaSteps) * step)
        value = next > 0 ? String(Int(next.rounded())) : ""
    }
}

// A candidate holding read from a screenshot — editable before import.
struct ParsedHolding: Identifiable {
    let id = UUID()
    var name: String
    var amountText: String   // raw digits, shown comma-grouped
    // 손익(원)과 수익률(%) — 화면에 있으면 투자 원금(평가액 − 손익)을 채운다.
    var gain: Double? = nil
    var gainPct: Double? = nil
    // 이름이 '…'로 잘렸다 — 기존 종목과는 앞부분으로 맞추고, 새로 넣을 땐 고쳐 달라고 한다.
    var truncated = false
    // 평가액이 가려져 손익·수익률로 거꾸로 계산했다.
    var estimated = false
    var include: Bool = true

    var amount: Double { Double(amountText) ?? 0 }
}

// On-device OCR of a holdings screenshot → candidate rows. Uses Vision (no
// network, nothing leaves the device). Heuristic parsing, so the UI always lets
// the user correct/deselect before anything is saved.
//
// 두 가지 배치를 읽는다.
//  · 두 줄 배치(뱅크샐러드·토스 등) — 왼쪽 종목명, 오른쪽 위 평가액 "23,157,790원",
//    그 아래 손익 "▲ 2,363,961원(11.36%)". 화살표는 OCR이 엉뚱한 글자로 읽으므로
//    손익의 부호는 괄호 속 수익률에서 가져온다.
//  · 한 줄 배치 — 종목명과 금액이 한 줄에. 두 줄 배치로 하나도 못 읽었을 때만.
enum HoldingsOCR {
    private typealias Token = (text: String, box: CGRect)

    private static let numberRegex = try! NSRegularExpression(pattern: #"[0-9][0-9,]*(?:\.[0-9]+)?"#)
    private static let valueRegex = try! NSRegularExpression(pattern: #"^\s*([0-9][0-9,]*)\s*원\s*$"#)
    private static let changeRegex = try! NSRegularExpression(
        pattern: #"([0-9][0-9,]*)\s*원\s*\(\s*([+\-−]?[0-9]+(?:\.[0-9]+)?)\s*%\s*\)"#)
    // 종목명 자리에 걸리는 화면 글자들.
    private static let notNames: Set<String> = ["자산", "조회", "목표", "홈", "가계부", "건강보험",
                                                "금융쇼핑", "투자", "주식", "전체", "국내", "해외"]

    static func rows(from image: UIImage) -> [ParsedHolding] {
        guard let cg = image.cgImage else { return [] }
        var tokens: [Token] = []
        let request = VNRecognizeTextRequest { req, _ in
            for o in (req.results as? [VNRecognizedTextObservation]) ?? [] {
                if let s = o.topCandidates(1).first?.string { tokens.append((s, o.boundingBox)) }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        let paired = parsePaired(tokens)
        return paired.isEmpty ? parseSingleLine(tokens) : paired
    }

    /// 여러 장에서 읽은 줄을 합친다. 스크롤 캡처가 겹치면 같은 종목이 두 번 나오므로
    /// 이름과 평가액이 같은 줄은 하나만 남긴다.
    static func merge(_ batches: [[ParsedHolding]]) -> [ParsedHolding] {
        var out: [ParsedHolding] = []
        for row in batches.joined() {
            let dup = out.contains {
                normalized($0.name) == normalized(row.name) && abs($0.amount - row.amount) < 1
            }
            if !dup { out.append(row) }
        }
        return out
    }

    /// 이름 비교용 — 띄어쓰기·말줄임·대소문자를 지운다.
    static func normalized(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "." && $0 != "…" }
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "−", with: "-"))
    }

    // boundingBox origin is bottom-left, so a larger midY is higher up.
    private static func parsePaired(_ tokens: [Token]) -> [ParsedHolding] {
        let values = tokens.filter { $0.box.midX > 0.5 && match(valueRegex, $0.text) != nil }
        let changes = tokens.filter { match(changeRegex, $0.text) != nil }
        let names = tokens.filter { t in
            t.box.minX < 0.45 && t.box.midX < 0.55
                && t.text.rangeOfCharacter(from: .letters) != nil
                && match(valueRegex, t.text) == nil && match(changeRegex, t.text) == nil
                && !notNames.contains(t.text.trimmingCharacters(in: .whitespaces))
                && t.text.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) == nil
        }
        var out: [ParsedHolding] = []
        for v in values.sorted(by: { $0.box.midY > $1.box.midY }) {
            let lineH = v.box.height
            // 평가액 바로 아래 줄의 손익.
            let change = changes
                .filter { $0.box.midY < v.box.midY && v.box.midY - $0.box.midY < lineH * 2 }
                .max { $0.box.midY < $1.box.midY }
            let rowMid = change.map { (v.box.midY + $0.box.midY) / 2 } ?? v.box.midY
            guard let name = names
                .filter({ abs($0.box.midY - rowMid) < lineH * 1.6 })
                .min(by: { abs($0.box.midY - rowMid) < abs($1.box.midY - rowMid) })
            else { continue }

            var value = match(valueRegex, v.text).flatMap { number($0[0]) } ?? 0
            var gain: Double?
            var pct: Double?
            var estimated = false
            if let c = change, let g = match(changeRegex, c.text),
               let amt = number(g[0]), let p = number(g[1]) {
                pct = p
                gain = p < 0 ? -amt : amt
                // 버튼에 가려 평가액 앞자리가 잘리면 손익·수익률과 맞지 않는다 — 거꾸로 계산한다.
                if p != 0, p > -100 {
                    let cost = amt / abs(p / 100)
                    let implied = cost + (gain ?? 0)
                    if implied > 0, value == 0 || abs(implied - value) / implied > 0.05 {
                        value = implied.rounded()
                        estimated = true
                    }
                }
            }
            guard value > 0 else { continue }
            let raw = name.text.trimmingCharacters(in: .whitespaces)
            // 말줄임이 OCR에서 빠지기도 한다 — 이름 칸 끝까지 찬 이름도 잘린 것으로 본다.
            // 가려져 평가액을 계산한 줄은 이름도 가려졌을 수 있다.
            let truncated = raw.hasSuffix("…") || raw.hasSuffix("...") || raw.hasSuffix("..")
                || name.box.maxX >= 0.47 || estimated
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".… "))
            out.append(ParsedHolding(name: clean, amountText: String(Int(value)),
                                     gain: gain, gainPct: pct,
                                     truncated: truncated, estimated: estimated))
        }
        return out
    }

    // Group tokens that sit on the same visual line, then parse each line.
    private static func parseSingleLine(_ tokens: [Token]) -> [ParsedHolding] {
        guard !tokens.isEmpty else { return [] }
        let sorted = tokens.sorted { $0.box.midY > $1.box.midY }
        var lines: [[Token]] = []
        let rowGap: CGFloat = 0.015
        for t in sorted {
            if let ref = lines.last?.first, abs(ref.box.midY - t.box.midY) < rowGap {
                lines[lines.count - 1].append(t)
            } else {
                lines.append([t])
            }
        }
        return lines.compactMap { line in
            let text = line.sorted { $0.box.minX < $1.box.minX }
                .map(\.text).joined(separator: " ")
            return parseLine(text)
        }
    }

    private static func parseLine(_ line: String) -> ParsedHolding? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = numberRegex.matches(in: line, range: full)
        let numbers = matches.compactMap { m -> Double? in
            Double(ns.substring(with: m.range).replacingOccurrences(of: ",", with: ""))
        }
        // 평가액 ≈ the largest sizeable number on the line; small numbers are
        // share counts / percentages and are ignored.
        guard let amount = numbers.filter({ $0 >= 1000 }).max() else { return nil }

        // Name = the line with numbers and trailing symbols stripped out.
        var name = numberRegex.stringByReplacingMatches(in: line, range: full, withTemplate: " ")
        let junk = CharacterSet(charactersIn: "원%+-▲▼△▽()[]{}·,.\\/|").union(.decimalDigits)
        name = name.components(separatedBy: junk).joined(separator: " ")
        name = name.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // Require a real name (some letters, not just a stray number row).
        guard name.count >= 2, name.rangeOfCharacter(from: .letters) != nil else { return nil }

        return ParsedHolding(name: name, amountText: String(Int(amount)))
    }
}

// 캡처를 여러 장 고르면 읽어서 — 이미 있는 종목은 평가액·원금을 갱신하고,
// 없는 종목만 새로 넣는다. 캡처에 안 보인 기존 종목은 '판 종목'으로 고를 수 있다.
struct ScreenshotImportView: View {
    let startingSortOrder: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]

    // 줄마다 이름으로 찾은 종목코드 후보와 고른 것. chosen 이 nil 이면 코드 없이(수동 평가액) 넣는다.
    struct SymbolLookup {
        var candidates: [PriceService.SymbolCandidate] = []
        var chosen: PriceService.SymbolCandidate?
        var ambiguous = false
        var loading = true
    }
    @State private var lookups: [UUID: SymbolLookup] = [:]
    // 적용 중 — 코드를 붙인 종목의 시세를 받아 수량을 맞춘다. (n/전체)
    @State private var applyProgress: (done: Int, total: Int)?

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var rows: [ParsedHolding] = []
    @State private var processing = false
    @State private var didProcess = false
    @State private var loadError: String?
    @State private var imageCount = 0
    // 캡처에 없던 기존 종목 중 '팔았다'고 고른 것.
    @State private var soldKeys: Set<UUID> = []

    // 맞춰 볼 기존 종목 — 주식·펀드·코인.
    private var holdings: [Asset] {
        assets.filter { $0.assetClass == .stocks || $0.assetClass == .fund || $0.assetClass == .crypto }
    }

    /// 줄마다 맞는 기존 종목. 이름 앞부분이 같고(잘린 이름 대비), 같은 이름이 여럿이면
    /// 평가액이 가장 가까운 것. 한 종목은 한 줄에만 붙는다.
    private var matches: [UUID: Asset] {
        var out: [UUID: Asset] = [:]
        var used: Set<UUID> = []
        for row in rows where row.include {
            let stem = HoldingsOCR.normalized(row.name)
            guard stem.count >= 2 else { continue }
            let pick = holdings
                .filter { a in
                    let n = HoldingsOCR.normalized(a.name)
                    return !used.contains(a.key) && !n.isEmpty && (n.hasPrefix(stem) || stem.hasPrefix(n))
                }
                .min { abs($0.amount - row.amount) < abs($1.amount - row.amount) }
            if let pick {
                out[row.id] = pick
                used.insert(pick.key)
            }
        }
        return out
    }

    private var missing: [Asset] {
        let matched = Set(matches.values.map(\.key))
        return holdings.filter { !matched.contains($0.key) }
    }

    private var selected: [ParsedHolding] { rows.filter { $0.include && $0.amount > 0 } }

    private var applyLabel: String {
        let m = matches
        let upd = selected.filter { m[$0.id] != nil }.count
        let add = selected.count - upd
        var parts: [String] = []
        if upd > 0 { parts.append(String(localized: "갱신 \(upd)")) }
        if add > 0 { parts.append(String(localized: "추가 \(add)")) }
        if !soldKeys.isEmpty { parts.append(String(localized: "정리 \(soldKeys.count)")) }
        return parts.isEmpty ? String(localized: "적용") : parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let p = applyProgress {
                    VStack(spacing: 14) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).tint(Theme.accent)
                        Text("시세를 확인해 수량을 맞추는 중… \(p.done)/\(p.total)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecond)
                    }
                    .padding(40)
                } else if processing {
                    VStack(spacing: 14) {
                        ProgressView().tint(Theme.accent)
                        Text("이미지에서 종목을 읽는 중…")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecond)
                    }
                } else if didProcess {
                    reviewContent
                } else {
                    intro
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("캡처로 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                if didProcess, !rows.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(applyLabel) { Task { await apply() } }
                            .disabled((selected.isEmpty && soldKeys.isEmpty) || applyProgress != nil)
                    }
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await process(items) }
        }
    }

    private var picker: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .screenshots) {
            HStack {
                Image(systemName: "photo.on.rectangle")
                Text(didProcess ? "캡처 더 고르기" : "캡처 고르기 (여러 장)")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.accent)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var intro: some View {
        VStack(spacing: 22) {
            Image(systemName: "text.viewfinder")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text("보유 종목 캡처를 고르세요")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("뱅크샐러드·증권사 앱의 자산 목록을 스크롤하며 여러 장 캡처해 한 번에 고르면, 종목명·평가액·손익을 읽어 맞춥니다. 이미 있는 종목은 갱신하고 없는 것만 더해요. 이미지는 기기에서만 처리되고, 종목코드를 찾을 때 종목 이름만 네이버 증권에 물어봐요.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
            }
            picker
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.negative)
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private var reviewContent: some View {
        if rows.isEmpty {
            VStack(spacing: 18) {
                Image(systemName: "questionmark.viewfinder")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.textSecond)
                Text("종목을 읽지 못했어요")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("종목명과 금액이 잘 보이는 캡처로 다시 시도해 보세요.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                picker
            }
            .padding(28)
        } else {
            let m = matches
            List {
                Section {
                    ForEach($rows) { $row in
                        rowView($row, match: m[row.id])
                            .listRowBackground(Theme.surface)
                    }
                } header: {
                    Text("캡처 \(imageCount)장에서 \(rows.count)개 읽음 · 잘못된 건 끄거나 고치세요")
                } footer: {
                    Text("갱신은 평가액과 투자 원금(평가액 − 손익)을 바꿔요. 종목코드를 찾은 종목은 시세를 받아 수량을 평가액에 맞추고, 시세 자동과 매도 알림(고점 대비 10%)이 켜져요. 코드를 못 찾으면 평가액만 수동값으로 들어가요.")
                        .font(.caption)
                }

                if !missing.isEmpty {
                    Section {
                        ForEach(missing) { a in
                            Button {
                                if soldKeys.contains(a.key) { soldKeys.remove(a.key) } else { soldKeys.insert(a.key) }
                            } label: {
                                HStack {
                                    Image(systemName: soldKeys.contains(a.key) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(soldKeys.contains(a.key) ? Theme.negative : Theme.textSecond)
                                    Text(a.name).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(Fmt.krw(a.amount))원")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(Theme.textSecond)
                                }
                            }
                            .listRowBackground(Theme.surface)
                        }
                    } header: {
                        Text("캡처에 없는 기존 종목 \(missing.count)개")
                    } footer: {
                        Text("판 종목만 골라 주세요 — 고른 것은 자산에서 지워요. 캡처를 덜 찍어서 빠진 거라면 그대로 두면 됩니다.")
                            .font(.caption)
                    }
                }

                Section {
                    picker
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .keyboardDismissable()
        }
    }

    private func rowView(_ row: Binding<ParsedHolding>, match: Asset?) -> some View {
        let r = row.wrappedValue
        return HStack(alignment: .top, spacing: 10) {
            Button { row.wrappedValue.include.toggle() } label: {
                Image(systemName: r.include ? "checkmark.circle.fill" : "circle")
                    .font(.system(.title2))
                    .foregroundStyle(r.include ? Theme.accent : Theme.textSecond)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                TextField("종목명", text: row.name)
                    .font(.subheadline.weight(.semibold))
                    .submitLabel(.search)
                    .onSubmit { Task { await lookup([row.wrappedValue], force: true) } }
                HStack(spacing: 6) {
                    TextField("평가액", text: row.amountText.commaGrouped)
                        .keyboardType(.numberPad)
                        .font(.system(.subheadline, design: .rounded))
                    Text("원").foregroundStyle(Theme.textSecond)
                }
                if let g = r.gain, let p = r.gainPct {
                    Text("손익 \(g >= 0 ? "+" : "−")\(Fmt.krw(abs(g)))원 (\(Fmt.trimNumber(p))%)")
                        .font(.caption)
                        .foregroundStyle(g >= 0 ? Theme.positive : Theme.negative)
                }
                // 무엇을 할지 — 기존 종목 갱신인지, 새 종목인지.
                if let match {
                    Text("‘\(match.name)’ 갱신 · \(Fmt.krw(match.amount)) → \(Fmt.krw(r.amount))원")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                } else {
                    Text("새 종목으로 추가")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                if needsSymbol(r, match: match) { symbolLine(r) }
                if r.estimated {
                    Label("평가액이 가려져 손익·수익률로 계산했어요. 확인해 주세요.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                if r.truncated && match == nil && lookups[r.id]?.chosen == nil {
                    Label("이름이 잘렸어요. 전체 이름으로 고쳐 주세요.", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .opacity(r.include ? 1 : 0.4)
        }
    }

    private func process(_ items: [PhotosPickerItem]) async {
        processing = true
        loadError = nil
        defer {
            processing = false
            pickerItems = []
        }
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                images.append(img)
            }
        }
        guard !images.isEmpty else {
            loadError = String(localized: "이미지를 불러오지 못했습니다.")
            return
        }
        let batches = await Task.detached(priority: .userInitiated) {
            images.map { HoldingsOCR.rows(from: $0) }
        }.value
        // 이미 읽어 둔 줄 뒤에 이어 붙인다 — 캡처를 나눠 골라도 된다.
        rows = HoldingsOCR.merge([rows] + batches)
        imageCount += images.count
        didProcess = true
        await lookup(rows)
    }

    // 코드가 필요한 줄 — 새 종목이거나, 맞춘 기존 종목에 코드가 아직 없을 때.
    private func needsSymbol(_ r: ParsedHolding, match: Asset?) -> Bool {
        guard let match else { return true }
        return match.symbol.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 이름으로 종목코드를 찾는다(한꺼번에). 이미 찾은 줄은 건너뛴다(force 면 다시).
    private func lookup(_ targets: [ParsedHolding], force: Bool = false) async {
        let m = matches
        let todo = targets.filter { needsSymbol($0, match: m[$0.id]) && (force || lookups[$0.id] == nil) }
        for r in todo { lookups[r.id] = SymbolLookup() }
        await withTaskGroup(of: (UUID, SymbolLookup).self) { group in
            for r in todo {
                let name = r.name
                let value = r.amount
                let truncated = r.truncated
                group.addTask {
                    let cands = await PriceService.searchSymbols(name)
                    var best = PriceService.bestSymbol(for: name, in: cands, truncated: truncated)
                    if best.ambiguous, let byShares = await Self.pickByWholeShares(name: name, value: value, in: cands) {
                        best = (byShares, false)
                    }
                    return (r.id, SymbolLookup(candidates: Array(cands.prefix(8)), chosen: best.pick,
                                               ambiguous: best.ambiguous, loading: false))
                }
            }
            for await (id, result) in group { lookups[id] = result }
        }
    }

    /// 잘린 이름으로 국내 후보가 여럿일 때 — 국내 주식은 1주 단위로 사므로, 평가액 ÷ 지금 가격이
    /// 딱 떨어지는 후보가 하나뿐이면 그게 내 종목이다. 캡처가 오늘 것일수록 잘 맞는다.
    private static func pickByWholeShares(name: String, value: Double,
                                          in cands: [PriceService.SymbolCandidate]) async -> PriceService.SymbolCandidate? {
        let q = HoldingsOCR.normalized(name)
        let pool = cands.filter { !$0.isUS && HoldingsOCR.normalized($0.name).hasPrefix(q) }.prefix(6)
        guard pool.count > 1, value > 0 else { return nil }
        var hits: [PriceService.SymbolCandidate] = []
        for c in pool {
            guard let price = await PriceService.naverKRPrice(code: c.code), price > 0 else { continue }
            let shares = value / price
            // 소수부가 0.01주 안쪽이어야 '딱 떨어진다'. 캡처 뒤 값이 움직였으면 아무것도 안 맞고 사람이 고른다.
            if shares >= 1, abs(shares - shares.rounded()) < 0.01 { hits.append(c) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    @ViewBuilder
    private func symbolLine(_ r: ParsedHolding) -> some View {
        if let l = lookups[r.id] {
            if l.loading {
                Text("종목코드 찾는 중…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            } else if l.candidates.isEmpty {
                Label("종목코드를 못 찾았어요. 이름을 고치고 ‘검색’을 눌러 보세요.", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            } else {
                Menu {
                    ForEach(l.candidates) { c in
                        Button("\(c.name) · \(c.code) (\(c.market))") {
                            lookups[r.id]?.chosen = c
                            lookups[r.id]?.ambiguous = false
                        }
                    }
                    Button("코드 없이 넣기 (수동 평가액)", role: .destructive) {
                        lookups[r.id]?.chosen = nil
                        lookups[r.id]?.ambiguous = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: l.chosen == nil ? "minus.circle" : "checkmark.seal.fill")
                        Text(l.chosen.map { "\($0.code) · \($0.name)" } ?? "코드 없이 넣기")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(l.chosen == nil ? Theme.textSecond : Theme.positive)
                }
                if l.ambiguous {
                    Label("비슷한 종목이 \(l.candidates.count)개예요. 맞는지 눌러서 확인해 주세요.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private static let etfBrands = ["TIGER", "KODEX", "SOL", "ACE", "RISE", "KBSTAR", "ARIRANG",
                                    "HANARO", "PLUS", "KOSEF", "TIMEFOLIO", "WON", "1Q"]

    private func apply() async {
        let m = matches
        let settings = settingsList.first ?? FireSettings()
        var order = startingSortOrder
        let work = selected
        applyProgress = (0, work.count)
        for row in work {
            let value = row.amount
            let cost = row.gain.map { value - $0 }
            let pick = needsSymbol(row, match: m[row.id]) ? lookups[row.id]?.chosen : nil
            let target: Asset
            if let a = m[row.id] {
                target = a
            } else {
                let name = pick?.name ?? row.name.trimmingCharacters(in: .whitespaces)
                let upper = name.uppercased()
                let isETF = Self.etfBrands.contains { upper.hasPrefix($0 + " ") }
                target = Asset(name: name, assetClass: isETF ? .fund : .stocks,
                               incomeKind: .dividend, liquidity: .liquid, sortOrder: order)
                context.insert(target)
                order += 1
            }
            target.amount = value
            // 매매 원장이 있으면 원금·수량은 원장이 진실 — 건드리지 않는다.
            let ledgerOwned = target.hasTrades
            if !ledgerOwned, let cost, cost > 0 { target.costBasis = cost.rounded() }

            // 새로 찾은 코드를 붙이고 시세를 켠다.
            if let pick {
                target.symbol = pick.code
                target.currency = pick.currency
            }
            // 코드가 있으면 지금 시세로 수량을 평가액에 맞춘다 — 그래야 다음 시세 갱신이
            // 평가액을 엉뚱하게 덮어쓰지 않고, 매도 알림도 1주 가격을 안다.
            if !target.symbol.trimmingCharacters(in: .whitespaces).isEmpty,
               pick != nil || target.autoPriced,
               let unit = try? await PriceService.autoValue(
                   assetClass: target.assetClass, symbol: target.symbol, name: target.name,
                   quantity: 1, currency: target.currency, date: Date(),
                   finnhubKey: settings.finnhubKey, kisAppKey: settings.kisAppKey,
                   kisAppSecret: settings.kisAppSecret, dataGoKey: settings.dataGoKey).unit,
               unit > 0 {
                target.autoPriced = true
                target.unitPriceKRW = unit
                target.lastPriced = Date()
                if !ledgerOwned {
                    let q = value / unit
                    // 국내 주식은 1주 단위, 미국 주식·코인은 소수점 매수가 있어 넷째 자리까지.
                    target.quantity = target.currency == "KRW" && target.assetClass != .crypto
                        ? max(1, q.rounded()) : (q * 10_000).rounded() / 10_000
                }
                SellWatch.evaluate(target)
            }
            applyProgress = ((applyProgress?.done ?? 0) + 1, work.count)
        }
        for a in holdings where soldKeys.contains(a.key) {
            context.delete(a)
        }
        context.saveReporting(String(localized: "자산"))
        if order > startingSortOrder { AppUsage.log(.assetAdded) }
        applyProgress = nil
        if assets.contains(where: SellWatch.isWatched) { await SellWatch.requestPermission() }
        dismiss()
    }
}

// 돈을 숫자로 입력하면 곧바로 한글 단위(예: "= 3,600만원")로 echo 해서, 자릿수를
// 눈으로 확인할 수 있게 한다. 비었거나 0이면 아무것도 그리지 않는다.
struct MoneyReadout: View {
    let amount: String
    var body: some View {
        let v = Double(amount.filter { $0.isNumber }) ?? 0
        if v > 0 {
            Text("= \(Fmt.krw(v))원")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
    }
}

// Itemized basis for net worth — shows how each asset/debt contributes so the
// user can see exactly why 순자산 = 총자산(보유 자산 합) − 부채 lands where it does.
struct NetWorthBreakdownView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]

    private var positives: [Asset] { assets.filter { !$0.isDebt && $0.netValue != 0 } }
    private var debts: [Asset] { assets.filter { $0.isDebt && $0.amount != 0 } }
    private var grossAssets: Double { positives.reduce(0) { $0 + $1.netValue } }
    private var debtTotal: Double { debts.reduce(0) { $0 + $1.amount } }
    private var netWorth: Double { grossAssets - debtTotal }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("순자산").font(.headline)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Fmt.krw(netWorth))원")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(netWorth >= 0 ? Theme.accent : Theme.negative)
                        }
                    }
                    Text("순자산 = 총자산(\(Fmt.krw(grossAssets))원) − 부채(\(Fmt.krw(debtTotal))원)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                } footer: {
                    Text("아래에서 자산·부채가 각각 순자산에 얼마씩 더하고 빼는지 확인하세요. 빚을 1,100만 졌는데 순자산이 −600만이라면, 총자산(보유 자산 합)이 500만이라는 뜻이에요.")
                        .font(.caption)
                }

                Section {
                    if positives.isEmpty {
                        Text("등록된 자산이 없어요").font(.caption).foregroundStyle(Theme.textSecond)
                    }
                    ForEach(positives) { a in
                        breakdownRow(a, value: a.netValue, sign: "+", tint: Theme.positive)
                    }
                    subtotal(String(localized: "총자산"), grossAssets, tint: Theme.textPrimary)
                } header: {
                    Text("보유 자산 (+)")
                }

                if !debts.isEmpty {
                    Section {
                        ForEach(debts) { a in
                            breakdownRow(a, value: a.amount, sign: "−", tint: Theme.negative)
                        }
                        subtotal(String(localized: "부채 합계"), debtTotal, sign: "−", tint: Theme.negative)
                    } header: {
                        Text("부채 (−)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("순자산 내역")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
    }

    private func breakdownRow(_ a: Asset, value: Double, sign: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hexCode: a.assetClass.colorHex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name.isEmpty ? a.assetClass.label : a.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(a.assetClass == .realEstate ? "\(a.assetClass.label) · \(a.realEstateUse.label)" : a.assetClass.label)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
            Text("\(sign)\(Fmt.krw(abs(value)))원")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    private func subtotal(_ title: String, _ value: Double, sign: String = "+", tint: Color) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(sign)\(Fmt.krw(value))원")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - 매도 원칙 한눈에

// 상태 칩 — 팔 때(빨강) · 목표가(초록) · 준비/근처(주황) · 지켜보는 중(회색).
struct SellSignalChip: View {
    let signal: SellWatch.Signal
    var body: some View {
        Text(signal.label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
    private var tint: Color {
        switch signal {
        case .stopHit: return Theme.negative
        case .targetHit: return Theme.positive
        case .nearStop, .nearTarget: return .orange
        case .holding: return Theme.textSecond
        }
    }
}

// 고점에서 얼마나 빠졌는지를 기준선까지의 막대로 — 끝에 닿으면 팔 때.
struct DrawdownBar: View {
    let drawdown: Double     // 0.06
    let limit: Double        // 0.10
    var body: some View {
        let p = limit > 0 ? min(drawdown / limit, 1) : 0
        let tint: Color = p >= 1 ? Theme.negative : (p >= 0.7 ? .orange : Theme.textSecond.opacity(0.6))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textSecond.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: max(geo.size.height, geo.size.width * p))
                    .opacity(p > 0 ? 1 : 0)
            }
        }
        .frame(height: 6)
    }
}

// 매도 원칙을 정한 종목 한 줄 — 대시보드 카드와 전체 목록이 같이 쓴다.
struct SellSignalRow: View {
    let asset: Asset
    let status: SellWatch.Status
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(asset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                SellSignalChip(signal: status.signal)
                Spacer(minLength: 4)
                Text("\(Fmt.krw(status.price))원")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            if status.floor != nil {
                DrawdownBar(drawdown: status.drawdown, limit: asset.trailingStopPct / 100)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .lineLimit(2)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let floor = status.floor {
            let dd = Fmt.trimNumber((status.drawdown * 1000).rounded() / 10)
            switch status.signal {
            case .stopHit:
                parts.append(String(localized: "고점 \(Fmt.krw(status.peak))원에서 \(dd)% 빠져 기준(−\(Fmt.trimNumber(asset.trailingStopPct))%)을 넘었어요. 정한 대로 파세요"))
            default:
                let room = Fmt.trimNumber(((status.roomToFloor ?? 0) * 1000).rounded() / 10)
                parts.append(String(localized: "고점 대비 −\(dd)% · \(room)% 더 빠지면 팔 때(\(Fmt.krw(floor))원)"))
            }
        }
        if let target = status.target {
            if status.signal == .targetHit {
                parts.append(String(localized: "살 때 정한 목표가 \(Fmt.krw(target))원에 닿았어요"))
            } else {
                let up = Fmt.trimNumber(((status.toTarget ?? 0) * 1000).rounded() / 10)
                parts.append(String(localized: "목표가 \(Fmt.krw(target))원까지 +\(up)%"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// 매도 원칙 전체 — 급한 순서로. 누르면 그 종목의 원칙을 고친다.
struct SellSignalsView: View {
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @State private var editing: Asset?

    private var watched: [(Asset, SellWatch.Status)] {
        assets.compactMap { a in SellWatch.status(a).map { (a, $0) } }
            .sorted { l, r in
                l.1.signal != r.1.signal ? l.1.signal < r.1.signal
                    : (l.1.roomToFloor ?? 1) < (r.1.roomToFloor ?? 1)
            }
    }
    private var unwatchable: [Asset] { assets.filter(SellWatch.isUnwatchable) }

    var body: some View {
        List {
            Section {
                ForEach(watched, id: \.0.key) { a, st in
                    Button { editing = a } label: { SellSignalRow(asset: a, status: st) }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface)
                }
            } header: {
                Text("지켜보는 종목 \(watched.count)개")
            } footer: {
                Text("앱을 열 때와 가끔 백그라운드에서 시세를 확인해요. 실시간은 아니니 알림을 받으면 증권사 앱에서 지금 가격을 다시 보고 파세요. 오를 땐 알리지 않고 고점만 따라 올라가요.")
            }
            if !unwatchable.isEmpty {
                Section {
                    ForEach(unwatchable, id: \.key) { a in
                        Button { editing = a } label: {
                            HStack {
                                Text(a.name).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(a.symbol.isEmpty ? "종목 코드 없음" : "자동 시세 꺼짐")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecond)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface)
                    }
                } header: {
                    Text("시세를 몰라 지켜보지 못하는 종목")
                } footer: {
                    Text("종목 코드를 넣고 자동 시세를 켜면 원칙대로 알려 드려요.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("매도 원칙")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { a in
            AssetEditor(asset: a, nextSortOrder: assets.count)
        }
        .overlay {
            if watched.isEmpty && unwatchable.isEmpty {
                ContentUnavailableView("지켜보는 종목이 없어요",
                                       systemImage: "bell.slash",
                                       description: Text("주식·펀드·코인을 열어 ‘팔 원칙’을 정하면 여기에 모여요."))
            }
        }
    }
}

// 매도 원칙 요약 카드 — 대시보드와 자산 탭이 같이 쓴다.
// 눈여겨볼 종목이 있으면 그 종목을, 없으면 "지금은 없어요" 를 한 줄로 먼저 말한다.
struct SellWatchCard: View {
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]

    private var watched: [(Asset, SellWatch.Status)] {
        assets.compactMap { a in SellWatch.status(a).map { (a, $0) } }
            .sorted { l, r in
                l.1.signal != r.1.signal ? l.1.signal < r.1.signal
                    : (l.1.roomToFloor ?? 1) < (r.1.roomToFloor ?? 1)
            }
    }
    private var unwatchable: [Asset] { assets.filter(SellWatch.isUnwatchable) }
    /// 원칙을 걸 수 있는데 아직 안 건 종목(주식·펀드·코인).
    private var unruled: Int {
        assets.filter { SellWatch.supports($0.assetClass) && $0.amount > 0
            && $0.trailingStopPct <= 0 && $0.sellTargetPrice <= 0 }.count
    }

    /// 보여 줄 게 있을 때만 카드를 띄운다.
    static func hasContent(_ assets: [Asset]) -> Bool {
        assets.contains { SellWatch.supports($0.assetClass) && $0.amount > 0 }
    }

    var body: some View {
        let list = watched
        let alerts = list.filter { $0.1.signal != .holding }
        NavigationLink { SellSignalsView() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: alerts.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(alerts.isEmpty ? Theme.positive : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline(list: list, alerts: alerts))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(subline(list: list, alerts: alerts))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if alerts.isEmpty {
                    // 그래도 기준선에 가장 가까운 종목 하나는 보여 준다.
                    if let first = list.first {
                        SellSignalRow(asset: first.0, status: first.1)
                    }
                } else {
                    ForEach(alerts.prefix(3), id: \.0.key) { a, st in
                        SellSignalRow(asset: a, status: st)
                    }
                    if alerts.count > 3 {
                        Text("외 \(alerts.count - 3)개")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
                HStack {
                    if !unwatchable.isEmpty {
                        Text("시세를 몰라 못 보는 종목 \(unwatchable.count)개")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("전체 보기")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func headline(list: [(Asset, SellWatch.Status)], alerts: [(Asset, SellWatch.Status)]) -> String {
        if let top = alerts.first {
            return alerts.count == 1
                ? String(localized: "\(top.0.name), 눈여겨봐 주세요")
                : String(localized: "\(alerts.count)개 종목을 눈여겨봐 주세요")
        }
        if list.isEmpty { return String(localized: "아직 매도 원칙을 정한 종목이 없어요") }
        return String(localized: "지금은 매도를 눈여겨볼 종목이 없어요")
    }

    private func subline(list: [(Asset, SellWatch.Status)], alerts: [(Asset, SellWatch.Status)]) -> String {
        if !alerts.isEmpty {
            return alerts.contains { $0.1.signal == .stopHit || $0.1.signal == .targetHit }
                ? String(localized: "정해 둔 가격에 닿았어요. 원칙대로 할 때예요")
                : String(localized: "정해 둔 가격에 가까워지고 있어요")
        }
        if list.isEmpty {
            return String(localized: "종목을 눌러 고점 대비 하락이나 목표가를 정하면 팔 때를 알려 드려요")
        }
        if unruled > 0 {
            return String(localized: "\(list.count)개 모두 원칙 안쪽이에요 · 원칙 없는 종목 \(unruled)개")
        }
        return String(localized: "\(list.count)개 모두 원칙 안쪽이에요. 닿으면 알림으로 알려 드려요")
    }
}
