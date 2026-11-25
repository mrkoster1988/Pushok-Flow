import AVFoundation
import NetworkExtension
import PhotosUI
import SwiftUI
import VisionKit

@main
struct PushokFlowApp: App {
    var body: some Scene { WindowGroup { Home() } }
}

private struct Home: View {
    @StateObject private var connection = Connection()
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @AppStorage("telegram-proxy-confirmed") private var proxyConfirmed = false
    @AppStorage("telegram-proxy-opened") private var proxyOpened = false
    @State private var confirmingProxy = false
    @State private var openingProxy = false
    private let accent = Color(red: 0.24, green: 0.91, blue: 0.85)
    private var active: Bool { [.connected, .connecting, .reasserting].contains(connection.status) }
    private var status: String {
        if !connection.operation.isEmpty { return connection.operation }
        switch connection.status {
        case .connected: return "Туннель включён"
        case .connecting: return "Подключение…"
        case .reasserting: return "Восстановление связи…"
        case .disconnecting: return "Отключение…"
        default: return connection.login.pending == nil ? "Туннель выключен" : "Ожидаем подтверждение в Telegram"
        }
    }
    private func proxy() {
        guard !openingProxy else { return }
        if proxyOpened { confirmingProxy = true; return }
        openingProxy = true
        Task {
            defer { openingProxy = false }
            do {
                let url = try await connection.proxyURL()
                proxyOpened = true
                if !(await UIApplication.shared.open(url)) {
                    proxyOpened = false
                    connection.message = "Установи Telegram, чтобы открыть настройки MTProxy."
                }
            } catch { connection.message = "Не удалось получить адрес MTProxy. Проверь связь с Pushok." }
        }
    }
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.03, green: 0.065, blue: 0.13),
                    Color(red: 0.06, green: 0.13, blue: 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        Image("pushok").resizable().scaledToFit().frame(height: 128).accessibilityHidden(true)
                        Button {
                            Task { await connection.primary() }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "power").font(.system(size: 38, weight: .medium))
                                Text(active ? "Отключить" : "Подключить").font(.headline)
                            }
                            .frame(width: 152, height: 152)
                            .background(Circle().fill(accent.opacity(0.10)))
                            .overlay(Circle().stroke(accent, lineWidth: 2))
                        }
                        .disabled(connection.busy || connection.status == .disconnecting)
                        Text(status).font(.subheadline).multilineTextAlignment(.center)
                        if connection.login.pending != nil {
                            Button("Гостевой доступ на 7 суток") { Task { await connection.guest() } }
                                .disabled(!connection.mayImport)
                        }
                        VStack(spacing: 10) {
                            if connection.hasProfile { row("Сервер", connection.server) }
                            if let expires = connection.expires {
                                row(connection.kind == "guest" ? "Гостевой доступ до" : "Подписка до",
                                    expires.formatted(date: .abbreviated, time: .shortened))
                            }
                            if connection.status == .connected {
                                row("Пинг до Pushok", connection.latency.map { "\($0) мс" } ?? "—")
                                if let sample = connection.metrics {
                                    row("Получено", bytes(sample.received)); row("Отправлено", bytes(sample.sent))
                                    row("Последний отклик", sample.handshake.map { Date(timeIntervalSince1970: Double($0)).formatted(date: .abbreviated, time: .standard) } ?? "Ожидаем")
                                }
                            }
                        }.font(.subheadline)
                        if !connection.hasProfile && connection.login.pending == nil {
                            Text("При первом подключении Flow получит профиль из Pushok Shop.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding(24).frame(maxWidth: 460).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Pushok Flow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !proxyConfirmed {
                        Button("MTProxy", action: proxy).font(.caption.bold()).disabled(openingProxy)
                    }
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Настройки")
                }
            }
            .navigationDestination(isPresented: $settings) {
                FlowSettings(connection: connection, proxy: {
                    if proxyConfirmed { proxyConfirmed = false }
                    proxy()
                })
            }
        }
        .preferredColorScheme(.dark).tint(accent)
        .environment(\.locale, Locale(identifier: "ru"))
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connection.reload()
            if proxyOpened { confirmingProxy = true }
            var tick = 0
            while !Task.isCancelled {
                await connection.poll()
                if tick % 8 == 0 { connection.sample() }
                tick += 1
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in connection.updateStatus() }
        .alert("Прокси подключён?", isPresented: $confirmingProxy) {
            Button("Прокси подключён") { proxyConfirmed = true; proxyOpened = false }
            Button("Пока нет", role: .cancel) { proxyOpened = false }
        } message: { Text("Проверь в Telegram, что у прокси Pushok статус «Подключён».") }
        .alert("Pushok Flow", isPresented: Binding(get: { connection.message != nil }, set: { if !$0 { connection.message = nil } })) {
            Button("Закрыть", role: .cancel) {}
        } message: { Text(connection.message ?? "") }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
    }
}

private struct FlowSettings: View {
    @ObservedObject var connection: Connection
    let proxy: () -> Void
    @State private var choosingFile = false
    @State private var scan = false
    @State private var picture: PhotosPickerItem?
    @State private var typing = false
    @State private var text = ""
    @State private var remove = false
    @State private var showingHelp = false
    @State private var confirmLogout = false
    private var canEdit: Bool { connection.mayImport && connection.login.pending == nil }
    var body: some View {
        List {
            Section {
                Button("Справка") { showingHelp = true }
            }
            Section("Аккаунт Pushok") {
                if connection.loggedIn {
                    if let account = connection.account {
                        Text(account.name)
                        if account.verified { Label("Телефон подтверждён", systemImage: "checkmark.circle") }
                        LabeledContent("Баланс", value: (Double(account.rub) / 100).formatted(.currency(code: "RUB")))
                        LabeledContent("Бонусы", value: (Double(account.bonus) / 100).formatted())
                        LabeledContent("Stars", value: "\(account.stars)")
                    }
                    Button("Обновить данные аккаунта") { Task { await connection.refreshAccount() } }
                    Button("Выйти", role: .destructive) { confirmLogout = true }.disabled(!connection.mayImport)
                } else {
                    Button(connection.login.pending == nil ? "Войти через Telegram" : "Открыть подтверждение") { Task { await connection.signIn() } }
                        .disabled(!connection.mayImport)
                    if connection.login.pending != nil {
                        Button("Отменить вход") { Task { await connection.cancelLogin() } }.disabled(connection.busy)
                    }
                    Button("Гостевой доступ на 7 суток") { Task { await connection.guest() } }.disabled(!connection.mayImport)
                }
            }
            Section("Подписка и сервер") {
                Link("Открыть Pushok Shop", destination: URL(string: "https://pushok.shop/shop/")!)
                if connection.hasProfile {
                    LabeledContent("Сервер", value: connection.server)
                    if connection.kind != "manual" {
                        if let expiry = connection.expires { LabeledContent("Действует до", value: expiry.formatted()) }
                        Button("Обновить подписку") { Task { await connection.refresh() } }.disabled(!canEdit)
                        if connection.servers.count > 1 {
                            ForEach(connection.servers, id: \.id) { server in
                                Button(server.name) { Task { await connection.refresh(serverID: server.id) } }.disabled(!canEdit)
                            }
                        }
                    }
                    Button("Удалить профиль с iPhone", role: .destructive) { remove = true }.disabled(!canEdit)
                }
                Button("Импортировать файл .conf") { choosingFile = true }.disabled(!canEdit)
                Button("Добавить ссылку Pushok") { typing = true }.disabled(!canEdit)
                if DataScannerViewController.isSupported {
                    Button("Сканировать QR-код") {
                        Task {
                            let allowed = await AVCaptureDevice.requestAccess(for: .video)
                            if allowed && DataScannerViewController.isAvailable { scan = true }
                            else { connection.message = "Разреши доступ к камере в настройках iPhone или выбери QR из фото." }
                        }
                    }.disabled(!canEdit)
                }
                PhotosPicker(selection: $picture, matching: .images) { Text("Считать QR из фото") }.disabled(!canEdit)
            }
            Section("Telegram") { Button("Открыть MTProxy Pushok", action: proxy) }
        }
        .navigationTitle("Настройки")
        .task { if connection.loggedIn { await connection.refreshAccount() } }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { Task { await connection.importFile(url) } }
        }
        .onChange(of: picture) { selection in
            guard let selection else { return }
            Task {
                defer { picture = nil }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw AccessError.invalid }
                    let value = try await QRImport.decode(data)
                    await connection.importCode(value)
                } catch { connection.message = "Не удалось прочитать QR. Выбери изображение с одним QR-кодом." }
            }
        }
        .sheet(isPresented: $scan) {
            NavigationStack {
                QRScanner(onRead: { value in scan = false; Task { await connection.importCode(value) } },
                          onFailure: { scan = false; connection.message = "Камера недоступна. Попробуй QR из фото." })
                    .toolbar { Button("Закрыть") { scan = false } }
            }
        }
        .alert("Ссылка подписки Pushok", isPresented: $typing) {
            SecureField("https://…", text: $text).textInputAutocapitalization(.never)
            Button("Добавить") { let value = text; text = ""; Task { await connection.importCode(value) } }
            Button("Отмена", role: .cancel) { text = "" }
        }
        .confirmationDialog("Удалить профиль с iPhone?", isPresented: $remove) {
            Button("Удалить профиль", role: .destructive) { Task { await connection.remove() } }
        }
        .confirmationDialog("Выйти и удалить подключение этого аккаунта с iPhone?", isPresented: $confirmLogout) {
            Button("Выйти", role: .destructive) { Task { await connection.logout() } }
        }
        .alert("Как подключиться", isPresented: $showingHelp) {
            Button("Закрыть") {}
        } message: { Text("Нажми «Подключить» на главной. Подтверди вход в Telegram и вернись в Flow. Если Telegram недоступен, выбери гостевой доступ. При первом запуске разреши iOS добавить конфигурацию VPN.") }
    }
}
