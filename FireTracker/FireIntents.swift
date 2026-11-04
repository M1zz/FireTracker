//
//  FireIntents.swift
//  FireTracker
//
//  "퇴사각, 퇴사까지 얼마나 남았어?" — 대시보드와 같은 계산(FireOutlook)으로 남은 기간과
//  목표에 얼마나 다가왔는지 알려 준다.
//
//  자산은 이름과 종류만 Siri · Spotlight 에 싣는다(iOS 18+). 금액은 싣지 않는다. 누르면 그 자산이 열린다.
//  앱 잠금을 켜 두면 자산을 내보이지 않는다 — 잠금 밖에서 무엇을 가졌는지 보이면 안 된다.
//

import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

struct FireCountdownIntent: AppIntent {
    static let title = LocalizedStringResource("퇴사까지 남은 기간", comment: "Siri: how long until financial independence")
    static let description = IntentDescription(
        LocalizedStringResource("목표 자산까지 남은 기간과 지금 얼마나 다가왔는지 알려 줍니다.", comment: "Siri: FIRE countdown description")
    )

    @Dependency private var container: ModelContainer

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContext(container)
        guard let settings = try? context.fetch(FetchDescriptor<FireSettings>()).first, settings.goalConfigured else {
            return .result(dialog: IntentDialog(LocalizedStringResource("먼저 앱에서 목표를 정해 주세요.", comment: "Siri: no goal yet")))
        }
        // 대시보드와 같다: 자산 목록이 있으면 그 합, 없으면 마지막 기록.
        let assets = (try? context.fetch(FetchDescriptor<Asset>())) ?? []
        let latest = try? context.fetch(FetchDescriptor<NetWorthSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])).first
        let netWorth = assets.isEmpty ? (latest?.netWorth ?? 0) : assets.reduce(0) { $0 + $1.netValue }
        let outlook = FireOutlook(netWorth: netWorth, settings: settings)

        let percent = Int((min(outlook.progress, 1) * 100).rounded())
        if outlook.progress >= 1 {
            return .result(dialog: IntentDialog(LocalizedStringResource("목표에 닿았어요. 언제든 퇴사할 수 있어요.", comment: "Siri: goal reached")))
        }
        guard let years = outlook.years else {
            return .result(dialog: IntentDialog(LocalizedStringResource("지금 저축으로는 목표에 닿지 않아요. 목표의 \(percent)%까지 왔어요.", comment: "Siri: goal not reachable with current savings. Argument is percent")))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("퇴사까지 \(Fmt.years(years)) 남았어요. 목표의 \(percent)%까지 왔어요.", comment: "Siri: time to FIRE. Arguments: duration, percent")))
    }
}

// MARK: - 자산

struct AssetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("자산", comment: "Siri/Spotlight: one asset the user holds")
    )
    static let defaultQuery = AssetQuery()

    let id: UUID
    let name: String
    let kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }

    init(_ asset: Asset) {
        id = asset.key
        name = asset.name
        kind = asset.displayClassLabel
    }
}

@available(iOS 18.0, *)
extension AssetEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.keywords = [kind]
        return set
    }
}

struct AssetQuery: EntityStringQuery {
    @Dependency private var container: ModelContainer

    func entities(for identifiers: [UUID]) async throws -> [AssetEntity] {
        let wanted = Set(identifiers)
        return AssetLibrary.assets(in: container).filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AssetEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func matches(_ s: String) -> Bool { s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return AssetLibrary.assets(in: container).filter { matches($0.name) || matches($0.kind) }
    }

    func suggestedEntities() async throws -> [AssetEntity] {
        AssetLibrary.assets(in: container)
    }
}

/// 자산을 연다. Spotlight · Siri 결과를 누르면 여기로 온다.
struct OpenAssetIntent: OpenIntent {
    static let title = LocalizedStringResource("자산 열기", comment: "Siri/Spotlight: open an asset")
    static let description = IntentDescription(
        LocalizedStringResource("고른 자산을 앱에서 엽니다.", comment: "Siri: open asset description")
    )

    @Parameter(title: LocalizedStringResource("자산", comment: "Siri: asset parameter"),
               description: LocalizedStringResource("열 자산. 이름이나 종류로 찾습니다.", comment: "Siri: asset parameter description"))
    var target: AssetEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.selectedTab = AppRouter.Tab.assets
        AppRouter.shared.openAsset = target.id
        return .result()
    }
}

enum AssetLibrary {
    /// 자산 탭과 같은 순서. 이름이 빈 것은 뺀다. 앱 잠금을 켰으면 아무것도 내보이지 않는다.
    static func assets(in container: ModelContainer) -> [AssetEntity] {
        guard !UserDefaults.standard.bool(forKey: "appLockEnabled") else { return [] }
        let descriptor = FetchDescriptor<Asset>(sortBy: [SortDescriptor(\.sortOrder)])
        return ((try? ModelContext(container).fetch(descriptor)) ?? [])
            .filter { !$0.name.isEmpty }
            .map(AssetEntity.init)
    }

    /// Spotlight 에 싣는 자산을 지금 것에 맞춘다. 앱을 열 때와 뒤로 보낼 때 부른다.
    static func reindex(_ container: ModelContainer) async {
        guard #available(iOS 18.0, *) else { return }
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: AssetEntity.self)
        try? await index.indexAppEntities(assets(in: container))
    }
}

// MARK: - Siri 문구

struct FireTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FireCountdownIntent(),
            phrases: ["How long until I can quit in \(.applicationName)", "\(.applicationName) countdown"],
            shortTitle: "FIRE Countdown",
            systemImageName: "flame"
        )
    }
}
