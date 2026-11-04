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

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        model.setLanguage(language)
    }

    /// Rebuilds the menu bar in the current language.
    func rebuildMenu() {
        MainMenu.install(target: self)
    }
}

@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let main = NSMenu()

        // Application
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("About AceStream Player", "О программе AceStream Player"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let languageItem = NSMenuItem(title: tr("Language", "Язык"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = languageMenu.addItem(withTitle: language.nativeName,
                                            action: #selector(AppDelegate.chooseLanguage(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = language.rawValue
            item.state = language == L10n.current ? .on : .off
        }
        languageItem.submenu = languageMenu
        appMenu.addItem(languageItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Hide AceStream Player", "Скрыть AceStream Player"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: tr("Hide Others", "Скрыть остальные"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: tr("Show All", "Показать все"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Quit AceStream Player", "Завершить AceStream Player"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, titled: "AceStream Player", to: main)

        // Edit — required for ⌘V in the link field.
        let edit = NSMenu(title: tr("Edit", "Правка"))
        edit.addItem(withTitle: tr("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Redo", "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copy", "Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Select All", "Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, titled: tr("Edit", "Правка"), to: main)

        // Window
        let windowMenu = NSMenu(title: tr("Window", "Окно"))
        windowMenu.addItem(withTitle: tr("Minimize", "Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: tr("Close", "Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(windowMenu, titled: tr("Window", "Окно"), to: main)
        NSApp.windowsMenu = windowMenu

        // Help
        let help = NSMenu(title: tr("Help", "Справка"))
        let reinstall = help.addItem(withTitle: tr("Check and Install Components…", "Проверить и установить компоненты…"),
                                     action: #selector(AppDelegate.reinstallComponents(_:)), keyEquivalent: "")
        reinstall.target = target
        let log = help.addItem(withTitle: tr("Show Log", "Показать журнал работы"),
                               action: #selector(AppDelegate.showLog(_:)), keyEquivalent: "")
        log.target = target
        addSubmenu(help, titled: tr("Help", "Справка"), to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func addSubmenu(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
