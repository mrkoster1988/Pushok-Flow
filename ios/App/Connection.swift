import Combine
import CryptoKit
import Foundation
import NetworkExtension
import UIKit

@MainActor
final class Connection: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var hasProfile = false
    @Published private(set) var busy = false
    @Published private(set) var operation = ""
    @Published private(set) var login = LoginState()
    @Published private(set) var kind = "manual"
    @Published private(set) var expires: Date?
    @Published private(set) var server = ""
    @Published private(set) var servers: [ShopFeed.Server] = []
    @Published private(set) var metrics: Traffic?
    @Published private(set) var latency: Int?
    @Published private(set) var account: AccessAPI.Account?
    @Published var message: String?
    private var manager: NETunnelProviderManager?
    private let api = AccessAPI()
    private let providerID = (Bundle.main.bundleIdentifier ?? "") + ".PacketTunnel"
    private var readingMetrics = false
    private var pinging = false
    private var generation = 0
    var mayImport: Bool { !busy && [.disconnected, .invalid].contains(status) }
    var loggedIn: Bool { (login.validUntil ?? .distantPast) > Date() && login.token != nil }
    var telegramInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "tg://resolve?domain=mtproxy_pushok_bot")!) }
    private var meta: [String: Any] { (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:] }

    private func run(_ title: String, _ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; operation = title
        defer { busy = false; operation = "" }
        do { try await work() }
        catch let error as AccessError { message = error.errorDescription }
        catch is FlowProfileError { message = "Проверь конфигурацию WireGuard и разрешение iOS на добавление подключения." }
        catch is CancellationError { }
        catch { message = "Не удалось завершить действие. Проверь сеть и разрешение iOS, затем повтори." }
    }

    private func readPreferences() async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
        hasProfile = manager?.protocolConfiguration?.passwordReference != nil
        kind = meta["kind"] as? String ?? "manual"
        expires = (meta["expiry"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        server = meta["name"] as? String ?? (hasProfile ? "WireGuard" : "")
        updateStatus()
    }

    func reload() async {
        await run("") {
            login = try LoginState.load()
            if let challenge = login.pending, challenge.deadline <= Date() { try setLogin(LoginState()) }
            try await readPreferences()
        }
    }
    private func setLogin(_ state: LoginState) throws { try state.save(); if state.token != login.token { account = nil }; login = state }
    func updateStatus() {
        let next = manager?.connection.status ?? .invalid
        if next != status { generation += 1; metrics = nil; latency = nil }
        status = next
    }

    func primary() async {
        await run("Подключение…") {
            try await readPreferences()
            switch status {
            case .connected, .connecting, .reasserting: manager?.connection.stopVPNTunnel(); return
            case .disconnecting: return
            default: break
            }
            if hasProfile && kind == "manual" { try await start(); return }
            if let pending = login.pending, pending.deadline > Date() {
                try await openTelegram(pending); return
            }
            if kind == "link" { try await sync("link", startAfter: true); return }
            if loggedIn { try await sync("account", startAfter: true); return }
            if kind == "guest" || (!telegramInstalled && kind != "account") {
                try await sync("guest", startAfter: true); return
            }
            try await beginLogin()
        }
    }
    private func openTelegram(_ challenge: LoginState.Challenge) async throws {
        let code = challenge.publicCode
        if telegramInstalled,
           await UIApplication.shared.open(URL(string: "tg://resolve?domain=mtproxy_pushok_bot&start=flow_" + code)!) { return }
        guard await UIApplication.shared.open(URL(string: "https://pushok.shop/?flow=" + code)!) else { throw AccessError.unavailable }
    }
    private func beginLogin() async throws {
        let challenge = try await api.begin()
        try setLogin(LoginState(pending: challenge))
        try await openTelegram(challenge)
    }
    func signIn() async {
        guard mayImport else { return }
        await run("Вход в Pushok…") {
            if let pending = login.pending, pending.deadline > Date() { try await openTelegram(pending) }
            else { try await beginLogin() }
        }
    }
    func guest() async {
        guard mayImport else { return }
        await run("Получаем гостевой профиль…") {
            if login.pending != nil { try setLogin(LoginState()) }
            try await sync("guest", startAfter: true)
        }
    }
    func poll() async {
        guard !busy, UIApplication.shared.applicationState == .active, var challenge = login.pending else { return }
        if Date() >= challenge.deadline {
            await run("") { try setLogin(LoginState()); throw AccessError.denied }; return
        }
        guard Date() >= challenge.nextPoll else { return }
        await run("Проверяем подтверждение…") {
            challenge.nextPoll = Date().addingTimeInterval(10)
            try setLogin(LoginState(pending: challenge))
            do {
                let state = try await api.poll(challenge)
                try setLogin(state)
                if state.token != nil { try await sync("account", startAfter: true) }
            } catch let wait as AccessAPI.PollDelay {
                challenge.nextPoll = Date().addingTimeInterval(Double(wait.seconds))
                try setLogin(LoginState(pending: challenge))
            } catch AccessError.denied {
                try setLogin(LoginState()); throw AccessError.denied
            }
        }
    }
    func refreshAccount() async {
        guard loggedIn, let token = login.token else { return }
        await run("Обновляем аккаунт…") {
            do { account = try await api.account(token) }
            catch AccessError.login { try setLogin(LoginState()); throw AccessError.login }
        }
    }
    func cancelLogin() async { await run("") { try setLogin(LoginState()) } }

    func logout() async {
        guard mayImport else { return }
        await run("") {
            if kind == "account" { try await removeProfile() }
            let token = login.token
            try setLogin(LoginState())
            if let token { try? await api.logout(token) }
        }
    }
    func remove() async { guard mayImport else { return }; await run("") { try await removeProfile() } }
    private func removeProfile() async throws {
        guard let manager else { return }
        try ensureStopped()
        let ref = manager.protocolConfiguration?.passwordReference
        try await manager.removeFromPreferences()
        if let ref { FlowProfile.remove(ref) }
        servers = []
        try await readPreferences()
    }
    private func ensureStopped() throws {
        guard [.invalid, .disconnected].contains(manager?.connection.status ?? .invalid) else { throw AccessError.busy }
    }

    func refresh(serverID: String? = nil) async {
        guard mayImport else { return }
        await run("Обновляем подписку…") { try await sync(kind, startAfter: false, selected: serverID) }
    }
    private func sync(_ source: String, startAfter: Bool, selected: String? = nil, imported: URL? = nil) async throws {
        try ensureStopped()
        let url: URL
        if source == "link" {
            if let imported { url = imported }
            else {
                guard let data = try PrivateStore.read("feed-" + (meta["feedID"] as? String ?? "")),
                      let value = String(data: data, encoding: .utf8), let saved = AccessAPI.feedURL(value) else { throw AccessError.invalid }
                url = saved
            }
        } else {
            if source == "account" && !loggedIn { throw AccessError.login }
            do {
                url = try await api.shopURL(token: source == "account" ? login.token : nil)
            } catch AccessError.login {
                if source == "account" { try setLogin(LoginState()) }
                throw AccessError.login
            } catch AccessError.expired {
                if source == kind && (source == "guest" || meta["sessionTag"] as? String == sessionTag) { try await removeProfile() }
                throw AccessError.expired
            }
        }
        let feed = try await api.feed(url)
        let feedID = SHA256.hash(data: Data(url.absoluteString.utf8)).hex
        let fingerprint = try feed.fingerprint()
        let same = meta["feedID"] as? String == feedID
        if same, let old = meta["revision"] as? Int {
            guard feed.revision > old || (feed.revision == old && meta["fingerprint"] as? String == fingerprint) else { throw AccessError.invalid }
        }
        guard feed.state == "active", Double(feed.expires_at) > Date().timeIntervalSince1970 else {
            if same { try await removeProfile() }
            throw AccessError.expired
        }
        let choose = selected ?? (same ? meta["selected"] as? String : nil)
        guard let profile = feed.profiles.first(where: {$0.id == choose}) ?? feed.profiles.first else { throw AccessError.invalid }
        var info: [String: Any] = ["kind":source, "expiry":feed.expires_at, "feedID":feedID, "revision":feed.revision,
            "fingerprint":fingerprint, "name":profile.name, "selected":profile.id]
        if source == "account" {
            guard loggedIn, let deadline = login.validUntil else { throw AccessError.login }
            info["authUntil"] = deadline.timeIntervalSince1970
            info["sessionTag"] = sessionTag
        }
        if source == "link" { try PrivateStore.write(Data(url.absoluteString.utf8), "feed-" + feedID) }
        if !same || meta["kind"] as? String != source || meta["fingerprint"] as? String != fingerprint ||
            meta["selected"] as? String != profile.id || (source == "account" && meta["sessionTag"] as? String != sessionTag) {
            try await install(Data(profile.config.utf8), info: info)
        }
        servers = feed.profiles
        if startAfter { try await start() }
    }
    private var sessionTag: String { SHA256.hash(data: Data((login.token ?? "").utf8)).hex }

    private func install(_ data: Data, info: [String: Any]) async throws {
        _ = try FlowProfile.parse(data)
        try await readPreferences()
        try ensureStopped()
        let target = manager ?? NETunnelProviderManager()
        let previous = target.protocolConfiguration?.passwordReference
        let reference = try FlowProfile.save(data)
        let settings = NETunnelProviderProtocol()
        settings.providerBundleIdentifier = providerID
        settings.serverAddress = "WireGuard"
        settings.passwordReference = reference
        settings.providerConfiguration = info
        target.protocolConfiguration = settings
        target.localizedDescription = "Pushok Flow"
        target.isEnabled = true
        do { try await target.saveToPreferences() }
        catch { FlowProfile.remove(reference); try? await readPreferences(); throw error }
        if let previous { FlowProfile.remove(previous) }
        try await readPreferences()
    }
    private func start() async throws {
        guard let manager, UIApplication.shared.applicationState == .active else { return }
        try await manager.loadFromPreferences()
        try ensureStopped()
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        try manager.connection.startVPNTunnel()
        updateStatus()
    }
    private func importData(_ data: Data) async throws {
        guard data.count <= FlowProfile.maximumSize else { throw FlowProfileError.invalid }
        if let text = String(data: data, encoding: .utf8),
           let url = AccessAPI.feedURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await sync("link", startAfter: false, imported: url)
        } else {
            try await install(data, info: ["kind":"manual", "name":"WireGuard"])
            servers = []
        }
        if login.pending != nil { try setLogin(LoginState()) }
    }
    func importCode(_ value: String) async {
        guard mayImport else { return }
        await run("Добавляем профиль…") { try await importData(Data(value.utf8)) }
    }
    func importFile(_ url: URL) async {
        guard mayImport else { return }
        await run("Добавляем профиль…") {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard let data = try file.read(upToCount: FlowProfile.maximumSize + 1) else { throw FlowProfileError.invalid }
            try await importData(data)
        }
    }
    func proxyURL() async throws -> URL { try await api.proxyURL() }

    func sample() {
        guard status == .connected, let session = manager?.connection as? NETunnelProviderSession, !readingMetrics else { return }
        let expected = generation
        readingMetrics = true
        do {
            try session.sendProviderMessage(Data([1])) { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    self.readingMetrics = false
                    guard self.generation == expected else { return }
                    self.metrics = data.flatMap { try? JSONDecoder().decode(Traffic.self, from: $0) }
                }
            }
        } catch { readingMetrics = false }
        guard !pinging else { return }
        pinging = true
        Task {
            let result = await TCPProbe.measure()
            pinging = false
            if generation == expected { latency = result }
        }
    }
}
