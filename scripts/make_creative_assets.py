#!/usr/bin/env python3
"""App Store 크리에이티브 자산(제품 페이지 헤더 · 검색 결과) 생성: HTML → 헤드리스 Chrome.

사용법: python3 scripts/make_creative_assets.py [언어 ...]     (없으면 전부)

자리
  docs/screenshots/creative/<스토어 로케일>/header.png   3840x1646  제품 페이지 맨 위
  docs/screenshots/creative/<스토어 로케일>/search.png   3840x2560  검색 결과 (없으면 스크린샷이 대신 보인다)

⚠️ 안전 영역 밖은 기기에 따라 잘린다. 글은 **반드시** 안전 영역 안에 둔다(배경 · 기기 그림은 넘쳐도 된다).
   수치는 Apple 공식 PSD 템플릿에서 잰 값이다(https://developer.apple.com/app-store/asset-best-practices/).
   아이폰에서 헤더는 가운데만 남고, 검색 결과는 약 385pt 폭으로 줄어 보인다. 그래서 글이 크다.

⚠️ 가격 · 할인 · 주소(URL) · 수상 · 다른 플랫폼 이름은 넣지 않는다(Apple 가이드).
"""
import shutil, subprocess, sys, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw" / "creative"
OUT = ROOT / "docs" / "screenshots" / "creative"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 앱 언어 코드 → App Store Connect 로케일. 퇴사각은 지금 한국어 페이지 하나뿐이다.
STORE = {"ko": "ko", "en": "en", "en-GB": "en-GB", "ja": "ja", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "es": "es", "de": "de", "fr": "fr", "it": "it", "pt-BR": "pt-BR", "ru": "ru", "th": "th", "vi": "vi", "cs": "cs", "da": "da", "el": "el"}

# (가로, 세로, 안전 영역 left, top, right, bottom)
SPEC = {
    "header": (3840, 1646, (1097, 493, 2743, 1154)),
    "search": (3840, 2560, (836, 765, 3004, 1795)),
}

# 검색 결과 — 스크린샷 1장(대시보드: 목표 달성률 · 목표까지 남은 금액)과 같은 이야기.
# 눈썹글은 검색어(키워드: 은퇴, 파이어족, 노후계산)다.
SEARCH = {
    "ko": ("은퇴 계산기", "내 은퇴,<br>얼마나 남았을까", "자산을 적으면 목표까지 남은 돈이 보여요"),
    "en": ("FIRE calculator", "How far is<br>your exit?", "Log your assets to see what's left to your goal"),
    "en-GB": ("FIRE calculator", "How far is<br>your exit?", "Log your assets to see what's left to your goal"),
    "ja": ("退職計算アプリ", "自分の退職まで、<br>あとどのくらい？", "資産を入力すると目標までの残りがわかります"),
    "zh-Hans": ("退休计算器", "我的退休，<br>还有多远？", "记录资产，就能看到距目标还差多少"),
    "zh-Hant": ("退休計算器", "我的退休，<br>還有多遠？", "記錄資產，就能看到距目標還差多少"),
    "es": ("Calculadora de retiro", "¿Cuánto falta para<br>tu salida?", "Registra tus activos y ve lo que falta para tu objetivo"),
    "de": ("Ruhestandsrechner", "Wie weit ist dein<br>Ausstieg entfernt?", "Trag dein Vermögen ein und sieh, was bis zum Ziel fehlt"),
    "fr": ("Calculateur de retraite", "Où en est<br>votre départ ?", "Notez vos actifs et voyez ce qu’il reste jusqu’à l’objectif"),
    "it": ("Calcolo pensione", "A che punto è<br>la tua uscita?", "Registra il patrimonio e vedi cosa manca all’obiettivo"),
    "pt-BR": ("Calculadora de aposentadoria", "Quanto falta para<br>a sua saída?", "Registre seus ativos e veja o que falta para a meta"),
    "ru": ("Калькулятор пенсии", "Сколько осталось<br>до вашего ухода?", "Запишите активы и увидите, сколько осталось до цели"),
    "th": ("เครื่องคิดเลขเกษียณ", "อีกไกลแค่ไหน<br>จะออกจากงานได้?", "บันทึกสินทรัพย์แล้วดูว่าเหลืออีกเท่าไรถึงเป้า"),
    "vi": ("Máy tính nghỉ hưu", "Ngày nghỉ việc của bạn<br>còn bao xa?", "Ghi tài sản để thấy còn bao nhiêu đến mục tiêu"),
    "cs": ("Důchodová kalkulačka", "Jak daleko je<br>váš odchod?", "Zapište majetek a uvidíte, kolik chybí k cíli"),
    "da": ("Pensionsberegner", "Hvor langt er der<br>til dit stop?", "Registrér aktiver og se, hvad der mangler til målet"),
    "el": ("Υπολογιστής σύνταξης", "Πόσο μακριά είναι<br>η αποχώρησή σας;", "Καταγράψτε τα περιουσιακά σας και δείτε τι λείπει για τον στόχο"),
}

# 헤더 — 한 가지 약속: 회사를 그만둬도 되는 날까지의 거리를 보여 준다.
HEADER = {
    "ko": ("파이어족 계산기", "퇴사까지 남은 거리,<br>숫자로 확인하세요"),
    "en": ("FIRE calculator", "See how far you are<br>from quitting, in numbers"),
    "en-GB": ("FIRE calculator", "See how far you are<br>from quitting, in numbers"),
    "ja": ("FIRE計算機", "退職までの距離を、<br>数字で確かめよう"),
    "zh-Hans": ("FIRE计算器", "距离辞职还有多远，<br>用数字确认"),
    "zh-Hant": ("FIRE計算機", "距離離職還有多遠，<br>用數字確認"),
    "es": ("Calculadora FIRE", "Mide con números<br>cuánto falta para dejarlo"),
    "de": ("FIRE-Rechner", "Wie weit ist dein Ausstieg?<br>Prüf es mit Zahlen"),
    "fr": ("Calculateur FIRE", "Mesurez en chiffres<br>la distance jusqu’au départ"),
    "it": ("Calcolo FIRE", "Misura con i numeri<br>quanto manca all’uscita"),
    "pt-BR": ("Calculadora FIRE", "Meça em números<br>a distância até a saída"),
    "ru": ("Калькулятор FIRE", "Расстояние до ухода<br>— в цифрах"),
    "th": ("เครื่องคิดเลข FIRE", "ระยะทางสู่วันออกจากงาน<br>ดูด้วยตัวเลข"),
    "vi": ("Máy tính FIRE", "Khoảng cách đến ngày nghỉ việc,<br>xem bằng con số"),
    "cs": ("Kalkulačka FIRE", "Vzdálenost k odchodu<br>změřte čísly"),
    "da": ("FIRE-beregner", "Mål afstanden til dit stop<br>med tal"),
    "el": ("Υπολογιστής FIRE", "Μετρήστε με αριθμούς<br>την απόσταση ως την αποχώρηση"),
}

# 바탕 · 글자색은 앱 화면(Theme.swift)과 같다: 따뜻한 크림 바탕, 금색 강조 하나("quiet money").
BASE_CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; }
body { background:#FAF6F0; position:relative;
  font-family:-apple-system, "SF Pro Display", "Apple SD Gothic Neo", sans-serif; }
.glow { position:absolute; border-radius:50%%; filter:blur(170px); pointer-events:none; }
.text { position:absolute; display:flex; flex-direction:column; justify-content:center; }
.eyebrow { font-weight:800; color:#D18A22; letter-spacing:-0.01em; line-height:1.15; }
.headline { font-weight:800; color:#1F1B17; letter-spacing:-0.03em; line-height:1.12; text-wrap:balance; }
.sub { font-weight:500; color:#6E675C; letter-spacing:-0.01em; line-height:1.35; text-wrap:balance; }
:lang(ko) .headline, :lang(ko) .sub, :lang(ko) .eyebrow { word-break:keep-all; }
.phone { position:absolute; background:#1F1B17; border:6px solid #d9cfbf; padding:40px; border-radius:190px;
  box-shadow: 0 60px 160px rgba(90,60,20,.22), 0 0 0 2px #2a2520 inset; }
.phone img { width:100%%; display:block; border-radius:152px; }
/* 달성률 링 — 대시보드의 '목표 달성률'을 닮은 장식. 안전 영역 밖에만 둔다. */
.ring { position:absolute; border-radius:50%%;
  -webkit-mask: radial-gradient(farthest-side, transparent calc(100%% - var(--w)), #000 calc(100%% - var(--w) + 1px));
          mask: radial-gradient(farthest-side, transparent calc(100%% - var(--w)), #000 calc(100%% - var(--w) + 1px)); }
"""

# 글이 상자를 넘지 않을 때까지 줄인다. 잘리는 글은 없다 - 끝까지 안 맞으면 표시하고 멈춘다.
FIT_JS = """
<script>
// 문구에 적은 줄(<br>)보다 더 쪼개지면 "Rispondi / con un / tocco" 처럼 읽기가 끊긴다.
// 적은 줄 수를 지킬 때까지 줄인다.
function lines(el) {
  return Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
}
function fit(box, el, max, min) {
  const want = el.querySelectorAll('br').length + 1;
  let size = max;
  el.style.fontSize = size + 'px';
  while (size > min && (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 ||
         lines(el) > want)) {
    size -= 4; el.style.fontSize = size + 'px';
  }
  if (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 || lines(el) > want)
    document.body.dataset.overflow = '1';
}
document.fonts.ready.then(() => {
  const box = document.querySelector('.text');
  const h = document.querySelector('.headline');
  fit(box, h, +h.dataset.max, +h.dataset.min);
  document.body.dataset.done = '1';
});
</script>
"""


def phone(img, left, top, width, rotate=0):
    return (f'<div class="phone" style="left:{left}px;top:{top}px;width:{width}px;'
            f'transform:rotate({rotate}deg)"><img src="{img}"></div>')


def ring(x, y, size, pct, width, color_a, color_b, track="rgba(120,90,40,.09)"):
    deg = int(360 * pct)
    return (f'<div class="ring" style="left:{x}px;top:{y}px;width:{size}px;height:{size}px;--w:{width}px;'
            f'background:conic-gradient({color_a} 0deg, {color_b} {deg}deg, {track} {deg}deg)"></div>')


GOLD = ("#E8A33D", "#F2C46B")
GREEN = ("#2E9E78", "#4CAF8E")


def search_html(lang):
    W, H, (l, t, r, b) = SPEC["search"]
    eyebrow, headline, sub = SEARCH[lang]
    sw, sh = r - l, b - t
    col = int(sw * 0.56)
    ph_w = 1040
    ph_left = l + col + int(sw * 0.04)
    img = (RAW / lang / "01-dashboard.png").as_uri()
    return f"""
<div class="glow" style="left:{ph_left - 300}px;top:500px;width:1700px;height:1700px;background:rgba(232,163,61,.20)"></div>
<div class="glow" style="left:{l - 700}px;top:{t - 500}px;width:1400px;height:1000px;background:rgba(46,158,120,.10)"></div>
{ring(120, 180, 560, 0.72, 70, *GOLD)}
{ring(380, 1960, 380, 1.0, 54, *GREEN)}
{phone(img, ph_left, t - 360, ph_w, 0)}
<div class="text" style="left:{l}px;top:{t}px;width:{col}px;height:{sh}px">
  <div class="eyebrow" style="font-size:96px">{eyebrow}</div>
  <div class="headline" data-max="250" data-min="140" style="margin-top:36px">{headline}</div>
  <div class="sub" style="font-size:84px;margin-top:52px">{sub}</div>
</div>"""


def header_html(lang):
    W, H, (l, t, r, b) = SPEC["header"]
    eyebrow, headline = HEADER[lang]
    sw, sh = r - l, b - t
    left_img = (RAW / lang / "02-assets.png").as_uri()
    right_img = (RAW / lang / "03-journey.png").as_uri()
    rings = "".join([
        ring(-120, -160, 520, 0.35, 64, *GOLD),
        ring(820, 1240, 300, 1.0, 44, *GREEN),
        ring(3500, -40, 360, 1.0, 50, *GREEN),
        ring(2860, 1280, 420, 0.6, 58, *GOLD),
    ])
    return f"""
<div class="glow" style="left:{l - 200}px;top:{t - 400}px;width:{sw + 400}px;height:{sh + 800}px;background:rgba(232,163,61,.14)"></div>
<div class="glow" style="left:2500px;top:200px;width:1400px;height:1400px;background:rgba(242,196,107,.20)"></div>
<div class="glow" style="left:0px;top:200px;width:1400px;height:1400px;background:rgba(46,158,120,.08)"></div>
{rings}
{phone(left_img, 300, 360, 640, -9)}
{phone(right_img, 2900, 360, 640, 9)}
<div class="text" style="left:{l}px;top:{t}px;width:{sw}px;height:{sh}px;align-items:center;text-align:center">
  <div class="eyebrow" style="font-size:76px">{eyebrow}</div>
  <div class="headline" data-max="210" data-min="110" style="margin-top:22px">{headline}</div>
</div>"""


def html_lang(lang):
    return {"zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}.get(lang, lang)


def render(lang, kind):
    W, H, _ = SPEC[kind]
    body = search_html(lang) if kind == "search" else header_html(lang)
    page = (f'<!doctype html><html lang="{html_lang(lang)}"><head><meta charset="utf-8"><style>'
            f'{BASE_CSS % {"W": W, "H": H}}</style></head><body>{body}{FIT_JS}</body></html>')
    html_path = pathlib.Path(tempfile.gettempdir()) / f"firetracker-creative-{lang}-{kind}.html"
    html_path.write_text(page, encoding="utf-8")
    # 글이 끝까지 안 맞으면 그림을 만들지 않는다(잘린 글이 스토어에 올라가는 것보다 낫다).
    dom = subprocess.run([CHROME, "--headless=new", "--dump-dom", f"--window-size={W},{H}",
                          "--force-device-scale-factor=1", "--disable-gpu", "--virtual-time-budget=3000",
                          html_path.as_uri()], capture_output=True, text=True, timeout=90).stdout
    if 'data-done="1"' not in dom:
        raise SystemExit(f"글 맞추기가 끝나지 않았다: {lang} {kind}")
    if 'data-overflow="1"' in dom:
        raise SystemExit(f"글이 안전 영역을 넘는다: {lang} {kind} - 문구를 줄일 것")
    out_dir = OUT / STORE.get(lang, lang)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_png = out_dir / f"{kind}.png"
    # ⚠️ Chrome 은 가끔 아무것도 안 그리고 끝나거나 멈춘다. 세 번까지 한다.
    for _ in range(3):
        try:
            r = subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                                f"--window-size={W},{H}", "--force-device-scale-factor=1",
                                "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=3000",
                                "--allow-file-access-from-files", html_path.as_uri()],
                               capture_output=True, timeout=90)
        except subprocess.TimeoutExpired:
            continue
        if r.returncode == 0:
            break
    else:
        raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
    print(f"rendered {out_png}")

if __name__ == "__main__":
    langs = sys.argv[1:] or list(SEARCH)
    for lang in langs:
        if lang not in SEARCH:
            raise SystemExit(f"모르는 언어: {lang} (아는 것: {', '.join(SEARCH)})")
        for kind in ("header", "search"):
            render(lang, kind)
