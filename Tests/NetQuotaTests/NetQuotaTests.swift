import Foundation
import Testing
@testable import NetQuotaCore

private let taipei: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    return calendar
}()

private func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = taipei
    formatter.timeZone = taipei.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

@Suite struct QuotaPolicyTests {
    @Test func midnightReset() {
        let policy = QuotaPolicy(quotaBytes: 12e9, resetHour: 0, calendar: taipei)
        let now = date("2026-11-01 15:30")
        #expect(policy.dayStart(containing: now) == date("2026-11-01 00:00"))
        #expect(policy.dayEnd(containing: now) == date("2026-11-02 00:00"))
        #expect(policy.dayKey(for: now) == "2026-11-01")
    }

    @Test func nonMidnightReset() {
        let policy = QuotaPolicy(quotaBytes: 12e9, resetHour: 6, calendar: taipei)
        // 凌晨 3 點仍屬於前一天。
        let early = date("2026-11-02 03:00")
        #expect(policy.dayStart(containing: early) == date("2026-11-01 06:00"))
        #expect(policy.dayKey(for: early) == "2026-11-01")
        #expect(policy.dayEnd(containing: early) == date("2026-11-02 06:00"))
        // 剛好 6 點是新的一天。
        #expect(policy.dayKey(for: date("2026-11-02 06:00")) == "2026-11-02")
    }

    @Test func splitAcrossDaysIsProportional() {
        let policy = QuotaPolicy(quotaBytes: 12e9, resetHour: 0, calendar: taipei)
        let parts = policy.split(ByteCounts(rx: 3000, tx: 300), from: date("2026-11-01 22:00"), to: date("2026-11-02 04:00"))
        #expect(parts.count == 2)
        #expect(parts[0].start == date("2026-11-01 22:00"))
        #expect(parts[0].bytes == ByteCounts(rx: 1000, tx: 100))
        #expect(parts[1].start == date("2026-11-02 00:00"))
        #expect(parts[1].bytes == ByteCounts(rx: 2000, tx: 200))
    }

    @Test func splitWithinOneDay() {
        let policy = QuotaPolicy(quotaBytes: 12e9, resetHour: 0, calendar: taipei)
        let parts = policy.split(ByteCounts(rx: 5, tx: 5), from: date("2026-11-01 10:00"), to: date("2026-11-01 11:00"))
        #expect(parts.count == 1)
        #expect(parts[0].bytes.total == 10)
    }

    @Test func quotaUnits() {
        #expect(QuotaPolicy.quotaBytes(gb: 12, binary: false) == 12_000_000_000)
        #expect(QuotaPolicy.quotaBytes(gb: 12, binary: true) == 12_884_901_888)
    }
}

@Suite struct ForecastTests {
    @Test func needsTwoMinutesOfData() {
        #expect(Forecast.make(used: 0, quota: 1, recentBytes: 1, window: 60, now: Date(), dayEnd: Date()) == nil)
    }

    @Test func projectsAndFindsExceedTime() {
        let now = date("2026-11-01 12:00")
        let end = date("2026-11-02 00:00")
        // 已用 6GB，最近 30 分鐘每秒 0.5MB → 12 小時再用 21.6GB。
        let forecast = Forecast.make(used: 6e9, quota: 12e9, recentBytes: 0.5e6 * 1800, window: 1800, now: now, dayEnd: end)!
        #expect(abs(forecast.projectedTotal - 27.6e9) < 1)
        #expect(forecast.rate == 0.5e6)
        // 剩 6GB ÷ 0.5MB/s = 12000 秒 = 3 小時 20 分。
        #expect(forecast.exceedAt == date("2026-11-01 15:20"))
    }

    @Test func historyProfileAvoidsNightOverProjection() {
        // 凌晨 1 點最近很忙（每秒 0.5MB），但過去這個時段之後幾乎不用網路。
        var hourly = [Double](repeating: 0, count: 24)
        hourly[20] = 2e9
        let profile = UsageProfile(hourly: hourly, days: 7)
        let now = date("2026-11-02 01:00")
        let end = date("2026-11-03 00:00")
        let forecast = Forecast.make(used: 1e9, quota: 12e9, recentBytes: 0.5e6 * 1800, window: 1800,
                                     now: now, dayEnd: end, profile: profile, calendar: taipei)!
        // 30 分鐘 × 0.5MB/s = 0.9GB，加上 20 點那一小時的 2GB
        #expect(abs(forecast.projectedTotal - 3.9e9) < 1e6)
        #expect(forecast.method == .history(days: 7))
        #expect(forecast.exceedAt == nil)
        // 直線延伸的舊算法會得到 1 + 0.5MB × 23 小時 ≈ 42GB
        let naive = Forecast.make(used: 1e9, quota: 12e9, recentBytes: 0.5e6 * 1800, window: 1800, now: now, dayEnd: end)!
        #expect(naive.projectedTotal > 40e9)
        #expect(naive.method == .recentRate)
    }

    @Test func historyProfileFindsExceedHour() {
        var hourly = [Double](repeating: 0, count: 24)
        hourly[21] = 6e9
        let forecast = Forecast.make(used: 8e9, quota: 12e9, recentBytes: 0, window: 1800,
                                     now: date("2026-11-02 18:00"), dayEnd: date("2026-11-03 00:00"),
                                     profile: UsageProfile(hourly: hourly, days: 5), calendar: taipei)!
        // 21 點開始每小時 6GB，還差 4GB → 21:40 超過
        #expect(forecast.exceedAt == date("2026-11-02 21:40"))
        #expect(forecast.curve.last?.date == date("2026-11-03 00:00"))
    }

    @Test func tooLittleHistoryFallsBackToRate() {
        let forecast = Forecast.make(used: 0, quota: 12e9, recentBytes: 1e6 * 1800, window: 1800,
                                     now: date("2026-11-02 12:00"), dayEnd: date("2026-11-03 00:00"),
                                     profile: UsageProfile(hourly: [Double](repeating: 1, count: 24), days: 2),
                                     calendar: taipei)!
        #expect(forecast.method == .recentRate)
    }

    @Test func noExceedWhenSlow() {
        let now = date("2026-11-01 23:00")
        let end = date("2026-11-02 00:00")
        let forecast = Forecast.make(used: 1e9, quota: 12e9, recentBytes: 1e6, window: 1800, now: now, dayEnd: end)!
        #expect(forecast.exceedAt == nil)
    }
}

@Suite struct CounterTests {
    @Test func normalDelta() {
        let delta = CounterMath.delta(previous: ["en0": ByteCounts(rx: 100, tx: 50)],
                                      current: ["en0": ByteCounts(rx: 160, tx: 70)])
        #expect(delta == ByteCounts(rx: 60, tx: 20))
    }

    @Test func counterResetCountsFromZero() {
        let delta = CounterMath.delta(previous: ["en0": ByteCounts(rx: 5_000_000_000, tx: 50)],
                                      current: ["en0": ByteCounts(rx: 300, tx: 10)])
        #expect(delta == ByteCounts(rx: 300, tx: 10))
    }

    @Test func newInterfaceCountsFully() {
        let delta = CounterMath.delta(previous: ["en0": ByteCounts(rx: 10, tx: 10)],
                                      current: ["en0": ByteCounts(rx: 10, tx: 10), "en7": ByteCounts(rx: 40, tx: 2)])
        #expect(delta == ByteCounts(rx: 40, tx: 2))
    }

    @Test func onlyPhysicalInterfacesCounted() {
        #expect(InterfaceCounter.isCounted("en0"))
        #expect(InterfaceCounter.isCounted("en5"))
        #expect(!InterfaceCounter.isCounted("lo0"))
        #expect(!InterfaceCounter.isCounted("utun3"))
        #expect(!InterfaceCounter.isCounted("awdl0"))
        #expect(!InterfaceCounter.isCounted("bridge0"))
    }

    @Test func readsRealCounters() {
        // 這台 Mac 至少要有一個 en* 介面，且計數器不會倒退。
        let first = InterfaceCounter.read()
        #expect(!first.isEmpty)
        let second = InterfaceCounter.read()
        for (name, counts) in first {
            #expect((second[name]?.rx ?? 0) >= counts.rx)
        }
        #expect(InterfaceCounter.bootTime() > 0)
    }
}

@Suite struct NettopParserTests {
    @Test func parsesLine() {
        let sample = NettopParser.parseLine("Google Chrome H.1234,5013505,447,")
        #expect(sample == ProcessSample(name: "Google Chrome H", pid: 1234, bytes: ByteCounts(rx: 5013505, tx: 447)))
        #expect(NettopParser.parseLine("com.apple.WebKi.88,10,20,")?.name == "com.apple.WebKi")
        #expect(NettopParser.parseLine(",bytes_in,bytes_out,") == nil)
    }

    @Test func dropsFirstCumulativeBlockAndSplitsChunks() {
        var parser = NettopParser()
        // pty 輸出：\r\n 換行、開頭有 ^D^H^H 控制字元，資料可能從任意位置被切開。
        let stream = "\u{4}\u{8}\u{8},bytes_in,bytes_out,\r\napsd.370,292890,61828,\r\n"
            + ",bytes_in,bytes_out,\r\nPython.37936,5013505,447,\r\nidle.1,0,0,\r\n"
            + ",bytes_in,bytes_out,\r\nPython.37936,0,0,\r\n"
            + ",bytes_in,bytes_out,\r\n"
        var blocks: [[ProcessSample]] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = stream.index(index, offsetBy: 7, limitedBy: stream.endIndex) ?? stream.endIndex
            blocks += parser.feed(String(stream[index..<end]))
            index = end
        }
        #expect(blocks.count == 2)
        #expect(blocks[0] == [ProcessSample(name: "Python", pid: 37936, bytes: ByteCounts(rx: 5013505, tx: 447))])
        #expect(blocks[1].isEmpty)
    }
}

@Suite struct AppResolverTests {
    @Test func outermostAppBundle() {
        let identity = AppResolver.identity(forExecutablePath:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        #expect(identity.name == "Google Chrome")
        #expect(identity.path == "/Applications/Google Chrome.app")
    }

    @Test func plainExecutable() {
        let identity = AppResolver.identity(forExecutablePath: "/usr/bin/curl")
        #expect(identity.name == "curl")
    }

    @Test func claudeDesktopAndClaudeCodeAreSeparate() {
        #expect(AppResolver.identity(forExecutablePath:
            "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper").name == "Claude")
        let desktop = AppResolver.identity(forExecutablePath:
            "/Users/someone/Library/Application Support/Claude/claude-code/2.1.309/0123abcd4567/claude.app/Contents/MacOS/claude")
        #expect(desktop.name == "Claude Code（桌面版）")
        #expect(desktop.path == "/Users/someone/Library/Application Support/Claude/claude-code/2.1.309/0123abcd4567/claude.app")
        #expect(AppResolver.identity(forExecutablePath: "/Users/someone/.local/share/claude/versions/2.1.312").name
                == "Claude Code（CLI）")
        #expect(AppResolver.identity(forExecutablePath: "/opt/homebrew/bin/claude").name == "Claude Code（CLI）")
    }

    @Test func versionNamedExecutableUsesToolName() {
        #expect(AppResolver.identity(forExecutablePath: "/Users/someone/.local/share/foo/versions/1.4.2").name == "foo")
        #expect(AppResolver.identity(forExecutablePath: "/usr/local/bin/1.4.2").name == "1.4.2")
        #expect(AppResolver.identity(forExecutablePath: "/opt/tool/versions/latest").name == "latest")
    }
}

@Suite struct TrafficStoreTests {
    @Test func aggregatesMinutesIntoDays() throws {
        let store = try TrafficStore(path: ":memory:")
        let policy = QuotaPolicy(quotaBytes: 12e9, resetHour: 6, calendar: taipei)
        try store.addMinute(at: date("2026-11-01 05:59"), ByteCounts(rx: 100, tx: 1))
        try store.addMinute(at: date("2026-11-01 06:00"), ByteCounts(rx: 200, tx: 2))
        try store.addMinute(at: date("2026-11-01 06:00"), ByteCounts(rx: 50, tx: 0))
        try store.addMinute(at: date("2026-11-02 05:00"), ByteCounts(rx: 300, tx: 3))
        try store.setCalibration(day: "2026-11-01", network: "mac:aa", bytes: 1000)

        let days = store.dailySummaries(from: date("2026-10-31 12:00"), to: date("2026-11-02 12:00"), policy: policy)
        #expect(days.map(\.day) == ["2026-10-31", "2026-11-01", "2026-11-02"])
        #expect(days[0].bytes == ByteCounts(rx: 100, tx: 1))
        #expect(days[1].bytes == ByteCounts(rx: 550, tx: 5))
        #expect(days[1].total == 1555)
        #expect(days[2].bytes == .zero)
    }

    @Test func appTotalsAndState() throws {
        let store = try TrafficStore(path: ":memory:")
        let now = date("2026-11-01 10:15")
        try store.addAppHour(at: now, app: "Safari", ByteCounts(rx: 10, tx: 1))
        try store.addAppHour(at: now.addingTimeInterval(60), app: "Safari", ByteCounts(rx: 10, tx: 1))
        try store.addAppHour(at: now, app: "Steam", ByteCounts(rx: 500, tx: 0))
        try store.setAppPath("Safari", path: "/Applications/Safari.app")
        let apps = store.appTotals(from: date("2026-11-01 00:00"), to: date("2026-11-02 00:00"))
        #expect(apps.map(\.name) == ["Steam", "Safari"])
        #expect(apps[1].bytes == ByteCounts(rx: 20, tx: 2))
        #expect(apps[1].path == "/Applications/Safari.app")

        try store.setState("k", "v")
        #expect(store.state("k") == "v")
        try store.setPeak(day: "2026-11-01", DayPeak(rxRate: 5, rxAt: now, txRate: 1, txAt: nil))
        #expect(store.peak(day: "2026-11-01")?.rxRate == 5)
        #expect(store.peak(day: "2026-11-01")?.txAt == nil)
    }

    @Test func renamesAppsWhenNamingRulesChange() throws {
        let store = try TrafficStore(path: ":memory:")
        let now = date("2026-11-01 10:15")
        let cli = "/Users/someone/.local/share/claude/versions/2.1.312"
        // 舊版用版本號當名稱；同一小時已經有新名稱的紀錄時要合併。
        try store.addAppHour(at: now, app: "2.1.312", ByteCounts(rx: 10, tx: 1))
        try store.addAppHour(at: now, app: "Claude Code（CLI）", ByteCounts(rx: 5, tx: 0))
        try store.addAppMinute(at: now, app: "2.1.312", ByteCounts(rx: 10, tx: 1))
        try store.addAppSample(AppSample(time: now, app: "2.1.312", pid: 7, bytes: ByteCounts(rx: 10, tx: 1), network: nil))
        try store.setAppPath("2.1.312", path: cli)
        try store.addAppHour(at: now, app: "Safari", ByteCounts(rx: 3, tx: 0))
        try store.setAppPath("Safari", path: "/Applications/Safari.app")

        try store.renameAppsByPath()

        let apps = store.appTotals(from: date("2026-11-01 00:00"), to: date("2026-11-02 00:00"))
        #expect(apps.map(\.name) == ["Claude Code（CLI）", "Safari"])
        #expect(apps[0].bytes == ByteCounts(rx: 15, tx: 1))
        #expect(apps[0].path == cli)
        #expect(store.appPaths()["2.1.312"] == nil)
        var minuteApps: [String] = []
        try store.db.query("SELECT app FROM minute_app") { minuteApps.append($0.text(0) ?? "") }
        #expect(minuteApps == ["Claude Code（CLI）"])
        var sampleApps: [String] = []
        try store.db.query("SELECT app FROM sample_app") { sampleApps.append($0.text(0) ?? "") }
        #expect(sampleApps == ["Claude Code（CLI）"])
    }
}

@Suite struct FormatTests {
    @Test func bytes() {
        #expect(ByteFormat.bytes(3_210_000_000.0) == "3.21 GB")
        #expect(ByteFormat.bytes(12_000_000_000.0) == "12.0 GB")
        #expect(ByteFormat.bytes(512.0) == "512 B")
        #expect(ByteFormat.compactGB(3_210_000_000) == "3.2")
        #expect(ByteFormat.compactRate(1_240_000) == "1.2M")
    }
}

@Suite struct ServiceComponentTests {
    @Test func onlyXPCAndExtensionsUseResponsibleApp() {
        #expect(AppResolver.isServiceComponent(
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"))
        #expect(!AppResolver.isServiceComponent("/usr/bin/curl"))
        #expect(!AppResolver.isServiceComponent("/opt/homebrew/bin/git"))
    }
}

@Suite struct PersistenceTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NetQuotaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func migratesOldDatabaseAndMarksUnknownCoverage() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("old.sqlite").path
        // 模擬 v0 的資料庫
        let old = try SQLiteDB(path: path)
        try old.exec("CREATE TABLE minute_total (ts INTEGER PRIMARY KEY, rx INTEGER NOT NULL, tx INTEGER NOT NULL);")
        try old.run("INSERT INTO minute_total VALUES (600, 10, 1)")

        let store = try TrafficStore(path: path)
        var observed: [Double] = []
        store.forEachMinute(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000)) { _, record in
            observed.append(record.observedSeconds)
        }
        #expect(observed == [-1])

        // 再開一次不會重複遷移
        _ = try TrafficStore(path: path)
        try store.addMinute(at: Date(timeIntervalSince1970: 610), MinuteRecord(bytes: ByteCounts(rx: 5, tx: 0), observedSeconds: 2))
        store.forEachMinute(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000)) { _, record in
            #expect(record.observedSeconds == 2)
            #expect(record.bytes.rx == 15)
        }
    }

    @Test func minuteFeaturesMerge() throws {
        let store = try TrafficStore(path: ":memory:")
        let t = Date(timeIntervalSince1970: 1200)
        try store.addMinute(at: t, MinuteRecord(bytes: ByteCounts(rx: 100, tx: 10), peakRx: 50, peakTx: 5,
                                                observedSeconds: 40, interface: "en0"))
        try store.addMinute(at: t.addingTimeInterval(30), MinuteRecord(bytes: ByteCounts(rx: 1, tx: 1), peakRx: 80, peakTx: 1,
                                                                       observedSeconds: 40))
        try store.addMinute(at: t, ByteCounts(rx: 3, tx: 0), recovered: true)
        var records: [MinuteRecord] = []
        store.forEachMinute(from: t, to: t.addingTimeInterval(60)) { records.append($1) }
        #expect(records.count == 1)
        #expect(records[0].bytes == ByteCounts(rx: 104, tx: 11))
        #expect(records[0].peakRx == 80)
        #expect(records[0].peakTx == 5)
        #expect(records[0].observedSeconds == 60)
        #expect(records[0].recovered)
        #expect(records[0].interface == "en0")
    }

    @Test func datasetHasDenseMinuteGrid() throws {
        let dir = try tempDir()
        let store = try TrafficStore(path: ":memory:")
        let policy = QuotaPolicy(quotaBytes: 12e9, resetHour: 0, calendar: taipei)
        let start = date("2026-11-02 10:00")
        try store.addMinute(at: start, MinuteRecord(bytes: ByteCounts(rx: 100, tx: 1), observedSeconds: 60, interface: "en0"))
        try store.addMinute(at: start.addingTimeInterval(180), MinuteRecord(bytes: ByteCounts(rx: 7, tx: 0), observedSeconds: 30))
        try store.addAppMinute(at: start, app: "Steam, Inc", ByteCounts(rx: 90, tx: 0))

        let result = try DatasetExporter.export(store: store, policy: policy, to: dir, now: start.addingTimeInterval(240))
        #expect(result.minuteRows == 5)   // 10:00–10:04，中間沒紀錄的分鐘也要有
        #expect(result.appRows == 1)
        let lines = try String(contentsOf: dir.appendingPathComponent("minutes.csv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 6)
        #expect(lines[1].hasSuffix(",100,1,0,0,60,0,en0,"))
        #expect(lines[1].contains(",2026-11-02,600,1,"))  // 第 600 分鐘、週一
        #expect(lines[2].hasSuffix(",0,0,0,0,0,0,,"))     // 沒有監測的分鐘
        let apps = try String(contentsOf: dir.appendingPathComponent("app_minutes.csv"), encoding: .utf8)
        #expect(apps.contains("\"Steam, Inc\",90,0"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("SCHEMA.md").path))
    }

    @Test func backupProducesReadableCopy() throws {
        let dir = try tempDir()
        let store = try TrafficStore(path: dir.appendingPathComponent("live.sqlite").path)
        try store.addMinute(at: Date(timeIntervalSince1970: 600), ByteCounts(rx: 42, tx: 0))
        let copy = dir.appendingPathComponent("backup.sqlite")
        try store.backup(to: copy)
        let restored = try TrafficStore(path: copy.path)
        #expect(restored.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000)).rx == 42)
    }
}

@Suite struct NetworkTests {
    @Test func parsesARPOutput() {
        #expect(NetworkProbe.parseARP("? (192.168.50.1) at aa:bb:cc:11:22:33 on en0 ifscope [ethernet]\n") == "aa:bb:cc:11:22:33")
        // arp 會省略前導 0
        #expect(NetworkProbe.parseARP("? (10.0.0.1) at 0:1a:2b:3:4c:5d on en5 ifscope [ethernet]") == "00:1a:2b:03:4c:5d")
        #expect(NetworkProbe.parseARP("? (10.0.0.1) at (incomplete) on en0 ifscope [ethernet]") == nil)
        #expect(NetworkProbe.networkID(router: "10.0.0.1", mac: "aa:bb:cc:dd:ee:ff", interface: "en0") == "mac:aa:bb:cc:dd:ee:ff")
        #expect(NetworkProbe.networkID(router: "10.0.0.1", mac: nil, interface: "en5") == "route:en5/10.0.0.1")
    }

    @Test func perNetworkTotalsQuotaAndLabels() throws {
        let store = try TrafficStore(path: ":memory:")
        let policy = QuotaPolicy(quotaBytes: 0, resetHour: 0, calendar: taipei)
        let dorm = NetworkInfo(id: "mac:aa", interface: "en0", router: "192.168.50.1", routerMAC: "aa", ssid: "Dorm_WiFi")
        let phone = NetworkInfo(id: "mac:bb", interface: "en0", router: "172.20.10.1", routerMAC: "bb")
        try store.upsertNetwork(dorm, at: date("2026-11-02 09:00"))
        try store.upsertNetwork(phone, at: date("2026-11-02 10:00"))
        // 第二次看到時沒拿到 SSID，不能把原本的名稱清掉
        try store.upsertNetwork(NetworkInfo(id: "mac:aa", interface: "en0", router: "192.168.50.1", routerMAC: "aa"),
                                at: date("2026-11-02 11:00"))
        try store.setNetworkQuota("mac:aa", bytes: 12e9)
        try store.setNetworkQuota("mac:bb", bytes: 16e9)
        try store.setNetworkLabel("mac:bb", "  手機熱點 ")

        let networks = store.networks()
        #expect(networks.map(\.displayName) == ["Dorm_WiFi", "手機熱點"])
        #expect(networks.map(\.quotaBytes) == [12e9, 16e9])

        let t = date("2026-11-02 10:00")
        try store.addNetworkMinute(at: t, network: "mac:aa", ByteCounts(rx: 100, tx: 10))
        try store.addNetworkMinute(at: t, network: "mac:bb", ByteCounts(rx: 5, tx: 0))
        try store.addNetworkMinute(at: t.addingTimeInterval(60), network: "mac:aa", ByteCounts(rx: 1, tx: 0))
        try store.setCalibration(day: "2026-11-02", network: "mac:aa", bytes: 500)

        let totals = store.networkTotals(from: date("2026-11-02 00:00"), to: date("2026-11-03 00:00"))
        #expect(totals["mac:aa"] == ByteCounts(rx: 101, tx: 10))
        #expect(totals["mac:bb"] == ByteCounts(rx: 5, tx: 0))
        #expect(store.calibrations(day: "2026-11-02") == ["mac:aa": 500])

        let dorm1 = store.dailySummaries(from: date("2026-11-02 00:00"), to: date("2026-11-02 23:00"), policy: policy, network: "mac:aa")
        #expect(dorm1.first?.total == 611)
        let phone1 = store.dailySummaries(from: date("2026-11-02 00:00"), to: date("2026-11-02 23:00"), policy: policy, network: "mac:bb")
        #expect(phone1.first?.total == 5)
    }

    @Test func usageProfileAveragesActiveDays() throws {
        let store = try TrafficStore(path: ":memory:")
        let policy = QuotaPolicy(quotaBytes: 0, resetHour: 0, calendar: taipei)
        try store.addNetworkMinute(at: date("2026-10-30 20:10"), network: "mac:aa", ByteCounts(rx: 300, tx: 0))
        try store.addNetworkMinute(at: date("2026-10-31 20:20"), network: "mac:aa", ByteCounts(rx: 100, tx: 0))
        try store.addNetworkMinute(at: date("2026-10-31 08:00"), network: "mac:aa", ByteCounts(rx: 40, tx: 0))
        try store.addNetworkMinute(at: date("2026-10-31 20:00"), network: "mac:bb", ByteCounts(rx: 999, tx: 0))
        // 今天的資料不算
        try store.addNetworkMinute(at: date("2026-11-02 20:00"), network: "mac:aa", ByteCounts(rx: 5000, tx: 0))
        let profile = store.usageProfile(network: "mac:aa", before: date("2026-11-02 00:00"), policy: policy)
        #expect(profile.days == 2)
        #expect(profile.hourly[20] == 200)
        #expect(profile.hourly[8] == 20)
        #expect(!profile.isUsable)
    }

    @Test func backfillsLegacyDataOnce() throws {
        let store = try TrafficStore(path: ":memory:")
        // 模擬升級前的資料：沒有網路資訊的分鐘與舊版校正
        try store.addMinute(at: Date(timeIntervalSince1970: 600), ByteCounts(rx: 42, tx: 8))
        try store.db.run("INSERT INTO calibration (day, bytes) VALUES ('1970-01-01', 7)")
        try store.upsertNetwork(NetworkInfo(id: "mac:aa", interface: "en0", router: "1.1.1.1", routerMAC: "aa"))

        #expect(try store.backfillUnassigned(to: "mac:aa", legacyQuotaBytes: 12e9))
        #expect(try !store.backfillUnassigned(to: "mac:bb", legacyQuotaBytes: 1))
        let totals = store.networkTotals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000))
        #expect(totals == ["mac:aa": ByteCounts(rx: 42, tx: 8)])
        #expect(store.networks().first?.quotaBytes == 12e9)
        #expect(store.calibrations(day: "1970-01-01") == ["mac:aa": 7])
        store.forEachMinute(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000)) { _, record in
            #expect(record.network == "mac:aa")
        }
    }

    @Test func datasetIncludesNetworks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NetQuotaTests-\(UUID().uuidString)")
        let store = try TrafficStore(path: ":memory:")
        let policy = QuotaPolicy(quotaBytes: 0, resetHour: 0, calendar: taipei)
        let t = date("2026-11-02 10:00")
        try store.upsertNetwork(NetworkInfo(id: "mac:aa", interface: "en0", router: "1.1.1.1", routerMAC: "aa", ssid: "Dorm_WiFi"))
        try store.setNetworkQuota("mac:aa", bytes: 100)
        try store.addMinute(at: t, MinuteRecord(bytes: ByteCounts(rx: 150, tx: 0), observedSeconds: 60, network: "mac:aa"))
        try store.addNetworkMinute(at: t, network: "mac:aa", ByteCounts(rx: 150, tx: 0))

        let result = try DatasetExporter.export(store: store, policy: policy, to: dir, now: t.addingTimeInterval(60))
        #expect(result.networkRows == 1)
        let days = try String(contentsOf: dir.appendingPathComponent("days.csv"), encoding: .utf8)
        #expect(days.contains("2026-11-02,mac:aa,150,0,0,150,100,1,"))   // 超過該網路的上限
        #expect(days.contains("2026-11-02,,150,0,0,150,,,"))             // 全部網路沒有上限
        let networks = try String(contentsOf: dir.appendingPathComponent("networks.csv"), encoding: .utf8)
        #expect(networks.contains("mac:aa,Dorm_WiFi,Dorm_WiFi,1.1.1.1,100,"))
        let minutes = try String(contentsOf: dir.appendingPathComponent("minutes.csv"), encoding: .utf8)
        #expect(minutes.contains(",60,0,,mac:aa"))
    }
}

@Suite struct SampleTests {
    @Test func migratesToV3AndRoundTripsSamples() throws {
        let store = try TrafficStore(path: ":memory:")
        var version: Int64 = 0
        try store.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == TrafficStore.schemaVersion)

        let t = Date(timeIntervalSince1970: 1_000.1234)
        let sample = TotalSample(time: t, dt: 2.003, bytes: ByteCounts(rx: 500, tx: 20), awake: true, network: "mac:aa",
                                 interfaces: ["en0": ByteCounts(rx: 480, tx: 20), "en7": ByteCounts(rx: 20, tx: 0)])
        try store.addSample(sample)
        try store.addSample(TotalSample(time: t.addingTimeInterval(30), dt: 28, bytes: .zero, awake: false,
                                        network: nil, interfaces: [:]))
        try store.addAppSample(AppSample(time: t, app: "Steam", pid: 42, bytes: ByteCounts(rx: 400, tx: 1), network: "mac:aa"))
        try store.addAppSample(AppSample(time: t, app: "Steam", pid: 43, bytes: ByteCounts(rx: 10, tx: 0), network: "mac:aa"))

        var samples: [TotalSample] = []
        store.forEachSample(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 5_000)) { samples.append($0) }
        #expect(samples.count == 2)
        #expect(abs(samples[0].time.timeIntervalSince1970 - 1_000.123) < 1e-6)   // 毫秒精度
        #expect(samples[0].interfaces == sample.interfaces)
        #expect(samples[0].network == "mac:aa")
        #expect(!samples[1].awake)
        #expect(samples[1].interfaces.isEmpty)

        var apps: [AppSample] = []
        store.forEachAppSample(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 5_000)) { apps.append($0) }
        #expect(apps.map(\.pid) == [42, 43])
        #expect(abs((store.firstSample()?.timeIntervalSince1970 ?? 0) - 1_000.123) < 1e-6)
    }

    @Test func exportsSamplesAcrossDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NetQuotaTests-\(UUID().uuidString)")
        let store = try TrafficStore(path: ":memory:")
        let policy = QuotaPolicy(quotaBytes: 0, resetHour: 0, calendar: taipei)
        let start = date("2026-11-01 23:59")
        // 跨過午夜、超過 24 小時，確認分塊不會漏也不會重複
        for offset in [0.0, 2.0, 90_000.0] {
            try store.addSample(TotalSample(time: start.addingTimeInterval(offset), dt: 2, bytes: ByteCounts(rx: 1, tx: 1),
                                            awake: true, network: "mac:aa", interfaces: ["en0": ByteCounts(rx: 1, tx: 1)]))
        }
        try store.addAppSample(AppSample(time: start, app: "a,b", pid: 7, bytes: ByteCounts(rx: 3, tx: 0), network: nil))

        let result = try DatasetExporter.export(store: store, policy: policy, to: dir, now: start.addingTimeInterval(90_000))
        #expect(result.sampleRows == 3)
        #expect(result.appSampleRows == 1)
        let lines = try String(contentsOf: dir.appendingPathComponent("samples.csv"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[1].hasSuffix(",2.000,1,1,1,mac:aa,en0=1/1"))
        let apps = try String(contentsOf: dir.appendingPathComponent("app_samples.csv"), encoding: .utf8)
        #expect(apps.contains("\"a,b\",7,3,0,"))
    }
}

@Suite struct AppVersionTests {
    @Test func parsing() {
        #expect(AppVersion("v1.2") == AppVersion(major: 1, minor: 2))
        #expect(AppVersion("1.2.1") == AppVersion(major: 1, minor: 2, patch: 1))
        #expect(AppVersion("v2") == AppVersion(major: 2, minor: 0))
        #expect(AppVersion("v1.2-beta") == nil)
        #expect(AppVersion("v1..2") == nil)
        #expect(AppVersion("v1.2.3.4") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v1.2")?.description == "1.2")
        #expect(AppVersion("v1.2.1")?.tag == "v1.2.1")
    }

    @Test func ordering() {
        let v = { AppVersion($0)! }
        #expect(v("1.2") < v("1.2.1"))
        #expect(v("1.2.2") < v("1.2.10"))
        #expect(v("1.9") < v("1.10"))
        #expect(v("1.10") < v("2.0"))
        #expect(v("1.2") == v("1.2.0"))
        #expect(v("1.2.1").isPatchUpdate(from: v("1.2")))
        #expect(!v("1.3").isPatchUpdate(from: v("1.2")))
    }

    @Test func latestFromLsRemote() {
        let output = """
            aaa\trefs/tags/v1.0
            bbb\trefs/tags/v1.10
            ccc\trefs/tags/v1.2.1
            ddd\trefs/tags/v2.0-rc1
            eee\trefs/tags/release-9
            """
        #expect(AppVersion.latest(fromLsRemote: output) == AppVersion("1.10"))
        #expect(AppVersion.latest(fromLsRemote: "") == nil)
    }
}
