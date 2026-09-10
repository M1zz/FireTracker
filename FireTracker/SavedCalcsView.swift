//
//  SavedCalcsView.swift
//  FireTracker
//
//  저장한 계산을 모아 보고, 그때의 입력값을 계산기로 되돌린다.
//

import SwiftUI
import SwiftData

// MARK: - 계산기 아래에 붙는 저장 줄

/// 각 계산 모드의 결과 아래에 붙는다. 지금 화면의 입력값을 통째로 떠서 이름을 붙여 저장한다.
struct CalcSaveRow: View {
    let kind: CalcKind
    /// 저장 목록에 보일 결과 한 줄.
    let headline: String
    /// 그때의 조건 요약.
    let detail: String

    @Environment(\.modelContext) private var context
    @Query private var saved: [SavedCalc]

    @State private var naming = false
    @State private var name = ""
    @State private var justSaved = false

    private var mine: [SavedCalc] {
        saved.filter { $0.kindRaw == kind.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: justSaved ? "checkmark.circle.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(justSaved ? Theme.positive : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(justSaved ? "저장했어요" : "이 계산 저장하기")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(justSaved
                         ? "계산 탭 오른쪽 위 책갈피에서 다시 볼 수 있어요."
                         : "지금 넣은 조건을 그대로 담아 둬요. 나중에 불러와 이어서 고칠 수 있어요.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    name = defaultName
                    naming = true
                } label: {
                    Text("저장")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.accent)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(headline.isEmpty)
            }

            if !mine.isEmpty {
                Text("이 계산으로 저장해 둔 것 \(mine.count)개")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .alert("계산에 이름 붙이기", isPresented: $naming) {
            TextField("이름", text: $name)
            Button("저장", action: save)
            Button("취소", role: .cancel) {}
        } message: {
            Text(headline)
        }
    }

    /// 같은 종류를 여러 번 저장해도 구분되게 번호를 붙인다.
    private var defaultName: String {
        let n = mine.count + 1
        return n == 1 ? kind.label : "\(kind.label) \(n)"
    }

    private func save() {
        let entry = SavedCalc(
            kind: kind,
            title: name.trimmingCharacters(in: .whitespaces),
            headline: headline,
            detail: detail,
            inputs: CalcSnapshot.capture(kind)
        )
        context.insert(entry)
        try? context.save()
        AppUsage.log(.calcSaved)
        withAnimation { justSaved = true }
        // 잠깐만 확인 표시를 두고 원래 문구로 돌아간다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { justSaved = false }
        }
    }
}

// MARK: - 저장한 계산 목록

struct SavedCalcsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedCalc.savedAt, order: .reverse) private var saved: [SavedCalc]

    /// 불러오기가 끝나면 계산 탭이 그 모드를 펼치도록 알린다.
    var onRestore: (() -> Void)?

    @State private var filter: CalcKind?
    @State private var restoring: SavedCalc?

    private var shown: [SavedCalc] {
        guard let filter else { return saved }
        return saved.filter { $0.kindRaw == filter.rawValue }
    }

    /// 저장된 것이 있는 종류만 칩으로 보여준다.
    private var usedKinds: [CalcKind] {
        CalcKind.allCases.filter { k in saved.contains { $0.kindRaw == k.rawValue } }
    }

    var body: some View {
        Group {
            if saved.isEmpty {
                emptyState
            } else {
                List {
                    if usedKinds.count > 1 {
                        Section {
                            filterChips
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        ForEach(shown) { calc in
                            Button { restoring = calc } label: { row(calc) }
                                .listRowBackground(Theme.surface)
                        }
                        .onDelete(perform: delete)
                    } footer: {
                        Text("탭하면 그때 넣었던 조건을 계산기로 되돌려요. 지금 계산기에 있는 값은 덮어써집니다.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("저장한 계산")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("이 계산을 불러올까요?",
                            isPresented: .init(get: { restoring != nil },
                                               set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button("불러오기") { restore() }
            Button("취소", role: .cancel) { restoring = nil }
        } message: {
            Text(restoring.map {
                "‘\($0.displayTitle)’의 조건으로 \($0.kind.label) 계산기를 채웁니다. 지금 들어 있는 값은 사라져요."
            } ?? "")
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "전체", active: filter == nil) { filter = nil }
                ForEach(usedKinds) { k in
                    chip(label: k.label, active: filter == k) { filter = k }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? Theme.accent : Theme.surfaceHigh)
                .foregroundStyle(active ? Color.black : Theme.textSecond)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func row(_ calc: SavedCalc) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: calc.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(calc.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(calc.kind.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceHigh)
                        .foregroundStyle(Theme.textSecond)
                        .clipShape(Capsule())
                }
                if !calc.headline.isEmpty {
                    Text(calc.headline)
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !calc.detail.isEmpty {
                    Text(calc.detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecond)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Fmt.date(calc.savedAt))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textSecond)
            Text("저장한 계산이 없어요")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("계산기를 돌린 뒤 결과 아래 ‘저장’을 누르면\n그때 넣은 조건이 그대로 여기 쌓여요.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func restore() {
        guard let calc = restoring else { return }
        calc.restoreIntoCalculator()
        restoring = nil
        onRestore?()
        dismiss()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(shown[index])
        }
        try? context.save()
    }
}

// MARK: - 사용 통계 전송 진단 (개발자 전용)

/// "허브에 이 앱 사용자가 왜 안 잡히지"를 기기에서 바로 확인하는 칸.
///
/// 전송은 조용히 실패한다 — iCloud에 로그인 안 된 기기는 아무 소리 없이 아무것도
/// 안 보낸다. 허브 쪽만 보면 사용자가 없는 건지 전송이 막힌 건지 구분이 안 되므로,
/// 보내는 쪽 상태를 여기서 보여준다.
struct UsageDiagnosticsSection: View {
    @State private var cloudStatus = "확인 중…"

    var body: some View {
        Section {
            row("iCloud 상태", cloudStatus, warn: cloudStatus.contains("안 됨"))
            row("마지막 전송",
                AppUsage.lastSentAt.map(Fmt.date) ?? "아직 없음",
                warn: AppUsage.lastSentAt == nil)
            row("이 기기 ID", String(AppUsage.installID.prefix(8)) + "…")
            let m = AppUsage.currentMetrics
            row("보내는 지표", m.isEmpty ? "아직 없음" : "\(m.count)개", warn: m.isEmpty)
        } header: {
            Text("사용 통계 전송 (개발자)")
        } footer: {
            Text("허브 레코드 이름은 usage-\(AppUsage.installID) 예요. 마지막 전송이 ‘아직 없음’이면 이 기기는 한 번도 허브에 닿지 못한 거고, 원인은 대부분 iCloud 로그인입니다. 전송은 12시간에 한 번으로 제한돼요.")
                .font(.caption)
                .foregroundStyle(Theme.textSecond)
        }
        .task { cloudStatus = await AppUsage.iCloudStatus() }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(warn ? Theme.negative : Theme.textSecond)
                .multilineTextAlignment(.trailing)
        }
    }
}
