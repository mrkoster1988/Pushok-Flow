import Foundation

struct Traffic: Codable {
    var received: Int64 = 0
    var sent: Int64 = 0
    var handshake: Int64?
    init?(runtime: String) {
        var observed = false
        for line in runtime.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let n = Int64(parts[1]), n >= 0 else { continue }
            switch parts[0] {
            case "rx_bytes": received += min(n, Int64.max - received); observed = true
            case "tx_bytes": sent += min(n, Int64.max - sent); observed = true
            case "last_handshake_time_sec": if n > 0 { handshake = max(n, handshake ?? 0) }
            default: break
            }
        }
        if !observed { return nil }
    }
}

func canStartManagedProfile(_ info: [String: Any], at now: Date = Date()) -> Bool {
    switch info["kind"] as? String {
    case nil, "manual": return true
    case "account", "guest", "link":
        guard let expiry = info["expiry"] as? NSNumber, expiry.doubleValue > now.timeIntervalSince1970 else { return false }
        if info["kind"] as? String == "account" {
            guard let deadline = info["authUntil"] as? NSNumber, deadline.doubleValue > now.timeIntervalSince1970 else { return false }
        }
        return true
    default: return false
    }
}
