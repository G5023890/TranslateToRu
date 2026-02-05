import Cocoa
import Carbon.HIToolbox
import Security

final class SelectionWindowController: NSWindowController {
    private let textView: NSTextView

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Selected Text"
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

enum KeychainService {
    private static let service = "TranslatorHotkey"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
    }
}

struct GeminiClient {
    let apiKey: String
    let model: String
    
    private var normalizedModel: String {
        if model.hasPrefix("models/") {
            return String(model.dropFirst("models/".count))
        }
        return model
    }

    func translateToRussian(_ text: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(normalizedModel):generateContent") else {
            throw NSError(domain: "FocusSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "Translate the following text to Russian. Return only the translation.\\n\\n\\(text)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if
                let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                let error = json["error"] as? [String: Any],
                let message = error["message"] as? String
            {
                throw NSError(domain: "FocusSelection", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "FocusSelection", code: 2, userInfo: [NSLocalizedDescriptionKey: "API error: \(body)"])
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        let text = parts?.first?["text"] as? String
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizeTranslation(trimmed)
    }
    
    private func normalizeTranslation(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("(") && text.hasSuffix(")") {
            let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                return inner
            }
        }
        return text
    }
}

struct OpenAIClient {
    let apiKey: String
    let model: String

    func translateToRussian(_ text: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "TranslatorHotkey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": "You are a translator. Translate the user text to Russian. Return only the translation."],
                ["role": "user", "content": text]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "TranslatorHotkey", code: 2, userInfo: [NSLocalizedDescriptionKey: "API error: \(body)"])
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String
        return content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum LocalTranslate {
    static func run(command: String, text: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "TranslatorHotkey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local command is empty"])
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
            throw NSError(domain: "TranslatorHotkey", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
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
    private let hotKeyID = EventHotKeyID(signature: OSType(0x53454C43), id: 1) // "SELC"
    private let windowController = SelectionWindowController()
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotKey()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "SEL"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Translate Selection", action: #selector(readSelection), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
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
        RegisterEventHotKey(UInt32(kVK_ANSI_S), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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

    private func translateAndShow(text: String) {
        let provider = UserDefaults.standard.string(forKey: "provider") ?? "gemini"
        windowController.show(text: "Translating…")
        Task {
            do {
                let translation: String
                switch provider {
                case "openai":
                    let apiKey = KeychainService.load(account: "OpenAIAPIKey") ?? ""
                    let model = UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-4o-mini"
                    if apiKey.isEmpty {
                        self.windowController.show(text: "OpenAI API key is missing.\nOpen Settings and add your key.")
                        return
                    }
                    let client = OpenAIClient(apiKey: apiKey, model: model)
                    translation = try await client.translateToRussian(text)
                case "local":
                    let command = UserDefaults.standard.string(forKey: "local_command") ?? "argos-translate --from-lang en --to-lang ru"
                    translation = try LocalTranslate.run(command: command, text: text)
                default:
                    let apiKey = KeychainService.load(account: "GeminiAPIKey") ?? ""
                    let model = UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-2.5-flash-lite"
                    if apiKey.isEmpty {
                        self.windowController.show(text: "Gemini API key is missing.\nOpen Settings and add your key.")
                        return
                    }
                    let client = GeminiClient(apiKey: apiKey, model: model)
                    translation = try await client.translateToRussian(text)
                }
                self.windowController.show(text: translation.isEmpty ? "Empty response." : translation)
            } catch {
                self.windowController.show(text: "Translation error: \(error.localizedDescription)")
            }
        }
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
    private let providerPopUp = NSPopUpButton()
    private let geminiKeyField = NSSecureTextField()
    private let geminiModelField = NSTextField()
    private let openAIKeyField = NSSecureTextField()
    private let openAIModelField = NSTextField()
    private let localCommandField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let recommendationLabel = NSTextField(labelWithString: "Recommended: gemini-2.5-flash-lite")
    private let showModelsButton = NSButton(title: "Show Models", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var cachedModels: [GeminiModel] = []
    private weak var modelPicker: NSPopUpButton?
    private weak var modelFilter: NSPopUpButton?
    private var supportedModelNames: [String] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let providerLabel = NSTextField(labelWithString: "Provider")
        let geminiKeyLabel = NSTextField(labelWithString: "Gemini API Key")
        let geminiModelLabel = NSTextField(labelWithString: "Gemini Model")
        let openAIKeyLabel = NSTextField(labelWithString: "OpenAI API Key")
        let openAIModelLabel = NSTextField(labelWithString: "OpenAI Model")
        let localCommandLabel = NSTextField(labelWithString: "Local Command (Argos)")
        [providerLabel, geminiKeyLabel, geminiModelLabel, openAIKeyLabel, openAIModelLabel, localCommandLabel]
            .forEach { $0.font = NSFont.systemFont(ofSize: 13, weight: .semibold) }

        providerPopUp.addItems(withTitles: ["Gemini", "OpenAI", "Local"])
        geminiKeyField.placeholderString = "AIza..."
        geminiModelField.placeholderString = "gemini-2.5-flash-lite"
        openAIKeyField.placeholderString = "sk-..."
        openAIModelField.placeholderString = "gpt-4o-mini"
        localCommandField.placeholderString = "argos-translate --from-lang en --to-lang ru"

        providerLabel.frame = NSRect(x: 20, y: 370, width: 200, height: 18)
        providerPopUp.frame = NSRect(x: 20, y: 345, width: 180, height: 26)

        geminiKeyLabel.frame = NSRect(x: 20, y: 310, width: 200, height: 18)
        geminiKeyField.frame = NSRect(x: 20, y: 285, width: 520, height: 24)
        geminiModelLabel.frame = NSRect(x: 20, y: 255, width: 200, height: 18)
        geminiModelField.frame = NSRect(x: 20, y: 230, width: 220, height: 24)
        showModelsButton.frame = NSRect(x: 260, y: 228, width: 110, height: 28)
        recommendationLabel.frame = NSRect(x: 20, y: 210, width: 260, height: 20)
        recommendationLabel.textColor = .secondaryLabelColor

        openAIKeyLabel.frame = NSRect(x: 20, y: 180, width: 200, height: 18)
        openAIKeyField.frame = NSRect(x: 20, y: 155, width: 520, height: 24)
        openAIModelLabel.frame = NSRect(x: 20, y: 125, width: 200, height: 18)
        openAIModelField.frame = NSRect(x: 20, y: 100, width: 220, height: 24)

        localCommandLabel.frame = NSRect(x: 20, y: 70, width: 260, height: 18)
        localCommandField.frame = NSRect(x: 20, y: 45, width: 520, height: 24)

        statusLabel.frame = NSRect(x: 20, y: 12, width: 300, height: 24)
        statusLabel.textColor = .secondaryLabelColor
        saveButton.frame = NSRect(x: 440, y: 8, width: 100, height: 28)

        content.addSubview(providerLabel)
        content.addSubview(providerPopUp)
        content.addSubview(geminiKeyLabel)
        content.addSubview(geminiKeyField)
        content.addSubview(geminiModelLabel)
        content.addSubview(geminiModelField)
        content.addSubview(openAIKeyLabel)
        content.addSubview(openAIKeyField)
        content.addSubview(openAIModelLabel)
        content.addSubview(openAIModelField)
        content.addSubview(localCommandLabel)
        content.addSubview(localCommandField)
        content.addSubview(statusLabel)
        content.addSubview(recommendationLabel)
        content.addSubview(showModelsButton)
        content.addSubview(saveButton)
        window.contentView = content

        super.init(window: window)

        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        geminiKeyField.delegate = self
        geminiModelField.delegate = self
        openAIKeyField.delegate = self
        openAIModelField.delegate = self
        localCommandField.delegate = self
        showModelsButton.target = self
        showModelsButton.action = #selector(showModels)
        saveButton.target = self
        saveButton.action = #selector(saveNow)

        loadValues()
    }

    required init?(coder: NSCoder) { nil }

    private func loadValues() {
        let provider = UserDefaults.standard.string(forKey: "provider") ?? "gemini"
        providerPopUp.selectItem(withTitle: provider == "openai" ? "OpenAI" : (provider == "local" ? "Local" : "Gemini"))
        geminiModelField.stringValue = UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-2.5-flash-lite"
        openAIModelField.stringValue = UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-4o-mini"
        localCommandField.stringValue = UserDefaults.standard.string(forKey: "local_command") ?? "argos-translate --from-lang en --to-lang ru"
        if let key = KeychainService.load(account: "GeminiAPIKey") {
            geminiKeyField.stringValue = key
        }
        if let key = KeychainService.load(account: "OpenAIAPIKey") {
            openAIKeyField.stringValue = key
        }
        updateProviderUI()
    }

    private func saveValues() {
        let provider = providerPopUp.titleOfSelectedItem ?? "Gemini"
        let providerValue = provider == "OpenAI" ? "openai" : (provider == "Local" ? "local" : "gemini")
        UserDefaults.standard.set(providerValue, forKey: "provider")
        _ = KeychainService.save(geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "GeminiAPIKey")
        _ = KeychainService.save(openAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "OpenAIAPIKey")
        UserDefaults.standard.set(geminiModelField.stringValue, forKey: "gemini_model")
        UserDefaults.standard.set(openAIModelField.stringValue, forKey: "openai_model")
        UserDefaults.standard.set(localCommandField.stringValue, forKey: "local_command")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveValues()
        validateModel()
    }

    @objc private func saveNow() {
        saveValues()
        statusLabel.stringValue = "Saved"
        validateModel()
    }

    @objc private func providerChanged() {
        saveValues()
        updateProviderUI()
        validateModel()
    }

    @objc private func showModels() {
        Task {
            do {
                let models = try await fetchModels(forceRefresh: true)
                presentModelPicker(models)
            } catch {
                statusLabel.stringValue = "Model fetch failed"
            }
        }
    }

    private func fetchModels(forceRefresh: Bool) async throws -> [GeminiModel] {
        if !forceRefresh, !cachedModels.isEmpty {
            return cachedModels
        }
        let apiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw NSError(domain: "FocusSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing API key"])
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
            throw NSError(domain: "FocusSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw NSError(domain: "FocusSelection", code: 2, userInfo: [NSLocalizedDescriptionKey: "API error"])
        }
        let parsed = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        cachedModels = parsed.models
        return parsed.models
    }

    private func presentModelPicker(_ models: [GeminiModel]) {
        supportedModelNames = models.filter { $0.supportsGenerateContent }.map { $0.name }
        if supportedModelNames.isEmpty {
            statusLabel.stringValue = "No models found"
            return
        }
        let filter = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 26), pullsDown: false)
        filter.addItems(withTitles: ["All", "flash", "pro"])
        filter.target = self
        filter.action = #selector(filterChanged)

        let popUp = NSPopUpButton(frame: NSRect(x: 130, y: 0, width: 290, height: 26), pullsDown: false)
        self.modelFilter = filter
        self.modelPicker = popUp
        updateModelPicker()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        container.addSubview(filter)
        container.addSubview(popUp)

        let alert = NSAlert()
        alert.messageText = "Gemini Models (generateContent)"
        alert.informativeText = "Select a model and click Choose."
        alert.accessoryView = container
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let selected = popUp.titleOfSelectedItem {
            geminiModelField.stringValue = selected
            saveValues()
            statusLabel.stringValue = "Saved"
            validateModel()
        }
    }

    @objc private func filterChanged() {
        updateModelPicker()
    }

    private func updateModelPicker() {
        guard let popUp = modelPicker, let filter = modelFilter else { return }
        let mode = filter.titleOfSelectedItem ?? "All"
        let filtered = supportedModelNames.filter { name in
            if mode == "All" { return true }
            return name.lowercased().contains(mode)
        }
        popUp.removeAllItems()
        popUp.addItems(withTitles: filtered.isEmpty ? supportedModelNames : filtered)
    }

    private func validateModel() {
        let provider = UserDefaults.standard.string(forKey: "provider") ?? "gemini"
        guard provider == "gemini" else { return }
        let apiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = geminiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty else { return }
        statusLabel.stringValue = "Validating model…"
        Task {
            do {
                let models = try await fetchModels(forceRefresh: false)
                let supported = models.filter { $0.supportsGenerateContent }.map { $0.name }
                if supported.contains(model) {
                    statusLabel.stringValue = "Model OK"
                } else if supported.contains("models/\(model)") {
                    geminiModelField.stringValue = "models/\(model)"
                    saveValues()
                    statusLabel.stringValue = "Model normalized"
                } else {
                    statusLabel.stringValue = "Model not supported"
                }
            } catch {
                statusLabel.stringValue = "Validation failed"
            }
        }
    }

    private func updateProviderUI() {
        let provider = UserDefaults.standard.string(forKey: "provider") ?? "gemini"
        let isGemini = provider == "gemini"
        let isOpenAI = provider == "openai"
        let isLocal = provider == "local"

        geminiKeyField.isEnabled = isGemini
        geminiModelField.isEnabled = isGemini
        showModelsButton.isEnabled = isGemini
        recommendationLabel.isEnabled = isGemini

        openAIKeyField.isEnabled = isOpenAI
        openAIModelField.isEnabled = isOpenAI

        localCommandField.isEnabled = isLocal
    }
}

struct GeminiModelsResponse: Decodable {
    let models: [GeminiModel]
}

struct GeminiModel: Decodable {
    let name: String
    let supportedGenerationMethods: [String]?

    var supportsGenerateContent: Bool {
        supportedGenerationMethods?.contains("generateContent") ?? false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
