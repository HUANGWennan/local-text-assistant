import AppKit
import ApplicationServices
import Carbon

private struct ToDoDraft {
    var title: String
    var dueDate: String
    var notes: String
    var issues: [String]

    init?(_ event: [String: Any]) {
        guard let title = event["title"] as? String,
              let dueDate = event["due_date"] as? String,
              let issues = event["issues"] as? [String] else { return nil }
        self.title = title
        self.dueDate = dueDate
        self.issues = issues
        notes = event["notes"] as? String ?? ""
    }

    var payload: [String: String] {
        ["title": title, "due_date": dueDate, "notes": notes]
    }
}

private final class ToDoSelectionAlert: NSObject {
    private let alert = NSAlert()
    private let selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let checkboxes: [NSButton]
    private let addButton: NSButton

    init(tasks: [ToDoDraft]) {
        checkboxes = tasks.map { task in
            let title = task.dueDate.isEmpty ? task.title : "\(task.title) [\(task.dueDate)]"
            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            checkbox.cell?.wraps = true
            checkbox.cell?.lineBreakMode = .byWordWrapping
            return checkbox
        }
        alert.messageText = "识别到 \(tasks.count) 个活动"
        alert.informativeText = "勾选要加入 Microsoft To Do 的活动。"
        addButton = alert.addButton(withTitle: "加入所选")
        let cancelButton = alert.addButton(withTitle: "取消")
        cancelButton.keyEquivalent = "\u{1B}"
        super.init()

        let listWidth: CGFloat = 356
        let rowWidth = listWidth - 18
        let rows = NSStackView(views: checkboxes)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 3, left: 1, bottom: 3, right: 0)
        for checkbox in checkboxes {
            let bounds = NSRect(x: 0, y: 0, width: rowWidth, height: 10_000)
            let height = ceil(checkbox.cell?.cellSize(forBounds: bounds).height ?? 22)
            checkbox.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            checkbox.heightAnchor.constraint(equalToConstant: max(22, height + 4)).isActive = true
            checkbox.target = self
            checkbox.action = #selector(updateSelection)
        }
        let contentHeight = rows.fittingSize.height
        rows.frame = NSRect(x: 0, y: 0, width: rowWidth + 1, height: contentHeight)
        let visibleHeight = min(contentHeight, 250)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: listWidth, height: visibleHeight))
        scroll.hasVerticalScroller = contentHeight > visibleHeight
        scroll.drawsBackground = false
        scroll.documentView = rows
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rows.isFlipped ? 0 : contentHeight - visibleHeight))
        scroll.reflectScrolledClipView(scroll.contentView)

        let preview = NSView(frame: NSRect(x: 0, y: 0, width: listWidth, height: visibleHeight + 28))
        selectAll.frame = NSRect(x: 1, y: visibleHeight + 4, width: rowWidth, height: 22)
        selectAll.target = self
        selectAll.action = #selector(toggleAll)
        preview.addSubview(selectAll)
        preview.addSubview(scroll)
        alert.accessoryView = preview
        alert.layout()
        alert.window.initialFirstResponder = selectAll
        updateSelection()
    }

    func selectedTasks(from tasks: [ToDoDraft], present: (NSAlert) -> NSApplication.ModalResponse) -> [ToDoDraft]? {
        guard present(alert) == .alertFirstButtonReturn else { return nil }
        return zip(tasks, checkboxes).compactMap { task, checkbox in
            checkbox.state == .on ? task : nil
        }
    }

    @objc private func toggleAll() {
        for checkbox in checkboxes { checkbox.state = selectAll.state }
        updateSelection()
    }

    @objc private func updateSelection() {
        let selectedCount = checkboxes.filter { $0.state == .on }.count
        selectAll.state = selectedCount == checkboxes.count ? .on : .off
        addButton.isEnabled = selectedCount > 0
    }
}

private enum ScreenshotAction {
    case ocr, translation
    var hint: String {
        self == .ocr ? "拖动框选文字与公式 · Esc 取消" : "拖动框选要翻译的文字 · Esc 取消"
    }
}

final class TextHelper: NSObject, NSApplicationDelegate {
    private var screenshotTap: CFMachPort?
    private var screenshotTapSource: CFRunLoopSource?
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = SelectionSpeechReader()
    private var busy = false
    private var panelPaused = false
    private var showingPreview = false
    private let panel = FloatingSelectionPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.title = "文字助手"
        panel.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.busy || self.panelPaused || self.showingPreview
        }
        panel.onAction = { [weak self] mode, selection in self?.run(mode, selection: selection) }
        reader.finished = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.panel.updateSpeechButton(isSpeaking: self.reader.isSpeaking)
            }
        }
        let menu = NSMenu()
        for (title, action) in [
            ("识别截图中的文字与公式", #selector(capture)),
            ("截图翻译为中文", #selector(captureTranslation)),
            ("朗读所选文字", #selector(speak)),
            ("停止朗读", #selector(stop)),
            ("暂停／继续浮动面板", #selector(togglePanel)),
            ("启用选区功能", #selector(requestAccessibility)),
            ("退出", #selector(quit))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        status.menu = menu
        installScreenshotShortcuts()
    }

    private func installScreenshotShortcuts() {
        guard screenshotTap == nil, AXIsProcessTrusted() else { return }
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: eventMask,
                                    callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let helper = Unmanaged<TextHelper>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = helper.screenshotTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            guard type == .keyDown, modifiers == [.maskCommand, .maskShift] else {
                return Unmanaged.passUnretained(event)
            }
            let action: ScreenshotAction
            switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
            case kVK_ANSI_Q: action = .ocr
            case kVK_ANSI_Z: action = .translation
            default: return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { helper.captureScreenshot(action) }
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        screenshotTap = tap
        screenshotTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    @objc private func capture() { captureScreenshot(.ocr) }
    @objc private func captureTranslation() { captureScreenshot(.translation) }

    private func captureScreenshot(_ action: ScreenshotAction) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showError("请在系统设置中允许录屏，然后重新打开文字助手。")
            return
        }
        panel.dismiss()
        busy = true
        status.button?.title = "框选截图…"
        OCRRegionCapture.begin(hint: action.hint) { result in
            switch result {
            case .success(let url):
                if let url { self.recognize(url, action: action) }
                else { self.finish() }
            case .failure(let error):
                self.finish(error: error.localizedDescription)
            }
        }
    }

    private func recognize(_ screenshot: URL, action: ScreenshotAction) {
        status.button?.title = action == .translation ? "翻译中…" : "识别中…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [Bundle.main.resourceURL!.appendingPathComponent("ocr_capture.py").path, "--file", screenshot.path] + (action == .translation ? ["--translate"] : [])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: screenshot)
            finish(error: error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: screenshot)
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            DispatchQueue.main.async {
                guard let text = result?["text"] as? String, !text.isEmpty else {
                    self.finish(error: result?["error"] as? String ?? "模型未返回识别结果。")
                    return
                }
                if action == .translation {
                    self.finish()
                    self.previewText(text, selection: nil, title: "截图翻译为中文")
                    return
                }
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setString(text, forType: .string)
                self.finish(error: copied ? nil : "无法复制识别结果。", copied: copied)
            }
        }
    }

    private func finish(error: String? = nil, copied: Bool = false) {
        busy = false
        status.button?.title = copied ? "已复制 ✓" : "文字助手"
        if let error { showError(error) }
        if copied {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !self.busy { self.status.button?.title = "文字助手" }
            }
        }
    }

    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            showError("请在系统设置中授予辅助功能权限。")
        }
    }

    @objc private func speak() {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard let selection = TextSelection.read() else {
            showError("请先在支持辅助功能的应用中选中文字。")
            return
        }
        startReading(selection.text)
    }

    private func startReading(_ text: String) {
        reader.start(text)
        panel.updateSpeechButton(isSpeaking: reader.isSpeaking)
    }

    @objc private func togglePanel() {
        panelPaused.toggle()
        panel.dismiss()
        if !panelPaused { panel.resume() }
    }

    private func run(_ mode: String, selection: TextSelection) {
        guard !busy else { return }
        if mode == "speak" {
            if reader.isSpeaking { reader.stop() } else { startReading(selection.text) }
            return
        }
        if mode == "todo" {
            runHelper("todo_public.py", mode: "extract", payload: ["text": selection.text]) { result in
                self.previewTasks(result)
            }
        } else {
            runHelper("process_text.py", mode: mode, payload: ["text": selection.text]) { result in
                guard let text = result["text"] as? String else { self.showError("模型未返回文字。"); return }
                self.previewText(text, selection: selection)
            }
        }
    }

    private func runHelper(_ script: String, mode: String, payload: [String: Any],
                           completion: @escaping ([String: Any]) -> Void) {
        guard let scriptURL = Bundle.main.resourceURL?.appendingPathComponent(script),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            showError("无法准备文字处理请求。")
            return
        }
        busy = true
        status.button?.title = "处理中…"
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, mode]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { finish(error: error.localizedDescription); return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            DispatchQueue.main.async {
                self.finish()
                if let error = result?["error"] as? String {
                    self.showError(error)
                } else if let result {
                    completion(result)
                } else {
                    self.showError("文字处理程序未返回结果。")
                }
            }
        }
    }

    private func previewText(_ text: String, selection: TextSelection?, title: String = "预览处理结果") {
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 210))
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.font = NSFont.systemFont(ofSize: 14)
        editor.string = text
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.addButton(withTitle: "复制")
        if selection != nil { alert.addButton(withTitle: "替换原选区") }
        alert.addButton(withTitle: selection == nil ? "关闭" : "取消").keyEquivalent = "\u{1B}"
        let choice = runPreview(alert)
        if choice == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(editor.string, forType: .string)
        } else if choice == .alertSecondButtonReturn, let selection, !selection.replace(with: editor.string) {
            showError("原选区已变化，或当前应用不支持替换。请重新选择文字或使用复制。")
        }
    }

    private func previewTasks(_ result: [String: Any]) {
        guard let events = result["events"] as? [[String: Any]], !events.isEmpty else {
            showError("未识别到可加入 To Do 的任务。")
            return
        }
        let drafts = events.compactMap(ToDoDraft.init)
        guard drafts.count == events.count else {
            showError("无法读取完整的任务信息。")
            return
        }
        var selected = drafts
        if drafts.count > 1 {
            let picker = ToDoSelectionAlert(tasks: drafts)
            guard let chosen = picker.selectedTasks(from: drafts, present: runPreview), !chosen.isEmpty else { return }
            selected = chosen
        }
        for index in selected.indices where drafts.count == 1 || !selected[index].issues.isEmpty || !selected[index].notes.isEmpty {
            guard let reviewed = reviewTask(selected[index]) else { return }
            selected[index] = reviewed
        }
        runHelper("todo_public.py", mode: "create", payload: ["events": selected.map(\.payload)]) { result in
            let report = NSAlert()
            report.messageText = "Microsoft To Do 处理结果"
            report.informativeText = result["text"] as? String ?? "处理已结束。"
            report.addButton(withTitle: "好")
            _ = self.runPreview(report)
        }
    }

    private func reviewTask(_ draft: ToDoDraft) -> ToDoDraft? {
        let alert = NSAlert()
        alert.messageText = "确认任务信息"
        alert.informativeText = draft.issues.joined(separator: "\n")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 236))
        let title = NSTextField(string: draft.title)
        title.frame = NSRect(x: 68, y: 203, width: 352, height: 26)
        title.setAccessibilityLabel("标题")
        let date = NSTextField(string: draft.dueDate)
        date.frame = NSRect(x: 68, y: 166, width: 352, height: 26)
        date.placeholderString = "YYYY-MM-DD（可留空）"
        date.setAccessibilityLabel("截止日期")
        for (name, y) in [("标题", 206.0), ("截止日期", 169.0), ("备注", 134.0)] {
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 0, y: CGFloat(y), width: 66, height: 22)
            accessory.addSubview(label)
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 4, width: 420, height: 128)
        scroll.borderType = .bezelBorder
        guard let notes = scroll.documentView as? NSTextView else { return nil }
        notes.isRichText = false
        notes.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        notes.string = draft.notes
        notes.setAccessibilityLabel("备注")
        accessory.addSubview(title)
        accessory.addSubview(date)
        accessory.addSubview(scroll)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1B}"
        guard runPreview(alert) == .alertFirstButtonReturn else { return nil }

        var reviewed = draft
        reviewed.title = title.stringValue
        reviewed.dueDate = date.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reviewed.notes = notes.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return reviewed
    }

    private func runPreview(_ alert: NSAlert) -> NSApplication.ModalResponse {
        showingPreview = true
        defer { showingPreview = false }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    @objc private func stop() { reader.stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "文字助手"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = runPreview(alert)
    }
}

let app = NSApplication.shared
let delegate = TextHelper()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
