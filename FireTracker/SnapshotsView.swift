import SwiftUI
import SwiftData

// History of recorded net-worth snapshots. Records are created from the 자산
// tab ("이번 달 기록 저장"); here you review, adjust income/expense, or delete.
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
                Text("저축률 \(Fmt.percent(s.savingsRate, fraction: 0)) · 자산 \(s.entries.count)개")
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
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecond)
            Text("아직 저장된 기록이 없습니다.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("자산 탭에서 자산을 등록한 뒤\n‘이번 달 기록 저장’을 누르면 여기에 쌓입니다.")
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
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("기간") {
                    DatePicker("월", selection: $date, displayedComponents: .date)
                }
                Section("순자산") {
                    HStack {
                        Text("총 자산")
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
                Section("저장된 자산 내역") {
                    ForEach(snapshot.entries.sorted { $0.amount > $1.amount }) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.assetClass.symbolName)
                                .foregroundStyle(Color(hex: entry.assetClass.colorHex))
                                .frame(width: 24)
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
        .preferredColorScheme(.dark)
    }

    private func load() {
        date = snapshot.date
        income = snapshot.monthlyIncome > 0 ? String(Int(snapshot.monthlyIncome)) : ""
        expense = snapshot.monthlyExpense > 0 ? String(Int(snapshot.monthlyExpense)) : ""
        note = snapshot.note
    }

    private func save() {
        snapshot.date = date
        snapshot.monthlyIncome = Double(income) ?? 0
        snapshot.monthlyExpense = Double(expense) ?? 0
        snapshot.note = note
        try? context.save()
        dismiss()
    }
}
