import Foundation
import Network

/// Converts macOS route availability changes into a single main-actor event.
///
/// The first snapshot is intentionally ignored because `AppModel.start()`
/// already performs the startup probe. A later unavailable -> available
/// transition covers Wi-Fi roaming and interface recovery without waiting for
/// the 30-second periodic timer.
final class NetworkPathObserver: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var lastStatus: NWPath.Status?
    private var callback: (@MainActor @Sendable (Bool) -> Void)?

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "com.szu-netlogin.network-path")
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    func start(callback: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.callback = callback
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(status: path.status)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        callback = nil
    }

    private func handle(status: NWPath.Status) {
        let previousStatus = lastStatus
        lastStatus = status
        guard let previousStatus, previousStatus != status, let callback else { return }
        let isAvailable = status == .satisfied
        Task { @MainActor in
            callback(isAvailable)
        }
    }
}
