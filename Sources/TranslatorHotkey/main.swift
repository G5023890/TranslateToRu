import Cocoa
import Carbon.HIToolbox
import Security
import ServiceManagement

final class TranslationWindowController: NSWindowController, NSWindowDelegate {
    private let textView: NSTextView
    private var escMonitor: Any?

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 360)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let window = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Перевод"
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
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.string = ""
        textView.textContainerInset = NSSize(width: 12, height: 12)

        scrollView.documentView = textView
        window.contentView = scrollView

        self.textView = textView
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(message: String) {
        textView.string = message
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if escMonitor != nil { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.window?.orderOut(nil)
                return nil
            }
            return event
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
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

struct HotKeyConfig: Codable {
    var keyCode: UInt32
    var modifiers: UInt32
}

enum HotKeyStore {
    private static let key = "hotkey_config_v1"
    static let defaultConfig = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | optionKey | controlKey)
    )

    static func load() -> HotKeyConfig {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let config = try? JSONDecoder().decode(HotKeyConfig.self, from: data)
        else {
            return defaultConfig
        }
        return config
    }

    static func save(_ config: HotKeyConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct OpenAIClient {
    let apiKey: String
    let model: String
    
    enum APIError: LocalizedError {
        case quota(message: String)
        case other(message: String)
        
        var errorDescription: String? {
            switch self {
            case .quota(let message): return message
            case .other(let message): return message
            }
        }
    }

    func translateToRussian(_ text: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "Translator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
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
            if
                let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                let error = json["error"] as? [String: Any],
                let message = error["message"] as? String,
                let code = error["code"] as? String
            {
                if code == "insufficient_quota" {
                    throw APIError.quota(message: message)
                }
                throw APIError.other(message: message)
            }
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw APIError.other(message: "API error: \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String
        return content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct GeminiClient {
    let apiKey: String
    let model: String

    func translateToRussian(_ text: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw NSError(domain: "Translator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "Translate the following text to Russian. Return only the translation.\n\n\(text)"]
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
                throw NSError(domain: "Translator", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "Translator", code: 2, userInfo: [NSLocalizedDescriptionKey: "API error: \(body)"])
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        let text = parts?.first?["text"] as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x54524E53), id: 1) // "TRNS"
    private let windowController = TranslationWindowController()
    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotKey()
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
                    delegate.handleHotKey()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), nil)

        let config = HotKeyStore.load()
        RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func handleHotKey() {
        windowController.show(message: "Перевожу…")
        captureSelectionAndTranslate()
    }

    private func captureSelectionAndTranslate() {
        if let axText = readSelectedTextViaAccessibility(),
           !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translate(text: axText)
            return
        }
        readSelectionViaCopy { selectedText in
            if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.windowController.show(message: "Не удалось получить выделенный текст.\nПроверьте Accessibility/Input Monitoring и попробуйте снова.")
                return
            }
            self.translate(text: selectedText)
        }
    }
}

extension AppDelegate {
    private func translate(text: String) {
        Task {
            do {
                let provider = UserDefaults.standard.string(forKey: "provider") ?? "openai"
                let translation: String
                if provider == "gemini" {
                    let apiKey = KeychainService.load(account: "GeminiAPIKey") ?? ""
                    let model = UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-flash-latest"
                    if apiKey.isEmpty {
                        self.windowController.show(message: "Не найден ключ Gemini.\nОткройте Настройки и добавьте ключ.")
                        return
                    }
                    let client = GeminiClient(apiKey: apiKey, model: model)
                    translation = try await client.translateToRussian(text)
                } else {
                    let apiKey = KeychainService.load(account: "OpenAIAPIKey") ?? ""
                    let model = UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-4o-mini"
                    if apiKey.isEmpty {
                        self.windowController.show(message: "Не найден OpenAI ключ.\nОткройте Настройки и добавьте ключ.")
                        return
                    }
                    let client = OpenAIClient(apiKey: apiKey, model: model)
                    translation = try await client.translateToRussian(text)
                }
                self.windowController.show(message: translation.isEmpty ? "Пустой ответ от модели." : translation)
            } catch {
                if case OpenAIClient.APIError.quota(let message) = error {
                    self.windowController.show(message: "Ошибка перевода: \(message)")
                    self.showQuotaAlert(message: message)
                } else {
                    self.windowController.show(message: "Ошибка перевода: \(error.localizedDescription)")
                }
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
}

extension AppDelegate {
    private func readSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        if let focusedElement = copyAXElementAttribute(systemWide, attribute: kAXFocusedUIElementAttribute as String) {
            if let text = extractSelectedText(from: focusedElement) {
                return text
            }
            if let text = searchSelectedText(in: focusedElement, maxNodes: 250) {
                return text
            }
        }

        if let focusedWindow = copyAXElementAttribute(systemWide, attribute: kAXFocusedWindowAttribute as String) {
            if let text = searchSelectedText(in: focusedWindow, maxNodes: 250) {
                return text
            }
        }

        return nil
    }

    private func copyAXAnyAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if err == .success, let unwrapped = value {
            return (unwrapped as AnyObject)
        }
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
                if !str.isEmpty {
                    return str
                }
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

    private func copyAXElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let unwrapped = value else { return nil }
        if CFGetTypeID(unwrapped) == AXUIElementGetTypeID() {
            return (unwrapped as! AXUIElement)
        }
        return nil
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let providerPopUp = NSPopUpButton()
    private let openAIKeyField = NSSecureTextField()
    private let openAIModelField = NSTextField()
    private let geminiKeyField = NSSecureTextField()
    private let geminiModelField = NSTextField()
    private let hotkeyButton = NSButton(title: "Нажмите, чтобы записать", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Запускать при входе в систему", target: nil, action: nil)
    private let showModelsButton = NSButton(title: "Показать модели", target: nil, action: nil)
    private let saveButton = NSButton(title: "Сохранить", target: nil, action: nil)
    private var isRecordingHotkey = false
    private var cachedGeminiModels: [GeminiModel] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let providerLabel = NSTextField(labelWithString: "Провайдер")
        let openAIKeyLabel = NSTextField(labelWithString: "OpenAI API ключ")
        let openAIModelLabel = NSTextField(labelWithString: "OpenAI модель")
        let geminiKeyLabel = NSTextField(labelWithString: "Gemini API ключ")
        let geminiModelLabel = NSTextField(labelWithString: "Gemini модель")
        let hotkeyLabel = NSTextField(labelWithString: "Горячая клавиша")

        [providerLabel, openAIKeyLabel, openAIModelLabel, geminiKeyLabel, geminiModelLabel, hotkeyLabel]
            .forEach { $0.font = NSFont.systemFont(ofSize: 13, weight: .semibold) }

        providerPopUp.addItems(withTitles: ["OpenAI", "Gemini"])
        openAIKeyField.placeholderString = "sk-..."
        openAIModelField.placeholderString = "gpt-4o-mini"
        geminiKeyField.placeholderString = "AIza..."
        geminiModelField.placeholderString = "gemini-flash-latest"

        providerLabel.frame = NSRect(x: 20, y: 270, width: 200, height: 18)
        providerPopUp.frame = NSRect(x: 20, y: 245, width: 180, height: 26)

        openAIKeyLabel.frame = NSRect(x: 20, y: 210, width: 200, height: 18)
        openAIKeyField.frame = NSRect(x: 20, y: 185, width: 520, height: 24)

        openAIModelLabel.frame = NSRect(x: 20, y: 155, width: 200, height: 18)
        openAIModelField.frame = NSRect(x: 20, y: 130, width: 220, height: 24)

        geminiKeyLabel.frame = NSRect(x: 300, y: 155, width: 200, height: 18)
        geminiKeyField.frame = NSRect(x: 300, y: 130, width: 240, height: 24)

        geminiModelLabel.frame = NSRect(x: 300, y: 100, width: 200, height: 18)
        geminiModelField.frame = NSRect(x: 300, y: 75, width: 240, height: 24)

        hotkeyButton.frame = NSRect(x: 20, y: 70, width: 220, height: 28)
        hotkeyLabel.frame = NSRect(x: 20, y: 98, width: 200, height: 18)

        statusLabel.frame = NSRect(x: 260, y: 70, width: 280, height: 28)
        statusLabel.textColor = .secondaryLabelColor

        launchAtLoginCheckbox.frame = NSRect(x: 20, y: 30, width: 300, height: 24)
        showModelsButton.frame = NSRect(x: 260, y: 26, width: 160, height: 28)
        saveButton.frame = NSRect(x: 430, y: 26, width: 110, height: 28)

        content.addSubview(providerLabel)
        content.addSubview(providerPopUp)
        content.addSubview(openAIKeyLabel)
        content.addSubview(openAIKeyField)
        content.addSubview(openAIModelLabel)
        content.addSubview(openAIModelField)
        content.addSubview(geminiKeyLabel)
        content.addSubview(geminiKeyField)
        content.addSubview(geminiModelLabel)
        content.addSubview(geminiModelField)
        content.addSubview(hotkeyLabel)
        content.addSubview(hotkeyButton)
        content.addSubview(statusLabel)
        content.addSubview(launchAtLoginCheckbox)
        content.addSubview(showModelsButton)
        content.addSubview(saveButton)
        window.contentView = content

        super.init(window: window)

        hotkeyButton.target = self
        hotkeyButton.action = #selector(beginHotkeyRecording)
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        saveButton.target = self
        saveButton.action = #selector(saveNow)
        showModelsButton.target = self
        showModelsButton.action = #selector(showModels)
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        openAIKeyField.delegate = self
        openAIModelField.delegate = self
        geminiKeyField.delegate = self
        geminiModelField.delegate = self

        loadValues()
        updateHotkeyDisplay()
        updateProviderUI()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isRecordingHotkey {
                self.captureHotkey(event: event)
                return nil
            }
            return event
        }
    }

    required init?(coder: NSCoder) { nil }

    private func loadValues() {
        let provider = UserDefaults.standard.string(forKey: "provider") ?? "openai"
        providerPopUp.selectItem(withTitle: provider == "gemini" ? "Gemini" : "OpenAI")
        openAIModelField.stringValue = UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-4o-mini"
        geminiModelField.stringValue = UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-flash-latest"
        if let key = KeychainService.load(account: "OpenAIAPIKey") {
            openAIKeyField.stringValue = key
        }
        if let key = KeychainService.load(account: "GeminiAPIKey") {
            geminiKeyField.stringValue = key
        }
        launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func saveValues() {
        let provider = providerPopUp.titleOfSelectedItem == "Gemini" ? "gemini" : "openai"
        UserDefaults.standard.set(provider, forKey: "provider")
        _ = KeychainService.save(openAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "OpenAIAPIKey")
        _ = KeychainService.save(geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "GeminiAPIKey")
        UserDefaults.standard.set(openAIModelField.stringValue, forKey: "openai_model")
        UserDefaults.standard.set(geminiModelField.stringValue, forKey: "gemini_model")
    }

    private func updateHotkeyDisplay() {
        let config = HotKeyStore.load()
        hotkeyButton.title = HotKeyFormatter.format(keyCode: config.keyCode, modifiers: config.modifiers)
    }

    @objc private func beginHotkeyRecording() {
        isRecordingHotkey = true
        statusLabel.stringValue = "Нажмите новую комбинацию..."
        hotkeyButton.title = "Запись…"
    }

    private func captureHotkey(event: NSEvent) {
        isRecordingHotkey = false
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = HotKeyFormatter.carbonModifiers(from: flags)
        if carbon == 0 {
            statusLabel.stringValue = "Нужны модификаторы (Ctrl/Option/Command/Shift)"
            updateHotkeyDisplay()
            return
        }
        let config = HotKeyConfig(keyCode: UInt32(event.keyCode), modifiers: carbon)
        HotKeyStore.save(config)
        statusLabel.stringValue = "Сохранено"
        hotkeyButton.title = HotKeyFormatter.format(keyCode: config.keyCode, modifiers: config.modifiers)
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        saveValues()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveValues()
        validateGeminiModelIfNeeded()
    }

    @objc private func saveNow() {
        saveValues()
        statusLabel.stringValue = "Сохранено"
        validateGeminiModelIfNeeded()
    }

    @objc private func providerChanged() {
        saveValues()
        updateProviderUI()
        validateGeminiModelIfNeeded()
    }

    private func updateProviderUI() {
        let isGemini = providerPopUp.titleOfSelectedItem == "Gemini"
        openAIKeyField.isEnabled = !isGemini
        openAIModelField.isEnabled = !isGemini
        geminiKeyField.isEnabled = isGemini
        geminiModelField.isEnabled = isGemini
        showModelsButton.isEnabled = isGemini
    }

    @objc private func showModels() {
        Task {
            do {
                let models = try await fetchGeminiModels(forceRefresh: true)
                presentModelsList(models)
            } catch {
                statusLabel.stringValue = "Ошибка загрузки моделей: \(error.localizedDescription)"
            }
        }
    }

    private func validateGeminiModelIfNeeded() {
        let isGemini = providerPopUp.titleOfSelectedItem == "Gemini"
        let apiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = geminiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGemini, !apiKey.isEmpty, !model.isEmpty else { return }

        statusLabel.stringValue = "Проверяю модель…"
        Task {
            do {
                let models = try await fetchGeminiModels(forceRefresh: false)
                let supported = models.filter { $0.supportsGenerateContent }.map { $0.name }
                if supported.contains("models/\(model)") || supported.contains(model) {
                    statusLabel.stringValue = "Модель поддерживается"
                } else {
                    statusLabel.stringValue = "Модель не поддерживает generateContent"
                }
            } catch {
                statusLabel.stringValue = "Не удалось проверить модель"
            }
        }
    }

    private func fetchGeminiModels(forceRefresh: Bool) async throws -> [GeminiModel] {
        if !forceRefresh, !cachedGeminiModels.isEmpty {
            return cachedGeminiModels
        }
        let apiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Translator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден ключ Gemini"])
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
            throw NSError(domain: "Translator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Translator", code: 2, userInfo: [NSLocalizedDescriptionKey: "API error: \(body)"])
        }
        let parsed = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        cachedGeminiModels = parsed.models
        return parsed.models
    }

    private func presentModelsList(_ models: [GeminiModel]) {
        let supported = models.filter { $0.supportsGenerateContent }
        let names = supported.map { $0.name }
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 26), pullsDown: false)
        popUp.addItems(withTitles: names)

        let alert = NSAlert()
        alert.messageText = "Доступные модели Gemini (generateContent)"
        alert.informativeText = "Выберите модель и нажмите «Выбрать»."
        alert.accessoryView = popUp
        alert.addButton(withTitle: "Выбрать")
        alert.addButton(withTitle: "Закрыть")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let selected = popUp.titleOfSelectedItem {
            let normalized = selected.replacingOccurrences(of: "models/", with: "")
            geminiModelField.stringValue = normalized
            saveValues()
            validateGeminiModelIfNeeded()
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
            statusLabel.stringValue = "Ошибка автозапуска: \(error.localizedDescription)"
            launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
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

enum HotKeyFormatter {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    static func format(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: "+")
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Return): return "Enter"
        case UInt32(kVK_Tab): return "Tab"
        case UInt32(kVK_Escape): return "Esc"
        default: return "Key\(keyCode)"
        }
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
}

extension AppDelegate {
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TR"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Перевести выделение", action: #selector(translateFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(reloadHotkey), name: .hotkeyChanged, object: nil)
    }

    @objc private func translateFromMenu() {
        handleHotKey()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func reloadHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        registerHotKey()
    }
    
    private func showQuotaAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Недостаточно квоты OpenAI"
            alert.informativeText = message
            alert.addButton(withTitle: "Открыть биллинг")
            alert.addButton(withTitle: "Закрыть")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "https://platform.openai.com/account/billing") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
