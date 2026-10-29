//
//  FireTrackerRoadmap.swift
//  FireTracker
//
//  **앞으로 만들 것**의 원본. 설정 ▸ 지원 ▸ 앞으로 만들 기능(`LeeoRoadmapView`)이 이 목록을 그대로 보여 준다.
//
//  ⚠️ 개발하다 "이건 다음에" 가 생기면 **여기에 한 줄을 더한다.** 코드의 TODO 주석으로만 남기지 않는다.
//     - 새 항목: `.planned`. 손대기 시작하면 `.building`. 내보내면 `.shipped("1.2.0")`.
//     - id 는 한 번 정하면 바꾸지 않는다(문구는 바꿔도 된다). 같은 피처는 다른 앱과 같은 id 를 쓴다.
//     - 문구는 사용자 말로 쓴다(내부 이름 · 기술 용어 금지). 영어는 FireTracker/Localizable.xcstrings 에 넣는다
//       (앱이 지원하는 모든 언어를 채운다 — deploy.env 의 LOCALES).
//     - 사용자에게 보일 만한 것만 적는다. 리팩터링 · 시험 · 빌드 설정은 `.sprintcommander/tasks.json` 의 몫이다.
//

import SwiftUI
import LeeoKit

extension FireTrackerSpec {
    static var roadmap: [LeeoRoadmapItem] {[
        // MARK: 다음에 만들어요
        .init(id: "gift", status: .building,
              title: NSLocalizedString("퇴사각 프로 선물하기", comment: "Roadmap item: gift Pro to someone"),
              detail: NSLocalizedString("가족이나 친구에게 퇴사각 프로를 선물할 수 있어요. 받은 선물 코드도 설정에서 넣어요.", comment: "Roadmap item detail: gift Pro to someone")),
        .init(id: "a11y.voiceover", status: .building,
              title: NSLocalizedString("VoiceOver로 더 편하게", comment: "Roadmap item: better VoiceOver support"),
              detail: NSLocalizedString("화면 읽기 기능이 단추와 숫자를 빠짐없이, 알맞은 순서로 읽어 줘요.", comment: "Roadmap item detail: better VoiceOver support")),
        .init(id: "a11y.largetext", status: .planned,
              title: NSLocalizedString("큰 글씨에 맞춘 화면", comment: "Roadmap item: Dynamic Type layouts"),
              detail: NSLocalizedString("글자 크기를 키워도 잘리지 않고 보기 좋게 다시 배치돼요.", comment: "Roadmap item detail: Dynamic Type layouts")),
        .init(id: "a11y.contrast", status: .building,
              title: NSLocalizedString("보기 편한 색과 대비", comment: "Roadmap item: contrast and color"),
              detail: NSLocalizedString("대비를 높이거나 색을 구별하기 어려워도 내용을 알아볼 수 있어요.", comment: "Roadmap item detail: contrast and color")),
        .init(id: "a11y.motion", status: .planned,
              title: NSLocalizedString("움직임 줄이기", comment: "Roadmap item: reduce motion"),
              detail: NSLocalizedString("움직임 줄이기를 켜면 화면 효과가 차분해져요.", comment: "Roadmap item detail: reduce motion")),
        .init(id: "lang.english", status: .shipped("1.2.1"),
              title: NSLocalizedString("영어 지원", comment: "Roadmap item: English"),
              detail: NSLocalizedString("앱을 영어로도 쓸 수 있어요.", comment: "Roadmap item detail: English")),
        .init(id: "lang.more", status: .shipped("1.2.1"),
              title: NSLocalizedString("더 많은 언어", comment: "Roadmap item: more languages"),
              detail: NSLocalizedString("더 많은 나라 말로 앱을 쓸 수 있게 해요.", comment: "Roadmap item detail: more languages")),
        .init(id: "whatsnew", status: .planned,
              title: NSLocalizedString("업데이트 소식", comment: "Roadmap item: what's new"),
              detail: NSLocalizedString("업데이트 뒤 처음 열 때 무엇이 새로 생겼는지 알려 줘요.", comment: "Roadmap item detail: what's new")),
        .init(id: "shortcuts", status: .planned,
              title: NSLocalizedString("Siri와 단축어", comment: "Roadmap item: Siri and Shortcuts"),
              detail: NSLocalizedString("Siri에게 물으면 퇴사까지 남은 기간을 바로 알려 줘요.", comment: "Roadmap item detail: Siri and Shortcuts")),
        .init(id: "sync.icloud", status: .planned,
              title: NSLocalizedString("기기 간 동기화", comment: "Roadmap item: iCloud sync"),
              detail: NSLocalizedString("새 아이폰으로 바꿔도 내 자산 기록이 iCloud로 그대로 이어져요.", comment: "Roadmap item detail: iCloud sync")),
        .init(id: "fold", status: .planned,
              title: NSLocalizedString("펼치는 아이폰 화면", comment: "Roadmap item: foldable iPhone layout"),
              detail: NSLocalizedString("펼치는 아이폰에서 넓은 화면을 두 쪽으로 나눠 써요.", comment: "Roadmap item detail: foldable iPhone layout")),
        .init(id: "data.delete", status: .planned,
              title: NSLocalizedString("내 기록 한 번에 지우기", comment: "Roadmap item: delete all data"),
              detail: NSLocalizedString("원하면 앱 안에서 자산과 기록을 모두 지울 수 있어요.", comment: "Roadmap item detail: delete all data")),
        .init(id: "autosave", status: .planned,
              title: NSLocalizedString("적던 내용 이어서 하기", comment: "Roadmap item: keep unsaved drafts"),
              detail: NSLocalizedString("자산을 적다가 앱이 꺼져도 적던 내용이 남아 있어요.", comment: "Roadmap item detail: keep unsaved drafts")),
    ]}
}

// MARK: - 화면

/// 설정 ▸ 앞으로 만들 기능. "이런 기능이 있으면 좋겠어요" 는 기능 제안으로 시작하는 피드백 창을 연다.
struct RoadmapScreen: View {
    @State private var showFeedback = false

    var body: some View {
        LeeoRoadmapView<FireTrackerSpec>(onSuggest: { showFeedback = true })
            .sheet(isPresented: $showFeedback) {
                NavigationStack {
                    LeeoFeedbackView<FireTrackerSpec>(initialType: .feature)
                }
            }
    }
}
