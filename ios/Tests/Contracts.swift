// The network contract suite runs on macOS. Xcode compiles the real profile parser into both device binaries.
import Foundation
enum FlowProfile {
    static func parse(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("[Interface]") else { throw AccessError.invalid }
        return text
    }
}

final class FixtureTransport: URLProtocol {
    static var guestStatus = "active"
    static let token = "pfa_" + String(repeating: "a", count: 64)
    static let feed = "https://pushok.shop/shop/flow/wireguard/" + String(repeating: "b", count: 43)
    static let code = "pfd_" + String(repeating: "c", count: 43)
    static let ticket = "psb1." + String(repeating: "d", count: 30) + "." + String(repeating: "e", count: 64)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        precondition(url.host == "pushok.shop")
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        var status = 200
        let reply: [String: Any]
        switch url.path {
        case "/api/v1/flow/capabilities":
            reply = ["protocol_version":1,"scopes":["profile:read","wallet:read"],"session_ttl_seconds":43200]
        case "/api/v1/flow/device":
            precondition(request.httpMethod == "POST" && bearer == nil)
            reply = ["device_code":Self.code,"user_code":"ABCDEFGHJKLM","expires_in":300,"interval":5]
        case "/api/v1/flow/device/token":
            precondition(bearer == nil)
            reply = ["status":"authorized","access_token":Self.token,"scope":["profile:read","wallet:read"],"token_type":"Bearer","expires_in":43200]
        case "/api/v1/flow/shop-ticket":
            precondition(bearer == "Bearer " + Self.token)
            reply = ["ticket":Self.ticket,"expires_in":60]
        case "/shop/api/flow/bridge/exchange":
            precondition(bearer == nil)
            reply = ["status":"active","subscription_url":Self.feed]
        case "/shop/api/flow/guest":
            precondition(request.httpMethod == "POST" && bearer == "Bearer " + String(repeating:"a", count:64))
            reply = ["status":Self.guestStatus, "subscription_url":Self.guestStatus == "active" ? Self.feed as Any : NSNull() as Any]
        case "/api/v1/public-config":
            reply = ["proxy_url":"https://t.me/proxy?server=proxy.example.org&port=443&secret=" + String(repeating:"a",count:32)]
        default:
            if url.absoluteString == Self.feed {
                precondition(bearer == nil)
                reply = ["schema":"pushok-flow-subscription","version":1,"state":"active","revision":2,"expires_at":2000000000,
                         "profiles":[["id":"one","name":"Pushok","protocol":"wireguard","config":"[Interface]"]]]
            } else { status = 404; reply = [:] }
        }
        let response = HTTPURLResponse(url: url,statusCode: status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Contracts {
    static func main() async throws {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FixtureTransport.self]
        let api = AccessAPI(configuration: c) { (String(repeating:"c", count:64), String(repeating:"a", count:64)) }
        let challenge = try await api.begin()
        let session = try await api.poll(challenge)
        precondition(session.token == FixtureTransport.token)
        let url = try await api.shopURL(token: session.token)
        let feed = try await api.feed(url)
        precondition(feed.profiles.first?.id == "one")
        let guestURL = try await api.shopURL(token: nil)
        precondition(guestURL == url)
        FixtureTransport.guestStatus = "pending"
        do { _ = try await api.shopURL(token: nil); preconditionFailure("Pending guest accepted") } catch AccessError.pending {}
        FixtureTransport.guestStatus = "expired"
        do { _ = try await api.shopURL(token: nil); preconditionFailure("Expired guest accepted") } catch AccessError.expired {}
        let proxy = try await api.proxyURL()
        precondition(proxy.scheme == "tg" && proxy.host == "proxy")
        for bad in [FixtureTransport.feed + "?x=y",FixtureTransport.feed.replacingOccurrences(of:"pushok.shop",with:"pushok.shop.example"),
                    FixtureTransport.feed.replacingOccurrences(of:"https:",with:"http:")] {
            precondition(AccessAPI.feedURL(bad) == nil)
        }
        let now = Date(timeIntervalSince1970: 100)
        precondition(!canStartManagedProfile(["kind":"guest","expiry":100], at: now))
        precondition(!canStartManagedProfile(["kind":"account","expiry":101,"authUntil":99], at: now))
        precondition(canStartManagedProfile(["kind":"account","expiry":101,"authUntil":101], at: now))
        precondition(canStartManagedProfile([:], at: now))
        let sample = Traffic(runtime:"private_key=secret\nrx_bytes=17\ntx_bytes=6\nlast_handshake_time_sec=8\nrx_bytes=15\ntx_bytes=0\n")
        precondition(sample?.received == 32 && sample?.sent == 6 && sample?.handshake == 8)
        precondition(Traffic(runtime:"private_key=secret") == nil)
        print("Verified Telegram login, ticket exchange, managed feed, proxy link, expiry gates and traffic totals.")
    }
}
