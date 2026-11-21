import Foundation
import SwiftUI

// Pure calculation layer. Keeps math out of the views and testable.
struct FireEngine {

    // Progress toward the FIRE number, clamped 0...1+.
    static func progress(netWorth: Double, fireNumber: Double) -> Double {
        guard fireNumber > 0 else { return 0 }
        return netWorth / fireNumber
    }

    // Average monthly savings across the most recent `months` snapshots.
    static func averageMonthlySavings(snapshots: [NetWorthSnapshot],
                                      months: Int = 6) -> Double {
        let recent = snapshots
            .sorted { $0.date > $1.date }
            .prefix(months)
        guard !recent.isEmpty else { return 0 }
        let total = recent.reduce(0) { $0 + $1.monthlySavings }
        return total / Double(recent.count)
    }

    // Years until FIRE using future-value of current net worth plus
    // monthly contributions, compounded at the expected return.
    // Returns nil if the goal is never reached within the cap.
    static func yearsToFire(currentNetWorth: Double,
                            fireNumber: Double,
                            monthlySavings: Double,
                            annualReturn: Double,
                            capYears: Int = 80) -> Double? {
        if currentNetWorth >= fireNumber { return 0 }
        let monthlyRate = annualReturn / 12
        var balance = currentNetWorth
        var months = 0
        let maxMonths = capYears * 12

        while balance < fireNumber && months < maxMonths {
            balance = balance * (1 + monthlyRate) + monthlySavings
            months += 1
            // No growth and no savings means it never converges.
            if monthlySavings <= 0 && monthlyRate <= 0 { return nil }
        }
        return months >= maxMonths ? nil : Double(months) / 12.0
    }

    // Where you should be `horizonMonths` from now if you climb linearly from
    // `current` to `goal` over the remaining months to retirement. Used to slice
    // the macro retirement goal into 이번달·올해·5년 targets.
    static func milestoneTarget(current: Double, goal: Double,
                                monthsToRetire: Int, horizonMonths: Int) -> Double {
        guard monthsToRetire > 0, goal > current else { return goal }
        let required = (goal - current) / Double(monthsToRetire)
        let h = min(max(horizonMonths, 0), monthsToRetire)
        return min(goal, current + required * Double(h))
    }

    // Month-over-month net worth delta between two most recent snapshots.
    static func latestDelta(snapshots: [NetWorthSnapshot]) -> Double? {
        let sorted = snapshots.sorted { $0.date > $1.date }
        guard sorted.count >= 2 else { return nil }
        return sorted[0].netWorth - sorted[1].netWorth
    }

    // Months remaining in the calendar year, counting the current month.
    // e.g. June → 7 (Jun…Dec).
    static func monthsLeftInYear(asOf date: Date) -> Int {
        let month = Calendar.gregorian.component(.month, from: date)
        return max(0, 12 - month + 1)
    }

    // Projected assets at year-end. Counts ONLY money we actually expect to come
    // in — salary-based monthly savings plus the passive income the assets are
    // scheduled to pay (배당·월세·이자 등). No speculative appreciation: an owner-
    // occupied apartment or a stock that "might go up" adds nothing here.
    static func projectedYearEnd(currentNetWorth: Double,
                                 monthlySavings: Double,
                                 monthlyPassiveIncome: Double,
                                 asOf date: Date) -> Double {
        projectionSteps(currentNetWorth: currentNetWorth,
                        monthlySavings: monthlySavings,
                        monthlyPassiveIncome: monthlyPassiveIncome,
                        asOf: date).last?.end ?? currentNetWorth
    }

    // One month of the projection, broken out so the basis can be shown.
    struct ProjectionStep: Identifiable {
        let month: Int           // 1...N
        let date: Date           // the calendar month it represents
        let start: Double
        let savings: Double      // salary − spending saved that month
        let passiveIncome: Double // dividends/rent/interest expected that month
        let end: Double
        var id: Int { month }
    }

    static func projectionSteps(currentNetWorth: Double,
                                monthlySavings: Double,
                                monthlyPassiveIncome: Double,
                                asOf date: Date) -> [ProjectionStep] {
        let cal = Calendar.gregorian
        let months = monthsLeftInYear(asOf: date)
        var balance = currentNetWorth
        var steps: [ProjectionStep] = []
        for i in 0..<months {
            let start = balance
            // Linear accumulation of expected inflows — no compounding return.
            let end = start + monthlySavings + monthlyPassiveIncome
            let monthDate = cal.date(byAdding: .month, value: i, to: date) ?? date
            steps.append(ProjectionStep(month: i + 1, date: monthDate,
                                        start: start, savings: monthlySavings,
                                        passiveIncome: monthlyPassiveIncome, end: end))
            balance = end
        }
        return steps
    }
}

// Currency / number formatting shared across the UI.
enum Fmt {
    // 금액 표기 모드. 기본은 억/만 단위(읽기 쉬움). 설정에서 켜면 숫자(콤마)만.
    // 앱 시작·설정 변경 시 RootView가 설정값으로 동기화한다.
    static var numbersOnly = false

    // 한국어로 볼 때만 억/만 단위를 쓴다. 다른 언어는 그 나라 말의 큰 수 표기(1.2M · 5.2億 · 1,2 Mio.)로.
    static var isKorean: Bool {
        (Bundle.main.preferredLocalizations.first ?? "ko").hasPrefix("ko")
    }

    // Formats a KRW amount into 억/만원 readable Korean string.
    static func krw(_ value: Double) -> String {
        // Int(NaN/Inf) traps — never let a bad number crash the money formatter.
        guard value.isFinite else { return "0" }
        // 숫자만 모드 — 콤마 구분 정수로.
        if numbersOnly { return won(value) }
        guard isKorean else {
            if abs(value) < 10_000 { return Int(value.rounded()).formatted() }
            return value.formatted(.number.notation(.compactName).precision(.significantDigits(1...4)))
        }
        let eok = 100_000_000.0
        let man = 10_000.0
        let sign = value < 0 ? "-" : ""
        let v = abs(value)

        if v >= eok {
            let eokPart = Int(v / eok)
            let remainder = v.truncatingRemainder(dividingBy: eok)
            let manPart = Int(remainder / man)
            if manPart == 0 {
                return "\(sign)\(eokPart.formatted())억"
            }
            return "\(sign)\(eokPart.formatted())억 \(manPart.formatted())만"
        } else if v >= man {
            let manPart = Int(v / man)
            return "\(sign)\(manPart.formatted())만"
        } else {
            return "\(sign)\(Int(v).formatted())"
        }
    }

    // Full KRW amount with thousands separators, e.g. 36,000,000.
    static func won(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return Int(value.rounded()).formatted()
    }

    // 금액 + '원'. 표기 모드를 따른다(억/만 또는 숫자). 예) "3,600만원" 또는 "36,000,000원".
    static func wonKo(_ value: Double) -> String {
        String(localized: "\(krw(value))원")
    }

    // 금액 + '원'. wonKo와 동일하게 표기 모드를 따른다.
    static func krwBoth(_ value: Double) -> String {
        String(localized: "\(krw(value))원")
    }

    static func percent(_ value: Double, fraction: Int = 1) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        return f.string(from: NSNumber(value: value)) ?? "0%"
    }

    static func years(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value < 1.0 / 12.0 { return String(localized: "달성!") }
        let whole = Int(value)
        let months = Int((value - Double(whole)) * 12)
        if whole == 0 { return String(localized: "\(months)개월") }
        if months == 0 { return String(localized: "\(whole)년") }
        return String(localized: "\(whole)년 \(months)개월")
    }

    // Renders a quantity without trailing ".0" (e.g. 3.0 → "3", 0.25 → "0.25").
    // 입력칸에 채우는 값이라 언제나 0~9 로 쓴다(Double(...) 이 다시 읽는다). 화면에 보일 때는 number(_:).
    static func trimNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }

    // 화면에 보이는 수. 기기의 숫자 체계를 따른다 — 아랍어 기기에서 ٣٫٥ 가 다른 숫자와 한 화면에 섞이지 않게.
    static func number(_ value: Double, maxFraction: Int = 6) -> String {
        guard value.isFinite else { return "0" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...maxFraction)))
    }

    // 소수 자리를 고정한 수(×1.25 처럼). String(format:) 은 언제나 0~9 라 아랍어 숫자와 섞인다.
    static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return "0" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(digits)))
    }

    // 연도(2026). 자릿수 쉼표 없이, 기기의 숫자 체계로.
    static func year(_ year: Int) -> String {
        year.formatted(.number.grouping(.never))
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = .gregorian
        f.setLocalizedDateFormatFromTemplate("yyyyMM")
        return f.string(from: date)
    }
}

extension Binding where Value == String {
    // Shows the digit string grouped with commas (100,000,000) for readability
    // while storing only the raw digits so `Double(...)` still parses.
    var commaGrouped: Binding<String> {
        Binding<String>(
            get: {
                let digits = wrappedValue.filter(\.isNumber)
                guard let n = Int64(digits) else { return "" }
                return n.formatted()
            },
            set: { newValue in
                wrappedValue = newValue.asciiDigits.filter(\.isNumber)
            }
        )
    }

    // 소수까지 받는 입력칸. 아랍어 숫자 자판(١٢٫٥)으로 쳐도 Double(...) 이 읽도록 0~9 와 '.' 로 바꿔 둔다.
    var asciiNumber: Binding<String> {
        Binding<String>(get: { wrappedValue }, set: { wrappedValue = $0.asciiDigits })
    }
}

extension String {
    // ٠١٢٣ · ۰۱۲۳ 같은 다른 숫자 체계를 0~9 로, 아랍어 소수점(٫)을 '.' 로, 자릿수 구분(٬)은 지운다.
    var asciiDigits: String {
        var out = ""
        for ch in self {
            if ch == "٫" { out.append(".") }
            else if ch == "٬" { continue }
            else if !ch.isASCII, let d = ch.wholeNumberValue { out.append(String(d)) }
            else { out.append(ch) }
        }
        return out
    }
}

extension Locale {
    // 기기의 언어 · 지역 · 숫자 체계는 그대로, 달력만 양력으로.
    static var gregorian: Locale {
        var parts = Locale.Components(locale: .current)
        parts.calendar = .gregorian
        return Locale(components: parts)
    }
}

extension Date.FormatStyle {
    // 그래프 눈금용 날짜 형식. 기본 .dateTime 은 기기 달력(사우디는 히즈라력)을 따른다.
    static var gregorian: Date.FormatStyle { Date.FormatStyle(locale: .gregorian, calendar: .gregorian) }
}

extension Calendar {
    // 날짜 계산과 표시는 양력으로 한다. 사우디 기기의 기본 달력은 히즈라력(1448년)이라
    // 올해 · 분기 · 물가 연도 계산이 어긋난다. 언어 · 지역 표기는 기기를 그대로 따른다.
    static var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = .gregorian
        cal.timeZone = .current
        return cal
    }
}

extension Color {
    init(hexCode hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension View {
    // 그래프는 x 축이 시간 · 금액 · 나이 같은 데이터라 아랍어에서도 왼쪽에서 오른쪽으로 둔다.
    // 거울처럼 뒤집으면 축 이름표와 손가락으로 고른 자리가 어긋난다. 도넛도 위에서 시계 방향으로.
    func dataAxisLeftToRight() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }
}

extension Font.Design {
    // 식(= ÷ ×)을 보여 주는 글꼴. 고정폭(SF Mono)에는 아랍 글자가 없어 낱자로 떨어지므로
    // 오른쪽에서 왼쪽으로 쓰는 언어에서는 기본 글꼴을 쓴다.
    static var formula: Font.Design {
        let shown = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: shown).characterDirection == .rightToLeft ? .default : .monospaced
    }
}
