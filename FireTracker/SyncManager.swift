//
//  SyncManager.swift
//  FireTracker
//
//  iCloud 동기화(퇴사각 프로). SwiftData 를 앱 전용 CloudKit 컨테이너에 미러링한다.
//
//  · 켜고 끄는 건 다음 실행부터 — ModelContainer 는 앱이 뜰 때 한 번 만들어진다.
//  · 컨테이너를 못 만들면(계정·권한 문제) 기기 저장소로 조용히 돌아가 앱이 죽지 않게 한다.
//  · 두 기기가 같은 날 기록을 각자 만들거나 설정을 각자 만들면 합쳐진 뒤 둘이 된다 —
//    합쳐질 때마다 하나만 남기는 정리(dedupe)를 돌린다.
//  · 데모 데이터는 실데이터를 지웠다 되돌리는 방식이라, 동기화 중에 켜면 다른 기기의
//    데이터까지 지워진다. 동기화 중에는 데모를 막는다.
//

import Foundation
import SwiftData
import SwiftUI
import CloudKit

enum SyncManager {
    static let enabledKey = "sync.iCloudEnabled"
    static let lastErrorKey = "sync.lastError"
    static let containerID = "iCloud.com.devkoan.FireTracker"

    /// 이번 실행에서 실제로 CloudKit 미러링이 켜졌는지(설정과 다를 수 있다 — 실패하면 꺼진 채 뜬다).
    nonisolated(unsafe) static var activeThisLaunch = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 앱 시작 시 컨테이너를 만든다. 동기화가 켜져 있으면 CloudKit, 실패하면 기기 저장소.
    static func makeContainer(schema: Schema) -> ModelContainer {
        if isEnabled {
            let cloud = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                           cloudKitDatabase: .private(containerID))
            do {
                let c = try ModelContainer(for: schema, configurations: [cloud])
                activeThisLaunch = true
                UserDefaults.standard.removeObject(forKey: lastErrorKey)
                return c
            } catch {
                UserDefaults.standard.set(String(describing: error), forKey: lastErrorKey)
            }
        }
        // 기기 안에만 둔다. cloudKitDatabase 를 비워 두면 entitlements 의 iCloud 권한을 보고
        // SwiftData 가 동기화를 멋대로 켜므로 .none 을 명시한다.
        let local = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            return StoreFallback.memoryContainer(schema: schema, after: error)
        }
    }

    static func accountStatusText() async -> String {
        guard let status = try? await CKContainer(identifier: containerID).accountStatus() else {
            return String(localized: "iCloud 상태를 확인하지 못했어요")
        }
        switch status {
        case .available:              return String(localized: "iCloud에 연결돼 있어요")
        case .noAccount:              return String(localized: "기기에 iCloud 로그인이 필요해요")
        case .restricted:             return String(localized: "기기 정책으로 iCloud를 쓸 수 없어요")
        case .temporarilyUnavailable: return String(localized: "iCloud를 잠시 쓸 수 없어요")
        default:                      return String(localized: "iCloud 상태를 확인하지 못했어요")
        }
    }

    // MARK: - 합쳐진 뒤 중복 정리

    /// 두 기기에서 따로 만들어진 같은 것(설정 · 같은 날 기록 · 같은 자산)을 하나만 남긴다.
    @MainActor
    static func dedupe(context: ModelContext) {
        var changed = false

        // 설정 — 가장 많이 채워진 하나만.
        if let all = try? context.fetch(FetchDescriptor<FireSettings>()), all.count > 1 {
            let keep = all.max { filledScore($0) < filledScore($1) }!
            for s in all where s !== keep { context.delete(s); changed = true }
        }

        // 기록 — 같은 날 기록은 항목이 많은(같으면 나중) 하나만.
        if let snaps = try? context.fetch(FetchDescriptor<NetWorthSnapshot>()) {
            let cal = Calendar.current
            let byDay = Dictionary(grouping: snaps) { cal.startOfDay(for: $0.date) }
            for (_, group) in byDay where group.count > 1 {
                // 직접 남긴 기록(메모가 '자동 기록'이 아닌 것)을 먼저, 그다음 항목 많은 것.
                func rank(_ s: NetWorthSnapshot) -> (Int, Int, Date) {
                    (s.note == "자동 기록" ? 0 : 1, s.entryList.count, s.date)
                }
                let keep = group.max { rank($0) < rank($1) }!
                for s in group where s !== keep { context.delete(s); changed = true }
            }
        }

        // 자산 — 같은 key(백업 복원을 두 기기에서 한 경우).
        if let assets = try? context.fetch(FetchDescriptor<Asset>()) {
            let byKey = Dictionary(grouping: assets, by: \.key)
            for (_, group) in byKey where group.count > 1 {
                let keep = group.max { $0.createdAt < $1.createdAt }!
                for a in group where a !== keep { context.delete(a); changed = true }
            }
        }

        if changed { try? context.save() }
    }

    private static func filledScore(_ s: FireSettings) -> Int {
        var n = 0
        if s.currentAge > 0 { n += 2 }
        if s.targetRetireAge > 0 { n += 1 }
        if s.monthlyTakeHome > 0 { n += 2 }
        if s.plannedMonthlyExpense > 0 || s.plannedNetSavings != 0 { n += 1 }
        if s.targetAnnualExpense != 36_000_000 { n += 2 }
        if !s.kisAppKey.isEmpty || !s.dataGoKey.isEmpty { n += 1 }
        return n
    }
}

// MARK: - 저장소를 못 연 날
//
// 예전에는 fatalError 로 죽었다. 그러면 마이그레이션 한 번 어긋난 사용자는 켤 때마다 죽고,
// 기기 안에 멀쩡히 있는 기록도 못 본다. 이제는 디스크의 기록은 건드리지 않고 이번 실행만
// 메모리에서 열고, 사용자에게 그 사실을 알린다.

enum StoreFallback {
    /// 이번 실행이 임시(메모리) 저장소로 열렸는가
    private(set) static var isActive = false

    static func memoryContainer(schema: Schema, after error: Error) -> ModelContainer {
        isActive = true
        print("⚠️ 저장소를 열지 못해 이번 실행은 메모리에서 엽니다: \(error)")
        do {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
        } catch {
            // 메모리 저장소마저 안 되는 건 스키마 자체가 잘못된 것 — 개발 중에 바로 드러난다
            fatalError("메모리 저장소도 열지 못함: \(error)")
        }
    }
}

extension View {
    /// 임시 저장소로 열렸으면 한 번 알린다. 앱의 맨 바깥 화면에 붙인다.
    func storeFallbackNotice() -> some View {
        modifier(StoreFallbackNotice())
    }
}

private struct StoreFallbackNotice: ViewModifier {
    @State private var isPresented = StoreFallback.isActive

    func body(content: Content) -> some View {
        content.alert("기록을 열지 못했어요", isPresented: $isPresented) {
        } message: {
            Text("저장된 기록은 지워지지 않았어요. 다만 지금 적는 내용은 저장되지 않으니, 앱을 껐다 켜 보세요.")
        }
    }
}
