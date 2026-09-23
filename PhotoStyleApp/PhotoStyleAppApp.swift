import SwiftUI

@main
struct PhotoStyleAppApp: App {
    @NSApplicationDelegateAdaptor(PhotoStyleApplicationDelegate.self) private var appDelegate
    @StateObject private var coordinator = PhotoStyleWebCoordinator()

    var body: some Scene {
        Window(coordinator.appDisplayName, id: "workspace") {
            ContentView(coordinator: coordinator)
                .task {
                    appDelegate.coordinator = coordinator
                    coordinator.startMCPServer()
                    coordinator.appUpdater.checkAtLaunch()
                }
                .onOpenURL { coordinator.openImage(at: $0) }
        }
        .defaultSize(width: 1380, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(coordinator.aboutAppTitle) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: coordinator.appDisplayName,
                        .applicationVersion: PhotoAppVersion.installed()?.display ?? "",
                        .version: ""
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(PhotoL10n.text("選取照片目錄…"), action: coordinator.openPhotoDirectoryPicker)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!coordinator.canImport)
                Button(PhotoL10n.text("開啟照片…"), action: coordinator.openFilePicker)
                    .keyboardShortcut("o")
                    .disabled(!coordinator.canImport)
            }
            CommandGroup(replacing: .saveItem) {
                Button(PhotoL10n.text("匯出照片…"), action: coordinator.requestImageExport)
                    .keyboardShortcut("s")
                    .disabled(!coordinator.canExport)
            }
            CommandGroup(replacing: .appSettings) {
                Button(PhotoL10n.text("設定…")) { coordinator.showPage("settings") }
                    .keyboardShortcut(",")
            }
            CommandMenu(PhotoL10n.text("照片")) {
                Button(PhotoL10n.text("AI 輔助計算"), action: coordinator.requestStyleComputation)
                    .keyboardShortcut(.return)
                    .disabled(!coordinator.canCompute)
                Divider()
                Button(PhotoL10n.text("放大")) { coordinator.showPage("zoomIn") }
                    .keyboardShortcut("+")
                Button(PhotoL10n.text("縮小")) { coordinator.showPage("zoomOut") }
                    .keyboardShortcut("-")
                Button(PhotoL10n.text("符合視窗")) { coordinator.showPage("zoomFit") }
                    .keyboardShortcut("0")
            }
            CommandGroup(after: .toolbar) {
                Button(PhotoL10n.text("工作台")) { coordinator.showPage("home") }.keyboardShortcut("1")
                Button(PhotoL10n.text("AI 核心")) { coordinator.showPage("ai") }.keyboardShortcut("3")
                Button(PhotoL10n.text("底片")) { coordinator.showPage("films") }.keyboardShortcut("4")
            }
        }
    }
}
