import CryptoKit
import Foundation
import Security

enum AccessError: LocalizedError {
    case invalid, expired, pending, unavailable, rateLimit, login, denied, busy, storage
    var errorDescription: String? {
        switch self {
        case .invalid: return "Не удалось проверить ответ Pushok. Попробуй ещё раз."
        case .expired: return "Доступ истёк или отозван. Проверь подписку в Pushok Shop."
        case .pending: return "Shop готовит подключение. Попробуй ещё раз через минуту."
        case .unavailable: return "Сейчас Shop не может выдать профиль. Проверь доступ в кабинете."
        case .rateLimit: return "Слишком много запросов. Повтори позже."
        case .login: return "Сессия закончилась. Подтверди вход ещё раз."
        case .denied: return "Вход отменён или время подтверждения истекло."
        case .busy: return "Сначала отключи текущее соединение."
        case .storage: return "Не удалось открыть связку ключей. Разблокируй iPhone и повтори."
        }
    }
}

enum PrivateStore {
    private static func query(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "shop.pushok.flow.ios.account",
         kSecAttrAccount: name]
    }
    static func read(_ name: String) throws -> Data? {
        var query = query(name)
        query[kSecReturnData] = true
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw AccessError.storage }
        return data
    }
    static func write(_ data: Data, _ name: String) throws {
        var attributes = query(name)
        let update = [kSecValueData: data] as CFDictionary
        let result = SecItemUpdate(attributes as CFDictionary, update)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw AccessError.storage }
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw AccessError.storage }
    }
    static func guest() throws -> (device: String, proof: String) {
        let key: SymmetricKey
        if let saved = try read("guest"), saved.count == 32 { key = SymmetricKey(data: saved) }
        else {
            key = SymmetricKey(size: .bits256)
            try write(key.withUnsafeBytes { Data($0) }, "guest")
        }
        let device = HMAC<SHA256>.authenticationCode(for: Data("pushok-flow-ios-guest-v1".utf8), using: key).hex
        let proof = HMAC<SHA256>.authenticationCode(for: Data(device.utf8), using: key).hex
        return (device, proof)
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct LoginState: Codable {
    struct Challenge: Codable {
        let code: String, publicCode: String
        let deadline: Date
        var nextPoll: Date
    }
    var pending: Challenge?
    var token: String?
    var validUntil: Date?
    func save() throws { try PrivateStore.write(JSONEncoder().encode(self), "login") }
    static func load() throws -> LoginState {
        guard let data = try PrivateStore.read("login") else { return LoginState() }
        return try JSONDecoder().decode(LoginState.self, from: data)
    }
}

struct ShopFeed: Codable, Equatable {
    struct Server: Codable, Equatable {
        let id, name, config: String
        let kind: String
        enum CodingKeys: String, CodingKey { case id, name, config, kind = "protocol" }
    }
    let schema, state: String
    let version, revision, expires_at: Int
    let profiles: [Server]

    func validate() throws {
        guard schema == "pushok-flow-subscription", version == 1, (1...9007199254740991).contains(revision),
              (1...253402300799).contains(expires_at), ["active","revoked","expired"].contains(state),
              state == "active" ? (1...20).contains(profiles.count) : profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count else { throw AccessError.invalid }
        for server in profiles {
            guard server.kind == "wireguard", server.id.matches("[A-Za-z0-9_-]{1,64}"),
                  !server.name.isEmpty, server.name.count <= 64,
                  server.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  server.config.utf8.count <= 65536 else { throw AccessError.invalid }
            _ = try FlowProfile.parse(Data(server.config.utf8))
        }
    }
    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(self)).hex
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class AccessAPI {
    private let session: URLSession
    private let guestCredentials: () throws -> (device: String, proof: String)
    init(configuration config: URLSessionConfiguration = .ephemeral,
         guestCredentials: @escaping () throws -> (device: String, proof: String) = PrivateStore.guest) {
        self.guestCredentials = guestCredentials
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func fetch(_ url: URL, body: [String: Any]? = nil, token: String? = nil, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccessError.invalid }
        switch http.statusCode {
        case 200...299: break
        case 401: throw AccessError.login
        case 403, 410: throw AccessError.denied
        case 429:
            if url.path == "/api/v1/flow/device/token" {
                let delay = min(300, max(5, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30))
                throw PollDelay(seconds: delay)
            }
            throw AccessError.rateLimit
        default: throw AccessError.unavailable
        }
        guard http.expectedContentLength <= limit else { throw AccessError.invalid }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw AccessError.invalid }
            data.append(byte)
        }
        return data
    }
    private func json(_ path: String, body: [String: Any]? = nil, token: String? = nil) async throws -> [String: Any] {
        let url = URL(string: "https://pushok.shop" + path)!
        let data = try await fetch(url, body: body, token: token, limit: 32 * 1024)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccessError.invalid }
        return object
    }
    struct PollDelay: Error { let seconds: Int }
    func begin() async throws -> LoginState.Challenge {
        let caps = try await json("/api/v1/flow/capabilities")
        guard caps["protocol_version"] as? Int == 1,
              Set(caps["scopes"] as? [String] ?? []) == ["profile:read", "wallet:read"] else { throw AccessError.invalid }
        let v = try await json("/api/v1/flow/device", body: [:])
        guard let code = v["device_code"] as? String, code.matches("pfd_[A-Za-z0-9_-]{43}"),
              let publicCode = v["user_code"] as? String, publicCode.matches("[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{12}"),
              let ttl = v["expires_in"] as? Int, (1...300).contains(ttl),
              let interval = v["interval"] as? Int, (1...60).contains(interval) else { throw AccessError.invalid }
        return .init(code: code, publicCode: publicCode, deadline: Date().addingTimeInterval(Double(ttl)),
                     nextPoll: Date().addingTimeInterval(Double(max(5, interval))))
    }
    func poll(_ challenge: LoginState.Challenge) async throws -> LoginState {
        let v = try await json("/api/v1/flow/device/token", body: ["device_code":challenge.code])
        switch v["status"] as? String {
        case "pending":
            guard let interval = v["interval"] as? Int, (1...300).contains(interval),
                  let ttl = v["expires_in"] as? Int, (1...300).contains(ttl) else { throw AccessError.invalid }
            return LoginState(pending: .init(code: challenge.code, publicCode: challenge.publicCode,
                deadline: min(challenge.deadline, Date().addingTimeInterval(Double(ttl))),
                nextPoll: Date().addingTimeInterval(Double(max(5, interval)))))
        case "authorized":
            guard let token = v["access_token"] as? String, token.matches("pfa_[a-f0-9]{64}"),
                  v["token_type"] as? String == "Bearer",
                  Set(v["scope"] as? [String] ?? []) == ["profile:read", "wallet:read"],
                  let ttl = v["expires_in"] as? Int, (1...43200).contains(ttl) else { throw AccessError.invalid }
            return LoginState(token: token, validUntil: Date().addingTimeInterval(Double(ttl)))
        default: throw AccessError.invalid
        }
    }
    struct Account {
        let name, role: String
        let verified: Bool
        let rub, bonus, stars: Int
    }
    func account(_ token: String) async throws -> Account {
        let v = try await json("/api/v1/flow/me", token: token)
        guard let name = v["display_name"] as? String, let role = v["role"] as? String,
              let verified = v["phone_verified"] as? Bool, let wallet = v["wallet"] as? [String: Int],
              let rub = wallet["RUB"], let bonus = wallet["BONUS"], let stars = wallet["XTR"] else { throw AccessError.invalid }
        return Account(name: name, role: role, verified: verified, rub: rub, bonus: bonus, stars: stars)
    }
    func logout(_ token: String) async throws { _ = try await json("/api/v1/flow/logout", body: [:], token: token) }

    func shopURL(token: String?) async throws -> URL {
        let reply: [String: Any]
        if let token {
            let result = try await json("/api/v1/flow/shop-ticket", body: ["consent":true], token: token)
            guard let ticket = result["ticket"] as? String, ticket.matches("psb1\\.[A-Za-z0-9_-]{20,720}\\.[a-f0-9]{64}") else { throw AccessError.invalid }
            reply = try await json("/shop/api/flow/bridge/exchange", body: ["ticket":ticket])
        } else {
            let guest = try guestCredentials()
            reply = try await json("/shop/api/flow/guest", body: ["device":guest.device], token: guest.proof)
        }
        switch reply["status"] as? String {
        case "active":
            guard let value = reply["subscription_url"] as? String, let url = Self.feedURL(value) else { throw AccessError.invalid }
            return url
        case "pending": throw AccessError.pending
        case "expired", "revoked": throw AccessError.expired
        default: throw AccessError.unavailable
        }
    }
    static func feedURL(_ value: String) -> URL? {
        guard value.matches("https://pushok\\.shop/(?:shop/)?flow/wireguard/(?:device/)?[A-Za-z0-9_-]{43}") else { return nil }
        return URL(string: value)
    }
    func feed(_ url: URL) async throws -> ShopFeed {
        guard Self.feedURL(url.absoluteString) != nil else { throw AccessError.invalid }
        let data = try await fetch(url, limit: 512 * 1024)
        let feed = try JSONDecoder().decode(ShopFeed.self, from: data)
        try feed.validate()
        return feed
    }
    func proxyURL() async throws -> URL {
        let config = try await json("/api/v1/public-config")
        guard let raw = config["proxy_url"] as? String, let u = URLComponents(string: raw),
              u.scheme == "https", u.host == "t.me", u.path == "/proxy", u.user == nil, u.password == nil,
              let items = u.queryItems, items.count == 3, Set(items.map(\.name)) == ["server","port","secret"],
              let host = items.first(where: {$0.name == "server"})?.value, host.matches("[A-Za-z0-9.:-]{1,253}"),
              let rawPort = items.first(where: {$0.name == "port"})?.value, let port = Int(rawPort), (1...65535).contains(port),
              let secret = items.first(where: {$0.name == "secret"})?.value, secret.matches("[A-Fa-f0-9]{32,512}") else { throw AccessError.invalid }
        var target = URLComponents()
        target.scheme = "tg"; target.host = "proxy"; target.queryItems = items
        guard let url = target.url else { throw AccessError.invalid }
        return url
    }
}
