//
//  TipMoments.swift
//  FireTracker
//
//  개발자 응원하기(팁)를 부탁할 순간. 퇴사각이 그 사람에게 도움이 됐다는 것이 숫자로 보일 때만 묻는다.
//
//  숫자: 첫 기록부터 지금까지 **퇴사 날짜를 지켜본 달 수**. 기록(스냅샷)은 자산이 바뀔 때마다,
//  적어도 주 1회 저절로 쌓이므로 새로 세는 것이 없다. 데모 데이터를 보는 중에는 묻지 않는다.
//  얼마나 드물게: LeeoKit 의 규칙(`LeeoTipAskPolicy`). 물으면 60일 쉬고, 낸 사람은 180일, '다음에' 세 번이면 끝.
//
//  ⚠️ 페이월이 꺼져 있어 모두가 이미 프로다(`ProAccess.paywallEnabled`) — 그래서 누구에게나 묻는다.
//

import Foundation
import LeeoKit

enum FireTrackerTipMoments {
    /// 지켜본 달 수. 큰 것부터.
    static let months = [24, 12, 6]

    /// 넘어선 순간, **인상적인 것부터**.
    static func reached(monthsTracked m: Int) -> [LeeoTipMoment] {
        months.filter { m >= $0 }.map { threshold in
            LeeoTipMoment(id: "months.\(threshold)",
                          message: String(localized: "퇴사각과 함께 \(m)개월째 퇴사 날짜를 지켜보고 있어요",
                                          comment: "Tip ask card: months since the first net-worth record"))
        }
    }

    static func reachedNow(snapshots: [NetWorthSnapshot]) -> [LeeoTipMoment] {
        guard !DemoData.isActive, let first = snapshots.map(\.date).min() else { return [] }
        let m = Calendar.current.dateComponents([.month], from: first, to: Date()).month ?? 0
        return reached(monthsTracked: m)
    }
}
