import AppKit
import NetQuotaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("外觀") {
                Picker("風格", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Text(settings.theme.subtitle).font(.caption).foregroundStyle(.secondary)
                if settings.theme == .standard {
                    Label(theme.liquidGlass ? "這台 Mac 支援，已自動套用 Apple Liquid Glass"
                                            : "未套用 Apple Liquid Glass（需要 macOS 26，且沒有開啟「減少透明度」）",
                          systemImage: theme.liquidGlass ? "checkmark.circle" : "circle.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("網路與每日上限") {
                Text("每個網路分開計算，可以各自設定每日上限（例如宿舍 12GB、另一個網路 16GB）。沒有設定上限的網路只記錄、不提醒。")
                    .font(.caption).foregroundStyle(.secondary)
                LocationPermissionRow(wifi: collector.wifi)
                if collector.networks.isEmpty {
                    Text("尚未偵測到網路").foregroundStyle(.secondary)
                }
                ForEach(collector.networks) { network in
                    NetworkSettingsRow(network: network)
                }
            }

            Section("單位與時間") {
                Toggle("使用 1024 進位（GiB）", isOn: $settings.binaryUnits)
                Text("不確定宿舍怎麼算時，1000 進位（預設）比較保守。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("每日歸零時間", selection: $settings.resetHour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .frame(maxWidth: 240)
            }

            Section("通知") {
                Toggle("有設定上限的網路用量達 70% / 90% / 100% 時通知", isOn: $settings.alertsEnabled)
                Toggle("預測今天會超過上限時通知（目前網路、已用 30% 以上才提醒）", isOn: $settings.forecastAlertEnabled)
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
        .scrollContentBackground(theme.isHack || theme.isGlass ? .hidden : .automatic)
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

private struct LocationPermissionRow: View {
    @ObservedObject var wifi: WiFiNameProvider

    var body: some View {
        HStack {
            if wifi.isAuthorized {
                Label("已允許讀取 Wi-Fi 名稱", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if wifi.isDenied {
                Label("沒有定位權限，無法顯示 Wi-Fi 名稱（仍可用路由器分辨網路，也可以自己命名）",
                      systemImage: "location.slash").foregroundStyle(.orange)
                Spacer()
                Button("打開系統設定") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            } else {
                Label("顯示 Wi-Fi 名稱需要定位權限（不會記錄位置）", systemImage: "location")
                Spacer()
                Button("允許") { wifi.requestIfNeeded() }
            }
        }
        .font(.callout)
    }
}

/// 一個網路的名稱、上限與今日校正。
private struct NetworkSettingsRow: View {
    let network: NetworkRecord
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var collector: TrafficCollector

    @State private var name = ""
    @State private var limited = false
    @State private var limitGB: Double?
    @State private var calibrationGB: Double?

    private var unit: String { settings.binaryUnits ? "GiB" : "GB" }
    private var isCurrent: Bool { network.id == collector.focusNetworkID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: NetworkIcon.symbol(for: network.interface)).foregroundStyle(.secondary)
                TextField("名稱", text: $name, prompt: Text(network.ssid ?? network.displayName))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .labelsHidden()
                    .onSubmit { collector.setLabel(network: network.id, name) }
                if isCurrent {
                    Text("目前連線").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text("今日 \(settings.format(collector.usage(for: network.id)))").monospacedDigit().foregroundStyle(.secondary)
            }
            Text(details).font(.caption).foregroundStyle(.secondary)

            HStack {
                Toggle("每日上限", isOn: $limited)
                    .onChange(of: limited) { _, on in
                        if on, limitGB == nil { limitGB = 12 }
                        collector.setQuota(network: network.id, gb: on ? limitGB : nil)
                    }
                TextField(unit, value: $limitGB, format: .number.precision(.fractionLength(0...2)), prompt: Text("12"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .labelsHidden()
                    .disabled(!limited)
                    .onSubmit { if limited { collector.setQuota(network: network.id, gb: limitGB) } }
                Text(unit).foregroundStyle(.secondary)
                Button("儲存") {
                    collector.setLabel(network: network.id, name)
                    collector.setQuota(network: network.id, gb: limited ? limitGB : nil)
                }
            }

            HStack {
                Text("校正今日已用").foregroundStyle(.secondary)
                TextField(unit, value: $calibrationGB, format: .number.precision(.fractionLength(0...3)), prompt: Text("例如 3.5"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .labelsHidden()
                Text(unit).foregroundStyle(.secondary)
                Button("套用") {
                    if let gb = calibrationGB {
                        collector.calibrate(network: network.id, toUsedGB: gb)
                        calibrationGB = nil
                    }
                }
                .disabled(calibrationGB == nil)
                if let value = collector.calibrations[network.id] {
                    Text("目前校正 \(value >= 0 ? "+" : "−")\(settings.format(abs(value)))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清除") { collector.clearCalibration(network: network.id) }
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        .onAppear(perform: load)
        .onChange(of: settings.binaryUnits) { _, _ in load() }
    }

    private var details: String {
        var parts: [String] = []
        if let ssid = network.ssid { parts.append("Wi-Fi：\(ssid)") }
        if let router = network.router { parts.append("路由器 \(router)") }
        if network.id.hasPrefix("mac:") { parts.append(String(network.id.dropFirst(4))) }
        parts.append("最後連線 \(network.lastSeen.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: " · ")
    }

    private func load() {
        name = network.label ?? ""
        limited = network.quotaBytes != nil
        limitGB = network.quotaBytes.map { ($0 / settings.bytesPerGB * 100).rounded() / 100 }
    }
}
