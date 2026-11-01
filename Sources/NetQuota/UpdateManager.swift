import AppKit
import NetQuotaCore
import UserNotifications

/// 檢查原始碼 repo 有沒有新的版本 tag，並在使用者按下更新時：抓取新版本、重新編譯、
/// 安裝後重新啟動。只在從 git clone 的原始碼用 scripts/build-app.sh 打包時可用。
@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppVersion)
        case updating(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "update.autoCheck") } }

    /// 目前執行中的版本。
    let current: AppVersion?
    /// 打包時記下的原始碼資料夾（git repo）；沒有就無法更新。
    let sourceDirectory: URL?
    let bundleID: String?
    let logURL: URL?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private static let checkInterval: TimeInterval = 24 * 3600

    init() {
        defaults.register(defaults: ["update.autoCheck": true])
        autoCheck = defaults.bool(forKey: "update.autoCheck")
        lastChecked = defaults.object(forKey: "update.lastChecked") as? Date
        let info = Bundle.main.infoDictionary ?? [:]
        current = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        bundleID = Bundle.main.bundleIdentifier
        let source = (info["NetQuotaSourceDirectory"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        sourceDirectory = source.flatMap {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) ? $0 : nil
        }
        logURL = (try? TrafficStore.defaultPath())?.deletingLastPathComponent().appendingPathComponent("update.log")
    }

    var isAvailable: Bool { sourceDirectory != nil && bundleID != nil && current != nil }

    var isBusy: Bool {
        switch state {
        case .checking, .updating: true
        default: false
        }
    }

    /// 啟動一分鐘後檢查一次，之後每小時看看距離上次檢查是否超過一天。
    func start() {
        guard isAvailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard autoCheck, !isBusy else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        Task { await check(notify: true) }
    }

    /// 讀取遠端的版本 tag，和目前版本比較。`notify` 時，每個新版本只通知一次。
    func check(notify: Bool = false) async {
        guard isAvailable, let sourceDirectory, let current, !isBusy else { return }
        state = .checking
        do {
            let output = try await Self.git(["ls-remote", "--tags", "--refs", "origin", "v*"], in: sourceDirectory, log: logURL)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: "update.lastChecked")
            guard let latest = AppVersion.latest(fromLsRemote: output), latest > current else {
                state = .upToDate
                return
            }
            state = .available(latest)
            if notify, defaults.string(forKey: "update.notifiedVersion") != latest.tag {
                defaults.set(latest.tag, forKey: "update.notifiedVersion")
                postNotification(for: latest)
            }
        } catch {
            state = .failed("無法檢查更新：\(error.localizedDescription)")
        }
    }

    func describe(_ version: AppVersion) -> String {
        guard let current else { return "新版本 \(version.tag)" }
        return version.isPatchUpdate(from: current) ? "修正版 \(version.tag)（修 bug）" : "新版本 \(version.tag)"
    }

    /// 抓取並切換到 `version`、重新編譯，成功後安裝並重新啟動。任何一步失敗都保留目前安裝的 App。
    func update(to version: AppVersion) async {
        guard let sourceDirectory, let bundleID, !isBusy else { return }
        let log = logURL
        do {
            state = .updating("檢查原始碼資料夾…")
            let changes = try await Self.git(["status", "--porcelain", "--untracked-files=no"], in: sourceDirectory, log: log)
            guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UpdateError("原始碼資料夾有尚未 commit 的修改，為了不覆蓋這些修改，已停止更新。")
            }

            state = .updating("抓取 \(version.tag)…")
            _ = try await Self.git(["fetch", "--tags", "origin"], in: sourceDirectory, log: log)
            let tagRef = "refs/tags/\(version.tag)"
            // 在分支上就快轉過去（保留分支）；沒有在分支上就直接切到那個 tag。
            if (try? await Self.git(["symbolic-ref", "-q", "HEAD"], in: sourceDirectory, log: log)) != nil {
                do {
                    _ = try await Self.git(["merge", "--ff-only", tagRef], in: sourceDirectory, log: log)
                } catch {
                    throw UpdateError("目前的分支無法直接快轉到 \(version.tag)（可能有自己的 commit），請手動更新。")
                }
            } else {
                _ = try await Self.git(["checkout", "--detach", tagRef], in: sourceDirectory, log: log)
            }

            state = .updating("編譯 \(version.tag)（約 1–2 分鐘）…")
            let script = sourceDirectory.appendingPathComponent("scripts/build-app.sh").path
            _ = try await Self.run("/bin/zsh", [script, "--bundle-id", bundleID], in: sourceDirectory, log: log)

            let built = sourceDirectory.appendingPathComponent("build/NetQuota.app")
            let builtVersion = Bundle(url: built)?.infoDictionary?["CFBundleShortVersionString"] as? String
            guard builtVersion.flatMap(AppVersion.init) == version else {
                throw UpdateError("編譯出來的版本是 \(builtVersion ?? "未知")，不是 \(version.tag)，沒有安裝。")
            }

            state = .updating("安裝並重新啟動…")
            try installAndRelaunch(built)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? "更新失敗：\(error.localizedDescription)")
        }
    }

    /// 執行中的 App 不能自己覆蓋自己，所以交給一個獨立的 shell：等 App 結束後替換、重新登記並打開。
    /// 複製失敗時把舊版放回去。
    private func installAndRelaunch(_ built: URL) throws {
        let destination = Bundle.main.bundleURL.standardizedFileURL.path
        guard destination.hasSuffix(".app"), destination.count > 5 else {
            throw UpdateError("找不到目前 App 的安裝位置，沒有安裝。")
        }
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$3.old"
            mv "$3" "$3.old" || exit 1
            if cp -R "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3"
            /usr/bin/open "$3"
            """
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/zsh")
        installer.arguments = ["-c", script, "netquota-update", "\(ProcessInfo.processInfo.processIdentifier)", built.path, destination]
        installer.standardOutput = FileHandle.nullDevice
        installer.standardError = FileHandle.nullDevice
        try installer.run()
        // 結束時收集器會把還沒寫入的資料存進資料庫。
        NSApp.terminate(nil)
    }

    private func postNotification(for version: AppVersion) {
        let content = UNMutableNotificationContent()
        content.title = "NetQuota 有\(describe(version))"
        content.body = "目前是 \(current?.tag ?? "未知版本")。到 設定 → 更新 按「更新」即可自動編譯並安裝。"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(version.tag)", content: content, trigger: nil))
    }

    // MARK: - 執行指令

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func git(_ arguments: [String], in directory: URL, log: URL?) async throws -> String {
        // 網路太慢時 20 秒後放棄，不會一直卡住。
        try await run("/usr/bin/git", ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=20"] + arguments,
                      in: directory, log: log)
    }

    /// 在背景執行指令，回傳輸出；結束代碼不是 0 時丟出錯誤（附最後幾行輸出）。輸出同時寫進更新紀錄。
    private static func run(_ executable: String, _ arguments: [String], in directory: URL, log: URL?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                // 從 Finder 打開的 App 的 PATH 很短；也不讓 git 停下來詢問帳號密碼。
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                appendLog(log, command: ([executable] + arguments).joined(separator: " "), output: output,
                          status: process.terminationStatus)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let tail = output.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
                    continuation.resume(throwing: UpdateError(tail.isEmpty ? "指令失敗（\(process.terminationStatus)）" : tail))
                }
            }
        }
    }

    private nonisolated static func appendLog(_ url: URL?, command: String, output: String, status: Int32) {
        guard let url else { return }
        let entry = "[\(Date().formatted(.iso8601))] $ \(command)\n\(output)(exit \(status))\n\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
