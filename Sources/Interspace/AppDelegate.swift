import AppKit
import ApplicationServices
import CDockSwipe
import Combine
import os
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let loginItemSetUpKey = "loginItemSetUp"

    private var statusItem: NSStatusItem?
    private let controller = TransitionController()
    private var permissionTimer: Timer?

    private let settings = AppSettings.shared
    private let settingsWindow = SettingsWindowController()
    private let updater = Updater()
    private var settingsObserver: AnyCancellable?
    private var hasAccessibility = false
    private var hasScreenRecording = false
    private var tapInstalled = false
    private var keyTapInstalled = false
    private var hasTrackpad = false

    private let log = Logger(subsystem: "com.cnrad.interspace", category: "state")
    private var lastStatus = ""
    private var didCaptureSpaces = false
    /// The kind of image the spaces were captured as: with the Dock in it, or without.
    private var capturedWithDock: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The notice comes before the value changes, so read it one step later.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluate()
            }
        }

        setUpStatusItem()
        updater.relaunch = { [weak self] in
            self?.relaunch()
        }

        // Open at login is on by default. This runs one time, so a later choice in the menu stays.
        if !UserDefaults.standard.bool(forKey: Self.loginItemSetUpKey) {
            UserDefaults.standard.set(true, forKey: Self.loginItemSetUpKey)
            setOpensAtLogin(true)
        }
        log.notice("opens at login: \(self.opensAtLogin)")

        controller.hideMenuBarIcon = { [weak self] screen in
            self?.hideIconForLoader(on: screen)
        }
        controller.showMenuBarIcon = { [weak self] in
            self?.statusItem?.button?.alphaValue = 1
        }

        SpaceShortcuts.onStep = { [weak self] step in
            self?.controller.keyboardStep(step)
        }

        MultitouchMonitor.shared.onFrame = { [weak self] frame in
            self?.controller.handle(frame)
        }
        hasTrackpad = MultitouchMonitor.shared.start()

        // Both prompts appear one time. The timer below sees the result.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        evaluate()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // The permissions and the keyboard shortcuts change in System Settings. See `updatePolling`.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(frontAppChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// Turns the transition on only when every part it needs works. If not, the system swipe stays as it is.
    private func evaluate() {
        hasAccessibility = AXIsProcessTrusted()
        // The swipe of macOS changes in System Settings too.
        SwipeFingers.refresh()
        let screenRecording = CGPreflightScreenCaptureAccess()
        if screenRecording, !hasScreenRecording {
            controller.prewarm()
        }
        hasScreenRecording = screenRecording

        if hasAccessibility, !tapInstalled {
            tapInstalled = ds_tap_install()
        }
        if hasAccessibility, !keyTapInstalled {
            keyTapInstalled = SpaceShortcuts.install()
            log.notice("keyboard tap installed: \(self.keyTapInstalled)")
        }
        if !hasTrackpad {
            hasTrackpad = MultitouchMonitor.shared.start()
        }

        let active = settings.transition.isCustom && hasAccessibility && hasScreenRecording && tapInstalled && hasTrackpad
            && Spaces.isAvailable
        let status = "active=\(active) transition=\(settings.transition.rawValue) accessibility=\(hasAccessibility) "
            + "screenRecording=\(hasScreenRecording) tap=\(tapInstalled) trackpad=\(hasTrackpad) spaces=\(Spaces.isAvailable) "
            + "swipe=\(SwipeFingers.description)"
        if status != lastStatus {
            lastStatus = status
            log.notice("\(status, privacy: .public)")
        }

        controller.isEnabled = active
        // The images of the other spaces are of the wrong kind after this setting changes. Capture them again.
        if capturedWithDock != settings.dockMovesWithSpace {
            capturedWithDock = settings.dockMovesWithSpace
            didCaptureSpaces = false
        }
        // Instant draws nothing and needs no images. They are taken when a drawn transition is chosen.
        if active, settings.transition.isDrawn, !didCaptureSpaces, Config.captureSpacesAtLaunch {
            didCaptureSpaces = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.controller.captureAllSpaces()
            }
        }
        ds_tap_set_suppress(active)
        // The keyboard shortcuts get the same transition as the swipe. Read again each time: the user can
        // change the shortcuts in System Settings.
        SpaceShortcuts.update(enabled: active && keyTapInstalled)
        statusItem?.button?.appearsDisabled = !active
        if let statusItem, statusItem.isVisible != settings.showsMenuBarIcon {
            statusItem.isVisible = settings.showsMenuBarIcon
        }
        updatePolling()
    }

    private static let systemSettingsBundleID = "com.apple.systempreferences"

    /// True when no part waits for the user or for a device, so nothing can change without a notice.
    private var isFullySetUp: Bool {
        hasAccessibility && hasScreenRecording && tapInstalled && keyTapInstalled && hasTrackpad
    }

    /// `evaluate` runs every 2 s only while its result can change with no notice to the app:
    /// - a part is missing (a permission not given yet, no trackpad found, a tap not installed);
    /// - System Settings is in front, where the user gives and takes away the permissions and changes
    ///   the keyboard shortcuts and the trackpad swipe.
    /// At all other times the app has no timer. A change of the app's own settings, a wake, a change of
    /// the displays and the menu call `evaluate` directly.
    private func updatePolling() {
        let settingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.systemSettingsBundleID
        let needed = !isFullySetUp || settingsInFront
        if needed, permissionTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        } else if !needed, permissionTimer != nil {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == Self.systemSettingsBundleID else { return }
        // To the front: the timer starts. Away from the front: one last read of what the user changed.
        evaluate()
    }

    @objc private func didWake() {
        // The contact callbacks can stop after sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.hasTrackpad = MultitouchMonitor.shared.start()
            self.evaluate()
        }
    }

    @objc private func screensChanged() {
        controller.displaysChanged()
        hasTrackpad = MultitouchMonitor.shared.start()
        evaluate()
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.image()
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = settings.showsMenuBarIcon
        statusItem = item
    }

    /// The user opened the app again while it runs: from Spotlight, Finder or Launchpad. This is the way
    /// to the settings when the icon is hidden, and it does the same when the icon is there.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// Hides the icon and gives its place on `screen`, for the loader on the cover of the visit of all
    /// spaces. `nil`, and the icon stays, when the icon is not on that screen or the menu bar is not shown.
    private func hideIconForLoader(on screen: NSScreen) -> Overlay.Loader? {
        guard settings.showsMenuBarIcon, let button = statusItem?.button, let window = button.window,
              window.occlusionState.contains(.visible)
        else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.contains(frame) else { return nil }
        // The menu bar is light or dark with the wallpaper, and the icon is the opposite. So is the loader.
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = button.appearsDisabled ? 0.35 : 1
        button.alphaValue = 0
        return Overlay.Loader(frame: frame, color: CGColor(gray: dark ? 1 : 0, alpha: alpha))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        evaluate()
        menu.removeAllItems()

        let enabled = NSMenuItem(title: "Enable", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.transition.isCustom ? .on : .off
        menu.addItem(enabled)

        let open = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)

        let update = actionItem(updater.menuTitle, #selector(checkForUpdates))
        update.isEnabled = !updater.isBusy
        menu.addItem(update)
        menu.addItem(.separator())

        let capture = actionItem("Capture All Spaces Again", #selector(captureSpaces))
        capture.isEnabled = controller.isEnabled
        menu.addItem(capture)

        let login = actionItem("Open at Login", #selector(toggleOpensAtLogin))
        login.state = opensAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(actionItem("Hide from Menu Bar…", #selector(hideFromMenuBar)))

        var problems: [NSMenuItem] = []
        if !hasAccessibility {
            problems.append(actionItem("Allow Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        if !hasScreenRecording {
            problems.append(actionItem("Allow Screen Recording…", #selector(openScreenRecordingSettings)))
        }
        if !hasTrackpad {
            problems.append(infoItem("No trackpad found"))
        }
        if !Spaces.isAvailable {
            problems.append(infoItem("Space list is not available on this macOS version"))
        }
        if hasAccessibility, !tapInstalled {
            problems.append(infoItem("Could not start the gesture filter"))
        }
        if !problems.isEmpty {
            menu.addItem(.separator())
            problems.forEach(menu.addItem)
            if !hasAccessibility || !hasScreenRecording {
                menu.addItem(actionItem("Relaunch Interspace", #selector(relaunch)))
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Interspace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        settings.transition = settings.transition.isCustom ? .system : settings.lastCustomTransition
        evaluate()
    }

    private var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("open at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func toggleOpensAtLogin() {
        setOpensAtLogin(!opensAtLogin)
    }

    /// Asks first: with no icon there is no menu, so the user must know the way back before it goes.
    @objc private func hideFromMenuBar() {
        let alert = NSAlert()
        alert.messageText = "Hide Interspace from the menu bar?"
        alert.informativeText = "Interspace stays on. To get to its settings, open Interspace again "
            + "from Spotlight or the Applications folder. “Show in menu bar” there brings the icon back."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The observer of the settings takes the icon away. See `evaluate`.
        settings.showsMenuBarIcon = false
    }

    @objc private func captureSpaces() {
        // After the menu has closed, so it is not in the frozen image.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.controller.captureAllSpaces(again: true)
        }
    }

    @objc private func checkForUpdates() {
        updater.check()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording access applies only after a new launch.
    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Without this the new instance sees this one, takes itself for a duplicate, and exits.
        configuration.arguments = ["--replace"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
