import AppKit

/// The Git tool window: changes, history, branches and stashes behind one
/// segmented control, with fetch/pull/push/undo-push in the header.
final class GitPanelViewController: NSViewController {

    private let header = NSView()
    private let branchButton = NSPopUpButton()
    private let syncLabel = NSTextField(labelWithString: "")
    private let segmented = NSSegmentedControl()
    private let banner = NSView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private var bannerButtons: [NSButton] = []
    private let contentContainer = NSView()
    private let outputScroll = NSScrollView()
    private let outputView = NSTextView()
    private var bannerHeight: NSLayoutConstraint!
    private var outputHeight: NSLayoutConstraint!

    private let changesView = GitChangesView()
    private let historyView = GitHistoryView()
    private let branchesView = GitBranchesView()
    private let stashView = GitStashView()

    private(set) var state: GitRepoState?
    private var commits: [GitCommit] = []
    private var branches: [GitBranch] = []
    private var stashes: [GitStashEntry] = []
    private var currentSection = 0

    private let refreshDebouncer = Debouncer(delay: 0.25)

    var onShowDiff: ((DiffRequest) -> Void)?

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.panelBackground)

        // ---- header
        header.translatesAutoresizingMaskIntoConstraints = false
        branchButton.translatesAutoresizingMaskIntoConstraints = false
        branchButton.bezelStyle = .rounded
        branchButton.controlSize = .small
        branchButton.font = Fonts.ui(size: 11, weight: .medium)
        branchButton.target = self
        branchButton.action = #selector(branchMenuChanged)
        branchButton.toolTip = "当前分支 · 点击切换"

        syncLabel.font = Fonts.ui(size: 10.5)
        syncLabel.textColor = ThemeManager.shared.current.tertiaryText
        syncLabel.translatesAutoresizingMaskIntoConstraints = false

        let fetchButton = makeButton("arrow.down.circle", tooltip: "获取所有远程更新 (fetch --all --prune)", action: #selector(doFetch))
        let pullButton = makeButton("arrow.down.to.line", tooltip: "拉取并合并 (pull)", action: #selector(doPull))
        let pullRebaseButton = makeButton("arrow.triangle.2.circlepath", tooltip: "拉取并变基 (pull --rebase)", action: #selector(doPullRebase))
        let pushButton = makeButton("arrow.up.to.line", tooltip: "推送 (push)", action: #selector(doPush))
        let undoButton = makeButton("arrow.uturn.backward.circle", tooltip: "撤回 push / 撤销提交", action: #selector(showUndoMenu))
        let refreshButton = makeButton("arrow.clockwise", tooltip: "刷新", action: #selector(refreshNow))
        let outputButton = makeButton("terminal", tooltip: "显示 / 隐藏 Git 输出", action: #selector(toggleOutput))

        let actionStack = NSStackView.horizontal(spacing: 2)
        for b in [fetchButton, pullButton, pullRebaseButton, pushButton, undoButton, refreshButton, outputButton] {
            actionStack.addArrangedSubview(b)
        }
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(branchButton)
        header.addSubview(syncLabel)
        header.addSubview(actionStack)
        NSLayoutConstraint.activate([
            branchButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            branchButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 190),

            syncLabel.leadingAnchor.constraint(equalTo: branchButton.trailingAnchor, constant: 6),
            syncLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            syncLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -6),

            actionStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            actionStack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        // ---- banner (merge / rebase / cherry-pick in progress)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.font = Fonts.ui(size: 11, weight: .medium)
        bannerLabel.lineBreakMode = .byTruncatingTail
        banner.addSubview(bannerLabel)

        let continueButton = smallButton("继续", #selector(doContinueOperation))
        let skipButton = smallButton("跳过", #selector(doSkipOperation))
        let abortButton = smallButton("中止", #selector(doAbortOperation))
        bannerButtons = [continueButton, skipButton, abortButton]
        let bannerStack = NSStackView.horizontal(spacing: 4)
        for b in bannerButtons { bannerStack.addArrangedSubview(b) }
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerStack)

        NSLayoutConstraint.activate([
            bannerLabel.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 8),
            bannerLabel.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            bannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bannerStack.leadingAnchor, constant: -6),
            bannerStack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -6),
            bannerStack.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])

        // ---- segmented control
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.segmentCount = 4
        segmented.setLabel("变更", forSegment: 0)
        segmented.setLabel("历史", forSegment: 1)
        segmented.setLabel("分支", forSegment: 2)
        segmented.setLabel("贮藏", forSegment: 3)
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(sectionChanged)
        segmented.controlSize = .small

        // ---- content
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // ---- output
        outputScroll.translatesAutoresizingMaskIntoConstraints = false
        outputScroll.hasVerticalScroller = true
        outputScroll.borderType = .noBorder
        outputScroll.drawsBackground = true
        outputScroll.autohidesScrollers = true
        outputView.isEditable = false
        outputView.font = Fonts.code(size: 10.5)
        outputView.textContainerInset = NSSize(width: 4, height: 4)
        outputScroll.documentView = outputView

        root.addSubview(header)
        root.addSubview(banner)
        root.addSubview(segmented)
        root.addSubview(contentContainer)
        root.addSubview(outputScroll)

        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        outputHeight = outputScroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            banner.topAnchor.constraint(equalTo: header.bottomAnchor),
            bannerHeight,

            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            segmented.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 4),
            segmented.heightAnchor.constraint(equalToConstant: 22),

            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
            contentContainer.bottomAnchor.constraint(equalTo: outputScroll.topAnchor),

            outputScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outputScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outputScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            outputHeight
        ])

        // Assign the view before anything that reads `self.view` — the getter
        // re-enters loadView() when the view is still nil.
        view = root
        installViews()
        wireCallbacks()
        applyTheme()

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged),
                                               name: .workspaceDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editorSaved),
                                               name: .editorDidSave, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func installViews() {
        let views: [NSView] = [changesView, historyView, branchesView, stashView]
        for (index, sub) in views.enumerated() {
            sub.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                sub.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                sub.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
            sub.isHidden = index != 0
        }
    }

    private func wireCallbacks() {
        let refresh: () -> Void = { [weak self] in self?.scheduleRefresh() }
        let info: (String) -> Void = { [weak self] message in
            self?.appendOutput(message)
            AppState.shared.postStatus(message)
        }
        let error: (String) -> Void = { [weak self] message in
            self?.appendOutput("⚠️ " + message)
            self?.showErrorAlert(message)
        }

        changesView.onNeedsRefresh = refresh
        changesView.onInfo = info
        changesView.onError = error
        changesView.onShowDiff = { [weak self] change, staged in
            self?.showWorkingTreeDiff(change: change, staged: staged)
        }

        historyView.onNeedsRefresh = refresh
        historyView.onInfo = info
        historyView.onError = error
        historyView.onShowCommitDiff = { [weak self] commit in
            self?.showCommitDiff(commit)
        }
        historyView.onShowRawDiff = { [weak self] diffs, title, subtitle in
            self?.onShowDiff?(DiffRequest(diffs: diffs, title: title, subtitle: subtitle))
        }

        branchesView.onNeedsRefresh = refresh
        branchesView.onInfo = info
        branchesView.onError = error

        stashView.onNeedsRefresh = refresh
        stashView.onInfo = info
        stashView.onError = error
    }

    private func makeButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        HoverIconButton(symbol: symbol, tooltip: tooltip, target: self, action: action,
                        width: 24, height: 22, symbolSize: 12.5)
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Fonts.ui(size: 10.5)
        return button
    }

    @objc private func themeChanged() { applyTheme() }

    private func applyTheme() {
        let theme = ThemeManager.shared.current
        view.setBackground(theme.panelBackground)
        header.setBackground(theme.tabBarBackground)
        banner.layer?.backgroundColor = theme.accentSoft.cgColor
        bannerLabel.textColor = theme.accent
        outputScroll.backgroundColor = theme.editorBackground
        outputView.backgroundColor = theme.editorBackground
        outputView.textColor = theme.secondaryText
        syncLabel.textColor = theme.tertiaryText
        view.refreshHoverButtons()
    }

    // MARK: - Data

    @objc private func workspaceChanged() {
        refreshNow()
    }

    @objc private func editorSaved() {
        scheduleRefresh()
    }

    func scheduleRefresh() {
        refreshDebouncer.schedule { [weak self] in self?.refreshNow() }
    }

    @objc func refreshNow() {
        guard GitService.shared.isOpen else {
            branchButton.removeAllItems()
            branchButton.addItem(withTitle: "非 Git 仓库")
            branchButton.isEnabled = false
            syncLabel.stringValue = ""
            changesView.update(with: nil)
            historyView.update(commits: [], graphRows: [])
            branchesView.update([])
            stashView.update([])
            setBanner(nil)
            return
        }
        branchButton.isEnabled = true

        GitService.shared.state { [weak self] state in
            guard let self else { return }
            self.state = state
            self.changesView.update(with: state)
            self.updateHeader(for: state)
            self.setBanner(state?.operation)
            NotificationCenter.default.post(name: .gitStatusDidChange, object: state)
        }

        GitService.shared.log(limit: 400) { [weak self] commits in
            guard let self else { return }
            self.commits = commits
            let rows = GitGraphLayout.compute(commits: commits)
            self.historyView.update(commits: commits, graphRows: rows)
        }

        GitService.shared.branches { [weak self] branches in
            guard let self else { return }
            self.branches = branches
            self.branchesView.update(branches)
            self.updateBranchMenu()
        }

        GitService.shared.stashes { [weak self] entries in
            self?.stashes = entries
            self?.stashView.update(entries)
        }
    }

    private func updateHeader(for state: GitRepoState?) {
        guard let state else {
            syncLabel.stringValue = ""
            return
        }
        if branchButton.numberOfItems == 0 || branchButton.titleOfSelectedItem != state.branch {
            updateBranchMenu()
        }
        var parts: [String] = []
        if state.ahead > 0 { parts.append("↑\(state.ahead)") }
        if state.behind > 0 { parts.append("↓\(state.behind)") }
        if !state.hasUpstream { parts.append("无上游") }
        if !state.isClean { parts.append("\(state.changes.count) 处改动") }
        syncLabel.stringValue = parts.joined(separator: "  ")
    }

    private func updateBranchMenu() {
        branchButton.removeAllItems()
        branchButton.menu = NSMenu()
        let current = branches.first(where: { $0.isCurrent })
        let title = current?.shortName ?? (state?.branch ?? "分支")
        branchButton.addItem(withTitle: title)

        guard let menu = branchButton.menu else { return }
        // The popup's own first item is the current branch (already added above).
        let local = branches.filter { !$0.isRemote }
        let remote = branches.filter { $0.isRemote }
        if !local.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "本地分支", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for branch in local where !branch.isCurrent {
                let item = NSMenuItem(title: branch.shortName,
                                      action: #selector(checkoutFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = branch.name
                menu.addItem(item)
            }
        }
        if !remote.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "远程分支", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for branch in remote.prefix(30) {
                let item = NSMenuItem(title: branch.name,
                                      action: #selector(checkoutFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = branch.name
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "新建分支…", action: #selector(newBranchFromMenu), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
    }

    @objc private func branchMenuChanged() {
        // The popup's first item is the current branch; ignore selection changes.
    }

    @objc private func checkoutFromMenu(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String else { return }
        GitService.shared.checkout(ref) { [weak self] result in
            if result.ok {
                self?.appendOutput("已切换到 \(ref)")
                AppState.shared.postStatus("已切换到 \(ref)")
            } else {
                self?.showErrorAlert(result.combined.trimmed)
            }
            self?.refreshNow()
        }
    }

    @objc private func newBranchFromMenu() {
        guard let name = promptForText(title: "新建分支", placeholder: "分支名，例如 feature/login") else { return }
        GitService.shared.createBranch(name, at: nil, checkout: true) { [weak self] result in
            if !result.ok { self?.showErrorAlert(result.combined.trimmed) }
            self?.refreshNow()
        }
    }

    @objc private func sectionChanged() {
        currentSection = segmented.selectedSegment
        let views: [NSView] = [changesView, historyView, branchesView, stashView]
        for (index, sub) in views.enumerated() { sub.isHidden = index != currentSection }
    }

    func showChangesSection() {
        segmented.selectedSegment = 0
        sectionChanged()
    }

    // MARK: - Banner

    private func setBanner(_ operation: String?) {
        guard let operation else {
            bannerHeight.constant = 0
            banner.isHidden = true
            return
        }
        banner.isHidden = false
        bannerHeight.constant = 26
        let labels = ["merge": "合并", "rebase": "变基", "cherry-pick": "挑拣", "revert": "还原"]
        let conflicts = state?.conflictedCount ?? 0
        bannerLabel.stringValue = "\(labels[operation] ?? operation) 进行中"
            + (conflicts > 0 ? " · \(conflicts) 个文件冲突待解决" : " · 解决后点「继续」")
    }

    @objc private func doContinueOperation() {
        guard let op = state?.operation else { return }
        GitService.shared.continueOperation(op) { [weak self] result in
            guard let self else { return }
            self.refreshNow()
            if result.ok {
                AppState.shared.postStatus("已继续\(op)")
            } else {
                // The output normally says what still needs resolving.
                self.showErrorAlert(result.combined.trimmed.isEmpty
                                    ? "继续\(op)失败" : result.combined.trimmed)
            }
        }
    }

    @objc private func doSkipOperation() {
        guard let op = state?.operation else { return }
        // The result used to be discarded entirely: a failed skip said nothing
        // and left the user stuck mid-operation with no explanation.
        GitService.shared.skipOperation(op) { [weak self] result in
            guard let self else { return }
            self.refreshNow()
            if result.ok {
                AppState.shared.postStatus("已跳过当前提交")
            } else {
                self.showErrorAlert(result.combined.trimmed.isEmpty
                                    ? "跳过失败" : result.combined.trimmed)
            }
        }
    }

    @objc private func doAbortOperation() {
        guard let op = state?.operation else { return }
        let alert = NSAlert()
        alert.messageText = "中止\(op)？"
        alert.informativeText = "所有已解决的冲突会丢失，工作区回到操作开始前的状态。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "中止")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.abortOperation(op) { [weak self] result in
            guard let self else { return }
            self.refreshNow()
            if result.ok {
                AppState.shared.postStatus("已中止\(op)，工作区已回到操作前")
            } else {
                self.showErrorAlert(result.combined.trimmed.isEmpty
                                    ? "中止\(op)失败" : result.combined.trimmed)
            }
        }
    }

    // MARK: - Remote operations

    private func beginOperation(_ title: String) {
        outputHeight.constant = 96
        outputScroll.isHidden = false
        outputView.string = ""
        appendOutput("$ \(title)")
    }

    private func appendOutput(_ text: String) {
        guard !text.isEmpty else { return }
        outputView.string += text.hasSuffix("\n") ? text : text + "\n"
        outputView.scrollToEndOfDocument(nil)
    }

    @objc private func toggleOutput() {
        let showing = outputHeight.constant > 0
        outputHeight.constant = showing ? 0 : 96
        outputScroll.isHidden = showing
    }

    @objc func doFetch() {
        beginOperation("git fetch --all --prune")
        GitService.shared.fetch { [weak self] text in
            self?.appendOutput(text.trimmed)
        } onExit: { [weak self] code in
            self?.appendOutput(code == 0 ? "✓ 获取完成" : "✗ 获取失败（退出码 \(code)）")
            self?.refreshNow()
        }
    }

    @objc func doPull() {
        beginOperation("git pull")
        GitService.shared.pull(rebase: false) { [weak self] text in
            self?.appendOutput(text.trimmed)
        } onExit: { [weak self] code in
            self?.appendOutput(code == 0 ? "✓ 拉取完成" : "✗ 拉取失败，可能有冲突需要解决")
            self?.refreshNow()
        }
    }

    @objc private func doPullRebase() {
        beginOperation("git pull --rebase")
        GitService.shared.pull(rebase: true) { [weak self] text in
            self?.appendOutput(text.trimmed)
        } onExit: { [weak self] code in
            self?.appendOutput(code == 0 ? "✓ 拉取并变基完成" : "✗ 变基过程出现问题，请查看输出")
            self?.refreshNow()
        }
    }

    @objc func doPush() {
        beginOperation("git push")
        GitService.shared.push(setUpstream: !(state?.hasUpstream ?? false),
                               remote: "origin", branch: state?.branch) { [weak self] text in
            self?.appendOutput(text.trimmed)
        } onExit: { [weak self] code in
            self?.appendOutput(code == 0 ? "✓ 推送完成" : "✗ 推送失败：如果远端有新提交，请先拉取；如果需要认证，请在终端执行一次 git push")
            self?.refreshNow()
        }
    }

    @objc private func showUndoMenu() {
        let menu = NSMenu()

        let info = NSMenuItem(title: "选择要撤销的操作", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        let softItem = NSMenuItem(title: "撤销上一次提交（保留改动在暂存区）",
                                  action: #selector(undoLastCommit), keyEquivalent: "")
        softItem.target = self
        menu.addItem(softItem)

        let upstreamItem = NSMenuItem(title: "回退到远程分支（保留改动，远端不变）",
                                      action: #selector(resetToUpstream), keyEquivalent: "")
        upstreamItem.target = self
        upstreamItem.isEnabled = state?.hasUpstream ?? false
        menu.addItem(upstreamItem)

        menu.addItem(.separator())

        let forceItem = NSMenuItem(title: "强制推送覆盖远程（force-with-lease）",
                                   action: #selector(forcePush), keyEquivalent: "")
        forceItem.target = self
        menu.addItem(forceItem)

        let undoPushItem = NSMenuItem(title: "撤回上一次 push（远端回退到指定提交）",
                                      action: #selector(undoPushDialog), keyEquivalent: "")
        undoPushItem.target = self
        menu.addItem(undoPushItem)

        menu.addItem(.separator())
        let branchFromItem = NSMenuItem(title: "从当前提交新建分支（备份用）",
                                        action: #selector(backupBranch), keyEquivalent: "")
        branchFromItem.target = self
        menu.addItem(branchFromItem)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: view.bounds.width - 150, y: 30),
                   in: view)
    }

    @objc private func undoLastCommit() {
        let alert = NSAlert()
        alert.messageText = "撤销上一次提交？"
        alert.informativeText = "提交会被移除，改动保留在暂存区，可以修改后重新提交。"
        alert.addButton(withTitle: "撤销提交")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.undoLastCommit { [weak self] result in
            if result.ok {
                self?.appendOutput("✓ 已撤销上一次提交，改动仍在暂存区")
                AppState.shared.postStatus("已撤销上一次提交")
            } else {
                self?.showErrorAlert(result.combined.trimmed)
            }
            self?.refreshNow()
        }
    }

    @objc private func resetToUpstream() {
        guard let upstream = state?.upstreamName else { return }
        let alert = NSAlert()
        alert.messageText = "回退到 \(upstream)？"
        alert.informativeText = "本地领先的提交会被移除，改动保留在暂存区。远端不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "回退")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.resetToUpstream(mode: .soft) { [weak self] result in
            if result.ok { self?.appendOutput("✓ 已回退到 \(upstream)") }
            else { self?.showErrorAlert(result.combined.trimmed) }
            self?.refreshNow()
        }
    }

    @objc private func forcePush() {
        let alert = NSAlert()
        alert.messageText = "强制推送？"
        alert.informativeText = """
        会用本地分支覆盖远端分支。

        使用 --force-with-lease：如果远端在你上次拉取之后有新提交，推送会被拒绝，不会覆盖别人的工作。

        仅在你确定要改写远端历史时使用。
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "强制推送")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beginOperation("git push --force-with-lease")
        GitService.shared.push(forceWithLease: true, remote: "origin", branch: state?.branch) { [weak self] text in
            self?.appendOutput(text.trimmed)
        } onExit: { [weak self] code in
            self?.appendOutput(code == 0 ? "✓ 强制推送完成" : "✗ 强制推送被拒绝（远端可能已有新提交）")
            self?.refreshNow()
        }
    }

    @objc private func undoPushDialog() {
        let alert = NSAlert()
        alert.messageText = "撤回 push"
        alert.informativeText = """
        请输入要回退到的提交（短哈希或分支名），例如 HEAD~1 或 abc1234。

        ⚠️ 此操作会把本地分支重置到该提交，然后强制推送覆盖远端，之后的提交会从远端消失。
        建议先用「从当前提交新建分支」备份。
        """
        alert.alertStyle = .critical
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "HEAD~1"
        alert.accessoryView = field
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        let confirm = NSAlert()
        confirm.messageText = "确认把远端回退到 \(target)？"
        confirm.informativeText = "会执行：git reset --hard \(target) && git push --force-with-lease\n\n之后 \(target) 之后的提交会从远端移除。"
        confirm.alertStyle = .critical
        confirm.addButton(withTitle: "确认执行")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        beginOperation("git reset --hard \(target) && git push --force-with-lease")
        GitService.shared.undoPush(to: target, mode: .hard) { [weak self] text in
            self?.appendOutput(text.trimmed)
        } onExit: { [weak self] code in
            self?.appendOutput(code == 0 ? "✓ 远端已回退到 \(target)" : "✗ 操作失败，请查看输出")
            self?.refreshNow()
        }
    }

    @objc private func backupBranch() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(17)
        let name = "backup/\(stamp)"
        GitService.shared.createBranch(String(name), at: nil, checkout: false) { [weak self] result in
            if result.ok {
                self?.appendOutput("✓ 已创建备份分支 \(name)")
                AppState.shared.postStatus("已创建备份分支 \(name)")
            } else {
                self?.showErrorAlert(result.combined.trimmed)
            }
        }
    }

    func generateCommitMessageAction() {
        changesView.generateCommitMessage()
    }

    // MARK: - Diffs

    private func showWorkingTreeDiff(change: GitFileChange, staged: Bool) {
        GitService.shared.diff(path: change.path, staged: staged) { [weak self] text in
            guard let self else { return }
            let diffs = DiffParser.parse(text)
            guard !diffs.isEmpty else {
                self.appendOutput("（\(change.path) 没有可显示的差异）")
                return
            }
            let request = DiffRequest(diffs: diffs,
                                      title: change.displayName,
                                      subtitle: (staged ? "已暂存 · " : "工作区 · ") + change.directory)
            self.onShowDiff?(request)
        }
    }

    private func showCommitDiff(_ commit: GitCommit) {
        GitService.shared.showCommit(commit.hash) { [weak self] text in
            guard let self else { return }
            let diffs = DiffParser.parse(text)
            let request = DiffRequest(diffs: diffs,
                                      title: commit.shortHash,
                                      subtitle: commit.subject)
            self.onShowDiff?(request)
        }
    }

    // MARK: - Errors

    private func showErrorAlert(_ message: String) {
        guard !message.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Git 操作失败"
        alert.informativeText = message.count > 1200 ? String(message.prefix(1200)) + "…" : message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
