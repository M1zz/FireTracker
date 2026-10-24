//
//  FireSummary.swift
//  FireTracker (앱 · 위젯 공용)
//
//  "언제 그만둘 수 있나" 한 장 요약. 앱이 계산해서 App Group 에 적어 두고,
//  위젯은 그것만 읽는다 — 위젯이 SwiftData 스토어를 직접 열지 않게 하려는 것.
//  금액은 담지 않는다(잠금 화면·홈 화면에 잔고가 보이면 안 되므로). 날짜와 비율만.
//

import Foundation

struct FireSummary: Codable, Equatable {
    /// 예상 퇴사(FIRE 달성) 시점. 목표에 영영 닿지 않으면 nil.
    var fireDate: Date?
    /// 그때 나이. 현재 나이를 모르면 nil.
    var ageAtFire: Int?
    /// 자산 목표 달성률 (0...1+).
    var progress: Double
    /// 사용자가 목표를 직접 정했는가 — 아니면 위젯은 "목표를 정해 주세요"를 보여 준다.
    var goalConfigured: Bool
    /// 앱 잠금을 켰는가 — 켰으면 위젯도 숫자를 가린다.
    var locked: Bool
    var updatedAt: Date

    static let appGroup = "group.com.devkoan.FireTracker"
    private static let key = "fireSummary.v1"

    static func load() -> FireSummary? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FireSummary.self, from: data)
    }

    /// 바뀐 게 있을 때만 쓴다. 쓰면 true — 호출부가 위젯 갱신을 요청한다.
    @discardableResult
    func save() -> Bool {
        if var old = FireSummary.load() {
            old.updatedAt = updatedAt   // 시각만 다른 건 바뀐 게 아니다
            if old == self { return false }
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        UserDefaults(suiteName: FireSummary.appGroup)?.set(data, forKey: FireSummary.key)
        return true
    }

    /// "2038년 4월" 처럼.
    var fireDateText: String? {
        guard let fireDate else { return nil }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return f.string(from: fireDate)
    }
}
