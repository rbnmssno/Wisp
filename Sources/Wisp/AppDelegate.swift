import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var player: PlayerWindow!
    private let monobrow = MonobrowPublisher()
    private let onePlayer = OnePlayer()
    private(set) var state = PlayerState()
    private var lastPublished = PlayerState()
    /// Development: a test copy beside the real Wisp. It shares nothing: its own website data and
    /// settings, no Dock icon and no Monobrow, so the real player and the island are left alone.
    /// (WebKit still lists it in Now Playing while it plays; keep such runs short.)
    private let isolated = Args.isolated

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.echo = Args.has("--log")
        let mine = ProcessInfo.processInfo.processIdentifier
        if !isolated, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != mine }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(isolated ? .accessory : .regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = Menus.build(target: self)

        player = PlayerWindow()
        player.onMessage = { [weak self] body in self?.handle(body) }
        monobrow.command = { [weak self] name, value in
            guard let self else { return }
            // Monobrow asks for the state when it starts or opens: answer at once, from what is known.
            if name == "refresh" { self.lastPublished = self.state; self.monobrow.publish(self.state); return }
            self.player.command(name, value)
        }
        // Spotify started playing: Wisp makes way.
        onePlayer.onSpotifyStarted = { [weak self] in
            guard let self, self.state.playing else { return }
            Log.debug("Spotify started, pausing")
            self.player.command("pause")
        }
        if !isolated {
            onePlayer.start()
            monobrow.start()
            // A Monobrow that is already running learns that Wisp is here.
            monobrow.publish(state)
        }

        if !Args.has("--hidden") { player.show() }
        DevProbe.run(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        player.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isolated else { return }
        monobrow.publishStopped()
    }

    private func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "state":
            let s = PlayerState(message: body)
            let started = s.playing && !state.playing
            state = s
            Log.debug("state: \(s.playing ? "▶" : "Ⅱ") \(s.artist) — \(s.title) \(Int(s.position))/\(Int(s.duration)) s, liked \(s.liked), volume \(Int(s.volume * 100))")
            guard !isolated else { return }
            if started { onePlayer.wispStarted() }
            // Monobrow hears only real changes; it counts the position on by itself.
            if !s.sameAs(lastPublished) {
                lastPublished = s
                monobrow.publish(s)
            }
        case "log":
            Log.debug("page: \(body["text"] as? String ?? "")")
        default:
            break
        }
    }

    // MARK: - Menu actions

    @objc func playPause(_ sender: Any?) { player.command("playpause") }
    @objc func nextTrack(_ sender: Any?) { player.command("next") }
    @objc func previousTrack(_ sender: Any?) { player.command("previous") }
    @objc func volumeUp(_ sender: Any?) { player.command("volume", min(1, state.volume + 0.1)) }
    @objc func volumeDown(_ sender: Any?) { player.command("volume", max(0, state.volume - 0.1)) }
    @objc func like(_ sender: Any?) { player.command("like") }
    @objc func search(_ sender: Any?) { player.show(); player.command("search") }
    @objc func goBack(_ sender: Any?) { player.webView.goBack() }
    @objc func goForward(_ sender: Any?) { player.webView.goForward() }
    @objc func reload(_ sender: Any?) { player.webView.reload() }
    @objc func goHome(_ sender: Any?) { player.webView.load(URLRequest(url: PlayerWindow.home)) }
    @objc func zoomIn(_ sender: Any?) { player.webView.pageZoom = min(2, player.webView.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { player.webView.pageZoom = max(0.5, player.webView.pageZoom - 0.1) }
    @objc func zoomReset(_ sender: Any?) { player.webView.pageZoom = 1 }
    @objc func showPlayer(_ sender: Any?) { player.show() }
    @objc func toggleAdBlock(_ sender: Any?) { player.setAdBlock(!AdBlock.enabled) }
    @objc func toggleOnePlayer(_ sender: Any?) { OnePlayer.enabled.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAdBlock(_:)) { item.state = AdBlock.enabled ? .on : .off }
        if item.action == #selector(toggleOnePlayer(_:)) { item.state = OnePlayer.enabled ? .on : .off }
        return true
    }
    @objc func showCurrentTrack(_ sender: Any?) {
        guard let url = URL(string: state.url), !state.url.isEmpty else { return }
        player.show()
        player.webView.load(URLRequest(url: url))
    }
}

/// The menu bar, with the shortcuts music apps on the Mac use (Spotify, Music).
enum Menus {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Wisp")
        app.addItem(withTitle: tr("О программе Wisp", "About Wisp"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, tr("Блокировать рекламу", "Block Ads"), #selector(AppDelegate.toggleAdBlock(_:)), "", target: target)
        item(app, tr("Не играть вместе со Spotify", "Don't Play Alongside Spotify"), #selector(AppDelegate.toggleOnePlayer(_:)), "", target: target)
        app.addItem(.separator())
        app.addItem(withTitle: tr("Скрыть Wisp", "Hide Wisp"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: tr("Скрыть остальные", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: tr("Показать все", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: tr("Выйти из Wisp", "Quit Wisp"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // The standard edit actions, so typing in the site's search and comments works as usual.
        let edit = submenu(main, tr("Правка", "Edit"))
        edit.addItem(withTitle: tr("Отменить", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Повторить", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Вырезать", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Копировать", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Вставить", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Выбрать все", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        item(edit, tr("Поиск", "Search"), #selector(AppDelegate.search(_:)), "f", target: target)

        let view = submenu(main, tr("Вид", "View"))
        item(view, tr("Назад", "Back"), #selector(AppDelegate.goBack(_:)), "[", target: target)
        item(view, tr("Вперёд", "Forward"), #selector(AppDelegate.goForward(_:)), "]", target: target)
        item(view, tr("Главная", "Home"), #selector(AppDelegate.goHome(_:)), "H", mods: [.command, .shift], target: target)
        item(view, tr("Обновить", "Reload"), #selector(AppDelegate.reload(_:)), "r", target: target)
        view.addItem(.separator())
        item(view, tr("Увеличить", "Zoom In"), #selector(AppDelegate.zoomIn(_:)), "+", target: target)
        item(view, tr("Уменьшить", "Zoom Out"), #selector(AppDelegate.zoomOut(_:)), "-", target: target)
        item(view, tr("Обычный размер", "Actual Size"), #selector(AppDelegate.zoomReset(_:)), "0", target: target)
        view.addItem(.separator())
        let full = view.addItem(withTitle: tr("Полный экран", "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]

        let controls = submenu(main, tr("Управление", "Controls"))
        // Space plays and pauses on the page itself (the site's own key), so the menu item has no key:
        // a Space shortcut here would also swallow spaces typed into the search field.
        item(controls, tr("Играть / Пауза (Пробел)", "Play / Pause (Space)"), #selector(AppDelegate.playPause(_:)), "", target: target)
        item(controls, tr("Следующий", "Next"), #selector(AppDelegate.nextTrack(_:)), arrow(NSRightArrowFunctionKey), target: target)
        item(controls, tr("Предыдущий", "Previous"), #selector(AppDelegate.previousTrack(_:)), arrow(NSLeftArrowFunctionKey), target: target)
        controls.addItem(.separator())
        item(controls, tr("Громче", "Volume Up"), #selector(AppDelegate.volumeUp(_:)), arrow(NSUpArrowFunctionKey), target: target)
        item(controls, tr("Тише", "Volume Down"), #selector(AppDelegate.volumeDown(_:)), arrow(NSDownArrowFunctionKey), target: target)
        controls.addItem(.separator())
        item(controls, tr("Нравится", "Like"), #selector(AppDelegate.like(_:)), "l", target: target)
        item(controls, tr("Открыть текущий трек", "Show Current Track"), #selector(AppDelegate.showCurrentTrack(_:)), "l", mods: [.command, .shift], target: target)

        let window = submenu(main, tr("Окно", "Window"))
        window.addItem(withTitle: tr("Свернуть", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: tr("Масштаб", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: tr("Закрыть окно", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        item(window, "Wisp", #selector(AppDelegate.showPlayer(_:)), "1", target: target)
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                             mods: NSEvent.ModifierFlags = [.command], target: AnyObject) -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    private static func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }
}
