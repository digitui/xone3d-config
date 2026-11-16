import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let bridge = USBBridge()
    private var window: NSWindow!

    // Controls
    private let versionField   = NSTextField(labelWithString: "—")
    private let modePopup      = NSPopUpButton()
    private let input1Label    = NSTextField(labelWithString: "Soundcard input:")
    private let input1Popup    = NSPopUpButton()
    private let input2Label    = NSTextField(labelWithString: "Soundcard In 1-2:")
    private let input2Popup    = NSPopUpButton()
    private let input2Row      = NSStackView()
    private let digOutPopup    = NSPopUpButton()
    private let returnsLabel   = NSTextField(labelWithString: "")
    private let midiChannelPopup = NSPopUpButton()
    private let midiMapPopup    = NSPopUpButton()
    private let rawField       = NSTextField(string: "0x0000")
    private let statusField    = NSTextField(labelWithString: "Not connected.")

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        rebuildForMode()
        connectAndRefresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { bridge.close() }

    // MARK: - menu bar

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Xone3D",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - window

    private func buildWindow() {
        modePopup.addItems(withTitles: SoundcardConfig.modeLabels)
        modePopup.target = self
        modePopup.action = #selector(onModeChanged)

        input1Popup.addItems(withTitles: SoundcardConfig.input1Labels)
        input2Popup.addItems(withTitles: SoundcardConfig.input2Labels)
        midiMapPopup.addItems(withTitles: SoundcardConfig.midiMapLabels)
        for i in 1...16 { midiChannelPopup.addItem(withTitle: "Channel \(i)") }

        returnsLabel.textColor = .secondaryLabelColor
        returnsLabel.font = .systemFont(ofSize: 11)

        let refreshButton = NSButton(title: "Refresh / Connect", target: self, action: #selector(onRefresh))
        let applyButton   = NSButton(title: "Apply", target: self, action: #selector(onApply))
        applyButton.keyEquivalent = "\r"
        let sendRawButton = NSButton(title: "Send raw", target: self, action: #selector(onSendRaw))

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let s = NSStackView(views: [l, control])
            s.orientation = .horizontal
            s.spacing = 10
            s.alignment = .firstBaseline
            return s
        }

        // Input 2 row (shown only in Mode 2); we keep references to its views.
        input2Label.alignment = .right
        input2Label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        input2Row.orientation = .horizontal
        input2Row.spacing = 10
        input2Row.alignment = .firstBaseline
        input2Row.setViews([input2Label, input2Popup], in: .leading)

        // Input 1 row (label text changes with mode).
        input1Label.alignment = .right
        input1Label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let input1Row = NSStackView(views: [input1Label, input1Popup])
        input1Row.orientation = .horizontal
        input1Row.spacing = 10
        input1Row.alignment = .firstBaseline

        let buttons = NSStackView(views: [refreshButton, applyButton])
        buttons.spacing = 10
        rawField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let rawRow = NSStackView(views: [rawField, sendRawButton])
        rawRow.spacing = 10

        let sep = NSBox(); sep.boxType = .separator

        let stack = NSStackView(views: [
            row("Firmware version:", versionField),
            row("Operating mode:", modePopup),
            input1Row,
            input2Row,
            row("3D Digital Out:", digOutPopup),
            returnsLabel,
            sep,
            row("MIDI channel:", midiChannelPopup),
            row("MIDI mapping:", midiMapPopup),
            row("", buttons),
            row("Routing word (raw):", rawRow),
            statusField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Xone:3D Configuration  (native arm64)"
        window.center()
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - mode-dependent layout  (mirrors -[XoneControl changeLayout:])

    @objc private func onModeChanged() { rebuildForMode(preserveSelections: true) }

    private func rebuildForMode(preserveSelections: Bool = false) {
        let mode = modePopup.indexOfSelectedItem

        input1Label.stringValue = (mode == 0) ? "Soundcard input:" : "Soundcard In 3-4:"
        input2Row.isHidden = (mode == 0)

        // Repopulate the digital-out menu for the current mode.
        let prevDig = digOutPopup.indexOfSelectedItem
        digOutPopup.removeAllItems()
        digOutPopup.addItems(withTitles: mode == 0
            ? SoundcardConfig.digitalOutMode1Labels
            : SoundcardConfig.digitalOutMode2Labels)
        if preserveSelections {
            let maxIdx = digOutPopup.numberOfItems - 1
            digOutPopup.selectItem(at: max(0, min(prevDig, maxIdx)))
        }

        returnsLabel.stringValue = SoundcardConfig.returnsText(mode: mode)
    }

    // MARK: - device actions

    @objc private func onRefresh() { connectAndRefresh() }

    private func connectAndRefresh() {
        do {
            if !bridge.isOpen { try bridge.open() }
            let v = try bridge.getVersion()
            let word = try bridge.readRouting()
            versionField.stringValue = v.text.isEmpty
                ? v.raw.map { String(format: "%02X", Int($0)) }.joined(separator: " ")
                : v.text
            loadConfig(SoundcardConfig.decode(word), word: word)
            status("Connected. Routing \(hex(word)).", ok: true)
        } catch {
            versionField.stringValue = "—"
            status("\(error)", ok: false)
        }
    }

    @objc private func onApply() {
        let word = currentConfig().encode()
        send(word, label: "Applied")
    }

    @objc private func onSendRaw() {
        guard let word = parseHex(rawField.stringValue) else {
            status("Raw value must be hex, e.g. 0x0107.", ok: false); return
        }
        send(word, label: "Sent raw")
    }

    private func send(_ word: UInt16, label: String) {
        do {
            if !bridge.isOpen { try bridge.open() }
            try bridge.sendRouting(word)
            let readback = try bridge.readRouting()
            loadConfig(SoundcardConfig.decode(readback), word: readback)
            status("\(label) \(hex(word)); device now \(hex(readback)).",
                   ok: readback == word)
        } catch {
            status("\(error)", ok: false)
        }
    }

    // MARK: - UI <-> config

    private func currentConfig() -> SoundcardConfig {
        SoundcardConfig(
            mode: modePopup.indexOfSelectedItem,
            input1: input1Popup.indexOfSelectedItem,
            input2: max(0, input2Popup.indexOfSelectedItem),
            digitalOut: max(0, digOutPopup.indexOfSelectedItem),
            midiChannel: midiChannelPopup.indexOfSelectedItem,
            midiMap: midiMapPopup.indexOfSelectedItem)
    }

    private func loadConfig(_ c: SoundcardConfig, word: UInt16) {
        modePopup.selectItem(at: clamp(c.mode, modePopup))
        rebuildForMode()                       // relayout before setting sub-menus
        input1Popup.selectItem(at: clamp(c.input1, input1Popup))
        input2Popup.selectItem(at: clamp(c.input2, input2Popup))
        digOutPopup.selectItem(at: clamp(c.digitalOut, digOutPopup))
        midiChannelPopup.selectItem(at: clamp(c.midiChannel, midiChannelPopup))
        midiMapPopup.selectItem(at: clamp(c.midiMap, midiMapPopup))
        rawField.stringValue = hex(word)
    }

    // MARK: - helpers

    private func clamp(_ i: Int, _ popup: NSPopUpButton) -> Int {
        max(0, min(i, popup.numberOfItems - 1))
    }

    private func hex(_ w: UInt16) -> String { String(format: "0x%04X", w) }

    private func parseHex(_ s: String) -> UInt16? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard let v = UInt32(t, radix: 16), v <= 0xFFFF else { return nil }
        return UInt16(v)
    }

    private func status(_ msg: String, ok: Bool) {
        statusField.stringValue = msg
        statusField.textColor = ok ? .secondaryLabelColor : .systemRed
    }
}
