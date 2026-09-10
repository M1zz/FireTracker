import Foundation
import LeeoKit

enum FireTrackerSpec: LeeoAppSpec {
    static let appName = "퇴사각"
    static let developerEmail = "leeo@kakao.com"
    static let feedback = LeeoFeedbackConfig(containerIdentifier: "iCloud.com.Ysoup.FeedbackHub", appIdentifier: "com.devkoan.FireTracker")

    /// 개인정보·지원 링크. 레포의 docs/ 를 GitHub Pages 로 올린 페이지들이다.
    /// index.html 이 지원 페이지 역할을 한다(문의 메일·기능 안내가 거기 있다).
    static let legal = LeeoLegalConfig(
        privacyURL: URL(string: "https://m1zz.github.io/FireTracker/privacy.html")!,
        supportURL: URL(string: "https://m1zz.github.io/FireTracker/")!
    )

    /// 수익모델 — 전 기능 무료. 페이월도, 잠긴 기능도 없다.
    static let monetization = LeeoMonetization.free

    /// 분석 싱크 — LeeoKit 이 스스로 남기는 이벤트(만족도·리뷰 프롬프트 등)를
    /// 앱이 쓰는 사용 통계와 **같은 스트림**으로 흘려보낸다. 외부 분석 SDK는 없다.
    /// 설정 ▸ 사용 통계(개발자)에서 앱 이벤트와 나란히 보인다.
    static let analytics: any LeeoAnalytics = LeeoUsageAnalytics(spec: FireTrackerSpec.self)
}
