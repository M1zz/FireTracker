//
//  FireIntents.swift
//  FireTracker
//
//  "퇴사각, 퇴사까지 얼마나 남았어?" — 대시보드와 같은 계산(FireOutlook)으로 남은 기간과
//  목표에 얼마나 다가왔는지 알려 준다.
//

import AppIntents
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
