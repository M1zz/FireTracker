//
//  FireTrackerWidget.swift
//  FireTrackerWidget
//
//  홈 화면에 퇴사각(예상 퇴사 시점)과 달성률을 띄운다.
//  앱이 App Group 에 적어 둔 FireSummary 만 읽는다 — 금액은 없다.
//

import WidgetKit
import SwiftUI

private let accent = Color(red: 232 / 255, green: 163 / 255, blue: 61 / 255)

struct FireEntry: TimelineEntry {
    let date: Date
    let summary: FireSummary?
}

struct FireProvider: TimelineProvider {
    func placeholder(in context: Context) -> FireEntry {
        FireEntry(date: Date(), summary: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (FireEntry) -> Void) {
        completion(FireEntry(date: Date(), summary: context.isPreview ? .preview : FireSummary.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FireEntry>) -> Void) {
        // 앱이 숫자를 바꿀 때마다 직접 다시 그리게 한다. 그 사이엔 하루 한 번이면 충분.
        let entry = FireEntry(date: Date(), summary: FireSummary.load())
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct FireWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FireEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder
    private var content: some View {
        if let s = entry.summary, s.goalConfigured, !s.locked {
            switch family {
            case .accessoryRectangular: rectangular(s)
            case .accessoryCircular: circular(s)
            default: small(s)
            }
        } else {
            placeholderView(locked: entry.summary?.locked == true)
        }
    }

    private func small(_ s: FireSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("퇴사각", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
            Spacer(minLength: 0)
            Text(s.fireDateText ?? String(localized: "아직 멀어요"))
                .font(.system(.title3, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let age = s.ageAtFire {
                Text("\(age)세에 그만둘 수 있어요")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: min(s.progress, 1))
                .tint(accent)
            Text("목표의 \(percent(s.progress))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func rectangular(_ s: FireSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("퇴사각", systemImage: "flame.fill")
                .font(.caption2.weight(.semibold))
            Text(s.fireDateText ?? String(localized: "아직 멀어요"))
                .font(.headline)
            Text("목표의 \(percent(s.progress))")
                .font(.caption2)
        }
    }

    private func circular(_ s: FireSummary) -> some View {
        Gauge(value: min(s.progress, 1)) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            Text(percent(s.progress))
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private func placeholderView(locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("퇴사각", systemImage: locked ? "lock.fill" : "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
            Spacer(minLength: 0)
            Text(locked ? "앱 잠금 중이라 숫자를 가렸어요" : "앱에서 목표를 정하면 여기에 퇴사일이 떠요")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ v: Double) -> String {
        "\(Int((min(v, 1) * 100).rounded()))%"
    }
}

struct FireTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FireTrackerWidget", provider: FireProvider()) { entry in
            FireWidgetView(entry: entry)
        }
        .configurationDisplayName("퇴사각")
        .description("지금 속도면 언제 그만둘 수 있는지 보여 줘요.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct FireTrackerWidgetBundle: WidgetBundle {
    var body: some Widget {
        FireTrackerWidget()
    }
}

private extension FireSummary {
    static let preview = FireSummary(
        fireDate: Calendar.current.date(byAdding: .year, value: 12, to: Date()),
        ageAtFire: 48, progress: 0.32, goalConfigured: true, locked: false, updatedAt: Date())
}
