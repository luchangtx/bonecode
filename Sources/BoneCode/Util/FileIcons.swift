import AppKit

/// Maps files to SF Symbols + accent colours for the tree and tabs.
enum FileIcons {

    private static let codeExtensions: Set<String> = [
        "java", "kt", "kts", "groovy", "gradle", "scala", "swift", "m", "mm", "c", "h", "cpp",
        "cc", "hpp", "cs", "go", "rs", "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "rb", "php",
        "lua", "pl", "r", "sql", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd"
    ]
    private static let markupExtensions: Set<String> = ["html", "htm", "vue", "svelte", "jsp", "ftl", "ejs", "hbs"]
    private static let styleExtensions: Set<String> = ["css", "scss", "sass", "less", "styl"]
    private static let configExtensions: Set<String> = [
        "json", "jsonc", "json5", "yaml", "yml", "toml", "properties", "ini", "cfg", "conf", "env", "lock"
    ]
    private static let docExtensions: Set<String> = ["md", "markdown", "mdx", "txt", "rst", "adoc", "log"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "tiff", "heic"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "jar", "war", "7z", "rar", "bz2", "xz", "dmg"]
    private static let dataExtensions: Set<String> = ["xml", "plist", "xsd", "csv", "tsv", "proto", "graphql", "gql"]

    static func symbolName(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if name.hasPrefix(".") && name.count > 1 && !name.contains(".") {
            return "gearshape"
        }
        switch name {
        case "dockerfile", "containerfile": return "shippingbox"
        case "makefile", "gnumakefile", "cmakelists.txt": return "hammer"
        case "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml": return "shippingbox"
        case "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle": return "hammer"
        default: break
        }
        if name == ".gitignore" || name == ".gitattributes" || name == ".dockerignore" { return "arrow.triangle.branch" }
        if name == ".env" || name.hasPrefix(".env.") { return "lock.doc" }

        if codeExtensions.contains(ext) {
            if ext == "sh" || ext == "bash" || ext == "zsh" || ext == "fish" { return "terminal" }
            if ext == "swift" { return "swift" }
            if ext == "sql" { return "cylinder" }
            return "chevron.left.forwardslash.chevron.right"
        }
        if markupExtensions.contains(ext) { return "globe" }
        if styleExtensions.contains(ext) { return "paintbrush" }
        if configExtensions.contains(ext) { return "gearshape" }
        if docExtensions.contains(ext) { return "doc.richtext" }
        if imageExtensions.contains(ext) { return "photo" }
        if archiveExtensions.contains(ext) { return "shippingbox" }
        if dataExtensions.contains(ext) { return "doc.text" }
        if ext == "pdf" { return "doc.viewfinder" }
        if ext == "diff" || ext == "patch" { return "plusminus.circle" }
        return "doc.text"
    }

    static func color(for url: URL, theme: Theme) -> NSColor {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle": return theme.diffAddedText
        case "package.json", "package-lock.json": return theme.diffRemovedText
        case "dockerfile", "containerfile": return theme.accent
        default: break
        }
        if codeExtensions.contains(ext) {
            switch ext {
            case "java": return theme.annotation
            case "kt", "kts": return theme.constant
            case "swift": return theme.diffRemovedText
            case "js", "jsx", "mjs", "cjs": return theme.constant
            case "ts", "tsx": return theme.accent
            case "py": return theme.function
            case "go": return theme.tag
            case "rs": return theme.constant
            case "sh", "bash", "zsh", "fish": return theme.diffAddedText
            case "sql": return theme.type
            default: return theme.function
            }
        }
        if markupExtensions.contains(ext) { return theme.tag }
        if styleExtensions.contains(ext) { return theme.accent }
        if configExtensions.contains(ext) { return theme.tertiaryText }
        if docExtensions.contains(ext) { return theme.secondaryText }
        if imageExtensions.contains(ext) { return theme.constant }
        if archiveExtensions.contains(ext) { return theme.annotation }
        return theme.secondaryText
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}
