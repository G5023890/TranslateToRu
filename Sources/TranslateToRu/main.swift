import Cocoa
import Carbon.HIToolbox
import ServiceManagement
final class SelectionWindowController: NSWindowController {
    private let textView: NSTextView

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Translation"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)

        scrollView.documentView = textView
        window.contentView = scrollView

        self.textView = textView
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show(text: String) {
        textView.string = text
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

final class HistoryWindowController: NSWindowController {
    private let textView: NSTextView

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 420)
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 12, height: 12)

        scrollView.documentView = textView
        window.contentView = scrollView

        self.textView = textView
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show(entries: [String]) {
        textView.string = entries.joined(separator: "\n\n—\n\n")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum LocalTranslate {
    static func run(command: String, text: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "TranslateToRu", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local command is empty"])
        }
        var parts = splitCommand(trimmed)
        if parts.contains("{text}") {
            parts = parts.map { $0 == "{text}" ? text : $0 }
        }
        let launchPath = parts.first ?? trimmed
        let args = Array(parts.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [launchPath] + args

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        if let data = text.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "Local translation failed"
            throw NSError(domain: "TranslateToRu", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitCommand(_ command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for char in command {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == " " && !inQuotes {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4C4F434C), id: 1) // "LOCL"
    private let windowController = SelectionWindowController()
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: HistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        }
        setupStatusItem()
        registerHotKey()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "灵⇢Я"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Translate Selection", action: #selector(readSelection), keyEquivalent: ""))
        let hotkeyItem = NSMenuItem(title: "Hotkey: Shift+Command+L", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if hk.id == delegate.hotKeyID.id {
                DispatchQueue.main.async {
                    delegate.readSelection()
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), nil)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc private func readSelection() {
        if let text = readSelectedTextViaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translateAndShow(text: text)
            return
        }
        readSelectionViaCopy { text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.windowController.show(text: "No selected text detected.\nTry selecting text again.")
            } else {
                self.translateAndShow(text: text)
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        let entries = UserDefaults.standard.stringArray(forKey: "history") ?? []
        historyWindowController?.show(entries: entries)
    }

    private func translateAndShow(text: String) {
        var commandTemplate = UserDefaults.standard.string(forKey: "local_command") ?? defaultCommandTemplate()
        let resolvedRoot = resolveRootPath()
        if commandTemplate.contains("New project/TranslateToRu") || !FileManager.default.fileExists(atPath: resolvedRoot + "/scripts/nllb_translate.py") {
            commandTemplate = defaultCommandTemplate()
            UserDefaults.standard.set(commandTemplate, forKey: "local_command")
        }
        let modelsPath = modelsDirectoryPath()
        let maxChars = UserDefaults.standard.string(forKey: "max_chars") ?? "2000"

        windowController.show(text: "Translating…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let translated: String
                let sourceLang = Self.containsHebrew(text) ? "he" : "en"
                if sourceLang == "he" {
                    // Hebrew to Russian via English (he->en->ru)
                    let step1 = commandTemplate
                        .replacingOccurrences(of: "{src}", with: "he")
                        .replacingOccurrences(of: "{dst}", with: "en")
                        .replacingOccurrences(of: "{models}", with: modelsPath)
                        .replacingOccurrences(of: "{max_chars}", with: maxChars)
                    let step2 = commandTemplate
                        .replacingOccurrences(of: "{src}", with: "en")
                        .replacingOccurrences(of: "{dst}", with: "ru")
                        .replacingOccurrences(of: "{models}", with: modelsPath)
                        .replacingOccurrences(of: "{max_chars}", with: maxChars)
                    let intermediate = try LocalTranslate.run(command: step1, text: text)
                    translated = try LocalTranslate.run(command: step2, text: intermediate)
                } else {
                    let command = commandTemplate
                        .replacingOccurrences(of: "{src}", with: "en")
                        .replacingOccurrences(of: "{dst}", with: "ru")
                        .replacingOccurrences(of: "{models}", with: modelsPath)
                        .replacingOccurrences(of: "{max_chars}", with: maxChars)
                    translated = try LocalTranslate.run(command: command, text: text)
                }
                DispatchQueue.main.async {
                    self.windowController.show(text: translated.isEmpty ? "Empty response." : translated)
                    self.appendHistory(sourceLang: sourceLang, input: text, output: translated)
                }
            } catch {
                DispatchQueue.main.async {
                    self.windowController.show(text: "Translation error: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func containsHebrew(_ text: String) -> Bool {
        return text.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
    }

    nonisolated func resolveRootPath() -> String {
        if let scriptsPath = UserDefaults.standard.string(forKey: "scripts_path"), !scriptsPath.isEmpty {
            return URL(fileURLWithPath: scriptsPath).deletingLastPathComponent().path
        }
        if let modelsPath = UserDefaults.standard.string(forKey: "models_path"), !modelsPath.isEmpty {
            return URL(fileURLWithPath: modelsPath).deletingLastPathComponent().path
        }
        if let detected = detectModelsPath() {
            return URL(fileURLWithPath: detected).deletingLastPathComponent().path
        }
        return projectRootURL().path
    }

    nonisolated func defaultCommandTemplate() -> String {
        let root = resolveRootPath()
        let pythonPath = "\(root)/.venv-nllb/bin/python"
        let scriptPath = "\(root)/scripts/nllb_translate.py"
        return "\"\(pythonPath)\" \"\(scriptPath)\" --models-dir \"{models}/nllb-200-distilled-600M-ct2-int8\" --tokenizer-dir \"{models}/nllb-200-distilled-600M-tokenizer\" --src {src} --dst {dst} --max-chars {max_chars}"
    }

    nonisolated func projectRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let parent = bundleURL.deletingLastPathComponent()
            if parent.lastPathComponent == "dist" {
                return parent.deletingLastPathComponent()
            }
            return parent
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    nonisolated func modelsDirectoryPath() -> String {
        if let stored = UserDefaults.standard.string(forKey: "models_path"), !stored.isEmpty {
            return stored
        }
        if let detected = detectModelsPath() {
            return detected
        }
        return projectRootURL().appendingPathComponent("models").path
    }

    nonisolated private func detectModelsPath() -> String? {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates: [URL] = [
            projectRootURL(),
            projectRootURL().deletingLastPathComponent(),
            home.appendingPathComponent("Documents/New project/TranslateToRu"),
            home.appendingPathComponent("Documents/TranslateToRu"),
            home.appendingPathComponent("Documents/Develop/Translate/TranslateToRu"),
        ]
        for root in candidates {
            let modelsDir = root.appendingPathComponent("models")
            let modelBin = modelsDir
                .appendingPathComponent("nllb-200-distilled-600M-ct2-int8")
                .appendingPathComponent("model.bin")
            if fm.fileExists(atPath: modelBin.path) {
                return modelsDir.path
            }
        }
        return nil
    }
    
    private func appendHistory(sourceLang: String, input: String, output: String) {
        let date = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(date)] \(sourceLang)→ru\nInput: \(input)\nOutput: \(output)"
        var items = UserDefaults.standard.stringArray(forKey: "history") ?? []
        items.insert(entry, at: 0)
        if items.count > 10 {
            items = Array(items.prefix(10))
        }
        UserDefaults.standard.set(items, forKey: "history")
    }

    private func readSelectionViaCopy(completion: @escaping (String) -> Void) {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        } ?? []
        let initialChangeCount = pasteboard.changeCount

        let src = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let cUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        cmdDown?.post(tap: .cgSessionEventTap)
        cDown?.post(tap: .cgSessionEventTap)
        cUp?.post(tap: .cgSessionEventTap)
        cmdUp?.post(tap: .cgSessionEventTap)

        readSelectionWithRetry(pasteboard: pasteboard, initialChangeCount: initialChangeCount, attempts: 8) { selectedText in
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                _ = pasteboard.writeObjects(previousItems)
            }
            completion(selectedText)
        }
    }

    private func readSelectionWithRetry(
        pasteboard: NSPasteboard,
        initialChangeCount: Int,
        attempts: Int,
        completion: @escaping (String) -> Void
    ) {
        let current = pasteboard.string(forType: .string) ?? ""
        if pasteboard.changeCount != initialChangeCount, !current.isEmpty {
            completion(current)
            return
        }
        if attempts <= 0 {
            completion("")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.readSelectionWithRetry(
                pasteboard: pasteboard,
                initialChangeCount: initialChangeCount,
                attempts: attempts - 1,
                completion: completion
            )
        }
    }

    private func readSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focusedElement = copyAXElementAttribute(systemWide, attribute: kAXFocusedUIElementAttribute as String) {
            if let text = extractSelectedText(from: focusedElement) { return text }
            if let text = searchSelectedText(in: focusedElement, maxNodes: 250) { return text }
        }
        if let focusedWindow = copyAXElementAttribute(systemWide, attribute: kAXFocusedWindowAttribute as String) {
            if let text = searchSelectedText(in: focusedWindow, maxNodes: 250) { return text }
        }
        return nil
    }

    private func copyAXElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let unwrapped = value else { return nil }
        if CFGetTypeID(unwrapped) == AXUIElementGetTypeID() {
            return (unwrapped as! AXUIElement)
        }
        return nil
    }

    private func copyAXAnyAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if err == .success, let unwrapped = value { return (unwrapped as AnyObject) }
        return nil
    }

    private func extractSelectedText(from element: AXUIElement) -> String? {
        if let selected = copyAXAnyAttribute(element, attribute: kAXSelectedTextAttribute as String) as? String {
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let value = copyAXAnyAttribute(element, attribute: kAXValueAttribute as String) as? String
        let rangeRef = copyAXAnyAttribute(element, attribute: kAXSelectedTextRangeAttribute as String)
        if let valueString = value, let axRange = rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange) {
                if cfRange.location != kCFNotFound, cfRange.length > 0, valueString.count >= cfRange.location {
                    let start = valueString.index(valueString.startIndex, offsetBy: max(0, cfRange.location))
                    let end = valueString.index(start, offsetBy: min(cfRange.length, valueString.count - cfRange.location))
                    return String(valueString[start..<end])
                }
            }
        }

        if let axRange = rangeRef {
            var attributed: CFTypeRef?
            let paramErr = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXAttributedStringForRangeParameterizedAttribute as CFString,
                axRange,
                &attributed
            )
            if paramErr == .success, let attr = attributed as? NSAttributedString {
                let str = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty { return str }
            }
        }

        return nil
    }

    private func searchSelectedText(in root: AXUIElement, maxNodes: Int) -> String? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            if let text = extractSelectedText(from: element) {
                return text
            }
            if let children = copyAXAnyAttribute(element, attribute: kAXChildrenAttribute as String) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let commandField = NSTextField()
    private let scriptsPathField = NSTextField()
    private let modelsPathField = NSTextField()
    private let maxCharsField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let modelsLabel = NSTextField(labelWithString: "")
    private let useNllbButton = NSButton(title: "Use NLLB Command", target: nil, action: nil)
    private let autoFillButton = NSButton(title: "Auto-fill paths", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let commandLabel = NSTextField(labelWithString: "Local Command (NLLB)")
        let scriptsPathLabel = NSTextField(labelWithString: "Scripts path")
        let modelsPathLabel = NSTextField(labelWithString: "Models path")
        let maxCharsLabel = NSTextField(labelWithString: "Max chars per chunk")
        [commandLabel].forEach { $0.font = NSFont.systemFont(ofSize: 13, weight: .semibold) }
        commandField.placeholderString = "\".../.venv-nllb/bin/python\" \".../scripts/nllb_translate.py\" --models-dir \"{models}/nllb-200-distilled-600M-ct2-int8\" --tokenizer-dir \"{models}/nllb-200-distilled-600M-tokenizer\" --src {src} --dst {dst}"
        maxCharsField.placeholderString = "2000"
        modelsLabel.textColor = .secondaryLabelColor

        launchAtLoginCheckbox.frame = NSRect(x: 20, y: 240, width: 200, height: 24)
        commandLabel.frame = NSRect(x: 20, y: 205, width: 260, height: 18)
        commandField.frame = NSRect(x: 20, y: 180, width: 580, height: 24)
        scriptsPathLabel.frame = NSRect(x: 20, y: 150, width: 120, height: 18)
        scriptsPathField.frame = NSRect(x: 140, y: 145, width: 460, height: 24)
        modelsPathLabel.frame = NSRect(x: 20, y: 120, width: 120, height: 18)
        modelsPathField.frame = NSRect(x: 140, y: 115, width: 460, height: 24)
        modelsLabel.frame = NSRect(x: 20, y: 85, width: 580, height: 18)
        maxCharsLabel.frame = NSRect(x: 20, y: 55, width: 160, height: 18)
        maxCharsField.frame = NSRect(x: 190, y: 50, width: 90, height: 24)

        statusLabel.frame = NSRect(x: 20, y: 20, width: 360, height: 24)
        statusLabel.textColor = .secondaryLabelColor
        autoFillButton.frame = NSRect(x: 300, y: 15, width: 120, height: 28)
        useNllbButton.frame = NSRect(x: 430, y: 15, width: 130, height: 28)
        saveButton.frame = NSRect(x: 560, y: 15, width: 60, height: 28)

        content.addSubview(launchAtLoginCheckbox)
        content.addSubview(commandLabel)
        content.addSubview(commandField)
        content.addSubview(scriptsPathLabel)
        content.addSubview(scriptsPathField)
        content.addSubview(modelsPathLabel)
        content.addSubview(modelsPathField)
        content.addSubview(modelsLabel)
        content.addSubview(maxCharsLabel)
        content.addSubview(maxCharsField)
        content.addSubview(statusLabel)
        content.addSubview(autoFillButton)
        content.addSubview(useNllbButton)
        content.addSubview(saveButton)
        window.contentView = content

        super.init(window: window)

        commandField.delegate = self
        scriptsPathField.delegate = self
        modelsPathField.delegate = self
        maxCharsField.delegate = self
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        saveButton.target = self
        saveButton.action = #selector(saveNow)
        autoFillButton.target = self
        autoFillButton.action = #selector(autoFillPaths)
        useNllbButton.target = self
        useNllbButton.action = #selector(useNllbCommand)

        loadValues()

    }

    required init?(coder: NSCoder) { nil }

    private func loadValues() {
        let defaultCommand = (NSApp.delegate as? AppDelegate)?.defaultCommandTemplate()
            ?? "\".../.venv-nllb/bin/python\" \".../scripts/nllb_translate.py\" --models-dir \"{models}/nllb-200-distilled-600M-ct2-int8\" --tokenizer-dir \"{models}/nllb-200-distilled-600M-tokenizer\" --src {src} --dst {dst}"
        commandField.stringValue = UserDefaults.standard.string(forKey: "local_command") ?? defaultCommand
        maxCharsField.stringValue = UserDefaults.standard.string(forKey: "max_chars") ?? "2000"
        launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let modelsPath = (NSApp.delegate as? AppDelegate)?.modelsDirectoryPath() ?? "{project}/models"
        modelsLabel.stringValue = "Models folder: \(modelsPath)"
    }

    private func saveValues() {
        UserDefaults.standard.set(commandField.stringValue, forKey: "local_command")
        let trimmed = maxCharsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? "2000" : trimmed, forKey: "max_chars")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveValues()
    }

    @objc private func saveNow() {
        saveValues()
        statusLabel.stringValue = "Saved"
    }

    @objc private func autoFillPaths() {
        let root = (NSApp.delegate as? AppDelegate)?.resolveRootPath() ?? ""
        if !root.isEmpty {
            scriptsPathField.stringValue = "\(root)/scripts"
            modelsPathField.stringValue = "\(root)/models"
            commandField.stringValue = (NSApp.delegate as? AppDelegate)?.defaultCommandTemplate() ?? commandField.stringValue
            saveValues()
            statusLabel.stringValue = "Paths filled"
        } else {
            statusLabel.stringValue = "Paths not detected"
        }
    }

    @objc private func useNllbCommand() {
        if let defaultCommand = (NSApp.delegate as? AppDelegate)?.defaultCommandTemplate() {
            commandField.stringValue = defaultCommand
            saveValues()
            statusLabel.stringValue = "NLLB command set"
        }
    }


    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusLabel.stringValue = "Launch at login failed"
            launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }


}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
