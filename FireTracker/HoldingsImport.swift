import SwiftUI
import SwiftData

// 캡처 말고 보유 종목을 가져오는 두 갈래 — 증권사에서 내려받은 표(CSV·엑셀 복사)와
// 한국투자증권 잔고. 둘 다 `ParsedHolding` 을 내고, 맞추기·적용은 ScreenshotImportView 가 한다.

// MARK: - 표 (CSV · TSV · 엑셀에서 복사 · HTML 로 된 .xls)

enum HoldingsFile {
    /// 파일 바이트 → 글자. 국내 증권사 CSV 는 아직 EUC-KR(CP949)이 많다.
    static func text(from data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        return String(data: data, encoding: cp949)
    }

    // 칸 이름 — 앞에 있는 말이 먼저 잡힌다. 비교는 소문자·띄어쓰기 없이.
    private static let codeHeads = ["종목코드", "종목번호", "상품코드", "상품번호", "티커", "ticker", "symbol", "코드", "code"]
    private static let nameHeads = ["종목명", "상품명", "종목", "name"]
    private static let qtyHeads = ["보유수량", "잔고수량", "보유량", "수량", "quantity", "shares", "qty"]
    private static let avgHeads = ["평균단가", "평균매입가", "매입평균가", "매입단가", "평단가", "평단",
                                   "averagecost", "avgcost", "avgprice", "averageprice", "costpershare"]
    private static let costHeads = ["매입금액", "매입원금", "투자원금", "원금", "costbasis", "totalcost"]
    private static let valueHeads = ["평가금액", "평가액", "marketvalue", "value"]
    private static let totalWords = ["합계", "총계", "소계", "total"]

    static func rows(from text: String) -> [ParsedHolding] {
        let table = cells(text)
        if let (at, cols) = header(table) {
            return table.dropFirst(at + 1).compactMap { row(from: $0, cols: cols) }
        }
        // 칸 이름이 없으면 '종목, 수량, 평균단가' 순서로 읽는다.
        return table.compactMap(bareRow)
    }

    // MARK: 표 쪼개기

    private static func cells(_ text: String) -> [[String]] {
        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        if body.range(of: "<table", options: .caseInsensitive) != nil { return htmlCells(body) }
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sample = lines.prefix(10).joined()
        let sep: Character = sample.contains("\t") ? "\t"
            : sample.filter { $0 == ";" }.count > sample.filter { $0 == "," }.count ? ";" : ","
        return lines.map { line in
            let parts = split(line, by: sep)
            // 구분자 없이 한 줄로 적은 것("삼성전자 10 71000")은 띄어쓰기로 나눈다.
            return parts.count == 1 ? line.split(separator: " ").map(String.init) : parts
        }
    }

    /// 따옴표 안의 구분자("1,234")는 칸을 나누지 않는다.
    private static func split(_ line: String, by sep: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            else if ch == sep && !quoted { out.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 증권사 '엑셀 저장'은 HTML 표인 경우가 많다.
    private static func htmlCells(_ html: String) -> [[String]] {
        html.components(separatedBy: "<tr").dropFirst().map { tr in
            tr.components(separatedBy: "<t").dropFirst()
                .filter { seg in ["d>", "d ", "h>", "h "].contains { seg.lowercased().hasPrefix($0) } }
                .map { cell in
                    let inner = cell.split(separator: ">", maxSplits: 1).last.map(String.init) ?? ""
                    return inner.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "&nbsp;", with: " ")
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
        }
    }

    // MARK: 칸 맞추기

    private struct Columns {
        var code: Int?, name: Int?, qty: Int?, avg: Int?, cost: Int?, value: Int?
        // 금액 칸 이름이 통화를 말하면 그대로, 말하지 않으면 nil — 미국 종목만 달러로 본다.
        var inUSD: Bool?
    }

    private static func key(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
    }

    /// 앞쪽 15줄에서 칸 이름 줄을 찾는다 — 종목(코드나 이름)과 수량·금액 중 하나가 있어야 한다.
    private static func header(_ table: [[String]]) -> (Int, Columns)? {
        for (i, row) in table.prefix(15).enumerated() {
            let keys = row.map(key)
            var used: Set<Int> = []
            func find(_ heads: [String]) -> Int? {
                for h in heads {
                    if let j = keys.indices.first(where: { !used.contains($0) && keys[$0].contains(h) }) {
                        used.insert(j)
                        return j
                    }
                }
                return nil
            }
            var c = Columns()
            c.code = find(codeHeads)
            c.avg = find(avgHeads)
            c.cost = find(costHeads)
            c.value = find(valueHeads)
            c.qty = find(qtyHeads)
            c.name = find(nameHeads)
            guard c.code != nil || c.name != nil, c.qty != nil || c.value != nil || c.cost != nil else { continue }
            let money = [c.avg, c.cost, c.value].compactMap { $0 }.map { keys[$0] }
            if money.contains(where: { $0.contains("usd") || $0.contains("$") || $0.contains("외화") }) {
                c.inUSD = true
            } else if money.contains(where: { $0.contains("krw") || $0.contains("원화") }) {
                c.inUSD = false
            }
            return (i, c)
        }
        return nil
    }

    private static func number(_ s: String?) -> Double? {
        guard let s else { return nil }
        let t = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(t)
    }

    /// 국내 6자리(앞에 'A'가 붙기도 함) 또는 미국 티커(대문자). 아니면 nil —
    /// 'Apple' 같은 이름을 티커로 잘못 보지 않게 소문자가 섞이면 이름으로 둔다.
    static func symbol(_ raw: String) -> (code: String, isUS: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.contains(where: \.isLowercase) else { return nil }
        if s.count == 7, s.hasPrefix("A"), s.dropFirst().first?.isNumber == true { s.removeFirst() }
        if s.count == 6, s.first?.isNumber == true, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) }) {
            return (s, false)
        }
        if (1...6).contains(s.count), s.first?.isLetter == true,
           s.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == ".") }) {
            return (s, true)
        }
        return nil
    }

    private static func make(code: String?, name: String, qty: Double?, avg: Double?,
                             cost: Double?, value: Double?, inUSD: Bool?) -> ParsedHolding? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !totalWords.contains(where: { name.lowercased().hasPrefix($0) }) else { return nil }
        let sym = code.flatMap(symbol)
        guard sym != nil || name.rangeOfCharacter(from: .letters) != nil else { return nil }
        let q = qty.flatMap { $0 > 0 ? $0 : nil }
        let cost = cost ?? q.flatMap { q in avg.map { q * $0 } }
        let value = value ?? cost ?? 0
        guard value > 0 || q != nil else { return nil }
        var row = ParsedHolding(name: name, amountText: String(Int(value.rounded())))
        row.symbol = sym?.code ?? ""
        row.isUS = sym?.isUS ?? false
        row.quantity = q
        row.cost = cost
        row.inUSD = inUSD ?? row.isUS
        return row
    }

    private static func row(from cells: [String], cols: Columns) -> ParsedHolding? {
        func at(_ i: Int?) -> String? { i.flatMap { cells.indices.contains($0) ? cells[$0] : nil } }
        let name = at(cols.name) ?? ""
        // 이름 칸에 코드가 들어 있는 표도 있다.
        let code = at(cols.code) ?? (symbol(name) != nil ? name : nil)
        return make(code: code, name: code == name ? "" : name,
                    qty: number(at(cols.qty)), avg: number(at(cols.avg)),
                    cost: number(at(cols.cost)), value: number(at(cols.value)), inUSD: cols.inUSD)
    }

    /// 칸 이름 없는 줄 — 앞의 글자 칸이 종목(코드나 이름), 그 뒤 숫자 둘이 수량·평균단가.
    private static func bareRow(_ cells: [String]) -> ParsedHolding? {
        guard let first = cells.first, symbol(first) != nil || first.rangeOfCharacter(from: .letters) != nil
        else { return nil }
        var end = 1
        while end < cells.count, cells[end].rangeOfCharacter(from: .letters) != nil { end += 1 }
        let nums = cells[end...].compactMap(number)
        guard nums.count >= 2 else { return nil }
        let isCode = symbol(first) != nil
        let name = cells[(isCode ? 1 : 0)..<end].joined(separator: " ")
        return make(code: isCode ? first : nil, name: name,
                    qty: nums[0], avg: nums[1], cost: nil, value: nil, inUSD: nil)
    }

    /// 달러로 읽은 줄을 원으로 바꾼다 — 앱의 금액은 모두 원이다.
    static func toKRW(_ rows: [ParsedHolding]) async -> [ParsedHolding] {
        guard rows.contains(where: \.inUSD), let fx = try? await PriceService.usdToKrw() else { return rows }
        return rows.map { r in
            guard r.inUSD else { return r }
            var r = r
            r.amountText = String(Int((r.amount * fx).rounded()))
            r.cost = r.cost.map { ($0 * fx).rounded() }
            r.gain = r.gain.map { $0 * fx }
            r.inUSD = false
            return r
        }
    }
}

// MARK: - 한국투자증권 잔고 (사용자가 직접 발급한 앱키)

enum KISBalance {
    private static let base = "https://openapi.koreainvestment.com:9443"

    /// "12345678-01" → (CANO, ACNT_PRDT_CD). 8자리만 넣으면 종합계좌(01)로 본다.
    static func account(_ s: String) -> (cano: String, product: String)? {
        let d = s.filter(\.isNumber)
        if d.count == 10 { return (String(d.prefix(8)), String(d.suffix(2))) }
        if d.count == 8 { return (d, "01") }
        return nil
    }

    /// 국내 + 미국 보유 종목. 해외주식을 안 쓰는 계좌면 국내만 돌려준다.
    static func holdings(appKey: String, appSecret: String, account acct: String) async throws -> [ParsedHolding] {
        guard let (cano, product) = account(acct) else {
            throw PriceError.message(String(localized: "계좌번호 10자리를 넣어 주세요 (예: 12345678-01)"))
        }
        let token = try await KISTokenStore.shared.token(appKey: appKey, appSecret: appSecret)
        let auth = ["authorization": "Bearer \(token)", "appkey": appKey, "appsecret": appSecret, "custtype": "P"]
        let acctQuery = ["CANO": cano, "ACNT_PRDT_CD": product]

        let kr = try await pages(path: "/uapi/domestic-stock/v1/trading/inquire-balance", trID: "TTTC8434R",
                                 headers: auth, query: acctQuery.merging([
                                    "AFHR_FLPR_YN": "N", "OFL_YN": "", "INQR_DVSN": "02", "UNPR_DVSN": "01",
                                    "FUND_STTL_ICLD_YN": "N", "FNCG_AMT_AUTO_RDPT_YN": "N", "PRCS_DVSN": "00"
                                 ]) { a, _ in a }, ctx: "100")
            .compactMap { o -> ParsedHolding? in
                row(code: o["pdno"], name: o["prdt_name"], qty: o["hldg_qty"],
                    cost: o["pchs_amt"], value: o["evlu_amt"], isUS: false)
            }
        // 실전 'NASD' 는 미국 전체(나스닥·뉴욕·아멕스).
        let us = (try? await pages(path: "/uapi/overseas-stock/v1/trading/inquire-balance", trID: "TTTS3012R",
                                   headers: auth, query: acctQuery.merging([
                                      "OVRS_EXCG_CD": "NASD", "TR_CRCY_CD": "USD"
                                   ]) { a, _ in a }, ctx: "200")) ?? []
        let usRows = us.compactMap { o -> ParsedHolding? in
            row(code: o["ovrs_pdno"], name: o["ovrs_item_name"], qty: o["ovrs_cblc_qty"],
                cost: o["frcr_pchs_amt1"], value: o["ovrs_stck_evlu_amt"], isUS: true)
        }
        return kr + usRows
    }

    private static func row(code: String?, name: String?, qty: String?, cost: String?,
                            value: String?, isUS: Bool) -> ParsedHolding? {
        guard let code, !code.isEmpty, let q = qty.flatMap(Double.init), q > 0 else { return nil }
        let value = value.flatMap(Double.init) ?? 0
        var r = ParsedHolding(name: name?.trimmingCharacters(in: .whitespaces) ?? "",
                              amountText: String(Int(value.rounded())))
        r.symbol = code.uppercased()
        r.isUS = isUS
        r.quantity = q
        r.cost = cost.flatMap(Double.init)
        r.inUSD = isUS
        return r
    }

    /// 50줄씩 나눠 오는 잔고를 끝까지 받는다. 응답 머리 tr_cont 가 F·M 이면 더 있다.
    private static func pages(path: String, trID: String, headers: [String: String],
                              query: [String: String], ctx: String) async throws -> [[String: String]] {
        var out: [[String: String]] = []
        var fk = "", nk = "", cont = ""
        for _ in 0..<10 {
            var comps = URLComponents(string: base + path)
            comps?.queryItems = query.merging(["CTX_AREA_FK\(ctx)": fk, "CTX_AREA_NK\(ctx)": nk]) { a, _ in a }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps?.url else { throw PriceError.badURL }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(trID, forHTTPHeaderField: "tr_id")
            req.setValue(cont, forHTTPHeaderField: "tr_cont")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw PriceError.http(http.statusCode) }
                throw PriceError.decode
            }
            if let rt = obj["rt_cd"] as? String, rt != "0" {
                throw PriceError.message(((obj["msg1"] as? String) ?? "").trimmingCharacters(in: .whitespaces))
            }
            out += ((obj["output1"] as? [[String: Any]]) ?? []).map { $0.compactMapValues { $0 as? String } }
            let next = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "tr_cont") ?? ""
            guard next == "F" || next == "M" else { break }
            fk = (obj["ctx_area_fk\(ctx)"] as? String) ?? ""
            nk = (obj["ctx_area_nk\(ctx)"] as? String) ?? ""
            cont = "N"
        }
        return out
    }
}

// 한국투자증권 키와 계좌번호를 넣고 잔고를 불러오는 시트. 키는 다음에도 쓰도록 설정에 남긴다.
struct KISImportSheet: View {
    let onLoaded: ([ParsedHolding]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var settingsList: [FireSettings]

    @State private var appKey = ""
    @State private var appSecret = ""
    @State private var account = ""
    @State private var loading = false
    @State private var error: String?

    private var ready: Bool {
        !appKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespaces).isEmpty
            && KISBalance.account(account) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("앱키", text: $appKey)
                    SecureField("앱시크릿", text: $appSecret)
                    TextField("계좌번호 (예: 12345678-01)", text: $account)
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("한국투자증권 KIS Developers에서 내 계좌로 앱키를 발급받아 넣어 주세요. 국내·미국 보유 종목의 수량과 매입금액을 가져와요. 조회만 하고 주문은 하지 않아요. 키는 이 기기에만(동기화를 켰다면 내 iCloud에도) 저장돼요.")
                        if let url = URL(string: "https://apiportal.koreainvestment.com") {
                            Link("KIS Developers 열기", destination: url)
                        }
                    }
                    .font(.footnote)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.negative)
                    }
                }

                Section {
                    Button {
                        Task { await load() }
                    } label: {
                        HStack {
                            Spacer()
                            if loading { ProgressView() } else { Text("잔고 불러오기").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!ready || loading)
                }
            }
            .navigationTitle("한국투자증권")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", systemImage: "xmark") { dismiss() } }
            }
        }
        .onAppear {
            guard let s = settingsList.first else { return }
            appKey = s.kisAppKey
            appSecret = s.kisAppSecret
            account = s.kisAccount
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        let key = appKey.trimmingCharacters(in: .whitespaces)
        let secret = appSecret.trimmingCharacters(in: .whitespaces)
        do {
            let rows = try await KISBalance.holdings(appKey: key, appSecret: secret, account: account)
            let s = settingsList.first ?? {
                let s = FireSettings()
                context.insert(s)
                return s
            }()
            s.kisAppKey = key
            s.kisAppSecret = secret
            s.kisAccount = account.trimmingCharacters(in: .whitespaces)
            context.saveReporting(String(localized: "API 키"))
            guard !rows.isEmpty else {
                error = String(localized: "이 계좌에 보유 종목이 없어요.")
                return
            }
            onLoaded(rows)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
