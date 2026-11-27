import Foundation
import Network

enum TCPProbe {
    static func measure() async -> Int? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "shop.pushok.flow.latency")
            let socket = NWConnection(host: "pushok.shop", port: 443, using: .tcp)
            let start = DispatchTime.now()
            var completed = false
            func finish(_ value: Int?) {
                guard !completed else { return }
                completed = true
                socket.stateUpdateHandler = nil
                socket.cancel()
                continuation.resume(returning: value)
            }
            socket.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            socket.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}
