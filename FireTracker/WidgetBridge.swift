//
//  WidgetBridge.swift
//  FireTracker (앱 + 위젯 공용)
//
//  앱이 계산한 퇴사각 요약을 App Group 저장소에 적고, 위젯은 그것만 읽는다.
//  위젯은 SwiftData 스토어를 열지 않는다 — 스토어를 공유 컨테이너로 옮기는 마이그레이션 없이,
//  필요한 숫자 몇 개만 넘기면 충분하다. 금액은 앱이 표기 모드에 맞춰 문자열로 만들어 둔다.
//

import Foundation

struct WidgetSummary: Codable, Equatable {
    var hasGoal: Bool = false
    var reached: Bool = false
    var yearsText: String = ""      // "8년 10개월"
    var quitYear: Int = 0
    var quitAge: Int = 0            // 0이면 나이 모름
    var progress: Double = 0        // 목표 자산 달성률 0...1
    var netWorthText: String = ""   // "5억 2,000만원"
    var isPro: Bool = false
    var updatedAt: Date = .now

    static let appGroup = "group.com.devkoan.FireTracker"
    static let key = "widget.summary"
    static let widgetKind = "FireTrackerQuitWidget"

    static func load() -> WidgetSummary? {
        guard let d = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSummary.self, from: d)
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(d, forKey: Self.key)
    }
}
