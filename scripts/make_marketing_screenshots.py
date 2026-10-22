#!/usr/bin/env python3
"""App Store 마케팅 스크린샷: 원본 캡처 + 헤드라인 → HTML → 헤드리스 Chrome (appstore-assets 스킬).

사용법: python3 scripts/make_marketing_screenshots.py [언어 ...]   (없으면 전부)

자리
  docs/screenshots/raw/<언어>/NN-….png          원본 캡처 (1320x2868, 스토어에 안 올라감)
  docs/screenshots/marketing/<로케일>/NN-….png   제출본 1242x2688 — DeployBar 가 이 폴더를 그대로 올린다
슬라이드마다 배치(layout)를 달리한다: hero-bleed · left-text · text-bottom · flat-rotate · dark
"""
import subprocess, sys, pathlib, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw"
OUT = ROOT / "docs" / "screenshots" / "marketing"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1242, 2688   # 이 계정의 아이폰 제출 규격

# 앱 언어 → App Store 로케일
STORE = {"ko": "ko", "en": "en", "en-GB": "en-GB", "ja": "ja", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "es": "es"}

# 파일 · 배치 · 언어별 (헤드라인, 보조 문장)
# 원본은 데모 데이터(설정 ▸ 데모)로 찍고, 맨 위 '데모 데이터로 보는 중' 띠를 잘라 냈다(1320x2702).
SHOTS = [
    ("01-dashboard.png", "hero-bleed",  {"ko": ("퇴사까지 남은 거리,<br>숫자로 확인하세요", "목표 달성률과 지난주 대비 변화를 한눈에"), "en": ("See how far you are<br>from quitting, in numbers", "Goal progress and weekly change at a glance"), "en-GB": ("See how far you are<br>from quitting, in numbers", "Goal progress and weekly change at a glance"), "ja": ("退職までの距離を、<br>数字で確かめよう", "目標達成率と先週からの変化がひと目で"), "zh-Hans": ("距离辞职还有多远，<br>用数字确认", "目标达成率与周变化一目了然"), "zh-Hant": ("距離離職還有多遠，<br>用數字確認", "目標達成率與週變化一目瞭然"), "es": ("Mide con números<br>cuánto falta para dejarlo", "Progreso del objetivo y cambio semanal de un vistazo")}),
    ("02-assets.png",    "left-text",   {"ko": ("흩어진 자산을<br>한 곳에", "부동산, 주식, 연금, 대출까지 모아 봐요"), "en": ("All your assets<br>in one place", "Property, stocks, pensions and loans together"), "en-GB": ("All your assets<br>in one place", "Property, stocks, pensions and loans together"), "ja": ("散らばった資産を<br>1か所に", "不動産、株式、年金、ローンまでまとめて確認"), "zh-Hans": ("把分散的资产<br>放在一处", "房产、股票、养老金、贷款一并查看"), "zh-Hant": ("把分散的資產<br>放在一處", "房產、股票、退休金、貸款一併檢視"), "es": ("Tus activos dispersos,<br>en un solo lugar", "Inmuebles, acciones, pensiones y préstamos juntos")}),
    ("03-journey.png",   "text-bottom", {"ko": ("목표까지 가는 길이<br>그려져요", "기간별 목표와 필요한 저축을 알려줘요"), "en": ("See the road<br>to your goal", "Goals by period and the savings you need"), "en-GB": ("See the road<br>to your goal", "Goals by period and the savings you need"), "ja": ("目標までの道のりが<br>見えてきます", "期間別の目標と必要な貯蓄がわかります"), "zh-Hans": ("通往目标的路，<br>清晰可见", "告诉你分期目标和所需储蓄"), "zh-Hant": ("通往目標的路，<br>清晰可見", "告訴你分期目標和所需儲蓄"), "es": ("El camino a tu objetivo,<br>dibujado", "Objetivos por periodo y el ahorro que necesitas")}),
    ("04-loan.png",      "dark",        {"ko": ("대출, 저축, 은퇴까지<br>계산해 봐요", "계산한 결과는 저장해 두고 다시 불러와요"), "en": ("From loans to savings<br>to retirement", "Save results and pick them up later"), "en-GB": ("From loans to savings<br>to retirement", "Save results and pick them up later"), "ja": ("ローンも貯蓄も<br>退職後も計算", "計算結果は保存して、いつでも呼び出せます"), "zh-Hans": ("贷款、储蓄、退休，<br>都能计算", "计算结果可保存，随时再次调出"), "zh-Hant": ("貸款、儲蓄、退休，<br>都能計算", "計算結果可儲存，隨時再次叫出"), "es": ("Préstamos, ahorro<br>y retiro, calculados", "Guarda los resultados y vuélvelos a cargar")}),
]

# 색은 헤더·검색 결과 그림(make_creative_assets.py)과 맞춘다.
THEME = dict(bg="#FAF6F0", ink="#1F1B17", sub="#6E675C", dark_bg="#1F1B17", dark_ink="#FAF6F0",
             dark_sub="#B9AE9C", frame="#1F1B17", rim="#d9cfbf", glow="rgba(209,138,34,.30)")

BASE_CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; }
body { background:%(bg)s; font-family:-apple-system, "Apple SD Gothic Neo", "Hiragino Sans", sans-serif; position:relative; }
.headline { font-size:96px; font-weight:800; color:%(ink)s; letter-spacing:-2px; line-height:1.22; text-wrap:balance; }
.sub { font-size:50px; font-weight:500; color:%(sub)s; letter-spacing:-1px; line-height:1.35; text-wrap:balance; }
:lang(ko) .headline, :lang(ko) .sub { word-break:keep-all; }
.phone { background:%(frame)s; border-radius:112px; border:3px solid %(rim)s; padding:24px;
  box-shadow: 60px 90px 120px rgba(0,0,0,.24), 20px 30px 50px rgba(0,0,0,.14); }
.phone img { width:100%%; display:block; border-radius:89px; }
"""

LAYOUTS = {
    "hero-bleed": """
.headline { text-align:center; margin-top:270px; padding:0 70px; }
.sub { text-align:center; margin-top:46px; padding:0 80px; }
.wrap { display:flex; justify-content:center; margin-top:130px; }
.phone { width:970px; }
""",
    "left-text": """
.headline { text-align:left; margin:280px 90px 0 105px; }
.sub { text-align:left; margin:44px 90px 0 109px; }
.wrap { perspective:2600px; perspective-origin:30% 30%; position:absolute; left:290px; top:960px; }
.phone { width:815px; transform:rotateY(16deg) rotateX(2deg); }
""",
    "text-bottom": """
.wrap { perspective:2800px; perspective-origin:50% 40%; display:flex; justify-content:center; margin-top:160px; }
.phone { width:850px; transform:rotateY(-10deg) rotateX(2deg); }
.headline { text-align:center; margin-top:110px; padding:0 70px; }
.sub { text-align:center; margin-top:44px; padding:0 80px; }
""",
    "flat-rotate": """
.headline { text-align:center; margin-top:250px; padding:0 70px; }
.sub { text-align:center; margin-top:46px; padding:0 80px; }
.wrap { position:absolute; left:115px; top:980px; }
.phone { width:980px; transform:rotate(-6deg); }
""",
    "dark": """
body { background:%(dark_bg)s; }
.headline { color:%(dark_ink)s; text-align:center; margin-top:270px; padding:0 70px; }
.sub { color:%(dark_sub)s; text-align:center; margin-top:46px; padding:0 80px; }
.wrap { display:flex; justify-content:center; margin-top:130px; }
.phone { width:900px; border-color:#48484e; box-shadow: 0 0 160px %(glow)s, 40px 70px 110px rgba(0,0,0,.55); }
""",
}

TEXT_FIRST = '<div class="headline">{h}</div><div class="sub">{s}</div><div class="wrap"><div class="phone"><img src="{img}"></div></div>'
PHONE_FIRST = '<div class="wrap"><div class="phone"><img src="{img}"></div></div><div class="headline">{h}</div><div class="sub">{s}</div>'
HTML = '<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'


def raw_for(lang, fname):
    p = RAW / lang / fname
    return p if p.exists() else RAW / fname


def main(langs):
    tmp = pathlib.Path(tempfile.mkdtemp())
    vals = dict(THEME, W=W, H=H)
    for lang in langs:
        out_dir = OUT / STORE[lang]
        out_dir.mkdir(parents=True, exist_ok=True)
        for fname, layout, texts in SHOTS:
            h, s = texts[lang]
            src = raw_for(lang, fname)
            assert src.exists(), f"원본 없음: {src}"
            tpl = PHONE_FIRST if layout == "text-bottom" else TEXT_FIRST
            css = BASE_CSS % vals + LAYOUTS[layout] % vals if "%(" in LAYOUTS[layout] else BASE_CSS % vals + LAYOUTS[layout]
            html = tmp / f"{lang}-{fname}.html"
            html.write_text(HTML.format(lang=lang, css=css, body=tpl.format(h=h, s=s, img=src.as_uri())), encoding="utf-8")
            out = out_dir / fname
            # Chrome 은 그림을 다 쓰고도 안 끝나거나, 아무것도 안 그리고 끝날 때가 있다.
            # 파일이 생기고 크기가 멈추면 다 된 것으로 보고 닫는다. 세 번까지 한다.
            for _ in range(3):
                out.unlink(missing_ok=True)
                proc = subprocess.Popen([CHROME, "--headless=new", f"--screenshot={out}", f"--window-size={W},{H}",
                                         "--force-device-scale-factor=1", "--hide-scrollbars", "--disable-gpu",
                                         "--no-first-run", "--disable-extensions", "--disable-background-networking",
                                         "--virtual-time-budget=3000", "--allow-file-access-from-files",
                                         f"--user-data-dir={tmp / 'chrome'}", html.as_uri()],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                size, deadline = -1, time.time() + 90
                while time.time() < deadline:
                    time.sleep(1)
                    now = out.stat().st_size if out.exists() else -1
                    if now > 0 and now == size:
                        break
                    if proc.poll() is not None and now <= 0:
                        break
                    size = now
                proc.kill(); proc.wait()
                if out.exists() and out.stat().st_size > 0:
                    break
            else:
                raise SystemExit(f"Chrome 이 그리지 못했다: {out}")
            print("rendered", out.relative_to(ROOT))


if __name__ == "__main__":
    main(sys.argv[1:] or list(STORE))
