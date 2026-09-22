import AppKit
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let picker = WindowPicker()
    private let dim = DimOverlay()
    private let controls = ControlPanel()
    private let recorder = Recorder()
    private let splash = Splash()
    private let launchedAt = Date()

    private var target: WindowCandidate?
    private var isRecording = false
    private var isBusy = false
    private var pendingReselect: CGWindowID?
    private var dragSelection: NSRect?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        controls.onGo = { [weak self] in self?.toggleRecording() }
        controls.onOff = { NSApp.terminate(nil) }
        controls.setSelectionMode(Prefs.shared.selectionMode)
        controls.onModeChange = { [weak self] mode in self?.switchTo(mode) }
        picker.onDragSelection = { [weak self] rect in self?.dragSelectionChanged(rect) }
        picker.onSelectionUpdated = { [weak self] candidate in
            guard let self, !self.isRecording else { return }
            if let candidate {
                self.target = candidate
                let area = self.captureRect(for: candidate)
                self.picker.markSelected(candidate, showing: area)
                self.placeControls(around: area)
            } else {
                self.target = nil
                self.controls.hide()
            }
        }
        recorder.onFailure = { [weak self] error in self?.recordingFailed(error) }

        // Switching desktops invalidates every candidate, so gather them again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isRecording, self.picker.isVisible else { return }
                self.chooseWindow()
        }

        NSApp.activate(ignoringOtherApps: true)
        splash.show()
        requestAccessThenBegin()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Route through the permission request: without access there is nothing to list.
        if !isRecording && target == nil && !picker.isVisible { requestAccessThenBegin() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isRecording {
            let sem = DispatchSemaphore(value: 0)
            Task { _ = try? await recorder.stop(); sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
        }
    }

    // MARK: Session flow

    private func beginSession() {
        dismissSplash()
        switch Prefs.shared.mode {
        case .window: chooseWindow()
        case .fullscreen: armFullscreen()
        }
    }

    /// Let the opening screen be read before it goes, however fast the app got going.
    private func dismissSplash() {
        guard splash.isVisible else { return }
        let shown = Date().timeIntervalSince(launchedAt)
        let remaining = max(0, 2.6 - shown)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.splash.hide()
        }
    }

    /// Switching between trimming modes and free-drawn areas resets what is armed.
    private func switchTo(_ mode: SelectionMode) {
        guard !isRecording else { return }
        Prefs.shared.selectionMode = mode
        picker.mode = mode == .dragSelect ? .dragSelect : .windows

        if mode == .dragSelect {
            target = nil
            picker.markSelected(nil)
            if let rect = dragSelection {
                placeControls(around: rect)
            } else {
                controls.hide()
            }
        } else {
            picker.clearDragSelection()
            dragSelection = nil
            if let target { arm(target) } else { controls.hide() }
        }
    }

    private func dragSelectionChanged(_ rect: NSRect?) {
        dragSelection = rect
        if let rect {
            placeControls(around: rect)
        } else {
            controls.hide()
        }
    }

    private func placeControls(around area: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main
        if let screen { controls.place(around: area, on: screen) }
        controls.showRecording(false)
        controls.show()
    }

    private func chooseWindow() {
        guard !isRecording else { return }
        dim.hide()
        if Prefs.shared.selectionMode != .dragSelect { controls.hide() }
        target = nil

        let candidates = WindowScanner.currentWindows(excluding: ProcessInfo.processInfo.processIdentifier)
        guard !candidates.isEmpty else {
            presentAlert("No windows to record",
                         "Open a window you would like to record, then choose Recording › Choose Window.")
            return
        }

        picker.mode = Prefs.shared.selectionMode == .dragSelect ? .dragSelect : .windows
        picker.show(candidates: candidates,
                    onPick: { [weak self] c in self?.arm(c) },
                    onCancel: { })

        if Prefs.shared.selectionMode == .dragSelect {
            if let rect = dragSelection { placeControls(around: rect) }
            pendingReselect = nil
            return
        }

        // Coming back from a recording, keep the same window selected.
        if let id = pendingReselect, let previous = candidates.first(where: { $0.id == id }) {
            arm(previous)
        }
        pendingReselect = nil
    }

    private func arm(_ candidate: WindowCandidate) {
        guard Prefs.shared.selectionMode != .dragSelect else { return }
        target = candidate
        let area = captureRect(for: candidate)
        picker.markSelected(candidate, showing: area)
        placeControls(around: area)
    }

    /// What will actually be recorded: the whole window frame, or just its contents.
    private func captureRect(for candidate: WindowCandidate) -> NSRect {
        Prefs.shared.selectionMode == .border ? candidate.rect : candidate.rect.contentAreaOnly
    }

    /// The region GO will record, whichever way it was chosen.
    private var armedRegion: NSRect? {
        Prefs.shared.selectionMode == .dragSelect ? dragSelection : target.map(captureRect(for:))
    }

    private func armFullscreen() {
        picker.hide()
        dim.hide()
        target = nil
        if let screen = NSScreen.main { controls.placeForFullscreen(on: screen) }
        controls.showRecording(false)
        controls.show()
    }

    // MARK: Recording

    private func toggleRecording() {
        guard !isBusy else { return }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let windowMode = Prefs.shared.mode == .window
        if windowMode && armedRegion == nil {
            chooseWindow()
            return
        }

        let directory = Prefs.shared.saveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            presentAlert("Cannot use the save location", "\(directory.path)\n\n\(error.localizedDescription)")
            return
        }

        let url = Prefs.shared.newOutputURL()
        let region = windowMode ? armedRegion : nil
        isBusy = true

        Task { @MainActor in
            do {
                try await recorder.start(region: region, url: url)
                // Hand the screen back to the user: the picker goes away and the
                // dimming takes over, leaving the recorded window clear to work in.
                self.picker.hide()
                if let area = self.armedRegion { self.dim.show(hole: area) }
                self.isRecording = true
                self.controls.showRecording(true)
            } catch {
                self.presentAlert("Could not start recording", error.localizedDescription)
            }
            self.isBusy = false
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isBusy = true

        Task { @MainActor in
            self.pendingReselect = self.target?.id
            do {
                let url = try await recorder.stop()
                self.isRecording = false
                self.controls.showRecording(false)
                self.dim.hide()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.isRecording = false
                self.controls.showRecording(false)
                self.dim.hide()
                self.presentAlert("Could not save the recording", error.localizedDescription)
            }
            self.isBusy = false
            self.beginSession()
        }
    }

    private func recordingFailed(_ error: Error) {
        guard isRecording else { return }
        isRecording = false
        controls.showRecording(false)
        presentAlert("Recording stopped", error.localizedDescription)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About YOINK!",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide YOINK!",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit YOINK!",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let recItem = NSMenuItem()
        let recMenu = NSMenu(title: "Recording")
        add(recMenu, "Choose Window…", #selector(chooseWindowAction), "k")
        toggleItem = add(recMenu, "Start Recording", #selector(toggleRecordingAction), "r")
        recMenu.addItem(.separator())
        windowModeItem = add(recMenu, "Window Record", #selector(setWindowMode), "")
        fullscreenModeItem = add(recMenu, "Fullscreen Record", #selector(setFullscreenMode), "")
        recMenu.addItem(.separator())
        add(recMenu, "Save Location…", #selector(chooseSaveLocation), "l")
        add(recMenu, "Show Save Location in Finder", #selector(revealSaveLocation), "")
        recItem.submenu = recMenu
        main.addItem(recItem)

        NSApp.mainMenu = main
    }

    private var toggleItem: NSMenuItem?
    private var windowModeItem: NSMenuItem?
    private var fullscreenModeItem: NSMenuItem?

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseWindowAction):
            return !isRecording && Prefs.shared.mode == .window
        case #selector(toggleRecordingAction):
            item.title = isRecording ? "Stop Recording" : "Start Recording"
            return !isBusy
        case #selector(setWindowMode):
            item.state = Prefs.shared.mode == .window ? .on : .off
            return !isRecording
        case #selector(setFullscreenMode):
            item.state = Prefs.shared.mode == .fullscreen ? .on : .off
            return !isRecording
        default:
            return true
        }
    }

    @objc private func chooseWindowAction() { chooseWindow() }

    @objc private func toggleRecordingAction() { toggleRecording() }

    @objc private func setWindowMode() {
        guard !isRecording, Prefs.shared.mode != .window else { return }
        Prefs.shared.mode = .window
        chooseWindow()
    }

    @objc private func setFullscreenMode() {
        guard !isRecording, Prefs.shared.mode != .fullscreen else { return }
        Prefs.shared.mode = .fullscreen
        picker.hide()
        armFullscreen()
    }

    @objc private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Prefs.shared.saveDirectory
        panel.prompt = "Choose"
        panel.message = "Choose where recordings are saved."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.shared.saveDirectory = url
        }
    }

    @objc private func revealSaveLocation() {
        NSWorkspace.shared.activateFileViewerSelecting([Prefs.shared.saveDirectory])
    }

    // MARK: Permission

    private var awaitingPermission = false
    private var accessAttempts = 0
    private var hasRequestedAccess = false
    private var pollingAccess = false

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// CGRequestScreenCaptureAccess is what actually puts macOS's own Screen
    /// Recording prompt on screen; ScreenCaptureKit alone just fails with -3801.
    /// We never quit on refusal - the app waits and retries when it is activated
    /// again, so granting access in System Settings is enough.
    private func requestAccessThenBegin() {
        if CGPreflightScreenCaptureAccess() {
            awaitingPermission = false
            beginSession()
            return
        }
        awaitingPermission = true

        // CGRequestScreenCaptureAccess is what puts macOS's prompt on screen, and it
        // must be called exactly once: calling it again dismisses the prompt already
        // up. Afterwards we only ever poll, which never prompts.
        splash.show(status: "Waiting for Screen Recording permission…")
        if !hasRequestedAccess {
            hasRequestedAccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                CGRequestScreenCaptureAccess()
                self.pollForAccess()
            }
        } else {
            pollForAccess()
        }
    }

    private func pollForAccess() {
        guard !pollingAccess else { return }
        pollingAccess = true
        Task { @MainActor in
            var waited = 0.0
            while !CGPreflightScreenCaptureAccess() {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                waited += 2
                // Screen Recording grants usually only take effect on relaunch.
                if waited == 40 { self.presentRelaunchHint() }
            }
            self.pollingAccess = false
            self.awaitingPermission = false
            self.beginSession()
        }
    }

    private func presentRelaunchHint() {
        let alert = NSAlert()
        alert.messageText = "Waiting for Screen Recording access"
        alert.informativeText = """
            If you have already allowed YOINK!, quit this app and open it \
            again - macOS only applies a new Screen Recording grant on relaunch.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Keep Waiting")
        if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard awaitingPermission else { return }
        awaitingPermission = false
        requestAccessThenBegin()
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is needed"
        alert.informativeText = """
            Turn on YOINK! under System Settings \u{203A} Privacy & Security \u{203A} \
            Screen & System Audio Recording, then click back to this app.

            If Screen Capture is already listed, select it, remove it with the \u{2212} button, \
            and launch the app again so macOS can ask fresh.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        awaitingPermission = true
    }

    private func presentAlert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
