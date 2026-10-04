import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instance: AppDelegate?   // NSApplication.delegate is weak
    private var edge: EdgeController?
    private var presence: PresenceMonitor?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)       // lives in the Dock, not in the menu bar tray (В2)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let edge = EdgeController()
        edge.show()
        self.edge = edge
        presence = PresenceMonitor(sim: edge.sim)
        // The Dock icon is the static AppIcon (user decision: a live tile was costly and laggy).
    }

    /// Clicking the Dock icon calls Чилк out (until the voice slice arrives).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        edge?.callChilk()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Позвать Чилка"), #selector(callChilk)))
        let side = edge?.edge == .left
            ? item(String(localized: "Переселить к правому краю"), #selector(moveRight))
            : item(String(localized: "Переселить к левому краю"), #selector(moveLeft))
        menu.addItem(side)
        menu.addItem(.separator())

        // Manual acceptance helpers for slice 1 (removed once real needs drive him).
        let check = NSMenuItem(title: String(localized: "Проверка"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in [(String(localized: "Усталость: бодрый"), 0.0), (String(localized: "Усталость: подустал"), 0.55), (String(localized: "Усталость: пересидел"), 1.0)] {
            let i = item(title, #selector(setFatigue(_:)))
            i.representedObject = value
            i.state = abs((edge?.sim.fatigue ?? 0) - value) < 0.01 ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(item(String(localized: "Уснуть"), #selector(sleepNow)))
        sub.addItem(item(String(localized: "Проснуться: «с возвращением»"), #selector(wakeWelcome)))
        sub.addItem(item(String(localized: "Проснуться: «доброе утро»"), #selector(wakeMorning)))
        check.submenu = sub
        menu.addItem(check)
        return menu
    }

    @objc private func callChilk() { edge?.callChilk() }
    @objc private func moveLeft() { edge?.move(to: .left) }
    @objc private func moveRight() { edge?.move(to: .right) }
    @objc private func setFatigue(_ sender: NSMenuItem) { edge?.sim.fatigue = sender.representedObject as? Double ?? 0 }
    @objc private func sleepNow() { edge?.sim.fallAsleep() }
    @objc private func wakeWelcome() { presence?.wake(after: 30 * 60, hour: 15) }
    @objc private func wakeMorning() { presence?.wake(after: 8 * 3600, hour: 8) }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "О Чилке"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Выйти из Чилка"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}
