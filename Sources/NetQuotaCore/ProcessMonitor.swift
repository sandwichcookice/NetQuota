import Foundation

/// 長駐執行 nettop（delta 模式），把每次取樣的各程序增量回呼出去。
///
/// nettop 的輸出接到 pipe 時會被整塊緩衝，所以透過 `script` 給它一個 pty，才能即時拿到資料。
/// 只監測非 loopback 的介面（`-t external`）。
public final class ProcessMonitor: @unchecked Sendable {
    /// 在背景佇列上呼叫。
    public var onSample: (([ProcessSample]) -> Void)?

    private let interval: Int
    private let queue = DispatchQueue(label: "NetQuota.ProcessMonitor")
    private var process: Process?
    private var parser = NettopParser()
    private var stopped = true

    public init(interval: Int = 3) {
        self.interval = interval
    }

    public func start() {
        queue.async { [self] in
            stopped = false
            launch()
        }
    }

    public func stop() {
        queue.sync { [self] in
            stopped = true
            process?.terminate()
            process = nil
        }
    }

    private func launch() {
        guard !stopped else { return }
        parser = NettopParser()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        task.arguments = [
            "-q", "/dev/null",
            "/usr/bin/nettop", "-P", "-n", "-L", "0", "-d", "-s", String(interval),
            "-t", "external", "-x", "-J", "bytes_in,bytes_out",
        ]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.queue.async {
                for block in self.parser.feed(text) {
                    self.onSample?(block)
                }
            }
        }
        task.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // nettop 意外結束時，5 秒後自動重啟。
            self.queue.asyncAfter(deadline: .now() + 5) {
                guard !self.stopped, self.process === task else { return }
                self.launch()
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            NSLog("NetQuota: 無法啟動 nettop：\(error)")
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.launch() }
        }
    }
}
