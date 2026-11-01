import Combine
import NetQuotaCore
import SwiftUI

/// 選單列上的圖示與文字。選單列只能顯示單色，所以用圖示形狀表示警戒程度。
struct MenuBarLabel: View {
    @ObservedObject var collector: TrafficCollector
    @ObservedObject var settings: AppSettings
    let dashboardRequests: PassthroughSubject<Void, Never>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).monospacedDigit()
        }
        .onReceive(dashboardRequests) {
            openWindow(id: "dashboard")
            NSApp.activate()
            // 視窗已經開著時 openWindow 不會把它帶到最前面。
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("dashboard") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    private var symbol: String {
        switch collector.fraction {
        case ..<0.7: "arrow.up.arrow.down.circle"
        case ..<0.9: "exclamationmark.circle"
        case ..<1.0: "exclamationmark.triangle.fill"
        default: "xmark.octagon.fill"
        }
    }

    private var text: String {
        let binary = settings.binaryUnits
        var parts: [String] = []
        switch settings.menuBarStyle {
        case .usedOfQuota:
            parts.append("\(ByteFormat.compactGB(collector.used, binary: binary))/\(ByteFormat.compactGB(collector.quota, binary: binary))G")
        case .remaining:
            parts.append("剩 \(ByteFormat.compactGB(collector.remaining, binary: binary))G")
        case .percent:
            parts.append("\(Int((collector.fraction * 100).rounded()))%")
        }
        if settings.showSpeedInMenuBar {
            parts.append("↓\(ByteFormat.compactRate(collector.rxRate)) ↑\(ByteFormat.compactRate(collector.txRate))")
        }
        return parts.joined(separator: " ")
    }
}
