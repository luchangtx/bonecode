import AppKit

// Entry point. We deliberately avoid @main / NSApplicationMain so the app can
// be built as a plain SwiftPM executable and wrapped into a .app bundle, with
// no storyboard or nib anywhere in the project.

// `BoneCode --selftest` exercises the engines headlessly and exits.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.runEngines() ? 0 : 1)
}

// `BoneCode --uitest` builds a real window hierarchy. AppKit can stall when
// creating a window in a headless process, so a watchdog turns a hang into a
// clear failure instead of an infinite wait.
if CommandLine.arguments.contains("--uitest") {
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
        FileHandle.standardError.write(Data("\nUITEST TIMEOUT: 界面自检超过 90 秒未完成\n".utf8))
        exit(3)
    }
    exit(SelfTest.runUI() ? 0 : 1)
}

// `BoneCode --bench [directory]` opens every file through the real editor path
// and reports per-file timing, to find pathological inputs.
if let index = CommandLine.arguments.firstIndex(of: "--bench") {
    let target = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : FileManager.default.currentDirectoryPath
    exit(SelfTest.bench(directory: target) ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
