import Darwin
import Foundation

/// 讀取系統網路介面的累計位元組數（64-bit，不會在 4GB 溢位）。
public enum InterfaceCounter {
    /// 只計算實體介面（Wi-Fi / 有線 / USB 網卡都是 en*）。
    /// 排除 lo（本機）、utun（VPN，封包已經算在 en* 裡）、awdl/llw（AirDrop）、bridge、anpi 等。
    public static func isCounted(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// 回傳所有被計算的介面目前的累計值。
    public static func read() -> [String: ByteCounts] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: ByteCounts] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let pointer = base.advanced(by: offset)
                let header = pointer.loadUnaligned(as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                if messageLength == 0 { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = pointer.loadUnaligned(as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if isCounted(name) {
                            result[name] = ByteCounts(rx: info.ifm_data.ifi_ibytes, tx: info.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    /// 本次開機時間（秒），用來判斷 App 重啟期間是否有重開機。
    public static func bootTime() -> Int64 {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, u_int(mib.count), &tv, &size, nil, 0) == 0 else { return 0 }
        return Int64(tv.tv_sec)
    }
}

public enum CounterMath {
    /// 計算兩次讀數之間的增量。
    /// - 計數器變小（介面重設）時，視為從 0 重新開始，增量 = 目前值。
    /// - 新出現的介面（例如剛插上的 USB 網卡），計數器是從 0 開始，增量 = 目前值。
    public static func delta(previous: [String: ByteCounts], current: [String: ByteCounts]) -> ByteCounts {
        sum(deltas(previous: previous, current: current))
    }

    /// 各介面各自的增量（用來記錄這一分鐘主要走哪個介面）。
    public static func deltas(previous: [String: ByteCounts], current: [String: ByteCounts]) -> [String: ByteCounts] {
        var result: [String: ByteCounts] = [:]
        for (name, now) in current {
            guard let before = previous[name] else {
                result[name] = now
                continue
            }
            result[name] = ByteCounts(rx: now.rx >= before.rx ? now.rx - before.rx : now.rx,
                                      tx: now.tx >= before.tx ? now.tx - before.tx : now.tx)
        }
        return result
    }

    public static func sum(_ counters: [String: ByteCounts]) -> ByteCounts {
        counters.values.reduce(.zero, +)
    }
}
