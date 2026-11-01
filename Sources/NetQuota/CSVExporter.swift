import AppKit
import NetQuotaCore
import SwiftUI
import UniformTypeIdentifiers

/// 匯出 CSV（數值一律用 bytes，方便用試算表自行換算）。
@MainActor
enum CSVExporter {
    static func dailySummaryCSV(collector: TrafficCollector, policy: QuotaPolicy) -> String {
        let from = collector.store.firstRecord() ?? Date()
        var summaries = collector.store.dailySummaries(from: from, to: Date(), policy: policy)
        if let index = summaries.firstIndex(where: { $0.day == collector.dayKey }) {
            summaries[index].bytes = collector.today
            summaries[index].calibration = collector.calibration
            summaries[index].peak = collector.peak
        }
        var lines = ["date,download_bytes,upload_bytes,calibration_bytes,total_bytes,total_gb,over_quota,peak_download_Bps,peak_download_at,peak_upload_Bps,peak_upload_at"]
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        for day in summaries {
            let peak = day.peak ?? DayPeak()
            lines.append([
                day.day,
                String(day.bytes.rx),
                String(day.bytes.tx),
                String(Int64(day.calibration)),
                String(Int64(day.total)),
                String(format: "%.3f", day.total / 1_000_000_000),
                day.total > policy.quotaBytes ? "1" : "0",
                String(Int64(peak.rxRate)),
                peak.rxAt.map { iso.string(from: $0) } ?? "",
                String(Int64(peak.txRate)),
                peak.txAt.map { iso.string(from: $0) } ?? "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func appDailyCSV(collector: TrafficCollector, policy: QuotaPolicy) -> String {
        var lines = ["date,app,download_bytes,upload_bytes,total_bytes"]
        for row in collector.store.appDaily(from: .distantPast, to: Date().addingTimeInterval(3600), policy: policy) {
            lines.append([row.day, escape(row.app), String(row.bytes.rx), String(row.bytes.tx), String(row.bytes.total)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func save(_ csv: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // 加 BOM，Excel 開啟中文才不會亂碼。
            try ("\u{FEFF}" + csv).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// 選一個資料夾，匯出完整的機器學習資料集（見 DatasetExporter）。
    static func exportDataset(collector: TrafficCollector, policy: QuotaPolicy) {
        collector.flush()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "匯出到這裡"
        panel.message = "選擇要存放資料集的資料夾"
        NSApp.activate()
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let folder = parent.appendingPathComponent("NetQuota-dataset-\(formatter.string(from: Date()))", isDirectory: true)
        do {
            let result = try DatasetExporter.export(store: collector.store, policy: policy, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            let alert = NSAlert()
            alert.messageText = "資料集已匯出"
            alert.informativeText = "每分鐘 \(result.minuteRows) 筆、各程式 \(result.appRows) 筆、每日 \(result.dayRows) 筆。欄位說明在 SCHEMA.md。"
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct ExportMenu: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    var body: some View {
        Menu {
            Button("每日摘要…") {
                collector.flush()
                CSVExporter.save(CSVExporter.dailySummaryCSV(collector: collector, policy: settings.policy),
                                 suggestedName: "NetQuota-每日摘要.csv")
            }
            Button("各程式每日用量…") {
                collector.flush()
                CSVExporter.save(CSVExporter.appDailyCSV(collector: collector, policy: settings.policy),
                                 suggestedName: "NetQuota-各程式每日.csv")
            }
            Divider()
            Button("機器學習資料集（每分鐘）…") {
                CSVExporter.exportDataset(collector: collector, policy: settings.policy)
            }
        } label: {
            Label("匯出 CSV", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
    }
}
