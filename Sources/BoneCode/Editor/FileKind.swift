import AppKit

/// What a file actually is, decided by **content first** and extension second.
///
/// Extension alone is not enough in either direction: a screenshot saved as
/// `img.jpg` is an image (obviously), but so is a PNG named `blob.dat`; and a
/// `.txt` full of JPEG bytes should not be rendered as text. Conversely a `.png`
/// that is really a Git LFS pointer or an error page must not be sent to the
/// image decoder.
enum FileKind {
    case text
    case image
    case binary

    /// Extensions `NSImage` can decode, used only as a hint.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff",
        "webp", "heic", "heif", "icns", "ico", "pict", "tga", "exr"
    ]

    static func isImageExtension(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Classify a file by reading just enough of it to know.
    ///
    /// Only the first 512 bytes are inspected, so this is safe on huge files.
    static func detect(url: URL) -> FileKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return isImageExtension(url) ? .image : .text
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        return classify(head: head, url: url)
    }

    /// The decision, split out so it can be asserted without touching disk.
    static func classify(head: Data, url: URL) -> FileKind {
        if isKnownImageMagic(head) { return .image }
        if isKnownBinaryMagic(head) || looksBinary(head) { return .binary }
        // A `.png` that is really a Git LFS pointer or a saved error page is
        // text, and showing it beats failing to decode it as an image.
        return .text
    }

    /// Formats that are definitively not text, by signature.
    ///
    /// The byte-ratio heuristic below cannot catch everything: a Mach-O header is
    /// `CF FA ED FE`, which contains no NUL and no control bytes, so a short
    /// sample looks like text. Signatures cover those cases exactly.
    static func isKnownBinaryMagic(_ data: Data) -> Bool {
        if isKnownImageMagic(data) { return true }

        func ascii(_ s: String, at offset: Int = 0) -> Bool {
            let bytes = Array(s.utf8)
            guard offset + bytes.count <= data.count else { return false }
            for (i, b) in bytes.enumerated() where data[data.startIndex + offset + i] != b {
                return false
            }
            return true
        }
        func starts(_ bytes: [UInt8]) -> Bool {
            guard data.count >= bytes.count else { return false }
            for (i, b) in bytes.enumerated() where data[data.startIndex + i] != b { return false }
            return true
        }

        // Archives
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return true }  // ZIP/JAR
        if starts([0x1F, 0x8B]) { return true }                                  // GZIP
        if starts([0x42, 0x5A, 0x68]) { return true }                            // BZIP2
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return true }          // XZ
        if starts([0x37, 0x7A, 0xBC, 0xAF]) { return true }                      // 7-Zip
        if ascii("!<arch>") { return true }                                      // ar / .deb
        // Executables and objects
        if starts([0x7F, 0x45, 0x4C, 0x46]) { return true }                      // ELF
        if starts([0xCF, 0xFA, 0xED, 0xFE]) || starts([0xCE, 0xFA, 0xED, 0xFE]) { return true }  // Mach-O
        if starts([0xFE, 0xED, 0xFA, 0xCF]) || starts([0xFE, 0xED, 0xFA, 0xCE]) { return true }
        if starts([0xCA, 0xFE, 0xBA, 0xBE]) { return true }                      // Java class
        if starts([0x00, 0x61, 0x73, 0x6D]) { return true }                      // WebAssembly
        if starts([0x4D, 0x5A]) { return true }                                  // PE / DOS
        // Documents and data
        if ascii("%PDF") { return true }
        if ascii("SQLite format 3") { return true }
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return true }                      // OLE (old Office)
        if starts([0x89, 0x48, 0x44, 0x46]) { return true }                      // HDF5
        // Media
        if starts([0x49, 0x44, 0x33]) || starts([0xFF, 0xFB]) { return true }    // MP3
        if starts([0x4F, 0x67, 0x67, 0x53]) { return true }                      // Ogg
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return true }                      // Matroska/WebM
        if starts([0x46, 0x4C, 0x56]) { return true }                            // FLV
        if data.count >= 12, ascii("ftyp", at: 4) { return true }                // MP4 / MOV / HEIF
        if data.count >= 12, ascii("RIFF", at: 0) { return true }                // WAV / AVI / WebP
        return false
    }

    /// A NUL byte, or a high share of control characters, means the bytes are
    /// not text.
    ///
    /// This matters because `String(data:encoding:.isoLatin1)` **never fails** —
    /// it maps every byte to a character. So the old loader's last-resort
    /// Latin-1 fallback turned a JPEG into a page of mojibake instead of
    /// reporting a binary file. The check has to happen *before* that fallback.
    static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // A UTF-16 BOM means NUL bytes are expected.
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) { return false }
        }

        var control = 0
        for byte in data {
            if byte == 0x00 { return true }                 // decisive
            let isTextControl = byte == 0x09 || byte == 0x0A || byte == 0x0D
                || byte == 0x0C || byte == 0x1B
            if byte < 0x20 && !isTextControl { control += 1 }
        }
        // The ratio is meaningless on a tiny sample: two stray bytes in a
        // five-byte file is 40 %, but such a file is harmless to display.
        guard data.count >= 32 else { return false }
        return control * 10 > data.count                    // > 10 % control bytes
    }

    /// Recognises the formats by their leading bytes.
    ///
    /// Extension is deliberately ignored here: the point of a magic-number check
    /// is to catch a file whose name lies.
    static func isKnownImageMagic(_ data: Data) -> Bool {
        func byte(_ i: Int) -> UInt8? { i < data.count ? data[data.startIndex + i] : nil }
        func matches(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            for (i, b) in bytes.enumerated() where byte(offset + i) != b { return false }
            return !bytes.isEmpty && offset + bytes.count <= data.count
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool {
            matches(Array(s.utf8), at: offset)
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        // JPEG: FF D8 FF
        if matches([0xFF, 0xD8, 0xFF]) { return true }
        // GIF87a / GIF89a
        if ascii("GIF87a") || ascii("GIF89a") { return true }
        // BMP: "BM"
        if matches([0x42, 0x4D]) { return true }
        // TIFF: little- or big-endian
        if matches([0x49, 0x49, 0x2A, 0x00]) || matches([0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // WebP: "RIFF" ???? "WEBP"
        if ascii("RIFF"), ascii("WEBP", at: 8) { return true }
        // HEIC / HEIF / AVIF: ISO-BMFF `ftyp` box
        if ascii("ftyp", at: 4) {
            for brand in ["heic", "heix", "hevc", "heim", "heis", "heif",
                          "mif1", "msf1", "avif"] where ascii(brand, at: 8) {
                return true
            }
        }
        // ICNS: "icns"
        if ascii("icns") { return true }
        // ICO / CUR: 00 00 01 00 / 00 00 02 00
        if matches([0x00, 0x00, 0x01, 0x00]) || matches([0x00, 0x00, 0x02, 0x00]) { return true }
        return false
    }

    /// Human-readable label for the status bar and the preview header.
    static func describe(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return "文件" }
        return ext.uppercased()
    }
}
