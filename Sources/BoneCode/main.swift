import AppKit

// Entry point. We deliberately avoid @main / NSApplicationMain so the app can
// be built as a plain SwiftPM executable and wrapped into a .app bundle, with
// no storyboard or nib anywhere in the project.

// `BoneCode --selftest` exercises the engines headlessly and exits.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
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
