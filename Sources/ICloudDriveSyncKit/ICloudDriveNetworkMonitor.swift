import Foundation
import Network

/// Thin wrapper around `NWPathMonitor` — the engine's only network-awareness
/// dependency. Kept separate from `ICloudDriveSyncEngine` just so that file
/// stays focused on sync logic.
final class ICloudDriveNetworkMonitor {
    struct PathState: Sendable {
        var isConnected: Bool
        var isWiFi: Bool
        var isCellular: Bool
        var isConstrained: Bool
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ICloudDriveSyncKit.NetworkMonitor")
    var onUpdate: ((PathState) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            #if os(iOS)
            let isWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let isCellular = path.status == .satisfied && path.usesInterfaceType(.cellular)
            let isConstrained = path.isConstrained
            #else
            let isWiFi = path.status == .satisfied
            let isCellular = false
            let isConstrained = false
            #endif

            self?.onUpdate?(
                PathState(
                    isConnected: path.status == .satisfied,
                    isWiFi: isWiFi,
                    isCellular: isCellular,
                    isConstrained: isConstrained
                )
            )
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
