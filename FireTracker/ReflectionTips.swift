import SwiftUI
import TipKit

// MARK: - "충분의 거울" — 4단계 성찰 팁
//
// 이 앱의 값은 "정답 금액"을 알려주는 데 있지 않다. 사람들은 자기가 월 200이면
// 되는지 300이 필요한지 한 번도 정직하게 들여다본 적이 없다. 그래서 돈이 생기면
// 그냥 모으고 집을 산다 — 욕망을 그려본 적이 없으니까. 이 팁들은 쓰는 흐름
// 속에서 슬쩍 "질문"을 던져, 사용자가 스스로 그 거울을 보게 한다.
//
//   1) 거울(빼기)   — 허영을 덜어낸 '진짜 나의 만족점'은 얼마인가      → 월 생활비
//   2) 버킷(더하기) — 그 돈으로 무엇을 누리고 싶은가, 그게 나인가      → 희망 월수령액
//   3) 닻(총액)     — '충분하다'고 한 삶의 값을 숫자로 마주하기        → 판정 카드
//   4) 반복되는 거울 — 만족점은 변한다. 매년 다시 묻는다              → 대시보드(연 1회)
//
// Rule로 단계를 순서대로 흐르게 하고(1을 본 뒤에야 2가 뜸), 4는 1년이 지나면
// 다시 떠오른다 — "일회성 답"이 아니라 "반복되는 동반".
//
// 전역 displayFrequency(.weekly) 아래 있으므로 한꺼번에 쏟아지지 않고, 잔소리가
// 아니라 가끔 던지는 한 줄의 질문으로 동작한다.

// 1단계 — 거울(빼기). 월 생활비를 채우기 전, 허영을 의식하게 한다.
struct VanityMirrorTip: Tip {
    // 생애주기 화면에 들어와 있을 때만 — 맥락에서 묻기 위해.
    @Parameter static var onLifecycleScreen: Bool = false

    var title: Text { Text("이 돈, 정말 당신을 위한 건가요?") }
    var message: Text? {
        Text("월 생활비에서 ‘남들이 사니까 산 것’을 한번 빼보세요. 진짜 나를 만족시키는 금액은 생각보다 적을지도 몰라요.")
    }
    var image: Image? { Image(systemName: "eye.trianglebadge.exclamationmark") }

    var rules: [Rule] {
        #Rule(Self.$onLifecycleScreen) { $0 == true }
    }
}

// 2단계 — 버킷(더하기). 절약 강요가 아니라, 무엇을 의도적으로 누릴지 묻는다.
// 1단계(월 생활비)를 채운 뒤에야 떠오른다.
struct BucketListTip: Tip {
    // 1단계를 지난(월 생활비를 입력한) 뒤에만 — 빼기 다음에 더하기.
    @Parameter static var mirrorDone: Bool = false

    var title: Text { Text("이 돈으로 무엇을 하고 싶나요?") }
    var message: Text? {
        Text("은퇴 후 매달 이 금액을 쓴다면, 구체적으로 뭘 누리고 싶은가요? 그게 진짜 당신인지, 아니면 남의 사진 속 장면인지 한번 가려보세요.")
    }
    var image: Image? { Image(systemName: "sparkles") }

    var rules: [Rule] {
        #Rule(Self.$mirrorDone) { $0 == true }
    }
}

// 3단계 — 닻(총액). 충분하다고 한 삶의 '값'을 마주하되, 매일 쫓지 말라고 짚는다.
struct EnoughAnchorTip: Tip {
    // 계산이 성립(은퇴 가능)한 결과가 나왔을 때만.
    @Parameter static var hasFeasibleResult: Bool = false

    var title: Text { Text("이게 ‘충분한 삶’의 값이에요") }
    var message: Text? {
        Text("이 숫자는 정답이 아니라 방향을 잡는 닻이에요. 매일 쫓을 필요는 없어요 — 방향만 맞으면, 나머지는 이번 주 한 칸씩이면 돼요.")
    }
    var image: Image? { Image(systemName: "scope") }

    var rules: [Rule] {
        #Rule(Self.$hasFeasibleResult) { $0 == true }
    }
}

// 4단계 — 반복되는 거울. 만족점은 시간이 지나며 변한다(허영도, 진짜 필요도).
// 마지막 점검 후 1년이 지나면 대시보드에서 다시 묻는다.
struct ReReflectTip: Tip {
    @Parameter static var dueForReview: Bool = false

    var title: Text { Text("그때의 ‘충분’, 지금도 그런가요?") }
    var message: Text? {
        Text("한동안 목표를 다시 보지 않았어요. 그동안 무엇이 달라졌나요? 계산 탭에서 만족점을 다시 한번 비춰보세요.")
    }
    var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }

    var rules: [Rule] {
        #Rule(Self.$dueForReview) { $0 == true }
    }
}

// MARK: - 성찰 상태 공유

// 4단계 재점검의 기준이 되는 "마지막으로 만족점을 점검한 시각".
// 계산 탭에서 '목표·설정에 반영'을 누르면 갱신되고, 1년이 지나면 ReReflectTip이 뜬다.
enum ReflectionState {
    private static let lastReviewedKey = "reflection.lastReviewedAt"
    private static let oneYear: TimeInterval = 365 * 24 * 60 * 60

    // 사용자가 만족점을 다시 확정한 순간 — 재점검 타이머를 리셋한다.
    static func markReviewed() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastReviewedKey)
        ReReflectTip.dueForReview = false
    }

    // 앱 시작 시 호출 — 1년 넘게 안 봤으면 재점검 팁을 깨운다.
    // 한 번도 점검한 적 없으면(신규) 닻을 먼저 거쳐야 하므로 깨우지 않는다.
    static func refreshReviewDue() {
        let last = UserDefaults.standard.double(forKey: lastReviewedKey)
        guard last > 0 else { return }
        ReReflectTip.dueForReview = (Date().timeIntervalSince1970 - last) > oneYear
    }
}
