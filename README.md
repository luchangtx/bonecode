# BoneCode

原生 · 轻量 · 面向 AI 的 macOS 代码编辑器。

纯 **Swift + AppKit** 手写，不依赖 Electron、不依赖任何第三方库、不需要完整 Xcode。
目标是做一个"打开就想用"的 IDE：保留 IDEA 里真正高频的能力（写代码、Git 可视化、
跑 Spring Boot / Vue），把剩下的重量去掉。

```
dist/BoneCode.app        3.5 MB 可执行文件 · 零第三方依赖
```

---

## 功能

### 编辑器
- **36 种语言的语法高亮**：手写线性扫描器（不是正则堆叠），支持多行状态
  —— 块注释嵌套、模板字符串、三引号、Vue/HTML 内嵌 JS 与 CSS 的混合语法。
- **智能补全**（`⌃Space` 或自动触发）
  - 项目级符号索引：扫描整个工程提取 class / interface / function / const
  - 本文件词频排序：你刚写过的名字排前面
  - 成员补全：输入 `.` 后优先给出该文件里出现过的成员名
  - 内置代码片段：`psvm` `sout` `fori` `ref` `computed` `ifmain` `iferr` …
- **编辑体验**：行号、当前行高亮、括号匹配、自动补全括号与引号、
  自动缩进、智能 `}` 展开、`Tab` 对齐到制表位、多行缩进/反缩进
- 行操作：切换注释、复制行、删除行、上下移动行、结构化重排缩进
- 查找替换（原生 find bar，支持增量搜索）

### Git 可视化
| 能力 | 说明 |
|---|---|
| 变更面板 | 暂存/未暂存分组，单个或批量暂存，丢弃改动（带确认与警告） |
| 提交 | 提交 / 提交并推送 / 修正上次提交；**AI 生成提交信息** |
| 提交图谱 | 自己实现泳道布局算法，彩色连线 + 分支合并可视化 |
| 分支 | 本地/远程列表、检出、新建、重命名、删除、合并、变基、推送 |
| 挑拣 | 多选提交 → cherry-pick 到当前分支 |
| 还原 | revert 生成反向提交 |
| 重置 | 软 / 混合 / 硬重置，硬重置有二次警告 |
| 贮藏 | 贮藏、应用、弹出、删除 |
| 冲突 | 识别冲突文件，操作进行中横幅提供「继续 / 跳过 / 中止」 |
| **撤回 push** | ① 撤销上一次提交（保留改动）② 回退到远程分支 ③ `push --force-with-lease` ④ 远端回退到指定提交（含备份分支一键创建） |

### 集成终端
- **真 PTY**（`forkpty`），所以 `Ctrl-C`、`Ctrl-Z`、`fg`、作业控制都正常工作
- **自己写的 VT100/xterm 模拟器**：SGR 颜色（16 色 / 256 色 / 真彩色）、
  光标移动、擦除、滚动区、插入删除、备用屏、OSC 标题、设备状态应答
- **中文宽字符正确对齐**（按显示宽度占两格，不会错位）
- 滚动历史 3000 行、选中复制、粘贴（支持 bracketed paste）、
  输入法（IME）可用、字号可调、多标签
- **AI 命令栏**：用中文描述你要做什么，生成可执行命令，确认后送入终端

### 运行项目
自动探测并生成运行配置：
- **Spring Boot**：识别 `pom.xml` / `build.gradle`，优先用 `./mvnw` 包装器，
  从 `application.properties` 读出端口号，提供 `spring-boot:run` 与打包/测试配置
- **Vue / Vite / Next / React / Svelte / Express**：读取 `package.json` scripts，
  自动选择 `npm` / `pnpm` / `yarn` / `bun`，缺少 `node_modules` 时先装依赖
- **Go / Rust / Python（含 Django）/ Docker Compose / Make**
- 运行后自动探测输出里的 `http://localhost:PORT` 并打开浏览器

### AI 助手
兼容任何 OpenAI 格式接口（OpenAI、DeepSeek、Kimi、通义、Ollama、vLLM、LM Studio…）。

- 流式对话，自动注入当前文件 / 选中代码 / 光标位置 / Git 状态 / 最近终端输出
- 快捷动作：解释代码、找 Bug、写测试、审查改动
- **代码可直接应用回编辑器**：替换选中内容 / 插入到光标处
- 生成提交信息、审查 diff
- API Key 存在 **macOS 钥匙串**，不落盘到配置文件

### 其他
- 浅色 / 深色双主题（跟随系统，`⌘⌥T` 切换），IDEA 风格配色
- 项目文件树：FSEvents 实时刷新、右键新建/重命名/复制/移到废纸篓/在 Finder 显示
- 快速打开 `⌘P`（模糊匹配）+ 项目内搜索 `⌘⇧F`（grep，可点击跳转到行）
- 最近打开记录、标签页管理

---

## 构建

只需要 macOS 命令行工具（Command Line Tools），不需要完整 Xcode：

```bash
cd BoneCode
./build.sh              # debug 构建 + 打包 .app
./build.sh release      # 优化构建
./build.sh release run  # 构建并启动
./build.sh release dmg  # 构建并打包成分发用磁盘映像
```

产物在 `dist/BoneCode.app`，可以直接拖进「应用程序」。

> **为什么脚本里要加 `--disable-sandbox`？**
> SwiftPM 编译 manifest 时会调用 `sandbox-exec`，在受限环境下会失败并报
> `sandbox-exec: sandbox_apply: Operation not permitted`。加这个参数绕过即可。

### 打包 DMG

```bash
./build.sh release dmg          # 等价于先构建再打包
tools/make-dmg.sh --no-build    # 只打包 dist/ 里已有的 .app
```

产出 `dist/BoneCode-<版本号>.dmg`（含同名 `.sha256` 校验文件）。映像里是应用本体
加上一个指向 `/Applications` 的快捷方式，打开后拖过去即可安装。

版本号从 `Info.plist` 的 `CFBundleShortVersionString` 读取，所以文件名不会和包内
版本脱节。

> **关于 Gatekeeper**：`build.sh` 用的是临时签名（ad-hoc）。在本机运行没问题，
> 但下载到的副本会带上隔离属性，首次打开时 macOS 会拦下来，需要右键 →「打开」，
> 或者执行 `xattr -dr com.apple.quarantine /Applications/BoneCode.app`。
> 想做到下载即开不报警，需要 Developer ID 证书 + 公证；打包前设置环境变量
> `SIGN_ID="Developer ID Application: 你的名字 (TEAMID)"` 即可让脚本改用正式签名。

### 自检

编辑器、Git、终端这些核心引擎可以在无界面环境下自测：

```bash
./dist/BoneCode.app/Contents/MacOS/BoneCode --selftest   # 引擎（不建窗口，稳定）
./dist/BoneCode.app/Contents/MacOS/BoneCode --uitest     # 界面（建真实窗口，需图形环境）
./dist/BoneCode.app/Contents/MacOS/BoneCode --bench DIR  # 逐文件打开计时，查卡顿
```

界面自检会创建真实 NSWindow。在无显示环境（SSH / 受限沙箱）下 AppKit 内部可能
停住，所以它单独成一个模式并带 90 秒看门狗——卡住会明确报超时，而不是无限等待。

覆盖 **476 项**断言（引擎 353 + 界面 123）：语法高亮（含 Vue 混合语法）、行内词级
diff、Diff 解析、补全排序、终端转义序列解析（含 256 色/真彩色/备用屏/宽字符）、
终端字格度量与光标定位、文件类型识别（图片魔数 / 二进制判定 / 编码回退链）、
分栏几何（拖动线性响应、富余空间归属、惰性加载）、标签栏命中测试、
项目类型探测、真实 Git 仓库操作（提交/暂存/日志/图谱/分支/贮藏/cherry-pick/
revert/reset/撤销提交）、**真实 PTY 端到端**（分配 PTY、shell 交互、
ANSI 颜色、窗口 resize、退出码传递），以及**整套界面构建冒烟测试**
（构建真实窗口层级、打开工作区与文件、打开差异页与图片预览、强制布局、
切换主题与设置、关闭工作区）。

> 界面冒烟测试这一项不是凑数：它在开发过程中真的抓到了两个启动即崩溃的缺陷
> —— `NSViewController` 视图加载顺序导致的无限递归，以及折叠面板的视图
> 未被加载时创建终端会话。没有它，这两个问题只能在肉眼打开 App 时才发现。

---

## 快捷键

| 分类 | 快捷键 |
|---|---|
| 文件 | `⌘N` 新建 · `⌘O` 打开文件 · `⌘⇧O` 打开文件夹 · `⌘S` 保存 · `⌘⇧S` 全部保存 · `⌘W` 关闭标签 |
| 导航 | `⌘P` 快速打开 · `⌘⇧F` 项目内搜索 · `⌘L` 跳转到行 · `⌘⇧]` `⌘⇧[` 切换标签 |
| 编辑 | `⌃Space` 补全 · `⌘/` 注释 · `⌘D` 复制行 · `⌘⇧K` 删除行 · `⌥↑` `⌥↓` 移动行 · `⌘⌥F` 格式化选中 · `⌘F` 查找 |
| 视图 | `⌘0` 侧边栏 · `` ⌘` `` 终端 · `⌘⇧G` Git · `⌘⇧A` AI · `⌘+` `⌘-` 字号 · `⌘⌥T` 主题 |
| 运行 | `⌘R` 运行 · `⌘.` 停止 |
| Git | `⌘K` 提交 · `⌘⇧F` 搜索 |
| 终端 | `⌘K` 清屏 · `⌘C` `⌘V` 复制粘贴 · `⌃C` 中断 |

---

## 代码结构

```
Sources/BoneCode/
├── main.swift                     入口（含 --selftest 分支）
├── SelfTest.swift                 121 项无界面自检
├── App/
│   ├── AppDelegate.swift          生命周期 + 完整菜单栏
│   ├── MainWindowController.swift 三栏布局、工具栏、状态栏
│   ├── SidebarViewController.swift 项目/Git/运行 三合一侧栏
│   ├── AppState.swift             跨模块共享状态
│   ├── QuickOpen.swift            快速打开 + 项目内搜索
│   └── Theme.swift                双主题 + 语法配色
├── Editor/
│   ├── CodeTextView.swift         NSTextView 子类：行号、缩进、括号、补全接入
│   ├── SyntaxHighlighter.swift    手写线性扫描器（36 语言）
│   ├── Language.swift             语言定义表
│   ├── CompletionEngine.swift     补全排序 + 项目符号索引 + 代码片段
│   ├── CompletionPanel.swift      自绘补全弹窗
│   ├── EditorArea.swift           标签栏 + 标签管理 + 欢迎页
│   └── CodeEditorViewController.swift
├── Git/
│   ├── GitService.swift           全部 git 操作封装
│   ├── GitModels.swift            状态/提交模型 + Diff 解析 + 词级 diff
│   ├── GitGraphView.swift         泳道布局算法 + 图谱绘制
│   ├── GitViews.swift             变更/历史/分支/贮藏 四个视图
│   ├── GitPanelViewController.swift
│   └── DiffViewController.swift   统一 diff 视图
├── Terminal/
│   ├── PTY.swift                  forkpty 进程与会话管理
│   ├── TerminalEmulator.swift     VT100/xterm 解析器 + 屏幕缓冲
│   ├── TerminalView.swift         渲染、键盘编码、IME
│   └── TerminalPanelController.swift
├── Run/ProjectRunner.swift        项目探测与运行
├── AI/
│   ├── AIService.swift            OpenAI 兼容客户端（SSE 流式）
│   ├── AIPanelViewController.swift
│   └── Keychain.swift
├── Files/FileTreeViewController.swift  文件树 + FSEvents
└── Util/
    ├── Extensions.swift           颜色/字体/路径/通知等基础设施
    ├── ProcessRunner.swift        子进程执行与流式输出
    └── FileIcons.swift
```

---

## 设计取舍

**为什么不用 Electron / Tauri？**
一个空载的 Electron 编辑器就要 200–400 MB 内存。纯 AppKit 的同一件事在 100 MB 以内，
冷启动不到一秒。这是"轻量"唯一诚实的实现方式。

**为什么 Git 走命令行而不是自己实现对象数据库？**
重写一遍 packfile 解析和合并算法是一个独立项目，而且会丢掉用户已经配好的
credential helper、SSH agent、hooks、`.gitconfig` 别名。调用 `git` 反而更正确。

**为什么终端模拟器是自己写的？**
引入 SwiftTerm 这类依赖会破坏"零依赖、只靠 CLT 就能编译"这个前提。
自己实现覆盖 CLI 工具实际会发出的那部分转义序列，代码量可控且行为可预测。

**已知边界**
- 没有 LSP。补全基于符号索引与词频，不是语义分析，跨文件跳转/重命名不提供。
- 终端不支持鼠标上报（`vim` 里点选、`htop` 点击），不支持 sixel 图形。
- 大文件（>12 MB）会拒绝加载并提示用终端打开。
- `git push` 若需要交互式输入密码会失败（GUI 里挂起等待输入体验更差），
  提示用户先在终端执行一次以缓存凭据。
- 未做代码签名与公证，首次打开可能需要在「系统设置 → 隐私与安全性」里放行。
