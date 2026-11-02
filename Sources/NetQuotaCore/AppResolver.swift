import Darwin
import Foundation

/// 用來把流量歸到哪個「程式」名下。
public struct AppIdentity: Hashable, Sendable {
    public let name: String
    /// .app 套件路徑，或一般執行檔路徑（用來取圖示）。
    public let path: String?

    public init(name: String, path: String?) {
        self.name = name
        self.path = path
    }
}

/// pid → 程式名稱。會把輔助程序（例如 Chrome Helper、WebKit Networking）歸到負責的 App 底下。
public final class AppResolver {
    private var cache: [Int32: AppIdentity] = [:]

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsiblePid: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    public init() {}

    public func resolve(pid: Int32, fallbackName: String) -> AppIdentity {
        if let cached = cache[pid] { return cached }
        var identity = AppIdentity(name: fallbackName, path: nil)
        if let path = Self.executablePath(of: pid) {
            identity = Self.identity(forExecutablePath: path)
            // XPC 服務與 App 擴充（例如 Safari 的 WebKit Networking）歸到負責的 App。
            // 一般命令列工具（curl、git、brew）保留自己的名字，不算到啟動它的終端機底下。
            if Self.isServiceComponent(path), let responsiblePid {
                let owner = responsiblePid(pid)
                if owner > 0, owner != pid, let ownerPath = Self.executablePath(of: owner) {
                    identity = Self.identity(forExecutablePath: ownerPath)
                }
            }
        }
        cache[pid] = identity
        return identity
    }

    static func isServiceComponent(_ path: String) -> Bool {
        path.contains(".xpc/") || path.contains(".appex/")
    }

    /// 移除已結束的程序，避免 pid 被重複使用時對應錯誤。
    public func pruneExited() {
        cache = cache.filter { kill($0.key, 0) == 0 || errno == EPERM }
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 從執行檔路徑推出顯示名稱：位於 .app 內的取最外層 .app 的名稱，否則取執行檔名。
    /// 以版本號為檔名的執行檔（例如 `~/.local/share/claude/versions/2.1.312`）取 `versions` 上一層的資料夾名稱，
    /// 這樣升級後仍算同一個程式。
    public static func identity(forExecutablePath path: String) -> AppIdentity {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = "/" + components[...index].joined(separator: "/")
            // Claude 桌面版內建的 Claude Code（Application Support/Claude/claude-code/<版本>/…/claude.app），
            // 和桌面版本身（Claude.app）分開算。
            if components[index] == "claude.app", components[..<index].contains("claude-code") {
                return AppIdentity(name: "Claude Code（桌面版）", path: bundlePath)
            }
            let name = String(components[index].dropLast(4))
            return AppIdentity(name: name, path: bundlePath)
        }
        var name = components.last.map(String.init) ?? path
        if components.count >= 3, isVersionNumber(name), components[components.count - 2] == "versions" {
            name = String(components[components.count - 3])
        }
        if name == "claude" { name = "Claude Code（CLI）" }
        return AppIdentity(name: name, path: path)
    }

    static func isVersionNumber<S: StringProtocol>(_ text: S) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
