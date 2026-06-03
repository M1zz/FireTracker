import SwiftUI
import SwiftData
import Charts
import TipKit

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
    @State private var editing: Asset?
    @State private var showingNew = false
    @State private var showingRecord = false
    @State private var showingHistory = false

    private let otherAssetsTip = OtherAssetsTip()

    private var total: Double { assets.reduce(0) { $0 + $1.netValue } }
    private var liquidTotal: Double { assets.reduce(0) { $0 + $1.liquidValue } }
    private var lockedTotal: Double { total - liquidTotal }
    private var monthlyIncome: Double { assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } }
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
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !assets.isEmpty { recordBar }
            }
            .sheet(isPresented: $showingNew) {
                AssetEditor(asset: nil, nextSortOrder: assets.count)
            }
            .sheet(item: $editing) { asset in
                AssetEditor(asset: asset, nextSortOrder: assets.count)
            }
            .sheet(isPresented: $showingRecord) { RecordSheet() }
            .sheet(isPresented: $showingHistory) { SnapshotsView() }
        }
    }

    private var catalogList: some View {
        List {
            Section {
                totalCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("내 자산") {
                ForEach(assets) { asset in
                    Button { editing = asset } label: { row(asset) }
                        .listRowBackground(Theme.surface)
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
            Section {
                TipView(otherAssetsTip)
                    .tipBackground(Theme.surface)
                    .listRowBackground(Theme.surface)
                Button { showingNew = true } label: {
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
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.positive)
            Text("= \(Fmt.won(liquidTotal))원")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
            liquidityBar
            HStack {
                Text("순자산 \(Fmt.krw(total))원")
                if lockedTotal > 0 {
                    Text("· 묶인 돈 \(Fmt.krw(lockedTotal))원")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecond)
            Text("순자산 \(Fmt.won(total))원")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            Divider().overlay(Theme.hairline)
            Text("자산 구성")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
            compositionBar
            Text("\(assets.count)개 자산")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)

            if monthlyIncome > 0 || totalGain != 0 {
                Divider().overlay(Theme.hairline)
                HStack(spacing: 0) {
                    if monthlyIncome > 0 {
                        flowStat(title: "월 현금흐름",
                                 value: "\(Fmt.krw(monthlyIncome))원",
                                 tint: Theme.positive)
                    }
                    if totalGain != 0 {
                        flowStat(title: "총 평가 차익",
                                 value: "\(totalGain >= 0 ? "+" : "-")\(Fmt.krw(abs(totalGain)))원",
                                 tint: totalGain >= 0 ? Theme.positive : Theme.negative)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.horizontal, 20)
        .padding(.top, 8)
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

    // Thin stacked bar showing class composition of the catalog.
    private var compositionBar: some View {
        let groups = AssetClass.allCases.compactMap { ac -> (AssetClass, Double)? in
            let sum = assets.filter { $0.assetClass == ac }.reduce(0) { $0 + $1.netValue }
            return sum > 0 ? (ac, sum) : nil
        }
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(groups, id: \.0) { item in
                    Color(hex: item.0.colorHex)
                        .frame(width: max(2, geo.size.width * (total > 0 ? item.1 / total : 0)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func row(_ asset: Asset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: asset.assetClass.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: asset.assetClass.colorHex))
                .frame(width: 32, height: 32)
                .background(Color(hex: asset.assetClass.colorHex).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name.isEmpty ? asset.assetClass.label : asset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if asset.assetClass == .realEstate {
                        Label(asset.realEstateUse.label, systemImage: asset.realEstateUse.icon)
                            .foregroundStyle(Color(hex: asset.assetClass.colorHex))
                    } else {
                        Text(asset.assetClass.label)
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
                }
                .font(.caption2)
                .lineLimit(1)
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
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecond)
            Text("내 자산을 먼저 등록해보세요.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("주식·코인·부동산·전세·현금 등\n보유한 자산을 목록으로 만들어 추적합니다.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
            Button { showingNew = true } label: {
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

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(assets[i]) }
        try? context.save()
    }

    private func move(from: IndexSet, to: Int) {
        var arr = assets
        arr.move(fromOffsets: from, toOffset: to)
        for (index, asset) in arr.enumerated() { asset.sortOrder = index }
        try? context.save()
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

    @State private var name = ""
    @State private var assetClass: AssetClass = .stocks
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

    // Seed all editor state directly from the asset so that opening the editor
    // does not mutate `assetClass` (which would trigger onChange and clobber the
    // stored liquidity/income with class-suggested defaults).
    init(asset: Asset?, nextSortOrder: Int) {
        self.asset = asset
        self.nextSortOrder = nextSortOrder
        let cls = asset?.assetClass ?? .stocks
        _name = State(initialValue: asset?.name ?? "")
        _assetClass = State(initialValue: cls)
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
                    Picker("종류", selection: $assetClass) {
                        ForEach(AssetClass.allCases) { ac in Text(ac.label).tag(ac) }
                    }
                    .onChange(of: assetClass) { _, newValue in
                        if !newValue.supportsAutoPrice { auto = false }
                        liquidity = Liquidity.suggested(for: newValue)
                    }
                    TextField(namePlaceholder, text: $name)
                }

                if assetClass == .realEstate {
                    Section {
                        Picker("이용 형태", selection: $realEstateUse) {
                            ForEach(RealEstateUse.allCases) { use in
                                Label(use.label, systemImage: use.icon).tag(use)
                            }
                        }
                        .onChange(of: realEstateUse) { _, newValue in
                            if newValue.hasRent { incomeKind = .rent }
                        }
                    } header: {
                        Text("이용 형태")
                    } footer: {
                        Text(realEstateUseHint)
                            .font(.caption)
                    }
                }

                if !isDebt {
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
                             : "실거주 부동산·전세보증금·연금처럼 당장 쓸 수 없는 자산입니다. 순자산엔 잡히지만 ‘쓸 수 있는 돈’에서는 빠집니다.")
                            .font(.caption)
                    }
                }

                if assetClass.supportsAutoPrice {
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
                            Text("= \(Fmt.won(v))원")
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
                            Text(isDebt ? "순자산에서 −\(Fmt.krwBoth(v)) 차감됩니다."
                                        : "= \(Fmt.krwBoth(v))")
                                .font(.caption)
                                .foregroundStyle(isDebt ? Theme.negative : Theme.textSecond)
                        }
                    }
                }

                if !isDebt {
                    if assetClass == .realEstate {
                        if realEstateUse.hasDeposit { depositSection }
                        if realEstateUse.hasRent { incomeSection }
                        costBasisSection
                    } else {
                        costBasisSection
                        incomeSection
                        depositSection
                    }
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
            .navigationTitle(asset == nil ? "자산 추가" : "자산 편집")
            .navigationBarTitleDisplayMode(.inline)
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save() } }
            }
        }
        .preferredColorScheme(.dark)
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

    // 취득가 대비 평가 차익 — 자산이 값이 올라서 만든 부가가치.
    private var costBasisSection: some View {
        Section {
            TextField("취득가 (산 가격, 원)", text: $costBasis.commaGrouped)
                .keyboardType(.numberPad)
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
                Text("= \(g >= 0 ? "+" : "-")\(Fmt.won(abs(g)))원")
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

    // 월세·배당·이자·연금·스테이킹 등 자산이 만들어내는 현금흐름.
    private var incomeSection: some View {
        Section {
            Picker("소득 유형", selection: $incomeKind) {
                ForEach(IncomeKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            if incomeKind != .none {
                TextField("월 소득 (원)", text: $monthlyIncome.commaGrouped)
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
                    Text("순자산 기여")
                    Spacer()
                    Text("\(Fmt.krw(value))원")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("전세 보증금")
        } footer: {
            Text("받은 보증금은 언젠가 돌려줘야 하지만 지금은 현금으로 보유 중이라, 순자산은 평가액 그대로입니다. 단지 구성이 ‘현금 + 부동산 지분’으로 나뉘어, 실거주(전액 묶임)와 달리 쓸 수 있는 현금이 생깁니다.")
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
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Fmt.krw(v)).font(.caption2) }
                }
            }
        }
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
    @State private var income = ""
    @State private var expense = ""
    @State private var note = ""

    private var settings: FireSettings { settingsList.first ?? FireSettings() }

    private var total: Double { assets.reduce(0) { $0 + $1.netValue } }
    private var liquidTotal: Double { assets.reduce(0) { $0 + $1.liquidValue } }
    private var passiveIncome: Double { assets.reduce(0) { $0 + $1.effectiveMonthlyIncome } }

    var body: some View {
        NavigationStack {
            Form {
                Section("기간") {
                    DatePicker("월", selection: $date, displayedComponents: .date)
                }
                Section("이번 달 순자산") {
                    HStack {
                        Text("쓸 수 있는 돈 (유동)")
                        Spacer()
                        Text("\(Fmt.krw(liquidTotal))원")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.positive)
                    }
                    HStack {
                        Text("순자산")
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
                    TextField("월 수입", text: $income.commaGrouped).keyboardType(.numberPad)
                    TextField("월 지출", text: $expense.commaGrouped).keyboardType(.numberPad)
                } header: {
                    Text("수입 / 지출 (원)")
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
                // Prefill this month's income/expense from the salary settings.
                if income.isEmpty, settings.monthlyTakeHome > 0 {
                    income = String(Int(settings.monthlyTakeHome))
                }
                if expense.isEmpty, settings.plannedMonthlyExpense > 0 {
                    expense = String(Int(settings.plannedMonthlyExpense))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let snap = NetWorthSnapshot(
            date: date,
            note: note,
            monthlyIncome: Double(income) ?? 0,
            monthlyExpense: Double(expense) ?? 0,
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
