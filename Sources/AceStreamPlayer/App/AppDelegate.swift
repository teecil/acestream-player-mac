import AppKit
import SwiftUI

@main
enum AceStreamPlayerMain {
    @MainActor
    static func main() {
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication.delegate is weak; keep ours alive.
    static var shared: AppDelegate?

    let model = AppModel()
    private var window: NSWindow?
    private var quitInProgress = false


    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
        model.onLaunch()
        NSApp.activate()
    }

    func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = ContentView().environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AceStream Player"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(Layout.windowSize)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        // Keep the remembered position, but always use the current layout size.
        window.setContentSize(Layout.windowSize)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitInProgress { return .terminateLater }
        guard model.needsCleanupOnQuit else { return .terminateNow }
        quitInProgress = true
        Task { @MainActor in
            await model.prepareForQuit(timeout: 20)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        for url in urls where url.scheme?.lowercased() == "acestream" {
            model.handleOpenURL(url)
        }
    }

    // MARK: - Menu actions

    @objc func showLog(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    @objc func reinstallComponents(_ sender: Any?) {
        showMainWindow()
        model.goToSetup()
    }
}

@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let main = NSMenu()

        // Application
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе AceStream Player",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть AceStream Player", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Скрыть остальные",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить AceStream Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, titled: "AceStream Player", to: main)

        // Edit — required for ⌘V in the link field.
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, titled: "Правка", to: main)

        // Window
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(windowMenu, titled: "Окно", to: main)
        NSApp.windowsMenu = windowMenu

        // Help
        let help = NSMenu(title: "Справка")
        let reinstall = help.addItem(withTitle: "Проверить и установить компоненты…",
                                     action: #selector(AppDelegate.reinstallComponents(_:)), keyEquivalent: "")
        reinstall.target = target
        let log = help.addItem(withTitle: "Показать журнал работы",
                               action: #selector(AppDelegate.showLog(_:)), keyEquivalent: "")
        log.target = target
        addSubmenu(help, titled: "Справка", to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func addSubmenu(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
