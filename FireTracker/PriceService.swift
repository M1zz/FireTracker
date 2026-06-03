import Foundation

// Errors surfaced to the UI as Korean status messages.
enum PriceError: LocalizedError {
    case badURL
    case http(Int)
    case decode
    case empty
    case missingKey(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badURL:            return "잘못된 요청 주소"
        case .http(let c):       return "서버 오류 (HTTP \(c))"
        case .decode:            return "응답을 해석할 수 없습니다"
        case .empty:             return "결과가 없습니다"
        case .missingKey(let k): return "\(k) API 키가 필요합니다 (설정 탭에서 입력)"
        case .message(let m):    return m
        }
    }
}

// Stateless network layer for live asset valuation. Every method returns a
// value already converted to KRW so the caller can store it straight into
// `AssetEntry.amount`.
enum PriceService {

    // Unified dispatch used by the asset editor: given a holding's definition,
    // returns its current value (KRW) and the per-unit price (KRW).
    static func autoValue(assetClass: AssetClass,
                          symbol: String,
                          name: String,
                          quantity: Double,
                          currency: String,
                          date: Date,
                          finnhubKey: String,
                          kisAppKey: String,
                          kisAppSecret: String,
                          dataGoKey: String) async throws -> (amount: Double, unit: Double) {
        switch assetClass {
        case .crypto:
            let unit = try await cryptoUnitKRW(symbol: symbol)
            return (unit * quantity, unit)
        case .stocks where currency == "USD":
            let unit = try await usStockUnitKRW(symbol: symbol, finnhubKey: finnhubKey)
            return (unit * quantity, unit)
        case .stocks:
            let unit = try await krStockUnitKRW(code: symbol, appKey: kisAppKey, appSecret: kisAppSecret)
            return (unit * quantity, unit)
        case .realEstate:
            let value = try await apartmentKRW(lawdCd: symbol, aptName: name, date: date, serviceKey: dataGoKey)
            return (value, value)
        default:
            throw PriceError.message("이 자산 종류는 자동 시세를 지원하지 않습니다")
        }
    }

    private static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PriceError.http(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - 암호화폐 (업비트, 인증 불필요)
    // symbol: "BTC" → market "KRW-BTC". Returns KRW price per coin.
    static func cryptoUnitKRW(symbol: String) async throws -> Double {
        let code = symbol.uppercased()
            .replacingOccurrences(of: "KRW-", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { throw PriceError.message("코인 심볼을 입력하세요 (예: BTC)") }
        guard let url = URL(string: "https://api.upbit.com/v1/ticker?markets=KRW-\(code)") else {
            throw PriceError.badURL
        }
        let result = try await json(url)
        guard let arr = result as? [[String: Any]],
              let first = arr.first,
              let price = first["trade_price"] as? Double else {
            throw PriceError.message("'\(code)' 시세를 찾을 수 없습니다")
        }
        return price
    }

    // MARK: - 환율 (open.er-api.com, 인증 불필요) USD→KRW
    static func usdToKrw() async throws -> Double {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { throw PriceError.badURL }
        let result = try await json(url)
        guard let obj = result as? [String: Any],
              let rates = obj["rates"] as? [String: Any],
              let krw = rates["KRW"] as? Double else {
            throw PriceError.message("환율을 가져오지 못했습니다")
        }
        return krw
    }

    // MARK: - 미국 주식 (Finnhub, 키 필요) → KRW per share
    static func usStockUnitKRW(symbol: String, finnhubKey: String) async throws -> Double {
        guard !finnhubKey.isEmpty else { throw PriceError.missingKey("Finnhub(미국주식)") }
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty else { throw PriceError.message("티커를 입력하세요 (예: AAPL)") }
        guard let url = URL(string: "https://finnhub.io/api/v1/quote?symbol=\(sym)&token=\(finnhubKey)") else {
            throw PriceError.badURL
        }
        let result = try await json(url)
        guard let obj = result as? [String: Any],
              let usd = obj["c"] as? Double, usd > 0 else {
            throw PriceError.message("'\(sym)' 시세를 찾을 수 없습니다")
        }
        let fx = try await usdToKrw()
        return usd * fx
    }

    // MARK: - 국내 주식 (한국투자증권 KIS, 키 필요) → KRW per share
    static func krStockUnitKRW(code: String, appKey: String, appSecret: String) async throws -> Double {
        guard !appKey.isEmpty, !appSecret.isEmpty else { throw PriceError.missingKey("한국투자증권(국내주식)") }
        let iscd = code.filter { $0.isNumber }
        guard iscd.count == 6 else { throw PriceError.message("종목코드 6자리를 입력하세요 (예: 005930)") }

        let token = try await KISTokenStore.shared.token(appKey: appKey, appSecret: appSecret)
        let base = "https://openapi.koreainvestment.com:9443"
        let path = "/uapi/domestic-stock/v1/quotations/inquire-price"
        guard let url = URL(string: "\(base)\(path)?FID_COND_MRKT_DIV_CODE=J&FID_INPUT_ISCD=\(iscd)") else {
            throw PriceError.badURL
        }
        let headers = [
            "authorization": "Bearer \(token)",
            "appkey": appKey,
            "appsecret": appSecret,
            "tr_id": "FHKST01010100",
            "custtype": "P"
        ]
        let result = try await json(url, headers: headers)
        guard let obj = result as? [String: Any] else { throw PriceError.decode }
        if let msg = obj["msg1"] as? String,
           let rt = obj["rt_cd"] as? String, rt != "0",
           (obj["output"] as? [String: Any])?["stck_prpr"] == nil {
            throw PriceError.message(msg.trimmingCharacters(in: .whitespaces))
        }
        guard let output = obj["output"] as? [String: Any],
              let priceStr = output["stck_prpr"] as? String,
              let price = Double(priceStr), price > 0 else {
            throw PriceError.message("'\(iscd)' 시세를 찾을 수 없습니다")
        }
        return price
    }

    // MARK: - 부동산 (국토부 아파트 실거래가, 키 필요) → KRW
    // Looks back up to 6 months from `date` for the most recent matching trade.
    static func apartmentKRW(lawdCd: String,
                             aptName: String,
                             date: Date,
                             serviceKey: String) async throws -> Double {
        guard !serviceKey.isEmpty else { throw PriceError.missingKey("공공데이터포털(부동산)") }
        let code5 = String(lawdCd.filter { $0.isNumber }.prefix(5))
        guard code5.count == 5 else { throw PriceError.message("법정동코드 5자리를 입력하세요 (예: 11680)") }

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMM"

        for back in 0..<6 {
            guard let month = cal.date(byAdding: .month, value: -back, to: date) else { continue }
            let ymd = fmt.string(from: month)
            if let amount = try await apartmentMonthKRW(code5: code5, ymd: ymd, aptName: aptName, serviceKey: serviceKey) {
                return amount
            }
        }
        throw PriceError.message("최근 6개월 내 일치하는 실거래가가 없습니다")
    }

    private static func apartmentMonthKRW(code5: String,
                                          ymd: String,
                                          aptName: String,
                                          serviceKey: String) async throws -> Double? {
        // data.go.kr decoded service keys contain +,/,= — encode fully to avoid the
        // common double-encoding failure.
        let encodedKey: String = serviceKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? serviceKey
        let endpoint: String = "https://apis.data.go.kr/1613000/RTMSDataSvcAptTrade/getRTMSDataSvcAptTrade"
        let params: [String] = [
            "serviceKey=\(encodedKey)",
            "LAWD_CD=\(code5)",
            "DEAL_YMD=\(ymd)",
            "numOfRows=200",
            "pageNo=1"
        ]
        let urlString: String = endpoint + "?" + params.joined(separator: "&")
        guard let url = URL(string: urlString) else { throw PriceError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PriceError.http(http.statusCode)
        }

        let parser = XMLParser(data: data)
        let delegate = AptTradeXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        var items = delegate.items
        let needle = aptName.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            items = items.filter { ($0["aptNm"] ?? "").contains(needle) }
        }
        guard !items.isEmpty else { return nil }

        func dayKey(_ d: [String: String]) -> Int {
            let year: Int = Int(d["dealYear"] ?? "0") ?? 0
            let month: Int = Int(d["dealMonth"] ?? "0") ?? 0
            let day: Int = Int(d["dealDay"] ?? "0") ?? 0
            return year * 10000 + month * 100 + day
        }
        guard let latest = items.max(by: { dayKey($0) < dayKey($1) }) else { return nil }
        let amtStr = (latest["dealAmount"] ?? "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let manWon = Double(amtStr) else { return nil }
        return manWon * 10_000   // 거래금액 단위: 만원
    }
}

// Caches the KIS OAuth token (valid ~24h, issuance rate-limited to 1/min).
actor KISTokenStore {
    static let shared = KISTokenStore()
    private var cached: (token: String, expiry: Date, key: String)?

    func token(appKey: String, appSecret: String) async throws -> String {
        if let c = cached, c.key == appKey, c.expiry > Date().addingTimeInterval(60) {
            return c.token
        }
        guard let url = URL(string: "https://openapi.koreainvestment.com:9443/oauth2/tokenP") else {
            throw PriceError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        let body: [String: String] = [
            "grant_type": "client_credentials",
            "appkey": appKey,
            "appsecret": appSecret
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let msg = obj?["error_description"] as? String { throw PriceError.message(msg) }
            throw PriceError.http(http.statusCode)
        }
        guard let token = obj?["access_token"] as? String else { throw PriceError.decode }
        let expiresIn = (obj?["expires_in"] as? Double) ?? 86_400
        cached = (token, Date().addingTimeInterval(expiresIn), appKey)
        return token
    }
}

// Minimal XML parser that collects <item> rows from the 국토부 response.
private final class AptTradeXMLDelegate: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var current: [String: String] = [:]
    private var value = ""
    private static let fields: Set<String> = [
        "dealAmount", "aptNm", "dealYear", "dealMonth", "dealDay", "excluUseAr"
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        value = ""
        if elementName == "item" { current = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        value += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if Self.fields.contains(elementName) {
            current[elementName] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if elementName == "item" { items.append(current) }
    }
}
