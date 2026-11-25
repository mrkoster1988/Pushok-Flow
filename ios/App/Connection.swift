import Combine
import Foundation
import NetworkExtension

@MainActor
final class Connection: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var hasProfile = false
    @Published private(set) var busy = false
    @Published var message: String?
    private var manager: NETunnelProviderManager?
    private let providerID = (Bundle.main.bundleIdentifier ?? "") + ".PacketTunnel"

    var mayImport: Bool { !busy && [.disconnected, .invalid].contains(status) }

    private func readPreferences() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
        hasProfile = manager?.protocolConfiguration?.passwordReference != nil
        updateStatus()
    }

    func reload() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await readPreferences() }
        catch { message = "Не удалось прочитать настройки подключения iPhone." }
    }

    func updateStatus() {
        status = manager?.connection.status ?? .invalid
    }

    func importFile(_ url: URL) async {
        guard mayImport else { return }
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard let data = try file.read(upToCount: FlowProfile.maximumSize + 1) else {
                throw FlowProfileError.invalid
            }
            _ = try FlowProfile.parse(data)
            try await readPreferences()
            guard [.disconnected, .invalid].contains(status) else {
                message = "Сначала отключи текущее соединение."
                return
            }
            let target = manager ?? NETunnelProviderManager()
            let previous = target.protocolConfiguration?.passwordReference
            let reference = try FlowProfile.save(data)
            let settings = NETunnelProviderProtocol()
            settings.providerBundleIdentifier = providerID
            settings.serverAddress = "WireGuard"
            settings.passwordReference = reference
            target.protocolConfiguration = settings
            target.localizedDescription = "Pushok Flow"
            target.isEnabled = true
            do { try await target.saveToPreferences() }
            catch {
                FlowProfile.remove(reference)
                try? await readPreferences()
                throw error
            }
            if let previous { FlowProfile.remove(previous) }
            manager = target
            hasProfile = true
            try await target.loadFromPreferences()
            updateStatus()
        } catch FlowProfileError.invalid {
            message = "Проверь файл .conf. Нужны адрес интерфейса, ключи, адрес сервера и маршруты WireGuard."
        } catch {
            message = "Не удалось сохранить подключение. Проверь доступ к файлу и разрешение iOS на добавление конфигурации."
        }
    }

    func toggle() async {
        guard !busy, hasProfile, let manager else { return }
        busy = true
        defer { busy = false }
        do {
            try await manager.loadFromPreferences()
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                manager.connection.stopVPNTunnel()
            case .disconnected, .invalid:
                if !manager.isEnabled {
                    manager.isEnabled = true
                    try await manager.saveToPreferences()
                    try await manager.loadFromPreferences()
                }
                try manager.connection.startVPNTunnel()
            default: break
            }
            updateStatus()
        } catch { message = "iOS не смогла запустить подключение. Проверь разрешение и профиль WireGuard." }
    }
}
