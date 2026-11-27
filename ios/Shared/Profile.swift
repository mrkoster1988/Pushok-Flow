import Foundation
import Security
import WireGuardKit

enum FlowProfileError: Error { case invalid, keychain }

enum FlowProfile {
    static let maximumSize = 256 * 1024

    static func parse(_ data: Data) throws -> TunnelConfiguration {
        guard data.count <= maximumSize, let text = String(data: data, encoding: .utf8),
              let config = try? TunnelConfiguration(fromWgQuickConfig: text, called: "Pushok Flow"),
              !config.interface.addresses.isEmpty, !config.peers.isEmpty,
              config.peers.contains(where: { $0.endpoint != nil && !$0.allowedIPs.isEmpty })
        else { throw FlowProfileError.invalid }
        return config
    }

    static func save(_ data: Data) throws -> Data {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FlowKeychainGroup") as? String
        else { throw FlowProfileError.keychain }
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrAccessGroup: group,
            kSecAttrService: "PushokFlow.WireGuard", kSecAttrAccount: UUID().uuidString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data, kSecReturnPersistentRef: true
        ]
        var value: CFTypeRef?
        guard SecItemAdd(item as CFDictionary, &value) == errSecSuccess,
              let reference = value as? Data else { throw FlowProfileError.keychain }
        return reference
    }

    static func load(_ reference: Data) throws -> Data {
        let query: [CFString: Any] = [kSecValuePersistentRef: reference, kSecReturnData: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { throw FlowProfileError.keychain }
        return data
    }

    static func remove(_ reference: Data) {
        SecItemDelete([kSecValuePersistentRef: reference] as CFDictionary)
    }
}
