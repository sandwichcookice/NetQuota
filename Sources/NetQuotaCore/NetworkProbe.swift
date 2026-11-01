import Foundation
import SystemConfiguration

/// 目前連線的網路。
public struct NetworkInfo: Equatable, Sendable {
    /// 穩定的識別碼：優先用路由器（預設閘道）的硬體位址，不需要任何權限。
    public let id: String
    public let interface: String
    public let router: String
    public let routerMAC: String?
    /// Wi-Fi 名稱（需要定位服務權限；有線網路為 nil）。
    public var ssid: String?

    public init(id: String, interface: String, router: String, routerMAC: String?, ssid: String? = nil) {
        self.id = id
        self.interface = interface
        self.router = router
        self.routerMAC = routerMAC
        self.ssid = ssid
    }
}

/// 偵測目前透過哪個網路上網。
public enum NetworkProbe {
    /// 系統目前的主要介面與預設閘道（例如 en0、192.168.50.1）。
    public static func primaryRoute() -> (interface: String, router: String)? {
        guard let store = SCDynamicStoreCreate(nil, "NetQuota" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = value["PrimaryInterface"] as? String,
              let router = value["Router"] as? String
        else { return nil }
        return (interface, router)
    }

    /// 用 arp 查路由器的硬體位址。
    public static func macAddress(of ip: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-n", ip]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parseARP(String(decoding: data, as: UTF8.self))
    }

    /// 解析 `? (192.168.50.1) at aa:bb:cc:11:22:33 on en0 ifscope [ethernet]`。
    public static func parseARP(_ output: String) -> String? {
        guard let atRange = output.range(of: " at ") else { return nil }
        let rest = output[atRange.upperBound...]
        let mac = rest.prefix { !$0.isWhitespace }
        let parts = mac.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ $0.count <= 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        // arp 會省略前導 0（例如 0:1a:…），補齊成固定格式。
        return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
    }

    public static func networkID(router: String, mac: String?, interface: String) -> String {
        if let mac { return "mac:\(mac)" }
        return "route:\(interface)/\(router)"
    }

    /// 目前的網路（不含 SSID，SSID 由 App 端在有權限時補上）。
    public static func current() -> NetworkInfo? {
        guard let route = primaryRoute() else { return nil }
        let mac = macAddress(of: route.router)
        return NetworkInfo(id: networkID(router: route.router, mac: mac, interface: route.interface),
                           interface: route.interface, router: route.router, routerMAC: mac)
    }
}
