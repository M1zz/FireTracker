import SwiftUI
import SwiftData

// History of recorded net-worth snapshots. Records accumulate automatically
// whenever assets change; here you review, adjust income/expense, or delete.
struct SnapshotsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \NetWorthSnapshot.date, order: .reverse) private var snapshots: [NetWorthSnapshot]
    @State private var editing: NetWorthSnapshot?

    var body: some View {
        NavigationStack {
            Group {
                if snapshots.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(snapshots) { s in
                            Button { editing = s } label: { row(s) }
                                .listRowBackground(Theme.surface)
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("기록")
            .sheet(item: $editing) { s in
                SnapshotDetail(snapshot: s)
            }
        }
    }

    private func row(_ s: NetWorthSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.date(s.date))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("저축률 \(Fmt.percent(s.savingsRate, fraction: 0)) · 자산 \(s.entries.count)개"
                     + (s.note.isEmpty ? "" : " · \(s.note)"))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
            Text("\(Fmt.krw(s.netWorth))원")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(.largeTitle))
                .foregroundStyle(Theme.textSecond)
            Text("아직 저장된 기록이 없습니다.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("자산 탭에서 자산을 등록하면\n변동이 생길 때마다 자동으로 기록이 쌓입니다.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecond)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Theme.bg)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(snapshots[i]) }
        try? context.save()
    }
}

// A recorded snapshot's detail: editable date/income/expense/note plus a
// read-only breakdown of the captured asset values.
struct SnapshotDetail: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let snapshot: NetWorthSnapshot

    @State private var date: Date = .now
    @State private var income: String = ""
    @State private var expense: String = ""
    @State private var passiveIncome: String = ""
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("기간") {
                    DatePicker("월", selection: $date, displayedComponents: .date)
                }
                Section("순자산") {
                    HStack {
                        Text("순자산")
                        Spacer()
                        Text("\(Fmt.krw(snapshot.netWorth))원")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Section("수입 / 지출 (원)") {
                    TextField("월 수입", text: $income).keyboardType(.numberPad)
                    TextField("월 지출", text: $expense).keyboardType(.numberPad)
                }
                // 이 기록 시점의 월 패시브 인컴 — 잘못 저장된 값이 기간별 목표·추이
                // 차트에 튀는 점으로 남을 때 여기서 바로 고칠 수 있다.
                Section {
                    TextField("월 패시브 인컴", text: $passiveIncome.commaGrouped)
                        .keyboardType(.numberPad)
                } header: {
                    Text("패시브 인컴 (원)")
                } footer: {
                    Text("이 기록 시점의 월 배당·이자·월세 합계예요. 대시보드 ‘기간별 목표(패시브 인컴)’ 차트의 점이 이 값입니다. 잘못 기록됐다면 고쳐서 저장하세요.")
                        .font(.caption)
                }
                Section("저장된 자산 내역") {
                    ForEach(snapshot.entries.sorted { $0.amount > $1.amount }) { entry in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hexCode: entry.assetClass.colorHex))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name.isEmpty ? entry.assetClass.label : entry.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(entry.assetClass.label)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecond)
                            }
                            Spacer()
                            Text("\(Fmt.krw(entry.amount))원")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                    if snapshot.entries.isEmpty {
                        Text("저장된 자산이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecond)
                    }
                }
                Section("메모") {
                    TextField("메모 (선택)", text: $note, axis: .vertical)
                }
                // 잘못 들어간 기록을 바로 지울 수 있게 — 목록 스와이프 말고도.
                Section {
                    Button("이 기록 삭제", role: .destructive) { deleteSnapshot() }
                } footer: {
                    Text("이 기록만 지워지고 자산 목록에는 영향이 없어요. 추이·기간별 목표 그래프에서도 빠집니다.")
                        .font(.caption)
                }
            }
            .navigationTitle(Fmt.date(snapshot.date))
            .navigationBarTitleDisplayMode(.inline)
            .scrollIndicators(.hidden)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save() } }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        date = snapshot.date
        income = snapshot.monthlyIncome > 0 ? String(Int(snapshot.monthlyIncome)) : ""
        expense = snapshot.monthlyExpense > 0 ? String(Int(snapshot.monthlyExpense)) : ""
        passiveIncome = snapshot.monthlyPassiveIncome > 0 ? String(Int(snapshot.monthlyPassiveIncome)) : ""
        note = snapshot.note
    }

    private func save() {
        snapshot.date = date
        snapshot.monthlyIncome = Double(income) ?? 0
        snapshot.monthlyExpense = Double(expense) ?? 0
        snapshot.monthlyPassiveIncome = Double(passiveIncome) ?? 0
        snapshot.note = note
        try? context.save()
        dismiss()
    }

    private func deleteSnapshot() {
        context.delete(snapshot)
        try? context.save()
        dismiss()
    }
}
