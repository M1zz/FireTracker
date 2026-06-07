# FireTracker TODO

## 완료
- [x] 대시보드 메인을 '현금유동성(월 수입 vs 원하는 월 지출)' 중심으로 전환
  - 맨 위 메인 카드를 `momentumCard`(목표 자산 진척) → `cashFlowCard`(월 수입)로 교체
  - 월 수입 = 자산이 만드는 패시브 인컴, 주 수입(월÷4.345)·연 수입 함께 표시
  - 원하는 월 지출(연간 목표 지출÷12) 커버율 + 부족/여유 금액 표시
  - 중복되던 `passiveIncomeCard` 제거

- [x] 자산 구성 카드에 부채 표현 + 총자산/순자산 토글 추가
  - 부채를 빨강 슬라이스(abs값)로 도넛에 표시, 범례는 −금액 빨강
  - 상단 세그먼트 토글(총자산/순자산)로 헤더 합계 전환 + 반대값 안내 캡션

- [x] 앱 잠금(Face ID/Touch ID) 보안 기능 추가 — 설정에서 켜기(기본 꺼짐)
  - `RootView`를 `AppLockGate`로 감싸 실행/복귀 시 인증 전까지 콘텐츠 가림
  - 백그라운드 전환(앱 스위처) 시에도 화면 가림 → 스냅샷 노출 방지
  - 생체인증 없으면 기기 암호로 폴백, 둘 다 없으면 잠그지 않음(잠금 아웃 방지)
  - 설정 탭에 '보안 > 앱 잠금' 토글, 기기별 Face ID/Touch ID 라벨 자동 표기
  - `INFOPLIST_KEY_NSFaceIDUsageDescription` 빌드 설정 추가(Debug/Release)
  - 토글 상태는 `@AppStorage`로 저장(SwiftData 마이그레이션 회피)

- [x] 총자산/순자산 토글이 그래프·연말 예상까지 반영되도록 + 연말 예상을 수입 기반으로 전환
  - 도넛 그래프: 총자산=자산만, 순자산=부채 슬라이스 포함 (토글 따라 변경)
  - 연말 예상 자산: 시작값이 토글(총/순) 따라 변경
  - FireEngine 연말 예측에서 수익률(평가차익) 가정 제거 → 월 저축 + 예정된 패시브 인컴(배당·월세·이자)만 선형 반영
  - 실거주 아파트(수입 0)는 연말 예상에 더 이상 자산 증가로 안 잡힘
  - ProjectionDetailView: '투자 수익' → '수입(배당·월세 등)'으로 교체, 근거 문구 수정

- [x] '만약에 — 빚 갚기 vs 투자하기' 비교 기능 추가 (대시보드 진입 카드 → WhatIfView)
  - 직접 입력: 투입 금액, 부채 연이자율, 투자 연수익률, 기간(년)
  - 빚 갚기 = 아낀 이자(복리, 확정), 투자 = 기대 수익(복리, 변동) 비교 + 유불리 판정
  - 총부채/예상 수익률을 기본값으로 프리필
  - WhatIfView는 DashboardView.swift에 함께 정의(새 파일 pbxproj 등록 회피)

- [x] 자산 탭의 '자산 구성'에도 총자산/순자산 토글 적용 (대시보드와 동일 동작)
  - 부채 있을 때만 헤더에 토글, 순자산 모드에서 부채 슬라이스·−금액 표시
  - 토글 따라 헤더 합계(총/순) + 보조 캡션 전환

- [x] 자산 종류 대폭 확장 + 직접 입력(커스텀) 지원
  - AssetClass 8종 → 17종: 현금·예금, 주식, 펀드·ETF, 채권, 암호화폐, 연금, 보험, 부동산, 전세보증금, 보증금, 자동차, 귀금속·미술품, 받을 돈, 지식재산권, 기타, 직접 입력, 부채
  - 각 종류 label/아이콘/색상/유동성·수입 기본값 부여 (Liquidity.suggested·IncomeKind.suggested 갱신)
  - 직접 입력(.custom): Asset.customLabel 필드 추가, 편집기에서 종류명 타이핑, 목록에 displayClassLabel로 표시
  - SwiftData: customLabel은 기본값 ""로 추가 → 경량 마이그레이션(추가 속성)

- [x] 자산 구성 도넛 차트 전환 애니메이션 추가 (대시보드·자산 탭)
  - 토글 시 슬라이스 각도 변화 easeInOut(0.45) 애니메이션
  - 범례 행(부채 등) 추가/제거도 opacity+move 트랜지션으로 부드럽게

- [x] 배당 입력 부담 완화: 소득 섹션에 원탭 배당률 프리셋 추가
  - 배당(코스피2%/S&P500 1.5%/고배당4.5%/무배당0%)·이자(예금3%)·스테이킹(ETH3.5%) 칩
  - 탭하면 annualYieldPct 설정 + 월소득 초기화 → 평가액 기준 배당 자동 계산(금액 입력 불필요)

- [x] 스크린샷 캡처로 종목 일괄 추가 (Vision 온디바이스 OCR) MVP
  - 자산 탭 + 메뉴 → '스크린샷으로 추가' → PhotosPicker → Vision OCR
  - 토큰을 행 단위로 그룹핑 후 (종목명 + 평가액) 파싱, 확인/수정 리스트 제공
  - 선택 항목을 주식(.stocks)으로 일괄 등록 (평가액 수동, 코드/배당은 이후 보완)
  - 이미지 온디바이스 처리(전송 없음), PhotosPicker라 권한 설명 불필요

- [x] 연간 배당수익(대략) 수동 입력 → 월 수입 환산 + 추이 기록
  - FireSettings.manualAnnualDividend 추가(기본 0, 경량 마이그레이션), manualMonthlyDividend = ÷12
  - 설정에 '패시브 인컴(배당 등)' 섹션: 연간 배당 입력 + 월 환산 표시
  - 대시보드 월 수입 / 자산 탭 월 현금흐름 / 기록(RecordSheet) 패시브 인컴에 합산
  - 기록 저장 시 스냅샷 monthlyPassiveIncome에 반영 → 추이로 누적
  - 종목별 입력분과 합산되므로 한쪽만 쓰도록 안내 문구 추가

- [x] 목표 월 수입 달성에 필요한 자금 계산 카드 추가 (현재 전략 기준)
  - 전략 수익률 = 연 패시브 인컴 ÷ 수입창출 자본(없으면 유동자산으로 폴백)
  - 필요 자금 = 목표 연수입 ÷ 전략 수익률, 부족분(gap)·현재 자본·진행바 표시
  - 4% 룰 기준 fireNumber도 참고로 병기, 수입 없으면 안내 상태

- [x] 대시보드 '재정 신호등'(signalCard) 순서를 맨 아래로 이동
- [x] 다크모드 온전 적용: 윈도우 overrideUserInterfaceStyle=.dark 강제(메뉴·피커·알럿·키보드 등 UIKit 크롬 포함) + 앱 루트/TrendView preferredColorScheme(.dark) 보강

- [x] 추이 탭: 라이브 현재값 자동 포함 + 주/월(주초/월초) 기준 버킷팅
  - 카탈로그 기반 '지금' 포인트를 자동 append → 새 기록 없이도 최신까지 표시
  - TrendPoint로 스냅샷+현재 통합, 주초/월초로 버킷팅(버킷당 최신값)
  - 주/월 세그먼트 토글 추가, 막대 차트 단위도 기간 따라 변경
  - 표시 조건 snapshots≥2 → 버킷 포인트≥2, 빈 상태 문구 개선

- [x] 대시보드 첫 화면 환영 요약 카드(맨 위) 추가
  - 지난 기록 이후 변화 금액: 한국식 색(상승=붉은색 Theme.rise, 하락=푸른색 Theme.fall) + 화살표
  - FIRE 목표 달성률 바 + 이번 변화로 가까워진/멀어진 %p
  - 재정 상태(신호등) 한눈 칩 요약(overallHeadline + 신호별 색 칩)
  - 신규 등록 자산 제외한 정직한 변화(sinceLastRecord, catalogKey 매칭)
  - '전월 대비' 지표도 상승=빨강/하락=파랑으로 통일

- [x] 카드 자잘한 설명을 항상 노출 대신 ⓘ 버튼 팝오버 + TipKit 안내로 전환
  - 재사용 InfoPopoverButton(팝오버, presentationCompactAdaptation/Background) 추가
  - InfoButtonTip(TipKit) — ⓘ 사용법 1회 안내, welcomeCard ⓘ에 popoverTip 부착
  - 적용: welcomeCard(빨강/파랑 설명)·cashFlowCard·capitalNeededCard·liquidityCard
  - 해당 카드의 장황한 캡션/가정 문구는 본문에서 제거 → 팝오버로 이동

- [x] welcomeCard 다듬기: '지난 기록 이후'를 카드 타이틀(.headline)로 승격
  - 총자산/순자산 변화 구분 표시(부채 변동 시 둘이 달라짐, lastRecordChange gross/net)
  - HStack 최소화: 화살표를 ▲▼ 글자로 단일 Text, ⓘ는 카드 overlay(topTrailing)로
  - 신호 칩은 Label로, 변화 없음(±0) 중립 처리

- [x] 패시브 인컴을 '월 수입'으로 부르던 UI 문구를 '패시브 인컴'으로 변경
  - 대시보드 카드 타이틀 '내 월 수입'→'내 패시브 인컴', '목표 수입에 필요한 자금'→'목표 패시브 인컴에…'
  - 연말예상 근거/설정 푸터의 패시브 인컴 표기 통일 (RecordSheet/SnapshotsView의 근로 '월 수입'은 유지)
- [x] 자산 탭 순서 변경: 자산구성 → 내 자산 → 쓸 수 있는 돈 요약 → 팁/추가

- [x] 총자산↔순자산 변화 차이를 글 대신 워터폴(다리) 차트로 시각화
  - changeBridge: 총자산 변화 → 부채 영향(floating bar) → 순자산 변화, 막대별 증감 주석
  - 부채가 움직여 둘이 다를 때만 표시, 기존 설명 문구 제거

- [x] 변화 워터폴 라벨/설명을 '자산−부채=순자산' 회계 모델에 맞게 정정
  - 막대 라벨 총자산/부채영향/순자산 → 자산/부채/순자산
  - welcomeCard ⓘ: 빚으로 받은 현금도 자산이라 빚 내면 보통 순자산 불변임을 명시

- [x] 기간별 목표 미설정 시 인라인 문구 → TipKit(TipView)로 노출 + 설정 안내
  - MilestoneSetupTip: '설정 ▸ 목표 측정 & 기간'에서 나이 입력 유도
  - monthsToRetire 있으면 카드, 없으면 TipView(닫기 가능)
- [x] FIRE 목표 측정 기준 설정(자산/패시브 인컴/둘 다, 기본 둘 다) + 기간별 목표
  - FireSettings: fireGoalType, currentAge, targetRetireAge, monthsToRetire, incomeGoalMonthly
  - 설정에 '목표 측정 & 기간' 섹션(세그먼트 + 나이 입력)
  - FireEngine.milestoneTarget: 은퇴까지 필요속도로 역산
  - 대시보드 '기간별 목표' 카드: 이번달·올해·5년·은퇴 목표치+진행바(자산/인컴 토글)
  - welcomeCard 달성률을 goalType 반영(자산/인컴/둘 다 바)

- [x] 라이트/다크 적응형 지원 (시스템 따라 자동)
  - Color(light:dark:) 동적 색 도입, Theme 팔레트를 라이트/다크 쌍으로 정의
  - accent는 두 모드 동일 골드(검정 텍스트 버튼 가독성 유지)
  - 강제 다크 제거: 모든 preferredColorScheme(.dark)·overrideUserInterfaceStyle 삭제
  - 탭/내비 바는 동적 UIColor(Theme.surfaceUI/bgUI)로 적응

- [x] 크래시 방어: Fmt.krw/won/wonKo/years/trimNumber에 isFinite 가드 (Int(NaN/Inf) trap 방지)
- [x] 지난기록 변화 차트: 떠있는 워터폴(yStart/yEnd) → 총자산·부채·순자산 '변화' 막대로 교체
  - 부채 변화 양수=빚 증가로 표기, 순자산=총자산−부채 관계 명확화 + ⓘ 문구 갱신

- [x] 변화 설명을 절대 구성 → '총자산의 변화량은 이렇게 구성돼요'로 변경
  - changeComposition: 총자산 변화 = 순자산 변화 + 부채 변화 색코딩 등식, 부채 변동 시만 표시
- [x] 총자산/부채/순자산 3막대 차트 → 직관적인 누적 구성 막대로 교체
  - assetCompositionBar: 한 막대를 순자산(초록)+부채(빨강)로 채워 '총자산=순자산+부채' 시각화
  - 색 코딩 Text 한 줄(내 몫+갚을 빚=총자산), HStack 없이 Text 연결, 빚>자산(underwater) 케이스 처리
  - 부채 있을 때만 표시

- [x] 설정: 연간 목표 지출 옆에 '월간 목표 지출' 입력 추가(양방향 연동, 월×12=연간)

- [x] 기간별 목표에 '은퇴까지 자산 궤도' 라인 차트 추가
  - trajectoryChart: 지금→은퇴 필요 궤도(Line+Area) + 마일스톤 점 + 현재/은퇴 강조
  - 자산/패시브 인컴 토글 반영, 기존 마일스톤 진행바 행은 아래 유지

- [x] welcomeCard 정리: 변화 구성을 바 차트 하나(총자산·순자산·부채)로, 달성률은 goalProgressCard로 분리, 신호등 글랜스(재정이 순항중…) 제거
  - changeComposition을 3-bar Chart로 (부채 변화 양수=빚 증가)
  - goalProgressCard 신설(자산/패시브 인컴 달성률), 본문 welcomeCard 다음 배치

## 다음에 해볼 만한 것
- [ ] (논의) 부채만 등록하고 대응 현금을 안 넣으면 총자산0/순자산−로 보임 — 부채 잔액을 현금으로 자동 인식 옵션 검토
- [ ] '만약에' 시나리오 확장: '투자했더라면', '빚 안 갚고 뒀다면 낸 이자' 추가 가능
- [ ] '예상 달성 시점(yearsToFire)'도 수익률 가정을 뺄지 결정 — 현재는 장기라 expectedAnnualReturn 유지 중
- [ ] 설정에 '원하는 월 지출'을 월 단위로 직접 입력하는 필드 추가 (현재는 연간 목표 지출÷12)
- [ ] 커버율 100% 달성 시 대시보드 상단 축하/배지 강조
