#!/bin/sh
# iPad 13" 스토어 스크린샷 원본을 언어마다 시뮬레이터로 찍는다 → docs/screenshots/raw/<언어>/ipad-NN-*.png (2064×2752)
# 제목을 얹은 제출본은 scripts/make_marketing_screenshots.py --pad 가 만든다.
#
# 사용법:
#   sh scripts/capture_ipad_screenshots.sh <iPad Pro 13 시뮬레이터 UDID> <앱(.app, Debug, iphonesimulator)> [언어 ...]
#   - 시뮬레이터는 미리 켜 둔다(세로). 앱은 Debug 빌드여야 한다(ShotMode 는 DEBUG 에만 있다).
#   - 화면 속 데이터는 iPhone 스크린샷과 같은 데모 데이터(-shotMode YES -shotTab N).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$1"; APP="$2"; shift 2
LANGS="$*"
[ -n "$LANGS" ] || LANGS="ko en en-GB ja zh-Hans zh-Hant es de fr it pt-BR ru th vi cs da el fi id nb nl pl sv tr ar"
BUNDLE="com.devkoan.FireTracker"
WAIT="${WAIT:-8}"

locale_of() {
  case "$1" in
    ko) echo ko_KR ;; en) echo en_US ;; en-GB) echo en_GB ;; zh-Hans) echo zh_CN ;; zh-Hant) echo zh_TW ;;
    ja) echo ja_JP ;; ru) echo ru_RU ;; es) echo es_ES ;; de) echo de_DE ;; fr) echo fr_FR ;; it) echo it_IT ;;
    pt-BR) echo pt_BR ;; th) echo th_TH@calendar=gregorian ;; vi) echo vi_VN ;; cs) echo cs_CZ ;; da) echo da_DK ;;
    el) echo el_GR ;; fi) echo fi_FI ;; id) echo id_ID ;; nb) echo nb_NO ;; nl) echo nl_NL ;; pl) echo pl_PL ;;
    sv) echo sv_SE ;; tr) echo tr_TR ;; ar) echo ar_SA@calendar=gregorian ;; *) echo "$1" ;;
  esac
}
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

shot() { # 언어 출력파일 탭번호
  lang="$1"; out="$2"; tab="$3"
  loc="$(locale_of "$lang")"
  t 30 xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
  # 가끔 launch 가 응답하지 않는다 — 한 번 더 시도한다.
  t 60 xcrun simctl launch "$DEV" "$BUNDLE" -shotMode YES -shotTab "$tab" \
      -AppleLanguages "($lang)" -AppleLocale "$loc" >/dev/null \
  || { t 30 xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true; sleep 3
       t 60 xcrun simctl launch "$DEV" "$BUNDLE" -shotMode YES -shotTab "$tab" \
           -AppleLanguages "($lang)" -AppleLocale "$loc" >/dev/null; }
  sleep "$WAIT"
  mkdir -p "$(dirname "$out")"
  # 시뮬레이터 서비스는 Documents 안에 바로 쓰지 못할 때가 있다 — 임시 폴더에 찍고 옮긴다.
  tmp="${TMPDIR:-/tmp}/ipad-shot-$$.png"
  t 60 xcrun simctl io "$DEV" screenshot "$tmp" >/dev/null 2>&1
  mv -f "$tmp" "$out"
  echo "  $out"
}

t 30 xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 >/dev/null 2>&1 || true
t 120 xcrun simctl install "$DEV" "$APP"
# 부팅 뒤 첫 실행은 시뮬레이터가 Apple 계정 로그인 창을 띄운다(계정이 없어서). 한 번 띄웠다 끄면 그 뒤로는 뜨지 않는다.
t 60 xcrun simctl launch "$DEV" "$BUNDLE" -shotMode YES -shotTab 0 >/dev/null 2>&1 || true
sleep "$WAIT"
t 30 xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
for lang in $LANGS; do
  echo "▸ $lang"
  OUT="$ROOT/docs/screenshots/raw/$lang"
  shot "$lang" "$OUT/ipad-01-assets.png"    1
  shot "$lang" "$OUT/ipad-02-dashboard.png" 0
  shot "$lang" "$OUT/ipad-03-journey.png"   2
  shot "$lang" "$OUT/ipad-04-calc.png"      3
done
