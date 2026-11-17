import AppIntents
import SwiftUI
import WidgetKit

struct RecordEntry: TimelineEntry {
    let date: Date
}

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry {
        RecordEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        completion(RecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        let entry = RecordEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct RecordComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
            }
        case .accessoryCorner:
            Image(systemName: "mic.fill")
        case .accessoryInline:
            Label("TapNote 录音", systemImage: "mic.fill")
        case .accessoryRectangular:
            HStack {
                Image(systemName: "mic.circle.fill")
                VStack(alignment: .leading) {
                    Text("TapNote")
                        .font(.headline)
                    Text("一键录音")
                        .font(.caption2)
                }
            }
        default:
            Image(systemName: "mic.fill")
        }
    }
}

@main
struct TapNoteWatchWidgets: WidgetBundle {
    var body: some Widget {
        RecordComplication()
    }
}

struct RecordComplication: Widget {
    let kind = "RecordComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordProvider()) { _ in
            // Tappable complication: App Intent starts recording; URL is fallback.
            Button(intent: StartRecordingIntent()) {
                RecordComplicationView()
            }
            .buttonStyle(.plain)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "tapnote://record"))
        }
        .configurationDisplayName("TapNote 录音")
        .description("一键开始录音（无需先打开应用再点按钮）")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}
