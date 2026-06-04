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

    // Month-over-month net worth delta between two most recent snapshots.
    static func latestDelta(snapshots: [NetWorthSnapshot]) -> Double? {
        let sorted = snapshots.sorted { $0.date > $1.date }
        guard sorted.count >= 2 else { return nil }
        return sorted[0].netWorth - sorted[1].netWorth
    }

    // Months remaining in the calendar year, counting the current month.
    // e.g. June → 7 (Jun…Dec).
    static func monthsLeftInYear(asOf date: Date) -> Int {
        let month = Calendar.current.component(.month, from: date)
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
        let cal = Calendar(identifier: .gregorian)
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
    // Formats a KRW amount into 억/만원 readable Korean string.
    static func krw(_ value: Double) -> String {
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
        Int(value.rounded()).formatted()
    }

    // Abbreviated form with the exact amount written alongside,
    // e.g. "3,600만 (36,000,000원)".
    static func krwBoth(_ value: Double) -> String {
        "\(krw(value)) (\(won(value))원)"
    }

    static func percent(_ value: Double, fraction: Int = 1) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        return f.string(from: NSNumber(value: value)) ?? "0%"
    }

    static func years(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1.0 / 12.0 { return "달성!" }
        let whole = Int(value)
        let months = Int((value - Double(whole)) * 12)
        if whole == 0 { return "\(months)개월" }
        if months == 0 { return "\(whole)년" }
        return "\(whole)년 \(months)개월"
    }

    // Renders a quantity without trailing ".0" (e.g. 3.0 → "3", 0.25 → "0.25").
    static func trimNumber(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM"
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
                wrappedValue = newValue.filter(\.isNumber)
            }
        )
    }
}

extension Color {
    init(hex: String) {
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
