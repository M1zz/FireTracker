//
//  FireTrackerWidget.swift
//  FireTrackerWidget
//
//  홈·잠금 화면 위젯 — 퇴사까지 남은 시간. 앱이 적어 둔 WidgetSummary 만 읽는다.
//

import WidgetKit
import SwiftUI

struct QuitEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary?
}

struct QuitProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuitEntry {
        QuitEntry(date: .now, summary: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuitEntry) -> Void) {
        completion(QuitEntry(date: .now, summary: context.isPreview ? .sample : WidgetSummary.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuitEntry>) -> Void) {
        // 앱이 자산을 바꿀 때마다 다시 그리라고 알려 주므로, 여기선 하루에 한 번만 새로 본다.
        let entry = QuitEntry(date: .now, summary: WidgetSummary.load())
        let next = Calendar.current.date(byAdding: .hour, value: 12, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

extension WidgetSummary {
    static var sample: WidgetSummary {
        WidgetSummary(hasGoal: true, reached: false, yearsText: "8년 10개월", quitYear: 2035,
                      quitAge: 44, progress: 0.49, netWorthText: "5억 2,000만원", isPro: true)
    }
}

private enum WColor {
    static let accent = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)
    static let positive = Color(red: 0x4C / 255, green: 0xAF / 255, blue: 0x8E / 255)
}

struct QuitWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuitEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder
    private var content: some View {
        if let s = entry.summary, s.isPro {
            if !s.hasGoal {
                message("목표 생활비를 정하면 퇴사까지 남은 시간이 보여요")
            } else {
                switch family {
                case .accessoryRectangular: lockScreen(s)
                case .systemMedium: medium(s)
                default: small(s)
                }
            }
        } else if entry.summary == nil {
            message("앱을 한 번 열면 퇴사까지 남은 시간이 보여요")
        } else {
            message("퇴사각 프로에서 위젯을 켤 수 있어요")
        }
    }

    private func headline(_ s: WidgetSummary) -> Text {
        s.reached ? Text("지금 퇴사해도 돼요") : Text(s.yearsText)
    }

    private func whenLine(_ s: WidgetSummary) -> Text {
        s.quitAge > 0
            ? Text("\(String(s.quitYear))년 · \(s.quitAge)세")
            : Text("\(String(s.quitYear))년")
    }

    private func small(_ s: WidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("퇴사까지", systemImage: "flame.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(WColor.accent)
            Spacer(minLength: 0)
            headline(s)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            if !s.reached, s.quitYear > 0 {
                whenLine(s)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(s.progress, 1))
                .tint(s.progress >= 1 ? WColor.positive : WColor.accent)
        }
    }

    private func medium(_ s: WidgetSummary) -> some View {
        HStack(alignment: .center, spacing: 16) {
            small(s)
            VStack(alignment: .leading, spacing: 6) {
                Text("목표까지")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("\(Int((min(s.progress, 1) * 100).rounded()))%")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(s.progress >= 1 ? WColor.positive : WColor.accent)
                Text("순자산")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(s.netWorthText)
                    .font(.body.weight(.semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
    }

    private func lockScreen(_ s: WidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("퇴사까지")
                .font(.body.weight(.semibold))
            headline(s)
                .font(.body.weight(.bold))
            if !s.reached, s.quitYear > 0 { whenLine(s).font(.body) }
        }
    }

    private func message(_ key: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(WColor.accent)
            Text(key)
                .font(.body)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.7)
        }
    }
}

struct FireTrackerQuitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSummary.widgetKind, provider: QuitProvider()) { entry in
            QuitWidgetView(entry: entry)
        }
        .configurationDisplayName("퇴사까지")
        .description("퇴사할 수 있는 날까지 남은 시간을 보여줘요.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct FireTrackerWidgets: WidgetBundle {
    var body: some Widget {
        FireTrackerQuitWidget()
    }
}
