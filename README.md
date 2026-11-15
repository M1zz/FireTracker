# FireTracker

순자산을 기록하고 FIRE 목표까지의 추이를 추적하는 iOS 앱. (앱 이름: **퇴사각**)

## 링크
- 지원 페이지: https://m1zz.github.io/FireTracker/
- 개인정보처리방침: https://m1zz.github.io/FireTracker/privacy.html
- 문의: leeo@kakao.com

## 빌드
1. `FireTracker.xcodeproj`를 Xcode 15+ 에서 열기
2. Signing & Capabilities 에서 본인 Team 선택
3. iPhone 시뮬레이터 또는 실기기 선택 후 ⌘R

- 최소 타깃: iOS 17.0
- 의존성: 없음 (SwiftUI, SwiftData, Swift Charts — 전부 내장 프레임워크)
- Bundle ID: `com.devkoan.FireTracker`

## 구조
- **대시보드** — FIRE 달성률 링, 예상 달성 시점, 월 평균 저축, 전월 대비 변화량, 자산 구성 도넛 차트
- **추이** — 순자산 라인 차트(목표선 포함) / 월별 저축률 막대 / 자산 클래스별 누적 막대
- **기록** — 월별 스냅샷 추가·편집·삭제. 자산을 클래스별(주식/전세/현금 등) 라인 아이템으로 입력
- **설정** — 연 목표 지출, 안전 인출률(SWR), 예상 연 수익률 → FIRE 목표 금액 자동 계산

## 데이터 모델 (SwiftData 영속)
- `FireSettings` — 목표/SWR/수익률
- `NetWorthSnapshot` — 월별 스냅샷 (수입/지출 포함, 저축률 파생)
- `AssetEntry` — 스냅샷에 속한 개별 자산 (클래스 + 금액)

## 계산 로직 (`FireEngine.swift`)
- FIRE 목표 = 연 지출 / SWR (4% 룰이면 연 지출 × 25)
- 달성 시점 = 현재 순자산 + 월 저축을 예상 수익률로 복리 적립해 목표 도달까지 시뮬레이션
- 월 평균 저축 = 최근 6개월 (수입 − 지출) 평균
- 전월 대비 = 최신 두 스냅샷 순자산 차이

## 요금제 (USD, App Store Connect 기준)
무료 다운로드 + 퇴사각 Plus · Pro. 칸 나누기와 잠기는 기능은 `ProAccess.swift`, 로컬 결제 테스트 값은 `FireTracker.storekit`.

| 상품 | ID | 가격 |
|---|---|---|
| Plus 주 · 월 · 연 구독 | `….plus.weekly` · `.monthly` · `.yearly` | $1.49 · $3.49 · $9.99 (연 첫해 $4.99) |
| Plus 평생 | `….plus` | $29.99 |
| Pro 주 · 월 · 연 구독 | `….pro.weekly` · `.monthly` · `.yearly` | $1.99 · $4.99 · $14.99 (연 첫해 $7.49) |
| **Pro 평생** | `….pro` | **$150.00** (2026-11-16 확정, 심사 문의에 의도한 값이라고 답함) |
| Plus 평생 → Pro 평생 올리기 | `….pro.upgrade` | $14.99 |
| 연 구독자용 Pro 평생(졸업) | `….pro.graduate` | $29.99 |
| Pro 선물 (소모성) | `….gift.pro` | $44.99 (App Store Connect 에 아직 없음) |
| 응원(팁) | `….tip.small` · `.medium` · `.large` | $1.49 · $3.49 · $7.99 |

가격을 바꾸면 App Store Connect 와 `FireTracker.storekit` 과 이 표를 함께 고친다.

## 사용 순서
1. 설정에서 목표 지출/SWR 입력
2. 기록 탭에서 첫 스냅샷 추가 (자산 + 수입/지출)
3. 매월 스냅샷을 추가하면 추이 탭에서 변화량이 그래프로 누적
