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

    /// 수익모델 — 부분 유료(퇴사각 프로, 1회 구매·평생).
    /// "언제 퇴사할 수 있나"에 답하는 기능은 전부 무료이고, 무엇을 잠그는지는 ProFeature 가 정한다.
    static let monetization = LeeoMonetization.freemium(
        LeeoPurchaseConfig(
            productIDs: ["com.devkoan.FireTracker.pro"],
            gate: ProFeature.gatePolicy,
            // 프로 선물하기. 보내는 사람은 소모성 선물 상품을 사고, 받는 사람은 퇴사각 프로를 산 것과 같아진다.
            // 선물 기록은 피드백과 같은 허브 컨테이너의 공개 DB 에 둔다. entitlements 에 이미 있다.
            gift: LeeoGiftConfig(
                productID: ProAccess.giftProductID,
                grantsProductID: ProAccess.productID,
                containerIdentifier: "iCloud.com.Ysoup.FeedbackHub"
            ),
            // 개발자 응원하기(팁). 소모성 세 가지, 기능을 열지 않는다.
            tipJar: LeeoTipJarConfig(productIDs: ProAccess.tipProductIDs)
        )
    )

    /// 분석 싱크 — LeeoKit 이 스스로 남기는 이벤트(만족도·리뷰 프롬프트 등)를
    /// 앱이 쓰는 사용 통계와 **같은 스트림**으로 흘려보낸다. 외부 분석 SDK는 없다.
    /// 설정 ▸ 사용 통계(개발자)에서 앱 이벤트와 나란히 보인다.
    static let analytics: any LeeoAnalytics = LeeoUsageAnalytics(spec: FireTrackerSpec.self)
}
