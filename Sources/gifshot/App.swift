import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private enum Phase { case idle, selecting, starting, recording, saving }

    private var phase = Phase.idle
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let hotKeys = HotKeys()
    private var picker: RegionPicker?
    private var recorder: Recorder?
    private var border: BorderWindow?
    private var timer: Timer?
    private var startedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        statusItem.button?.imagePosition = .imageLeading

        let shortcut: NSEvent.ModifierFlags = [.command, .option, .control]
        menu.addItem(item("Record Full Screen", #selector(recordFullScreen), key: "3", shortcut))
        menu.addItem(item("Record Region", #selector(recordRegion), key: "4", shortcut))
        menu.addItem(.separator())
        menu.addItem(item("Open Last GIF", #selector(openLastGIF)))
        menu.addItem(item("Reveal Output Folder", #selector(revealOutputFolder)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit gifshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        showIdle()

        let modifiers = cmdKey | optionKey | controlKey
        hotKeys.register(keyCode: kVK_ANSI_3, modifiers: modifiers) { [weak self] in self?.recordFullScreen() }
        hotKeys.register(keyCode: kVK_ANSI_4, modifiers: modifiers) { [weak self] in self?.recordRegion() }
    }

    // MARK: Actions

    @objc private func recordFullScreen() {
        switch phase {
        case .recording: stop()
        case .selecting: picker?.cancel()
        case .idle:
            guard hasScreenRecordingPermission() else { return }
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { return }
            start(screen: screen, region: nil)
        case .starting, .saving: break
        }
    }

    @objc private func recordRegion() {
        switch phase {
        case .recording: stop()
        case .selecting: picker?.cancel()
        case .idle:
            guard hasScreenRecordingPermission() else { return }
            phase = .selecting
            let picker = RegionPicker { [weak self] selection in
                guard let self else { return }
                self.picker = nil
                self.phase = .idle
                if let selection { self.start(screen: selection.screen, region: selection.rect) }
            }
            self.picker = picker
            picker.begin()
        case .starting, .saving: break
        }
    }

    /// While recording the status item has no menu, so a click lands here and stops.
    @objc private func statusItemClicked() {
        if phase == .recording { stop() }
    }

    @objc private func openLastGIF() { Output.openLast() }
    @objc private func revealOutputFolder() { Output.revealFolder() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openLastGIF): Output.lastGIF != nil
        case #selector(recordFullScreen), #selector(recordRegion): phase == .idle
        default: true
        }
    }

    // MARK: Recording

    private func start(screen: NSScreen, region: NSRect?) {
        phase = .starting
        let border = BorderWindow(around: region ?? screen.frame, on: screen)
        border.orderFrontRegardless()
        self.border = border
        Task {
            do {
                recorder = try await Recorder.start(screen: screen, region: region) { error in
                    NSLog("gifshot: stream stopped: \(error.localizedDescription)")
                    self.stop()
                }
                phase = .recording
                startedAt = Date()
                statusItem.menu = nil
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    MainActor.assumeIsolated { self.tick() }
                }
                tick()
            } catch {
                self.border?.orderOut(nil)
                self.border = nil
                phase = .idle
                showIdle()
                showStartError(error)
            }
        }
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Recorder.maxDuration { return stop() }
        let seconds = Int(elapsed)
        setStatus(symbol: "stop.circle.fill", title: String(format: " %d:%02d", seconds / 60, seconds % 60))
    }

    private func stop() {
        guard phase == .recording, let recorder else { return }
        phase = .saving
        self.recorder = nil
        timer?.invalidate()
        timer = nil
        border?.orderOut(nil)
        border = nil
        setStatus(symbol: "hourglass", title: "")
        Task {
            do {
                _ = try Output.deliver(try await recorder.stop())
                phase = .idle
                showIdle(symbol: "checkmark.circle")
                try? await Task.sleep(for: .seconds(1.5))
                if phase == .idle { showIdle() }
            } catch {
                phase = .idle
                showIdle()
                showAlert("Couldn't save the GIF", error.localizedDescription)
            }
        }
    }

    // MARK: Status item

    private func showIdle(symbol: String = "record.circle") {
        setStatus(symbol: symbol, title: "")
        statusItem.menu = menu
    }

    private func setStatus(symbol: String, title: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "gifshot")
        statusItem.button?.title = title
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: Permission and errors

    private func hasScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The first request shows the system prompt and adds gifshot to the list in System Settings.
        let key = "requestedScreenRecording"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }
        showPermissionAlert()
        return false
    }

    private func showStartError(_ error: Error) {
        if !CGPreflightScreenCaptureAccess() || (error as? SCStreamError)?.code == .userDeclined {
            showPermissionAlert()
        } else {
            showAlert("Couldn't start recording", error.localizedDescription)
        }
    }

    private func showPermissionAlert() {
        let open = showAlert(
            "gifshot needs Screen Recording permission",
            "Turn on gifshot in System Settings > Privacy & Security > Screen & System Audio Recording. "
                + "If it's already on, quit and reopen gifshot.",
            buttons: ["Open System Settings", "Cancel"])
        if open {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Returns true if the first button was chosen.
    @discardableResult
    private func showAlert(_ message: String, _ info: String, buttons: [String] = ["OK"]) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
