import CoreLocation
import CoreWLAN
import Foundation

/// 讀取 Wi-Fi 名稱。macOS 15 起需要定位服務權限，否則系統只會回傳 nil。
/// 只用來讀 Wi-Fi 名稱，不會取得或記錄位置。
@MainActor
final class WiFiNameProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    var onAuthorizationChange: (() -> Void)?

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func requestIfNeeded() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func ssid(for interface: String) -> String? {
        guard isAuthorized else { return nil }
        return CWWiFiClient.shared().interface(withName: interface)?.ssid()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.onAuthorizationChange?()
        }
    }
}
