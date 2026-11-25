import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { _, _ in }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let settings = protocolConfiguration as? NETunnelProviderProtocol,
                  let reference = settings.passwordReference else { throw FlowProfileError.invalid }
            let config = try FlowProfile.parse(FlowProfile.load(reference))
            adapter.start(tunnelConfiguration: config) { error in completionHandler(error) }
        } catch { completionHandler(error) }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }
}
