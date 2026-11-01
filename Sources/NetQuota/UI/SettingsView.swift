import AppKit
import NetQuotaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    @State private var calibrationGB: Double?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("額度") {
                TextField("每日上限（\(settings.binaryUnits ? "GiB" : "GB")）", value: $settings.quotaGB,
                          format: .number.precision(.fractionLength(0...2)), prompt: Text("12"))
                    .frame(maxWidth: 300)
                Toggle("使用 1024 進位（GiB）", isOn: $settings.binaryUnits)
                Text("目前上限 = \(Int64(settings.policy.quotaBytes).formatted()) bytes。不確定宿舍怎麼算時，1000 進位（預設）比較保守。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("每日歸零時間", selection: $settings.resetHour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .frame(maxWidth: 240)
            }

            Section("校正今日已用量") {
                Text("第一天安裝、或 App 沒開時用掉的流量無法分辨時，可以輸入宿舍系統顯示的今日用量，讓數字對齊。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("今日已用（\(settings.binaryUnits ? "GiB" : "GB")）", value: $calibrationGB,
                              format: .number.precision(.fractionLength(0...3)), prompt: Text("例如 3.5"))
                        .frame(maxWidth: 300)
                    Button("套用") {
                        if let gb = calibrationGB {
                            collector.calibrate(toUsedGB: gb)
                            calibrationGB = nil
                        }
                    }
                    .disabled(calibrationGB == nil)
                    Button("清除校正") { collector.clearCalibration() }
                        .disabled(collector.calibration == 0)
                }
                Text("實測 \(settings.format(collector.today.total))，校正 \(collector.calibration >= 0 ? "+" : "−")\(settings.format(abs(collector.calibration)))，顯示 \(settings.format(collector.used))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }

            Section("通知") {
                Toggle("用量達 70% / 90% / 100% 時通知", isOn: $settings.alertsEnabled)
                Toggle("預測今天會超過額度時通知（已用 30% 以上才提醒）", isOn: $settings.forecastAlertEnabled)
                    .disabled(!settings.alertsEnabled)
                Toggle("單一程式短時間大量使用時通知", isOn: $settings.appSpikeEnabled)
                HStack {
                    Stepper("\(settings.appSpikeMinutes) 分鐘內", value: $settings.appSpikeMinutes, in: 1...60)
                    Stepper("超過 \(settings.appSpikeGB, specifier: "%.1f") GB", value: $settings.appSpikeGB, in: 0.1...20, step: 0.1)
                }
                .disabled(!settings.appSpikeEnabled)
                if Bundle.main.bundleIdentifier == nil {
                    Text("目前不是以 .app 執行，通知不會顯示。請用 scripts/build-app.sh 打包。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("選單列") {
                Picker("顯示", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 360)
                Toggle("同時顯示即時速率", isOn: $settings.showSpeedInMenuBar)
            }

            Section("系統") {
                Toggle("登入時自動啟動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("資料") {
                HStack {
                    ExportMenu()
                    if let url = model.databaseURL {
                        Button("在 Finder 中顯示資料庫") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                if let url = model.databaseURL {
                    Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("所有資料永久保留：每分鐘總量與特徵、各程式每分鐘用量。「機器學習資料集」會匯出完整的分鐘網格，可直接用 pandas 讀取。")
                    .font(.caption).foregroundStyle(.secondary)
                if let backups = model.backups {
                    BackupRow(backups: backups)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "設定失敗：\(error.localizedDescription)（請先把 NetQuota.app 放到「應用程式」資料夾再試）"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct BackupRow: View {
    @ObservedObject var backups: BackupManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("每日自動備份（保留 14 份）")
                Text(backups.lastBackup.map { "上次備份：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未備份")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = backups.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("立即備份") { backups.backupNow() }
            Button("顯示備份") {
                NSWorkspace.shared.activateFileViewerSelecting([backups.folder])
            }
        }
    }
}
