//
//  SavedCalc.swift
//  FireTracker
//
//  계산 탭에서 돌린 계산 하나를 통째로 보관한다.
//
//  계산기는 값을 @AppStorage에 들고 있어서 "마지막 한 번"만 남는다. 대출 조건을
//  세 가지로 비교해 보거나, 작년에 세운 생애주기 가정을 올해와 견줘 보려면
//  그 시점의 입력값 묶음이 통째로 남아 있어야 한다. 여기 저장하는 건 결과 문구가
//  아니라 **입력값 전체**라, 나중에 그대로 불러와 이어서 만질 수 있다.
//

import Foundation
import SwiftData

// MARK: - 계산 종류

enum CalcKind: String, Codable, CaseIterable, Identifiable {
    case lifecycle, loan, savings, invest, wage, time

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lifecycle: return "생애주기"
        case .loan:      return "대출"
        case .savings:   return "저축"
        case .invest:    return "투자"
        case .wage:      return "구매력"
        case .time:      return "시간"
        }
    }

    var symbol: String {
        switch self {
        case .lifecycle: return "figure.walk.motion"
        case .loan:      return "building.columns"
        case .savings:   return "banknote"
        case .invest:    return "chart.line.uptrend.xyaxis"
        case .wage:      return "cart"
        case .time:      return "hourglass"
        }
    }

    /// 이 계산의 입력값이 UserDefaults에 저장될 때 쓰는 키 접두사.
    /// 계산기마다 키를 `sim.<모드>.` 로 통일해 둔 덕에 접두사만으로 통째로 뜬다.
    var prefixes: [String] {
        switch self {
        case .lifecycle: return ["sim.life."]
        case .loan:      return ["sim.mtg."]
        case .savings:   return ["sim.sav."]
        case .invest:    return ["sim.invest."]
        case .wage:      return ["sim.wage."]
        // 시간 계산은 구매력에 적어 둔 월급 기록을 시급 계산에 재사용한다.
        case .time:      return ["sim.time.", "sim.wage."]
        }
    }

    /// 계산 탭의 모드 선택값(`sim.mode`)에 쓰이는 문자열. 불러오기가 그 모드를 펼친다.
    var simModeRawValue: String { label }
}

// MARK: - 입력값 한 칸

/// UserDefaults에 들어가는 값의 종류. 타입을 같이 적어 둬야 되돌릴 때
/// 켬/끔이 1/0으로, 숫자가 문자열로 뒤바뀌지 않는다.
enum CalcValue: Codable, Equatable {
    case text(String)
    case flag(Bool)
    case number(Double)
}

// MARK: - 입력값 묶음 뜨기 · 되돌리기

enum CalcSnapshot {

    /// 켬/끔으로 저장되는 키. 나머지는 전부 문자열이거나 숫자다.
    /// (UserDefaults는 Bool도 NSNumber로 들고 있어서 값만 봐서는 1과 true를 구분 못 한다.)
    private static let flagKeys: Set<String> = [
        "sim.life.seeded", "sim.life.scaleReturns", "sim.sav.taxed", "sim.time.seeded",
    ]

    /// 지금 계산기에 들어 있는 값을 통째로 뜬다.
    static func capture(_ kind: CalcKind) -> [String: CalcValue] {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var out: [String: CalcValue] = [:]
        for (key, raw) in all where kind.prefixes.contains(where: key.hasPrefix) {
            if flagKeys.contains(key) {
                if let n = raw as? NSNumber { out[key] = .flag(n.boolValue) }
            } else if let s = raw as? String {
                out[key] = .text(s)
            } else if let n = raw as? NSNumber {
                out[key] = .number(n.doubleValue)
            }
        }
        return out
    }

    /// 저장해 둔 값을 계산기에 되돌린다.
    static func restore(_ inputs: [String: CalcValue], kind: CalcKind) {
        let defaults = UserDefaults.standard
        // 지금 값 중 이 계산의 것만 먼저 비운다 — 저장 당시엔 없던 키가 남아
        // 옛 입력과 새 입력이 섞이는 걸 막는다.
        for key in defaults.dictionaryRepresentation().keys
        where kind.prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in inputs {
            switch value {
            case .text(let s):   defaults.set(s, forKey: key)
            case .flag(let b):   defaults.set(b, forKey: key)
            case .number(let d): defaults.set(d, forKey: key)
            }
        }
        // 계산 탭이 이 모드를 펼친 채로 열리게 한다.
        defaults.set(kind.simModeRawValue, forKey: "sim.mode")
    }

    static func encode(_ inputs: [String: CalcValue]) -> String {
        guard let data = try? JSONEncoder().encode(inputs) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> [String: CalcValue] {
        guard let data = json.data(using: .utf8),
              let out = try? JSONDecoder().decode([String: CalcValue].self, from: data)
        else { return [:] }
        return out
    }
}

// MARK: - 저장된 계산

@Model
final class SavedCalc {
    var id: UUID = UUID()
    var savedAt: Date = Date.now
    var kindRaw: String = CalcKind.lifecycle.rawValue
    /// 사용자가 붙인 이름. 비어 있으면 종류 이름으로 대신 보여준다.
    var title: String = ""
    /// 저장 시점의 결과 한 줄 — 목록에서 이것만 보고도 어떤 계산이었는지 안다.
    var headline: String = ""
    /// 그때의 조건 요약.
    var detail: String = ""
    /// 그때의 입력값 전체(JSON). 불러오기가 이걸 되돌린다.
    var inputsJSON: String = ""

    init(kind: CalcKind = .lifecycle,
         title: String = "",
         headline: String = "",
         detail: String = "",
         inputs: [String: CalcValue] = [:],
         savedAt: Date = .now) {
        self.id = UUID()
        self.savedAt = savedAt
        self.kindRaw = kind.rawValue
        self.title = title
        self.headline = headline
        self.detail = detail
        self.inputsJSON = CalcSnapshot.encode(inputs)
    }

    var kind: CalcKind { CalcKind(rawValue: kindRaw) ?? .lifecycle }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? kind.label : title
    }

    var inputs: [String: CalcValue] { CalcSnapshot.decode(inputsJSON) }

    /// 이 계산을 계산기로 되돌린다.
    func restoreIntoCalculator() {
        CalcSnapshot.restore(inputs, kind: kind)
    }
}
