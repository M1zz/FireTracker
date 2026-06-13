import Foundation
import SwiftData

// 앱의 모든 데이터를 JSON 한 덩어리로 내보내고/되돌리는 백업·복원 엔진.
//
// 백업 대상:
//   • SwiftData — FireSettings(설정·목표·API키), Asset(자산 목록·세부 종목),
//     NetWorthSnapshot(기록·자산 항목)
//   • UserDefaults — 계산 탭 입력값(sim.*), 표시·잠금 설정
//
// 복원은 기존 데이터를 전부 지우고 백업 시점으로 통째로 되돌린다(파괴적).
// 자동 백업은 앱이 켜질 때마다 로컬에 남겨, 실수로 지워도 직전 상태로 복구 가능.

// MARK: - Codable DTO (저장 포맷)

struct BackupData: Codable {
    var version: Int = 1
    var createdAt: Date
    var appVersion: String

    var settings: SettingsDTO?
    var assets: [AssetDTO]
    var snapshots: [SnapshotDTO]

    // UserDefaults — 계산 탭/표시 설정. 문자열·불리언으로 나눠 보관.
    var stringDefaults: [String: String]
    var boolDefaults: [String: Bool]

    struct SettingsDTO: Codable {
        var targetAnnualExpense: Double
        var safeWithdrawalRate: Double
        var expectedAnnualReturn: Double
        var displayUnit: Double
        var monthlyTakeHome: Double
        var plannedMonthlyExpense: Double
        var plannedNetSavings: Double
        var manualAnnualDividend: Double
        var fireGoalTypeRaw: String
        var currentAge: Int
        var targetRetireAge: Int
        var finnhubKey: String
        var kisAppKey: String
        var kisAppSecret: String
        var dataGoKey: String
    }

    struct AssetDTO: Codable {
        var key: UUID
        var name: String
        var assetClassRaw: String
        var customLabel: String
        var amount: Double
        var quantity: Double
        var symbol: String
        var currency: String
        var autoPriced: Bool
        var unitPriceKRW: Double
        var lastPriced: Date?
        var incomeKindRaw: String
        var monthlyIncome: Double
        var annualYieldPct: Double
        var depositReceived: Double
        var depositLiquid: Bool
        var costBasis: Double
        var realEstateUseRaw: String
        var liquidityRaw: String
        var sortOrder: Int
        var createdAt: Date
        var details: [DetailDTO]
    }

    struct DetailDTO: Codable {
        var name: String
        var amount: Double
        var sortOrder: Int
    }

    struct SnapshotDTO: Codable {
        var date: Date
        var note: String
        var monthlyIncome: Double
        var monthlyExpense: Double
        var monthlyNetSavings: Double
        var monthlyPassiveIncome: Double
        var liquidNetWorth: Double
        var entries: [EntryDTO]
    }

    struct EntryDTO: Codable {
        var assetClassRaw: String
        var name: String
        var amount: Double
        var catalogKey: UUID?
        var symbol: String
        var quantity: Double
        var currency: String
        var autoPriced: Bool
        var unitPriceKRW: Double
        var lastPriced: Date?
    }
}

// MARK: - 백업 엔진

enum BackupManager {
    // 백업/복원 대상 UserDefaults 키.
    static let stringKeys: [String] = [
        "sim.mode",
        "sim.life.currentAge", "sim.life.retireAge", "sim.life.endAge",
        "sim.life.startAsset", "sim.life.grossSalary", "sim.life.raisePct",
        "sim.life.monthlyLiving", "sim.life.retireMonthly", "sim.life.retirePension",
        "sim.life.passiveMonthly", "sim.life.returnPct", "sim.life.inflationPct",
        "sim.mtg.principal", "sim.mtg.ratePct", "sim.mtg.years", "sim.mtg.method",
        "sim.sav.kind", "sim.sav.principal", "sim.sav.monthly", "sim.sav.months",
        "sim.sav.ratePct", "sim.sav.compound", "sim.sav.goal",
    ]
    static let boolKeys: [String] = [
        "sim.life.seeded", "sim.sav.taxed", "amountNumbersOnly", "appLockEnabled",
    ]

    // MARK: 백업 만들기

    @MainActor
    static func makeBackup(context: ModelContext) throws -> BackupData {
        let settings = try context.fetch(FetchDescriptor<FireSettings>()).first
        let assets = try context.fetch(FetchDescriptor<Asset>())
        let snapshots = try context.fetch(FetchDescriptor<NetWorthSnapshot>())

        let defaults = UserDefaults.standard
        var stringDefaults: [String: String] = [:]
        for key in stringKeys where defaults.object(forKey: key) != nil {
            if let v = defaults.string(forKey: key) { stringDefaults[key] = v }
        }
        var boolDefaults: [String: Bool] = [:]
        for key in boolKeys where defaults.object(forKey: key) != nil {
            boolDefaults[key] = defaults.bool(forKey: key)
        }

        return BackupData(
            createdAt: Date(),
            appVersion: appVersionString,
            settings: settings.map(settingsDTO),
            assets: assets.map(assetDTO),
            snapshots: snapshots.map(snapshotDTO),
            stringDefaults: stringDefaults,
            boolDefaults: boolDefaults
        )
    }

    static func encode(_ backup: BackupData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> BackupData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupData.self, from: data)
    }

    // MARK: 복원 (파괴적 — 기존 데이터를 백업 시점으로 통째로 교체)

    @MainActor
    static func restore(from backup: BackupData, context: ModelContext) throws {
        // 1) 기존 데이터 전부 삭제. 부모를 지우면 자식(세부 종목·자산 항목)은 cascade.
        try context.delete(model: AssetDetail.self)
        try context.delete(model: AssetEntry.self)
        try context.delete(model: Asset.self)
        try context.delete(model: NetWorthSnapshot.self)
        try context.delete(model: FireSettings.self)

        // 2) 설정 복원 (단일 인스턴스).
        if let s = backup.settings {
            let settings = FireSettings()
            settings.targetAnnualExpense = s.targetAnnualExpense
            settings.safeWithdrawalRate = s.safeWithdrawalRate
            settings.expectedAnnualReturn = s.expectedAnnualReturn
            settings.displayUnit = s.displayUnit
            settings.monthlyTakeHome = s.monthlyTakeHome
            settings.plannedMonthlyExpense = s.plannedMonthlyExpense
            settings.plannedNetSavings = s.plannedNetSavings
            settings.manualAnnualDividend = s.manualAnnualDividend
            settings.fireGoalTypeRaw = s.fireGoalTypeRaw
            settings.currentAge = s.currentAge
            settings.targetRetireAge = s.targetRetireAge
            settings.finnhubKey = s.finnhubKey
            settings.kisAppKey = s.kisAppKey
            settings.kisAppSecret = s.kisAppSecret
            settings.dataGoKey = s.dataGoKey
            context.insert(settings)
        }

        // 3) 자산 목록 + 세부 종목.
        for a in backup.assets {
            let asset = Asset()
            asset.key = a.key            // 시계열 연결용 식별자는 반드시 보존.
            asset.name = a.name
            asset.assetClassRaw = a.assetClassRaw
            asset.customLabel = a.customLabel
            asset.amount = a.amount
            asset.quantity = a.quantity
            asset.symbol = a.symbol
            asset.currency = a.currency
            asset.autoPriced = a.autoPriced
            asset.unitPriceKRW = a.unitPriceKRW
            asset.lastPriced = a.lastPriced
            asset.incomeKindRaw = a.incomeKindRaw
            asset.monthlyIncome = a.monthlyIncome
            asset.annualYieldPct = a.annualYieldPct
            asset.depositReceived = a.depositReceived
            asset.depositLiquid = a.depositLiquid
            asset.costBasis = a.costBasis
            asset.realEstateUseRaw = a.realEstateUseRaw
            asset.liquidityRaw = a.liquidityRaw
            asset.sortOrder = a.sortOrder
            asset.createdAt = a.createdAt
            context.insert(asset)
            asset.details = a.details.map { d in
                let detail = AssetDetail(name: d.name, amount: d.amount, sortOrder: d.sortOrder)
                context.insert(detail)
                return detail
            }
        }

        // 4) 기록(스냅샷) + 자산 항목.
        for s in backup.snapshots {
            let snap = NetWorthSnapshot(
                date: s.date, note: s.note,
                monthlyIncome: s.monthlyIncome, monthlyExpense: s.monthlyExpense,
                monthlyNetSavings: s.monthlyNetSavings,
                monthlyPassiveIncome: s.monthlyPassiveIncome,
                liquidNetWorth: s.liquidNetWorth
            )
            context.insert(snap)
            snap.entries = s.entries.map { e in
                let entry = AssetEntry(
                    assetClass: AssetClass(rawValue: e.assetClassRaw) ?? .other,
                    name: e.name, amount: e.amount, catalogKey: e.catalogKey,
                    symbol: e.symbol, quantity: e.quantity, currency: e.currency,
                    autoPriced: e.autoPriced, unitPriceKRW: e.unitPriceKRW,
                    lastPriced: e.lastPriced
                )
                context.insert(entry)
                return entry
            }
        }

        try context.save()

        // 5) UserDefaults(계산 탭/표시 설정) 복원.
        let defaults = UserDefaults.standard
        for (key, value) in backup.stringDefaults { defaults.set(value, forKey: key) }
        for (key, value) in backup.boolDefaults { defaults.set(value, forKey: key) }
    }

    // MARK: 자동 백업 (앱 실행 시 로컬에 남기는 안전망)

    static let maxAutoBackups = 20

    static var backupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Backups", isDirectory: true)
    }

    // 직전 자동 백업과 내용이 같으면 건너뛰고, 다르면 새로 남긴 뒤 오래된 것 정리.
    @MainActor
    static func autoBackup(context: ModelContext) {
        do {
            let backup = try makeBackup(context: context)
            // 빈 상태(자산·기록 모두 없음)는 굳이 백업하지 않는다.
            guard !backup.assets.isEmpty || !backup.snapshots.isEmpty
                    || backup.settings != nil else { return }
            let data = try encode(backup)

            let fm = FileManager.default
            try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            // 직전 백업과 동일하면 중복 저장 생략(타임스탬프·생성시각 제외 비교).
            if let latest = listBackups().first,
               let prev = try? Data(contentsOf: latest.url),
               sameContent(prev, data) { return }

            let name = "auto-\(fileTimestamp(backup.createdAt)).json"
            try data.write(to: backupDirectory.appendingPathComponent(name), options: .atomic)
            pruneOldBackups()
        } catch {
            // 자동 백업 실패는 조용히 무시 — 앱 동작을 막지 않는다.
        }
    }

    struct BackupFile: Identifiable {
        var id: URL { url }
        let url: URL
        let createdAt: Date
    }

    // 최신순 자동 백업 목록.
    static func listBackups() -> [BackupFile] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date(timeIntervalSince1970: 0)
                return BackupFile(url: url, createdAt: date)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @MainActor
    static func restore(fromFileAt url: URL, context: ModelContext) throws {
        let data = try Data(contentsOf: url)
        let backup = try decode(data)
        try restore(from: backup, context: context)
    }

    private static func pruneOldBackups() {
        let files = listBackups()
        guard files.count > maxAutoBackups else { return }
        for file in files.dropFirst(maxAutoBackups) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: 내보내기용 파일

    // 공유 시트로 내보낼 임시 파일 URL. 파일명에 날짜를 넣어 알아보기 쉽게.
    @MainActor
    static func exportFileURL(context: ModelContext) throws -> URL {
        let backup = try makeBackup(context: context)
        let data = try encode(backup)
        let name = "FireTracker-백업-\(fileTimestamp(backup.createdAt)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - DTO 변환 헬퍼

    private static func settingsDTO(_ s: FireSettings) -> BackupData.SettingsDTO {
        .init(targetAnnualExpense: s.targetAnnualExpense,
              safeWithdrawalRate: s.safeWithdrawalRate,
              expectedAnnualReturn: s.expectedAnnualReturn,
              displayUnit: s.displayUnit,
              monthlyTakeHome: s.monthlyTakeHome,
              plannedMonthlyExpense: s.plannedMonthlyExpense,
              plannedNetSavings: s.plannedNetSavings,
              manualAnnualDividend: s.manualAnnualDividend,
              fireGoalTypeRaw: s.fireGoalTypeRaw,
              currentAge: s.currentAge,
              targetRetireAge: s.targetRetireAge,
              finnhubKey: s.finnhubKey,
              kisAppKey: s.kisAppKey,
              kisAppSecret: s.kisAppSecret,
              dataGoKey: s.dataGoKey)
    }

    private static func assetDTO(_ a: Asset) -> BackupData.AssetDTO {
        .init(key: a.key, name: a.name, assetClassRaw: a.assetClassRaw,
              customLabel: a.customLabel, amount: a.amount, quantity: a.quantity,
              symbol: a.symbol, currency: a.currency, autoPriced: a.autoPriced,
              unitPriceKRW: a.unitPriceKRW, lastPriced: a.lastPriced,
              incomeKindRaw: a.incomeKindRaw, monthlyIncome: a.monthlyIncome,
              annualYieldPct: a.annualYieldPct, depositReceived: a.depositReceived,
              depositLiquid: a.depositLiquid, costBasis: a.costBasis,
              realEstateUseRaw: a.realEstateUseRaw, liquidityRaw: a.liquidityRaw,
              sortOrder: a.sortOrder, createdAt: a.createdAt,
              details: a.sortedDetails.map {
                  .init(name: $0.name, amount: $0.amount, sortOrder: $0.sortOrder)
              })
    }

    private static func snapshotDTO(_ s: NetWorthSnapshot) -> BackupData.SnapshotDTO {
        .init(date: s.date, note: s.note, monthlyIncome: s.monthlyIncome,
              monthlyExpense: s.monthlyExpense, monthlyNetSavings: s.monthlyNetSavings,
              monthlyPassiveIncome: s.monthlyPassiveIncome,
              liquidNetWorth: s.liquidNetWorth,
              entries: s.entries.map { e in
                  .init(assetClassRaw: e.assetClassRaw, name: e.name, amount: e.amount,
                        catalogKey: e.catalogKey, symbol: e.symbol, quantity: e.quantity,
                        currency: e.currency, autoPriced: e.autoPriced,
                        unitPriceKRW: e.unitPriceKRW, lastPriced: e.lastPriced)
              })
    }

    // MARK: - 잡다한 헬퍼

    static var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // 파일명용 타임스탬프 — yyyyMMdd-HHmmss (정렬 가능).
    private static func fileTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // createdAt 한 줄만 다른 두 백업은 같은 내용으로 본다(중복 자동백업 방지).
    private static func sameContent(_ a: Data, _ b: Data) -> Bool {
        func stripped(_ data: Data) -> String? {
            guard var s = String(data: data, encoding: .utf8) else { return nil }
            // "createdAt" : "...." 한 줄을 제거하고 비교.
            s = s.split(separator: "\n")
                .filter { !$0.contains("\"createdAt\"") }
                .joined(separator: "\n")
            return s
        }
        return stripped(a) == stripped(b)
    }
}
