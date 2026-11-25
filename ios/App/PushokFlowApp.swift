import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

@main
struct PushokFlowApp: App {
    var body: some Scene { WindowGroup { Home() } }
}

private struct Home: View {
    @StateObject private var connection = Connection()
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFile = false
    private let accent = Color(red: 0.24, green: 0.91, blue: 0.85)

    private var status: String {
        if !connection.hasProfile { return "Добавь профиль WireGuard, чтобы подключиться." }
        switch connection.status {
        case .connected: return "Туннель включён"
        case .connecting: return "Подключение…"
        case .reasserting: return "Восстановление связи…"
        case .disconnecting: return "Отключение…"
        default: return "Туннель выключен"
        }
    }

    private var action: String {
        if !connection.hasProfile { return "Добавить файл .conf" }
        switch connection.status {
        case .connected, .reasserting: return "Отключить"
        case .connecting: return "Отменить подключение"
        default: return "Подключить"
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.065, blue: 0.13),
                Color(red: 0.06, green: 0.13, blue: 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Text("Pushok Flow").font(.largeTitle.bold())
                    Image("pushok").resizable().scaledToFit().frame(height: 170).accessibilityHidden(true)
                    Text(status).font(.headline).multilineTextAlignment(.center)
                    Button {
                        if connection.hasProfile { Task { await connection.toggle() } }
                        else { choosingFile = true }
                    } label: {
                        Text(action).font(.headline).frame(maxWidth: .infinity).padding(8)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundColor(.black)
                    .disabled(connection.busy || connection.status == .disconnecting)
                    if connection.hasProfile {
                        Button("Заменить файл .conf") { choosingFile = true }
                            .disabled(!connection.mayImport)
                    }
                    Link("Открыть Pushok Shop", destination: URL(string: "https://pushok.shop/shop/")!)
                }
                .padding(24).frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark).tint(accent)
        .task { await connection.reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await connection.reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in connection.updateStatus() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await connection.importFile(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { connection.message = "Не удалось открыть файл." }
            }
        }
        .alert("Pushok Flow", isPresented: Binding(get: { connection.message != nil }, set: { if !$0 { connection.message = nil } })) {
            Button("Закрыть", role: .cancel) {}
        } message: { Text(connection.message ?? "") }
    }
}
