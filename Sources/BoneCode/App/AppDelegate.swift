import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved theme before any window is created.
        NSApp.appearance = NSAppearance(named: ThemeManager.shared.current.isDark ? .darkAqua : .aqua)

        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        NSApp.mainMenu = buildMainMenu()

        if let saved = UserDefaults.standard.string(forKey: "lastWorkspace"),
           FileManager.default.fileExists(atPath: saved) {
            controller.mainViewController.openWorkspace(URL(fileURLWithPath: saved))
        }

        NSApp.activate(ignoringOtherApps: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = windowController else { return .terminateNow }
        guard controller.mainViewController.editorArea.promptSaveAllIfNeeded() else { return .terminateCancel }
        if let root = AppState.shared.workspaceRoot {
            UserDefaults.standard.set(root.path, forKey: "lastWorkspace")
        }
        controller.mainViewController.terminalPanel.terminateAll()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if FileManager.default.isDirectory(url.path) {
                windowController?.mainViewController.openWorkspace(url)
            } else {
                AppState.shared.openFile(url)
            }
        }
    }

    // MARK: - Menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // ---- App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BoneCode", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        let aiSettings = NSMenuItem(title: "AI 助手设置…", action: #selector(openAISettings), keyEquivalent: ",")
        aiSettings.target = self
        appMenu.addItem(aiSettings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoneCode", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BoneCode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ---- File
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        add(fileMenu, "新建文件", #selector(newFile), "n")
        add(fileMenu, "打开文件…", #selector(openFile), "o")
        add(fileMenu, "打开文件夹…", #selector(openFolder), "O", [.command, .shift])
        let recentItem = NSMenuItem(title: "打开最近", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "打开最近")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        add(fileMenu, "保存", #selector(saveFile), "s")
        add(fileMenu, "全部保存", #selector(saveAll), "S", [.command, .shift])
        add(fileMenu, "从磁盘重新加载", #selector(reloadFile), "r", [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "关闭标签页", #selector(closeTab), "w")
        add(fileMenu, "关闭所有标签页", #selector(closeAllTabs), "W", [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "关闭项目", #selector(closeWorkspace), "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // ---- Edit
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        add(editMenu, "查找 / 替换…", #selector(performFind), "f")
        add(editMenu, "查找下一个", #selector(findNext), "g")
        add(editMenu, "查找上一个", #selector(findPrevious), "G", [.command, .shift])
        editMenu.addItem(.separator())
        add(editMenu, "代码补全", #selector(completeCode), " ", [.control])
        add(editMenu, "切换注释", #selector(toggleComment), "/")
        add(editMenu, "复制当前行", #selector(duplicateLine), "d")
        add(editMenu, "删除当前行", #selector(deleteLine), "K", [.command, .shift])
        let moveUp = NSMenuItem(title: "上移当前行", action: #selector(moveLineUp), keyEquivalent: "\u{F700}")
        moveUp.keyEquivalentModifierMask = [.option]
        moveUp.target = nil
        editMenu.addItem(moveUp)
        let moveDown = NSMenuItem(title: "下移当前行", action: #selector(moveLineDown), keyEquivalent: "\u{F701}")
        moveDown.keyEquivalentModifierMask = [.option]
        moveDown.target = nil
        editMenu.addItem(moveDown)
        add(editMenu, "增加缩进", #selector(indentSelection), "]")
        add(editMenu, "减少缩进", #selector(outdentSelection), "[")
        add(editMenu, "格式化选中代码", #selector(formatSelection), "F", [.command, .option])
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // ---- Navigate
        let navMenuItem = NSMenuItem()
        let navMenu = NSMenu(title: "导航")
        add(navMenu, "快速打开文件…", #selector(quickOpen), "p")
        add(navMenu, "在项目中搜索…", #selector(projectSearch), "f", [.command, .shift])
        add(navMenu, "跳转到行…", #selector(gotoLine), "l")
        navMenu.addItem(.separator())
        add(navMenu, "下一个标签页", #selector(nextTab), "]", [.command, .shift])
        add(navMenu, "上一个标签页", #selector(previousTab), "[", [.command, .shift])
        navMenu.addItem(.separator())
        for index in 1...9 {
            let item = NSMenuItem(title: "第 \(index) 个标签页",
                                  action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(index)")
            item.target = self
            item.tag = index
            navMenu.addItem(item)
        }
        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        // ---- View
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        add(viewMenu, "显示 / 隐藏侧边栏", #selector(toggleSidebar), "0")
        add(viewMenu, "显示 / 隐藏终端", #selector(toggleTerminal), "`")
        add(viewMenu, "显示 / 隐藏 Git 面板", #selector(toggleGit), "g", [.command, .shift])
        add(viewMenu, "显示 / 隐藏 AI 助手", #selector(toggleAI), "a", [.command, .shift])
        viewMenu.addItem(.separator())

        let editorSettingsItem = NSMenuItem(title: "编辑器设置", action: nil, keyEquivalent: "")
        editorSettingsItem.submenu = buildEditorSettingsMenu()
        viewMenu.addItem(editorSettingsItem)
        viewMenu.addItem(.separator())

        let zoomIn = NSMenuItem(title: "放大字体", action: #selector(zoomIn), keyEquivalent: "=")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "缩小字体", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "重置字体大小", action: #selector(zoomReset), keyEquivalent: "0")
        zoomReset.keyEquivalentModifierMask = [.command, .option]
        zoomReset.target = self
        viewMenu.addItem(zoomReset)
        viewMenu.addItem(.separator())
        let themeItem = NSMenuItem(title: "切换浅色 / 深色主题", action: #selector(toggleTheme), keyEquivalent: "t")
        themeItem.keyEquivalentModifierMask = [.command, .option]
        themeItem.target = self
        viewMenu.addItem(themeItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // ---- Run
        let runMenuItem = NSMenuItem()
        let runMenu = NSMenu(title: "运行")
        add(runMenu, "运行", #selector(runProject), "r")
        add(runMenu, "停止", #selector(stopProject), ".")
        runMenu.addItem(.separator())
        add(runMenu, "在终端中打开项目目录", #selector(openTerminalHere), "")
        runMenuItem.submenu = runMenu
        mainMenu.addItem(runMenuItem)

        // ---- Git
        let gitMenuItem = NSMenuItem()
        let gitMenu = NSMenu(title: "Git")
        add(gitMenu, "提交…", #selector(gitCommit), "k")
        add(gitMenu, "拉取 (pull)", #selector(gitPull), "")
        add(gitMenu, "推送 (push)", #selector(gitPush), "")
        add(gitMenu, "获取远程更新 (fetch)", #selector(gitFetch), "")
        gitMenu.addItem(.separator())
        add(gitMenu, "显示 Git 面板", #selector(toggleGit), "")
        gitMenu.addItem(.separator())
        add(gitMenu, "用 AI 生成提交信息", #selector(gitAIMessage), "")
        add(gitMenu, "用 AI 审查改动", #selector(gitAIReview), "")
        gitMenuItem.submenu = gitMenu
        mainMenu.addItem(gitMenuItem)

        // ---- Window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // ---- Help
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        add(helpMenu, "BoneCode 快捷键", #selector(showShortcuts), "")
        add(helpMenu, "打开数据目录", #selector(openDataDirectory), "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        return mainMenu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = self
        menu.addItem(item)
        return item
    }

    private func buildEditorSettingsMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑器设置")
        let settings = EditorSettings.shared

        let wrap = NSMenuItem(title: "自动换行", action: #selector(toggleWrap), keyEquivalent: "")
        wrap.target = self
        wrap.state = settings.wrapLines ? .on : .off
        menu.addItem(wrap)

        let lineNumbers = NSMenuItem(title: "显示行号", action: #selector(toggleLineNumbers), keyEquivalent: "")
        lineNumbers.target = self
        lineNumbers.state = settings.showLineNumbers ? .on : .off
        menu.addItem(lineNumbers)

        let currentLine = NSMenuItem(title: "高亮当前行", action: #selector(toggleCurrentLine), keyEquivalent: "")
        currentLine.target = self
        currentLine.state = settings.highlightCurrentLine ? .on : .off
        menu.addItem(currentLine)

        let brackets = NSMenuItem(title: "自动补全括号", action: #selector(toggleAutoClose), keyEquivalent: "")
        brackets.target = self
        brackets.state = settings.autoCloseBrackets ? .on : .off
        menu.addItem(brackets)

        let completion = NSMenuItem(title: "自动代码提示", action: #selector(toggleAutoCompletion), keyEquivalent: "")
        completion.target = self
        completion.state = settings.autoCompletionEnabled ? .on : .off
        menu.addItem(completion)

        let autoSave = NSMenuItem(title: "运行前自动保存", action: #selector(toggleAutoSave), keyEquivalent: "")
        autoSave.target = self
        autoSave.state = settings.autoSaveOnRun ? .on : .off
        menu.addItem(autoSave)

        menu.addItem(.separator())
        let spaces = NSMenuItem(title: "使用空格缩进", action: #selector(toggleSpaces), keyEquivalent: "")
        spaces.target = self
        spaces.state = settings.useSpaces ? .on : .off
        menu.addItem(spaces)

        let tabItem = NSMenuItem(title: "Tab 宽度", action: nil, keyEquivalent: "")
        let tabMenu = NSMenu(title: "Tab 宽度")
        for width in [2, 4, 8] {
            let item = NSMenuItem(title: "\(width) 个空格", action: #selector(setTabWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = width
            item.state = settings.tabWidth == width ? .on : .off
            tabMenu.addItem(item)
        }
        tabItem.submenu = tabMenu
        menu.addItem(tabItem)

        return menu
    }

    // MARK: - Menu actions

    private var main: MainViewController? { windowController?.mainViewController }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "BoneCode"
        alert.informativeText = """
        原生 · 轻量 · 面向 AI 的 macOS 代码编辑器

        纯 Swift + AppKit 构建，不依赖 Electron 或任何第三方运行时。
        集成编辑器、Git 可视化、真 PTY 终端与 AI 助手。

        版本 1.0
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openAISettings() {
        main?.toggleAIAction()
        AppState.shared.aiPanel?.openSettings()
    }

    @objc private func newFile() { main?.handleNewFileAction() }
    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要打开的文件"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { AppState.shared.openFile(url) }
    }
    @objc private func openFolder() { main?.handleOpenFolder() }
    @objc private func saveFile() { main?.saveCurrentFile() }
    @objc private func saveAll() { main?.saveAll() }
    @objc private func reloadFile() {
        AppState.shared.editorArea?.reloadCurrentFromDisk()
        AppState.shared.postStatus("已从磁盘重新加载")
    }
    @objc private func closeTab() { AppState.shared.editorArea?.closeCurrentTab() }
    @objc private func closeAllTabs() { AppState.shared.editorArea?.closeAllTabs() }
    @objc private func closeWorkspace() {
        AppState.shared.closeWorkspace()
        AppState.shared.postStatus("已关闭项目")
    }

    @objc private func performFind() { sendFinderAction(.showFindInterface) }
    @objc private func findNext() { sendFinderAction(.nextMatch) }
    @objc private func findPrevious() { sendFinderAction(.previousMatch) }

    private func sendFinderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
            responder.performTextFinderAction(item)
        } else {
            NSSound.beep()
        }
    }

    @objc private func completeCode() {
        (NSApp.keyWindow?.firstResponder as? CodeTextView)?.showCompletions(explicit: true)
    }
    @objc private func toggleComment() { forwardToEditor(#selector(CodeTextView.performToggleComment(_:))) }
    @objc private func duplicateLine() { forwardToEditor(#selector(CodeTextView.performDuplicateLine(_:))) }
    @objc private func deleteLine() { forwardToEditor(#selector(CodeTextView.performDeleteLine(_:))) }
    @objc private func moveLineUp() { forwardToEditor(#selector(CodeTextView.performMoveLineUp(_:))) }
    @objc private func moveLineDown() { forwardToEditor(#selector(CodeTextView.performMoveLineDown(_:))) }
    @objc private func indentSelection() { forwardToEditor(#selector(CodeTextView.performIndent(_:))) }
    @objc private func outdentSelection() { forwardToEditor(#selector(CodeTextView.performOutdent(_:))) }
    @objc private func formatSelection() { forwardToEditor(#selector(CodeTextView.performFormat(_:))) }

    private func forwardToEditor(_ selector: Selector) {
        guard let editor = AppState.shared.editorArea?.currentCodeEditor else { return }
        editor.textView.perform(selector, with: nil)
        editor.focusEditor()
    }

    @objc private func quickOpen() { main?.showQuickOpen() }
    @objc private func projectSearch() { main?.showProjectSearch() }

    @objc private func gotoLine() {
        guard let editor = AppState.shared.editorArea?.currentCodeEditor else { return }
        let alert = NSAlert()
        alert.messageText = "跳转到行"
        alert.addButton(withTitle: "跳转")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "行号"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        editor.gotoLine(line)
    }

    @objc private func nextTab() { AppState.shared.editorArea?.selectNextTab() }
    @objc private func previousTab() { AppState.shared.editorArea?.selectPreviousTab() }
    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        AppState.shared.editorArea?.selectTab(at: sender.tag - 1)
    }

    @objc private func toggleSidebar() { NotificationCenter.default.post(name: .toggleSidebar, object: nil) }
    @objc private func toggleTerminal() { NotificationCenter.default.post(name: .toggleTerminal, object: nil) }
    @objc private func toggleGit() {
        NotificationCenter.default.post(name: .toggleSidebar, object: "show")
        NotificationCenter.default.post(name: .toggleGitPanel, object: nil)
    }
    @objc private func toggleAI() { NotificationCenter.default.post(name: .toggleAIPanel, object: nil) }

    @objc private func zoomIn() { ThemeManager.shared.setCodeFontSize(ThemeManager.shared.codeFontSize + 1) }
    @objc private func zoomOut() { ThemeManager.shared.setCodeFontSize(ThemeManager.shared.codeFontSize - 1) }
    @objc private func zoomReset() { ThemeManager.shared.setCodeFontSize(13) }
    @objc private func toggleTheme() { ThemeManager.shared.toggle() }

    @objc private func toggleWrap() {
        EditorSettings.shared.wrapLines.toggle()
        applyEditorSettings()
    }
    @objc private func toggleLineNumbers() {
        EditorSettings.shared.showLineNumbers.toggle()
        applyEditorSettings()
    }
    @objc private func toggleCurrentLine() {
        EditorSettings.shared.highlightCurrentLine.toggle()
        applyEditorSettings()
    }
    @objc private func toggleAutoClose() {
        EditorSettings.shared.autoCloseBrackets.toggle()
        applyEditorSettings()
    }
    @objc private func toggleAutoCompletion() {
        EditorSettings.shared.autoCompletionEnabled.toggle()
        applyEditorSettings()
    }
    @objc private func toggleAutoSave() {
        EditorSettings.shared.autoSaveOnRun.toggle()
        applyEditorSettings()
    }
    @objc private func toggleSpaces() {
        EditorSettings.shared.useSpaces.toggle()
        applyEditorSettings()
    }
    @objc private func setTabWidth(_ sender: NSMenuItem) {
        EditorSettings.shared.tabWidth = sender.tag
        applyEditorSettings()
    }

    private func applyEditorSettings() {
        NSApp.mainMenu = buildMainMenu()
        for editor in AppState.shared.editorArea?.openEditors ?? [] {
            editor.textView.applyWrapSetting()
            editor.textView.updateParagraphStyle()
            editor.textView.rehighlight()
        }
        AppState.shared.postStatus("编辑器设置已更新")
    }

    @objc private func runProject() { NotificationCenter.default.post(name: .runProject, object: nil) }
    @objc private func stopProject() { NotificationCenter.default.post(name: .stopProject, object: nil) }
    @objc private func openTerminalHere() {
        NotificationCenter.default.post(name: .toggleTerminal, object: "show")
        if let root = AppState.shared.workspaceRoot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .terminalSendText, object: "cd \"\(root.path)\"\n")
            }
        }
    }

    @objc private func gitCommit() {
        main?.sidebar.select(1)
        main?.sidebar.gitPanel.showChangesSection()
    }
    @objc private func gitPull() { main?.gitPull() }
    @objc private func gitPush() { main?.gitPush() }
    @objc private func gitFetch() {
        main?.sidebar.select(1)
        main?.sidebar.gitPanel.doFetch()
    }
    @objc private func gitAIMessage() {
        main?.sidebar.select(1)
        main?.sidebar.gitPanel.generateCommitMessageAction()
    }
    @objc private func gitAIReview() {
        main?.toggleAIAction()
        AppState.shared.aiPanel?.quickReviewDiffAction()
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "BoneCode 快捷键"
        alert.informativeText = """
        文件
          ⌘N 新建文件        ⌘O 打开文件        ⌘⇧O 打开文件夹
          ⌘S 保存            ⌘⇧S 全部保存      ⌘W 关闭标签

        导航
          ⌘P 快速打开文件    ⌘⇧F 项目内搜索    ⌘L 跳转到行
          ⌘⇧] / ⌘⇧[ 切换标签页

        编辑
          ⌃Space 代码补全    ⌘/ 切换注释       ⌘D 复制当前行
          ⌘⇧K 删除当前行     ⌥↑ / ⌥↓ 移动行    ⌘⌥F 格式化选中
          ⌘F 查找替换        ⌘G 查找下一个

        视图与运行
          ⌘0 侧边栏          ⌘` 终端           ⌘⇧G Git 面板
          ⌘⇧A AI 助手        ⌘R 运行           ⌘. 停止
          ⌘+ / ⌘- 字号       ⌘⌥T 切换主题

        终端
          ⌘K 清屏            ⌘C / ⌘V 复制粘贴   ⌃C 中断当前命令
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openDataDirectory() {
        let path = NSHomeDirectory() + "/Library/Application Support/BoneCode"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "打开最近" else { return }
        menu.removeAllItems()
        let items = RecentProjects.shared.recentItems
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: "暂无记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for item in items {
            let menuItem = NSMenuItem(title: item.display, action: #selector(openRecent(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清除记录", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? RecentItem else { return }
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: item.path) else {
            AppState.shared.postStatus("文件已不存在：\(item.path)")
            return
        }
        if item.isDirectory {
            main?.openWorkspace(url)
        } else {
            AppState.shared.openFile(url)
        }
    }

    @objc private func clearRecent() {
        RecentProjects.shared.clear()
    }
}
