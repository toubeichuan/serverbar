import AppKit
import SwiftUI
import Combine

/// Owns the desktop status item independently of the main window.
@MainActor
final class DesktopStatusBar: NSObject, ObservableObject {
    private let store: MonitorStore
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var mainWindow: NSWindow?
    private var preferencesObservation: AnyCancellable?
    private var wakeObservation: AnyCancellable?
    private var lastStatusOnly: Bool?
    private var didStart = false
    var statusOnly: Bool { UserDefaults.standard.object(forKey: "statusBarOnly") as? Bool ?? true }

    init(store: MonitorStore) {
        self.store = store
        super.init()
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    private func start() {
        guard !didStart else { return }
        didStart = true
        install()
        applyRunMode()
        preferencesObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.applyRunMode() }
        wakeObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.store.refreshAll() }
        if !statusOnly { showMainWindow() }
    }

    private func applyRunMode() {
        let only = statusOnly
        guard only != lastStatusOnly else { return }
        lastStatusOnly = only
        NSApp.setActivationPolicy(only ? .accessory : .regular)
    }

    func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let root = DashboardView().environmentObject(store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "ServerBar"
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: root)
            window.minSize = NSSize(width: 1080, height: 660)
            window.center()
            window.setFrameAutosaveName("GPU Monitor Main")
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        item.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "ServerBar")
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("ServerBar 桌面状态栏")
        popover.behavior = .transient
        popover.animates = true
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        let summary = store.summary()
        item?.button?.title = " " + store.menuTitle
        let mode = store.isDemo ? "演示数据" : store.paused ? "已暂停" : "自动更新"
        item?.button?.appearsDisabled = store.paused
        item?.button?.toolTip = "空闲 / 总卡数 · \(summary.idle) 空闲 · \(summary.occupied) 占用 · \(summary.unknown) 未知\n\(mode) · \(store.servers.count) 台服务器 · \(summary.unavailable) 台不可用"
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    func show() {
        guard let button = item?.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let availableHeight = min(620, max(260, (screen?.visibleFrame.height ?? 800) - 160))
        let view = MenuPanel(availableContentHeight: availableHeight, openMainAction: { [weak self] in
            self?.popover.performClose(nil)
            self?.showMainWindow()
        }).environmentObject(store)
        let controller = NSHostingController(rootView: view)
        // Explicit size avoids an empty/undersized SwiftUI status popup on newer macOS.
        controller.preferredContentSize = NSSize(width: 560, height: availableHeight + 125)
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

@MainActor
final class MonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var store: MonitorStore!
    private var statusBar: DesktopStatusBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MonitorStore(demo: ProcessInfo.processInfo.arguments.contains("--demo"))
        statusBar = DesktopStatusBar(store: store)
        let menu = NSMenu()
        let appMenu = NSMenu(title: "ServerBar")
        add("设置…", key: ",", action: #selector(settings), to: appMenu)
        appMenu.addItem(.separator())
        add("退出 ServerBar", key: "q", action: #selector(quit), to: appMenu)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let monitorMenu = NSMenu(title: "监控")
        add("显示服务器总览", key: "0", action: #selector(overview), to: monitorMenu)
        add("展开桌面状态栏", key: "M", action: #selector(showStatus), to: monitorMenu)
        monitorMenu.addItem(.separator())
        add("刷新全部", key: "r", action: #selector(refresh), to: monitorMenu)
        add("暂停 / 恢复监控", key: "", action: #selector(togglePause), to: monitorMenu)
        add("添加服务器…", key: "n", action: #selector(addServer), to: monitorMenu)
        let monitorItem = NSMenuItem(title: "监控", action: nil, keyEquivalent: "")
        monitorItem.submenu = monitorMenu
        menu.addItem(monitorItem)
        // Standard Edit actions keep text fields and SSH import usable.
        let editMenu = NSMenu(title: "编辑")
        for (title, key, action) in [("剪切", "x", "cut:"), ("拷贝", "c", "copy:"),
                                      ("粘贴", "v", "paste:"), ("全选", "a", "selectAll:")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func add(_ title: String, key: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func overview() { store.showSettings = false; statusBar?.showMainWindow() }
    @objc private func settings() { store.showSettings = true; statusBar?.showMainWindow() }
    @objc private func showStatus() { statusBar?.show() }
    @objc private func refresh() { store.refreshAll() }
    @objc private func togglePause() { store.togglePause() }
    @objc private func addServer() {
        guard !store.isDemo else { return }
        store.showAdd = true
        statusBar?.showMainWindow()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A deliberate second open should provide a route back to the window.
        // First launch still follows statusBarOnly in DesktopStatusBar.start().
        statusBar?.showMainWindow()
        return false
    }
}
