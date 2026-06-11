import SwiftUI
import SwiftData
import Charts
import TipKit
import PhotosUI
import Vision

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
    @State private var editing: Asset?
    @State private var showingNew = false
    @State private var showingRecord = false
    @State private var showingHistory = false
    @State private var showingImport = false
    @State private var showingBreakdown = false
    @State private var totalMode: AssetTotalMode = .gross
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
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } + settings.manualMonthlyDividend
    }
    private var totalDebtCost: Double { assets.reduce(0) { $0 + $1.monthlyDebtCost } }
    private var totalGain: Double { assets.reduce(0) { $0 + $1.gain } }

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
            .navigationTitle("자산")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingCategoryPicker = true } label: {
                            Label("카테고리 추가", systemImage: "folder.badge.plus")
                        }
                        Button { startNewAsset() } label: {
                            Label("직접 추가", systemImage: "square.and.pencil")
                        }
                        Button { showingImport = true } label: {
                            Label("스크린샷으로 추가", systemImage: "text.viewfinder")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !assets.isEmpty { recordBar }
            }
            .sheet(isPresented: $showingNew) {
                AssetEditor(asset: nil, nextSortOrder: assets.count,
                            initialClass: newClass, initialCustomLabel: newCustomLabel,
                            lockedClass: newLockedClass,
                            classTotal: newLockedClass ? newClassTotal : nil)
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
            .sheet(isPresented: $showingRecord) { RecordSheet() }
            .sheet(isPresented: $showingHistory) { SnapshotsView() }
            .sheet(isPresented: $showingImport) {
                ScreenshotImportView(startingSortOrder: assets.count)
            }
            .sheet(isPresented: $showingBreakdown) { NetWorthBreakdownView() }
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
            // 2) 내 자산 — 종류(카테고리)별로 묶어, 접고 펼치며 종목을 관리.
            ForEach(assetGroups) { group in
                Section {
                    if !collapsedGroups.contains(group.id) {
                        ForEach(group.assets) { asset in
                            Button { editing = asset } label: { row(asset) }
                                .listRowBackground(Theme.surface)
                        }
                        .onDelete { delete(in: group, at: $0) }
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
            Text("= \(Fmt.wonKo(liquidTotal))")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            Text("지금 바로 현금화해 쓸 수 있는 자산(현금·주식·코인 등)이에요. 실거주 부동산·전세보증금·연금처럼 묶인 돈과 부채는 빠집니다.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            liquidityBar
            HStack(spacing: 10) {
                legendDot("유동 \(Fmt.krw(liquidTotal))원", Theme.positive)
                if lockedTotal > 0 {
                    legendDot("묶임 \(Fmt.krw(lockedTotal))원", Theme.textSecond.opacity(0.5))
                }
            }
            .font(.caption2)

            Button { showingBreakdown = true } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("총자산 \(Fmt.krw(total))원")
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
                        flowStat(title: "월 현금흐름",
                                 value: "+\(Fmt.krw(monthlyIncome))원",
                                 tint: Theme.positive)
                    }
                    if totalDebtCost > 0 {
                        flowStat(title: "부채가 가져가는 돈",
                                 value: "−\(Fmt.krw(totalDebtCost))원",
                                 tint: Theme.negative)
                    }
                    if totalGain != 0 {
                        flowStat(title: "총 평가 차익",
                                 value: "\(totalGain >= 0 ? "+" : "-")\(Fmt.krw(abs(totalGain)))원",
                                 tint: totalGain >= 0 ? Theme.positive : Theme.negative)
                    }
                }
                if monthlyIncome > 0 && totalDebtCost > 0 {
                    let net = monthlyIncome - totalDebtCost
                    Text("월 순현금흐름 \(net >= 0 ? "+" : "−")\(Fmt.krw(abs(net)))원 (현금흐름 − 부채)")
                        .font(.caption2)
                        .foregroundStyle(net >= 0 ? Theme.positive : Theme.negative)
                }
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
    private var compositionEntries: [(assetClass: AssetClass, amount: Double)] {
        AssetClass.allCases.compactMap { ac in
            guard ac != .debt else { return nil }
            let sum = assets.filter { $0.assetClass == ac }
                .reduce(0) { $0 + max(0, $1.netValue) }
            return sum > 0 ? (ac, sum) : nil
        }
    }
    // Debt magnitude, gross assets, and the toggle's effective mode — mirror the
    // dashboard so 총자산/순자산 behaves the same on both screens.
    private var debtTotal: Double { abs(assets.filter { $0.isDebt }.reduce(0) { $0 + $1.netValue }) }
    private var grossAssets: Double { compositionEntries.reduce(0) { $0 + $1.amount } }
    private var hasDebt: Bool { debtTotal > 0 }
    private var effectiveMode: AssetTotalMode { hasDebt ? totalMode : .gross }
    // Chart/legend rows: assets always; 순자산 mode adds a debt slice.
    private var compositionRows: [(assetClass: AssetClass, amount: Double)] {
        var rows = compositionEntries
        if effectiveMode == .net && debtTotal > 0 {
            rows.append((assetClass: .debt, amount: debtTotal))
        }
        return rows
    }

    // Donut chart + legend showing how net worth breaks down by class.
    private var compositionCard: some View {
        let rows = compositionRows
        let sum = rows.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("자산 구성")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if hasDebt {
                    Picker("", selection: $totalMode) {
                        ForEach(AssetTotalMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                } else {
                    Text("\(assets.count)개 자산")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
            }

            if hasDebt {
                VStack(alignment: .leading, spacing: 2) {
                    Text(effectiveMode == .gross ? "순자산" : "총자산")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                    Text("\(Fmt.krw(effectiveMode == .gross ? grossAssets : total))원")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(effectiveMode == .gross ? Theme.textPrimary : Theme.accent)
                    Text(effectiveMode == .gross
                         ? "부채 \(Fmt.krw(debtTotal))원 차감 시 총자산 \(Fmt.krw(total))원"
                         : "순자산 \(Fmt.krw(grossAssets))원 − 부채 \(Fmt.krw(debtTotal))원")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Chart(rows, id: \.assetClass) { item in
                SectorMark(
                    angle: .value("금액", item.amount),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .foregroundStyle(Color(hex: item.assetClass.colorHex))
                .cornerRadius(4)
            }
            .frame(height: 170)
            .animation(.easeInOut(duration: 0.45), value: rows.map(\.amount))

            VStack(spacing: 10) {
                ForEach(rows, id: \.assetClass) { item in
                    let isDebt = item.assetClass == .debt
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: item.assetClass.colorHex))
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
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
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(collectibleClasses) { ac in
                    let owned = collected.contains(ac)
                    Button { if !owned { startNewAsset(ac, lock: true) } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: owned ? ac.symbolName : "plus")
                                .font(.subheadline)
                                .foregroundStyle(owned ? Color(hex: ac.colorHex) : Theme.textSecond.opacity(0.5))
                                .frame(height: 18)
                            Text(ac.label)
                                .font(.caption2)
                                .foregroundStyle(owned ? Theme.textPrimary : Theme.textSecond.opacity(0.6))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(owned ? Color(hex: ac.colorHex).opacity(0.13) : Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(owned ? Color(hex: ac.colorHex).opacity(0.45) : Theme.hairline,
                                        style: owned ? StrokeStyle(lineWidth: 1)
                                                     : StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(owned)
                }
            }
            Text(count == total
                 ? "모든 자산 종류를 수집했어요! 🎉"
                 : "빈 칸을 누르면 그 종류의 자산을 바로 추가할 수 있어요.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row(_ asset: Asset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: asset.assetClass.symbolName)
                .font(.system(.subheadline))
                .foregroundStyle(Color(hex: asset.assetClass.colorHex))
                .frame(width: 32, height: 32)
                .background(Color(hex: asset.assetClass.colorHex).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name.isEmpty ? asset.displayClassLabel : asset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if asset.assetClass == .realEstate {
                        Label(asset.realEstateUse.label, systemImage: asset.realEstateUse.icon)
                            .foregroundStyle(Color(hex: asset.assetClass.colorHex))
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
                    if asset.effectiveMonthlyIncome > 0 {
                        Text("월 \(Fmt.krw(asset.effectiveMonthlyIncome))")
                            .foregroundStyle(Theme.positive)
                    }
                    if asset.monthlyDebtCost > 0 {
                        Text("월 −\(Fmt.krw(asset.monthlyDebtCost))")
                            .foregroundStyle(Theme.negative)
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                // 세부 종목 한 줄 요약 — 예) 삼성전자 1,000만 · 애플 2,000만
                if !asset.details.isEmpty {
                    Text(asset.sortedDetails.map { "\($0.name) \(Fmt.krw($0.amount))" }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Fmt.krw(asset.netValue))원")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(asset.netValue < 0 ? Theme.negative : Theme.textPrimary)
                if asset.depositReceived > 0 {
                    Text("현금 \(Fmt.krw(asset.depositCash)) + \(Fmt.krw(asset.equityValue))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 4)
    }

    private var recordBar: some View {
        Button { showingRecord = true } label: {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                Text("이번 달 기록 저장")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(Theme.bg.opacity(0.9))
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

    private func delete(in group: AssetGroup, at offsets: IndexSet) {
        for i in offsets { context.delete(group.assets[i]) }
        try? context.save()
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
            let members = assets.filter { $0.assetClass == ac }
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
        return groups
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
                Image(systemName: group.assetClass.symbolName)
                    .font(.caption)
                    .foregroundStyle(Color(hex: group.assetClass.colorHex))
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
                                Image(systemName: ac.symbolName)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(hex: ac.colorHex))
                                    .frame(width: 26)
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

    let asset: Asset?
    let nextSortOrder: Int
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

    // Cash flow / yield
    @State private var incomeKind: IncomeKind = .none
    @State private var monthlyIncome = ""
    @State private var annualYieldPct = ""
    @State private var depositReceived = ""
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
        _currency = State(initialValue: asset?.currency ?? "KRW")
        _auto = State(initialValue: asset?.autoPriced ?? false)
        _unitPriceKRW = State(initialValue: asset?.unitPriceKRW ?? 0)
        _lastPriced = State(initialValue: asset?.lastPriced)
        _incomeKind = State(initialValue: asset?.incomeKind ?? IncomeKind.suggested(for: cls))
        _monthlyIncome = State(initialValue: asset.map { $0.monthlyIncome > 0 ? String(Int($0.monthlyIncome)) : "" } ?? "")
        _annualYieldPct = State(initialValue: asset.map { $0.annualYieldPct > 0 ? Fmt.trimNumber($0.annualYieldPct) : "" } ?? "")
        _depositReceived = State(initialValue: asset.map { $0.depositReceived > 0 ? String(Int($0.depositReceived)) : "" } ?? "")
        _costBasis = State(initialValue: asset.map { $0.costBasis > 0 ? String(Int($0.costBasis)) : "" } ?? "")
        _realEstateUse = State(initialValue: asset?.realEstateUse ?? .residence)
        _liquidity = State(initialValue: asset?.liquidity ?? Liquidity.suggested(for: cls))
        _detailDrafts = State(initialValue: (asset?.sortedDetails ?? []).map {
            DetailDraft(name: $0.name, amount: $0.amount > 0 ? String(Int($0.amount)) : "")
        })
    }

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    // This holding's value at each past record, stitched by catalog key.
    private var history: [(date: Date, amount: Double)] {
        guard let key = asset?.key else { return [] }
        return snapshots.compactMap { snap -> (Date, Double)? in
            guard let entry = snap.entries.first(where: { $0.catalogKey == key }) else { return nil }
            return (snap.date, entry.amount)
        }
        .sorted { $0.0 < $1.0 }
        .map { (date: $0.0, amount: $0.1) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("기본 정보") {
                    if lockedClass {
                        // 그룹에서 들어옴 — 종류는 고정, 현재 그룹 합계를 컨텍스트로.
                        HStack {
                            Label(lockedTitle, systemImage: assetClass.symbolName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(hex: assetClass.colorHex))
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

                // 전세·반전세는 받은 보증금(유동) + 부동산 지분(묶임)으로 자동 분리되므로
                // 수동 유동성 토글을 숨긴다 — 토글이 보증금 분리와 충돌해 혼란을 줬음.
                if showAdvanced && !isDebt && !(assetClass == .realEstate && realEstateUse.hasDeposit) {
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

                if showAdvanced && assetClass.supportsAutoPrice {
                    Section {
                        Toggle(isOn: $auto) {
                            Label("시세 자동", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tint(Theme.accent)
                        if auto {
                            autoInputs
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
                        if let v = Double(amount), v > 0 {
                            Text("= \(Fmt.wonKo(v))")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecond)
                        }
                        if !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(failed ? Theme.negative : Theme.textSecond)
                        }
                    } else {
                        TextField(isDebt ? "남은 대출 잔액 (원)" : "금액 (원)", text: $amount.commaGrouped)
                            .keyboardType(.numberPad)
                        if let v = Double(amount), v > 0 {
                            Text(isDebt ? "총자산에서 −\(Fmt.krwBoth(v)) 차감됩니다."
                                        : "= \(Fmt.krwBoth(v))")
                                .font(.caption)
                                .foregroundStyle(isDebt ? Theme.negative : Theme.textSecond)
                        }
                    }
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
                             : "유동성·소득·취득가·시세 자동 등은 종류에 맞게 자동 설정돼요. 바꾸고 싶을 때만 펼치면 됩니다. 저장 후 자산을 눌러도 수정할 수 있어요.")
                            .font(.caption)
                    }
                } else if isDebt {
                    debtInterestSection
                } else if assetClass == .realEstate {
                    // 부동산은 이용형태에 따라 보증금/월세가 갈린다.
                    if realEstateUse.hasDeposit { depositSection }
                    if realEstateUse.hasRent { incomeSection }
                    costBasisSection
                } else {
                    // 자산 종류별로 필요한 칸만. (전세 보증금은 부동산 전세/반전세 전용)
                    if assetClass.tracksCostBasis { costBasisSection }
                    if !availableIncomeKinds.isEmpty { incomeSection }
                }

                if !history.isEmpty {
                    Section("이 자산의 추이") {
                        historyChart
                    }
                }

                if asset != nil {
                    Section {
                        Button("이 자산 삭제", role: .destructive) { deleteAsset() }
                    }
                }
            }
            .navigationTitle(asset == nil
                             ? (lockedClass ? "\(lockedTitle) 추가" : "자산 추가")
                             : "자산 편집")
            .navigationBarTitleDisplayMode(.inline)
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save() } }
            }
        }
    }

    private var namePlaceholder: String {
        switch assetClass {
        case .stocks:     return "이름 (예: 삼성전자, Apple)"
        case .crypto:     return "이름 (예: 비트코인)"
        case .realEstate: return "아파트명 (예: 래미안)"
        case .jeonse:     return "이름 (예: 우리집 전세)"
        case .pension:    return "이름 (예: 국민연금, IRP)"
        case .debt:       return "이름 (예: 주택담보대출, 신용대출)"
        default:          return "이름"
        }
    }

    private var isDebt: Bool { assetClass == .debt }

    // 고정된 종류의 표시명 — 직접 입력이면 사용자 라벨.
    private var lockedTitle: String {
        assetClass == .custom && !customLabel.isEmpty ? customLabel : assetClass.label
    }

    private var realEstateUseHint: String {
        switch realEstateUse {
        case .residence:  return "내가 사는 집입니다. 현금흐름 없이 평가액만 잡힙니다."
        case .jeonse:     return "전세를 줬습니다. 받은 보증금은 현금(유동)으로 인식됩니다."
        case .wolse:      return "월세를 줬습니다. 매달 월세가 현금흐름으로 잡힙니다."
        case .semiJeonse: return "반전세입니다. 보증금(현금) + 월세(현금흐름) 둘 다 입력하세요."
        }
    }

    private var autoHint: String {
        switch assetClass {
        case .crypto:     return "업비트 시세로 자동 계산됩니다 (키 불필요)."
        case .stocks:     return currency == "USD" ? "Finnhub 시세 + 실시간 환율로 환산합니다." : "한국투자증권 시세로 계산합니다."
        case .realEstate: return "법정동코드 + 아파트명으로 국토부 최근 실거래가를 조회합니다."
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
            TextField("취득가 (산 가격, 원)", text: $costBasis.commaGrouped)
                .keyboardType(.numberPad)
            MoneyReadout(amount: costBasis)
            if let cb = Double(costBasis), cb > 0 {
                let cur = Double(amount) ?? 0
                let g = cur - cb
                HStack {
                    Text("평가 차익")
                    Spacer()
                    Text("\(g >= 0 ? "+" : "-")\(Fmt.krw(abs(g)))원 (\(g >= 0 ? "+" : "-")\(Fmt.percent(abs(g / cb), fraction: 1)))")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(g >= 0 ? Theme.positive : Theme.negative)
                }
                Text("= \(g >= 0 ? "+" : "-")\(Fmt.wonKo(abs(g)))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
        } header: {
            Text("취득가 · 평가 차익")
        } footer: {
            Text("산 가격을 넣으면 현재 평가액 대비 얼마나 올랐는지(부가가치)가 계산됩니다.")
                .font(.caption)
        }
    }

    // One-tap yield presets so dividends don't have to be entered won-by-won.
    // Selecting a chip sets the annual yield %, and the dividend is derived from
    // the (often auto-priced) value — no manual amount entry needed.
    private var yieldPresets: [(label: String, pct: Double)] {
        switch incomeKind {
        case .dividend:
            return [("코스피 2%", 2), ("S&P500 1.5%", 1.5), ("고배당 ETF 4.5%", 4.5), ("무배당 0%", 0)]
        case .interest:
            return [("예금 3%", 3), ("0%", 0)]
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
        case .rent:     return "월세 (원)"
        case .pension:  return "월 연금 수령액 (원)"
        case .interest: return "월 이자 (원)"
        case .dividend: return "월 배당 (원)"
        case .staking:  return "월 스테이킹 보상 (원)"
        default:        return "월 소득 (원)"
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

                Divider().overlay(Theme.hairline)
                Text("이 자산의 구성")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
                compositionRow("보유 현금 (돌려줘야 할 돈)",
                               symbol: "banknote.fill", value: cash, tint: Theme.positive)
                compositionRow("\(assetClass.label) 지분 (묶임)",
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
            Text("받은 보증금은 언젠가 돌려줘야 하지만 지금은 현금으로 보유 중이라, 총자산은 평가액 그대로입니다. 단지 구성이 ‘현금 + 부동산 지분’으로 나뉘어, 실거주(전액 묶임)와 달리 쓸 수 있는 현금이 생깁니다.")
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

    @ViewBuilder
    private var autoInputs: some View {
        switch assetClass {
        case .crypto:
            TextField("코인 심볼 (예: BTC)", text: $symbol)
                .textInputAutocapitalization(.characters)
            TextField("수량", text: $quantity)
                .keyboardType(.decimalPad)
        case .stocks:
            Picker("시장", selection: $currency) {
                Text("국내").tag("KRW")
                Text("미국").tag("USD")
            }
            .pickerStyle(.segmented)
            TextField(currency == "USD" ? "티커 (예: AAPL)" : "종목코드 6자리 (예: 005930)", text: $symbol)
                .textInputAutocapitalization(.characters)
                .keyboardType(currency == "USD" ? .asciiCapable : .numberPad)
            TextField("보유 주식 수", text: $quantity)
                .keyboardType(.decimalPad)
        case .realEstate:
            TextField("법정동코드 5자리 (예: 11680)", text: $symbol)
                .keyboardType(.numberPad)
            Text("아파트명은 위 ‘이름’ 칸을 사용합니다.")
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
        status = "불러오는 중…"
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
                status = "최근 실거래가 반영됨"
            } else {
                status = "단가 \(Fmt.krw(result.unit))원 × \(quantity.isEmpty ? "0" : quantity)"
            }
        } catch {
            failed = true
            status = "실패: \(error.localizedDescription)"
        }
        fetching = false
    }


    @discardableResult
    private func persist() -> Asset {
        let target: Asset
        if let asset {
            target = asset
        } else {
            target = Asset(sortOrder: nextSortOrder)
            context.insert(target)
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
        target.costBasis = Double(costBasis) ?? 0
        target.realEstateUse = realEstateUse
        target.liquidity = liquidity
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
        for old in target.details { context.delete(old) }
        target.details = drafts.enumerated().compactMap { idx, d in
            let nm = d.name.trimmingCharacters(in: .whitespaces)
            let amt = Double(d.amount) ?? 0
            guard !nm.isEmpty, amt > 0 else { return nil }
            return AssetDetail(name: nm, amount: amt, sortOrder: idx)
        }
        try? context.save()
        return target
    }

    private func save() {
        persist()
        dismiss()
    }

    private func deleteAsset() {
        if let asset { context.delete(asset) }
        try? context.save()
        dismiss()
    }
}

// Captures the current catalog as a dated NetWorthSnapshot, plus the month's
// income/expense, so the dashboard and trend screens can track over time.
struct RecordSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Asset.sortOrder) private var assets: [Asset]
    @Query private var settingsList: [FireSettings]

    @State private var date = Date()
    @State private var netSavings = ""
    @State private var income = ""
    @State private var expense = ""
    @State private var note = ""

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    private var total: Double { assets.reduce(0) { $0 + $1.netValue } }
    private var liquidTotal: Double { assets.reduce(0) { $0 + $1.liquidValue } }
    private var passiveIncome: Double {
        assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } + settings.manualMonthlyDividend
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("기간") {
                    DatePicker("월", selection: $date, displayedComponents: .date)
                }
                Section("이번 달 총자산") {
                    HStack {
                        Text("쓸 수 있는 돈 (유동)")
                        Spacer()
                        Text("\(Fmt.krw(liquidTotal))원")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.positive)
                    }
                    HStack {
                        Text("총자산")
                        Spacer()
                        Text("\(Fmt.krw(total))원")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if passiveIncome > 0 {
                        HStack {
                            Text("월 현금흐름")
                            Spacer()
                            Text("\(Fmt.krw(passiveIncome))원")
                                .foregroundStyle(Theme.positive)
                        }
                    }
                    Text("현재 \(assets.count)개 자산이 이 기록에 저장됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
                Section {
                    HStack {
                        TextField("수입 − 지출", text: $netSavings.commaGrouped)
                            .keyboardType(.numberPad)
                        Text("원").foregroundStyle(Theme.textSecond)
                    }
                    if let v = Double(netSavings), v > 0 {
                        Text("= \(Fmt.wonKo(v))")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                } header: {
                    Text("이번 달 저축 (수입 − 지출)")
                } footer: {
                    Text("수입·지출을 나눠 적기 번거로우면 차액(저축액)만 적으세요. 아래에 수입/지출을 따로 적으면 그 차액이 우선 쓰이고 저축률도 계산됩니다.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }

                Section {
                    TextField("월 수입", text: $income.commaGrouped).keyboardType(.numberPad)
                    MoneyReadout(amount: income)
                    TextField("월 지출", text: $expense.commaGrouped).keyboardType(.numberPad)
                    MoneyReadout(amount: expense)
                    if let inc = Double(income), inc > 0 {
                        let exp = Double(expense) ?? 0
                        HStack {
                            Text("저축률")
                            Spacer()
                            Text(Fmt.percent((inc - exp) / inc, fraction: 0))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } header: {
                    Text("수입 / 지출 따로 (선택 · 저축률용)")
                } footer: {
                    Text("설정의 세후 월급·월 지출이 자동으로 채워집니다. 이번 달 실제 값으로 수정할 수 있어요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                }
                Section("메모") {
                    TextField("메모 (선택)", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("이번 달 기록 저장")
            .navigationBarTitleDisplayMode(.inline)
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }.disabled(assets.isEmpty)
                }
            }
            .onAppear {
                // Prefill from settings, matching how the user set up savings:
                // salary/spending breakdown, or a single net-savings number.
                guard income.isEmpty, expense.isEmpty, netSavings.isEmpty else { return }
                if settings.monthlyTakeHome > 0 || settings.plannedMonthlyExpense > 0 {
                    if settings.monthlyTakeHome > 0 { income = String(Int(settings.monthlyTakeHome)) }
                    if settings.plannedMonthlyExpense > 0 { expense = String(Int(settings.plannedMonthlyExpense)) }
                } else if settings.plannedMonthlySavings > 0 {
                    netSavings = String(Int(settings.plannedMonthlySavings))
                }
            }
        }
    }

    private func save() {
        let snap = NetWorthSnapshot(
            date: date,
            note: note,
            monthlyIncome: Double(income) ?? 0,
            monthlyExpense: Double(expense) ?? 0,
            monthlyNetSavings: Double(netSavings) ?? 0,
            monthlyPassiveIncome: passiveIncome,
            liquidNetWorth: liquidTotal
        )
        context.insert(snap)
        for asset in assets where asset.netValue != 0 {
            let entry = AssetEntry(
                assetClass: asset.assetClass,
                name: asset.name,
                amount: asset.netValue,
                catalogKey: asset.key,
                symbol: asset.symbol,
                quantity: asset.quantity,
                currency: asset.currency,
                autoPriced: asset.autoPriced,
                unitPriceKRW: asset.unitPriceKRW,
                lastPriced: asset.lastPriced
            )
            entry.snapshot = snap
            snap.entries.append(entry)
        }
        try? context.save()
        dismiss()
    }
}

// A candidate holding read from a screenshot — editable before import.
struct ParsedHolding: Identifiable {
    let id = UUID()
    var name: String
    var amountText: String   // raw digits, shown comma-grouped
    var include: Bool = true
}

// On-device OCR of a brokerage holdings screenshot → candidate (종목명, 평가액)
// rows. Uses Vision (no network, nothing leaves the device). Heuristic parsing,
// so the UI always lets the user correct/deselect before anything is saved.
enum HoldingsOCR {
    private static let numberRegex = try! NSRegularExpression(pattern: #"[0-9][0-9,]*(?:\.[0-9]+)?"#)

    static func rows(from image: UIImage) -> [ParsedHolding] {
        guard let cg = image.cgImage else { return [] }
        var tokens: [(text: String, box: CGRect)] = []
        let request = VNRecognizeTextRequest { req, _ in
            for o in (req.results as? [VNRecognizedTextObservation]) ?? [] {
                if let s = o.topCandidates(1).first?.string { tokens.append((s, o.boundingBox)) }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-Hangul", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return parse(tokens)
    }

    // Group tokens that sit on the same visual line, then parse each line.
    private static func parse(_ tokens: [(text: String, box: CGRect)]) -> [ParsedHolding] {
        guard !tokens.isEmpty else { return [] }
        // boundingBox origin is bottom-left, so a larger midY is higher up.
        let sorted = tokens.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(text: String, box: CGRect)]] = []
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

// Pick a holdings screenshot → OCR → review/correct → bulk-add as 주식.
struct ScreenshotImportView: View {
    let startingSortOrder: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var pickerItem: PhotosPickerItem?
    @State private var rows: [ParsedHolding] = []
    @State private var processing = false
    @State private var didProcess = false
    @State private var loadError: String?

    private var selectedCount: Int {
        rows.filter { $0.include && (Double($0.amountText) ?? 0) > 0 }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if processing {
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
            .navigationTitle("스크린샷으로 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                if didProcess, !rows.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("\(selectedCount)개 추가") { importSelected() }
                            .disabled(selectedCount == 0)
                    }
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await process(item) }
        }
    }

    private var intro: some View {
        VStack(spacing: 22) {
            Image(systemName: "text.viewfinder")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text("보유 종목 스크린샷을 불러오세요")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("증권사 앱의 ‘보유 종목’ 화면을 캡처해서 고르면, 종목명과 평가액을 읽어 한 번에 등록합니다. 이미지는 기기에서만 처리되고 전송되지 않아요.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("스크린샷 선택")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.accent)
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
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
                Text("‘보유 종목’ 목록이 잘 보이는 스크린샷으로 다시 시도해보세요.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecond)
                PhotosPicker("다른 스크린샷 선택", selection: $pickerItem, matching: .images)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(28)
        } else {
            List {
                Section {
                    ForEach($rows) { $row in
                        HStack(spacing: 10) {
                            Button { row.include.toggle() } label: {
                                Image(systemName: row.include ? "checkmark.circle.fill" : "circle")
                                    .font(.system(.title2))
                                    .foregroundStyle(row.include ? Theme.accent : Theme.textSecond)
                            }
                            .buttonStyle(.plain)
                            VStack(spacing: 6) {
                                TextField("종목명", text: $row.name)
                                    .font(.subheadline.weight(.semibold))
                                HStack(spacing: 6) {
                                    TextField("평가액", text: $row.amountText.commaGrouped)
                                        .keyboardType(.numberPad)
                                        .font(.system(.subheadline, design: .rounded))
                                    Text("원").foregroundStyle(Theme.textSecond)
                                }
                                MoneyReadout(amount: row.amountText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .opacity(row.include ? 1 : 0.4)
                        }
                        .listRowBackground(Theme.surface)
                    }
                } header: {
                    Text("읽은 종목 \(selectedCount)/\(rows.count) 선택 · 잘못된 건 끄거나 고치세요")
                } footer: {
                    Text("모두 ‘주식’으로 등록됩니다. 평가액은 수동값이며, 나중에 편집에서 종목코드를 넣으면 시세 자동을, 배당률 프리셋으로 배당을 채울 수 있어요.")
                        .font(.caption)
                }

                Section {
                    PhotosPicker("다른 스크린샷 선택", selection: $pickerItem, matching: .images)
                        .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .keyboardDismissable()
        }
    }

    private func process(_ item: PhotosPickerItem) async {
        processing = true
        loadError = nil
        defer { processing = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            loadError = "이미지를 불러오지 못했습니다."
            return
        }
        let parsed = await Task.detached(priority: .userInitiated) {
            HoldingsOCR.rows(from: image)
        }.value
        rows = parsed
        didProcess = true
    }

    private func importSelected() {
        var order = startingSortOrder
        for row in rows where row.include {
            let amount = Double(row.amountText) ?? 0
            guard amount > 0 else { continue }
            let name = row.name.trimmingCharacters(in: .whitespaces)
            let asset = Asset(name: name,
                              assetClass: .stocks,
                              amount: amount,
                              incomeKind: .dividend,
                              liquidity: .liquid,
                              sortOrder: order)
            context.insert(asset)
            order += 1
        }
        try? context.save()
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
// user can see exactly why 총자산(net) = 순자산(보유 자산) − 부채 lands where it does.
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
                        Text("총자산").font(.headline)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Fmt.krw(netWorth))원")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(netWorth >= 0 ? Theme.accent : Theme.negative)
                            Text(Fmt.wonKo(netWorth))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    Text("총자산 = 순자산(\(Fmt.krw(grossAssets))원) − 부채(\(Fmt.krw(debtTotal))원)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                } footer: {
                    Text("아래에서 순자산·부채가 각각 총자산에 얼마씩 더하고 빼는지 확인하세요. 빚을 1,100만 졌는데 총자산이 −600만이라면, 순자산(보유 자산) 합이 500만이라는 뜻이에요.")
                        .font(.caption)
                }

                Section {
                    if positives.isEmpty {
                        Text("등록된 자산이 없어요").font(.caption).foregroundStyle(Theme.textSecond)
                    }
                    ForEach(positives) { a in
                        breakdownRow(a, value: a.netValue, sign: "+", tint: Theme.positive)
                    }
                    subtotal("순자산", grossAssets, tint: Theme.textPrimary)
                } header: {
                    Text("보유 자산 (+)")
                }

                if !debts.isEmpty {
                    Section {
                        ForEach(debts) { a in
                            breakdownRow(a, value: a.amount, sign: "−", tint: Theme.negative)
                        }
                        subtotal("부채 합계", debtTotal, sign: "−", tint: Theme.negative)
                    } header: {
                        Text("부채 (−)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("총자산 내역")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
    }

    private func breakdownRow(_ a: Asset, value: Double, sign: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.assetClass.symbolName)
                .foregroundStyle(Color(hex: a.assetClass.colorHex))
                .frame(width: 22)
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
