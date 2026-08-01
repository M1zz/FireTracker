#!/usr/bin/env python3
"""나라별 소비자물가지수(CPI)를 받아 FireTracker/CPIData.swift 를 생성한다.

출처: World Bank Open Data — Consumer price index (FP.CPI.TOTL, 2010 = 100).
      원자료는 각국 통계기관(한국 통계청, 미국 BLS, 일본 총무성 …)이고
      World Bank가 같은 기준으로 표준화해 제공한다. 인증 키 없이 쓸 수 있다.

받은 값을 2020년 = 100으로 다시 맞춰(rebase) 앱에 내장한다. 실질임금 계산은
지수의 '비율'만 쓰기 때문에 어느 해를 100으로 두든 결과는 같지만, 화면에
"2020년 기준"으로 표기하고 있어 기준연도를 통일해 둔다.

물가는 1년에 한 번 갱신되므로, 연초에 이 스크립트를 다시 돌려 표를 새로 만들면 된다.

    python3 scripts/fetch_cpi.py
"""
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

BASE_YEAR = 2020
FIRST_YEAR = 1995
OUT = Path(__file__).resolve().parent.parent / "FireTracker" / "CPIData.swift"

# (World Bank 코드, 표기 이름, 국기, 통화 기호, 기호가 앞에 오는지)
COUNTRIES = [
    ("KR",  "한국",       "🇰🇷", "원",   False),
    ("US",  "미국",       "🇺🇸", "$",    True),
    ("JP",  "일본",       "🇯🇵", "¥",    True),
    ("CN",  "중국",       "🇨🇳", "元",   False),
    ("HK",  "홍콩",       "🇭🇰", "HK$",  True),
    ("SG",  "싱가포르",   "🇸🇬", "S$",   True),
    ("VN",  "베트남",     "🇻🇳", "₫",    False),
    ("TH",  "태국",       "🇹🇭", "฿",    True),
    ("PH",  "필리핀",     "🇵🇭", "₱",    True),
    ("ID",  "인도네시아", "🇮🇩", "Rp",   True),
    ("MY",  "말레이시아", "🇲🇾", "RM",   True),
    ("IN",  "인도",       "🇮🇳", "₹",    True),
    ("AU",  "호주",       "🇦🇺", "A$",   True),
    ("NZ",  "뉴질랜드",   "🇳🇿", "NZ$",  True),
    ("CA",  "캐나다",     "🇨🇦", "C$",   True),
    ("GB",  "영국",       "🇬🇧", "£",    True),
    ("DE",  "독일",       "🇩🇪", "€",    True),
    ("FR",  "프랑스",     "🇫🇷", "€",    True),
    # 대만·유로존 합계는 World Bank FP.CPI.TOTL에 없어 제외.
    ("CH",  "스위스",     "🇨🇭", "CHF ", True),
]


def fetch_all():
    """한 번의 요청으로 모든 나라를 받는다(나라별 요청은 자주 타임아웃난다)."""
    codes = ";".join(c[0] for c in COUNTRIES)
    url = (f"https://api.worldbank.org/v2/country/{codes}/indicator/FP.CPI.TOTL"
           f"?format=json&per_page=20000&date={FIRST_YEAR}:2035")
    last_error = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                payload = json.load(r)
            break
        except Exception as e:  # 네트워크가 자주 끊겨 재시도한다.
            last_error = e
            print(f"  재시도 {attempt + 1}: {e}", file=sys.stderr)
    else:
        raise SystemExit(f"World Bank API 호출 실패: {last_error}")

    meta = payload[0]
    rows = payload[1] or []
    series = {}
    for row in rows:
        if row["value"] is None:
            continue
        series.setdefault(row["country"]["id"], {})[int(row["date"])] = row["value"]
    return meta.get("lastupdated", "?"), series


def contiguous(raw):
    """기준연도(2020)를 포함하는 연속 구간만 남긴다 — 중간에 빈 해가 있으면 잘라낸다."""
    start = end = BASE_YEAR
    while start - 1 in raw:
        start -= 1
    while end + 1 in raw:
        end += 1
    return start, end


def main():
    updated, series = fetch_all()
    entries = []
    for code, name, flag, symbol, leading in COUNTRIES:
        raw = series.get(code)
        if not raw or BASE_YEAR not in raw:
            print(f"건너뜀 {code} {name}: 자료 없음", file=sys.stderr)
            continue
        start, end = contiguous(raw)
        base = raw[BASE_YEAR]
        values = [round(raw[y] / base * 100, 2) for y in range(start, end + 1)]
        entries.append((code, name, flag, symbol, leading, start, end, values))
        print(f"{code} {name}: {start}~{end} ({len(values)}년), 최신 {values[-1]}")

    today = subprocess.run(["date", "+%Y-%m-%d"], capture_output=True, text=True).stdout.strip()
    lines = [
        "import Foundation",
        "",
        "// 나라별 소비자물가지수(CPI) — 2020년 = 100으로 맞춘 연평균 값.",
        "//",
        "// 출처: World Bank Open Data, Consumer price index (FP.CPI.TOTL).",
        "//       원자료는 각국 통계기관(한국 통계청, 미국 BLS, 일본 총무성 등)이고",
        "//       World Bank가 같은 기준으로 표준화해 제공한다.",
        f"// World Bank 최종 갱신: {updated} · 이 파일 생성: {today}",
        "//",
        "// ⚠️ 손으로 고치지 말 것 — `python3 scripts/fetch_cpi.py`로 다시 생성한다.",
        "//    물가는 1년에 한 번 확정되므로 연초에 한 번 돌려주면 된다.",
        "",
        "// 한 나라의 물가 시계열. values[0]이 firstYear의 지수이고 1년 간격으로 이어진다.",
        "struct CPICountry: Identifiable, Hashable {",
        "    let code: String",
        "    let name: String",
        "    let flag: String",
        "    let symbol: String        // 통화 기호",
        "    let symbolLeading: Bool   // 기호가 금액 앞에 붙는지",
        "    let firstYear: Int",
        "    let values: [Double]      // 2020년 = 100",
        "",
        "    var id: String { code }",
        "    var lastYear: Int { firstYear + values.count - 1 }",
        "",
        "    // 표 밖의 연도는 가장 가까운 끝값으로 클램프한다(아직 확정 안 난 올해 포함).",
        "    func cpi(_ year: Int) -> Double {",
        "        guard !values.isEmpty else { return 100 }",
        "        return values[min(max(year - firstYear, 0), values.count - 1)]",
        "    }",
        "",
        "    // from → to 구간의 누적 물가상승률.",
        "    func inflation(from: Int, to: Int) -> Double {",
        "        let a = cpi(from)",
        "        guard a > 0 else { return 0 }",
        "        return cpi(to) / a - 1",
        "    }",
        "",
        "    // 그 나라 통화로 금액 표기. 한국은 앱 공통 표기(억/만원)를 그대로 쓴다.",
        "    func money(_ value: Double) -> String {",
        "        if code == \"KR\" { return Fmt.wonKo(value) }",
        "        guard value.isFinite else { return symbol }",
        "        let n = Int(value.rounded()).formatted()",
        "        return symbolLeading ? \"\\(symbol)\\(n)\" : \"\\(n)\\(symbol)\"",
        "    }",
        "}",
        "",
        "enum CPIData {",
        f"    static let baseYear = {BASE_YEAR}",
        f"    static let sourceUpdated = \"{updated}\"",
        "",
        "    static let all: [CPICountry] = [",
    ]
    for code, name, flag, symbol, leading, start, end, values in entries:
        nums = ", ".join(f"{v:g}" for v in values)
        lines.append(f'        CPICountry(code: "{code}", name: "{name}", flag: "{flag}",')
        lines.append(f'                   symbol: "{symbol}", symbolLeading: {str(leading).lower()},')
        lines.append(f'                   firstYear: {start},  // ~{end}')
        lines.append(f'                   values: [{nums}]),')
    lines += [
        "    ]",
        "",
        "    // 코드로 찾기 — 없으면 한국(첫 항목)으로 되돌린다.",
        "    static func country(_ code: String) -> CPICountry {",
        "        all.first { $0.code == code } ?? all[0]",
        "    }",
        "}",
        "",
    ]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n→ {OUT} ({len(entries)}개국)")


if __name__ == "__main__":
    main()
