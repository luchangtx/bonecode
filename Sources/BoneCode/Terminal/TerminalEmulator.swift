import AppKit
import Foundation

// MARK: - Cell

struct TermCell {
    var ch: UInt32 = 32
    /// -1 = default, 0...255 = palette index, -2 = truecolor (use fgRGB)
    var fgIndex: Int16 = -1
    var bgIndex: Int16 = -1
    var fgRGB: UInt32 = 0
    var bgRGB: UInt32 = 0
    var flags: UInt16 = 0
    var width: UInt8 = 1
    /// Second half of a double-width glyph; skipped when rendering.
    var isPad: Bool = false

    static let flagBold: UInt16 = 1 << 0
    static let flagItalic: UInt16 = 1 << 1
    static let flagUnderline: UInt16 = 1 << 2
    static let flagDim: UInt16 = 1 << 3
    static let flagReverse: UInt16 = 1 << 4
    static let flagStrike: UInt16 = 1 << 5
    static let flagFaint: UInt16 = 1 << 6
}

/// Resolves a palette index to a concrete colour for the active theme.
enum TerminalPalette {
    static func color(index: Int16, rgb: UInt32, isForeground: Bool, theme: Theme) -> NSColor? {
        switch index {
        case -1: return nil                       // caller substitutes the default
        case -2: return NSColor.hex(rgb)
        case 0...15:
            return theme.ansi[Int(index)]
        case 16...231:
            let i = Int(index) - 16
            let r = CGFloat((i / 36) % 6) / 5.0
            let g = CGFloat((i / 6) % 6) / 5.0
            let b = CGFloat(i % 6) / 5.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 232...255:
            let v = CGFloat(Int(index) - 232) / 23.0
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        default:
            return nil
        }
    }
}

// MARK: - Emulator

/// A VT100/xterm terminal emulator.
///
/// Scope: the sequences real CLI tools actually emit — SGR colour/attributes,
/// cursor movement, erase, scroll regions, insert/delete, alternate screen,
/// bracketed paste, OSC titles. Mouse reporting and sixel are out of scope.
final class TerminalEmulator {

    private(set) var cols: Int
    private(set) var rows: Int

    var onUpdate: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    /// Bytes the emulator wants to send back (device status reports etc).
    var onResponse: ((String) -> Void)?

    // Grid
    private var grid: [TermCell]
    private var lineWrapped: [Bool]
    private var scrollback: [[TermCell]] = []
    private let maxScrollbackLines = 3000

    // Cursor
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private(set) var cursorVisible = true
    private(set) var cursorShape = 0        // 0 block, 1 block-blink, 2 underline, 3 underline-blink, 4 bar, 5 bar-blink
    private var savedCursor: SavedCursor?

    private struct SavedCursor {
        var row: Int, col: Int
        var fg: Int16, bg: Int16
        var fgRGB: UInt32, bgRGB: UInt32
        var flags: UInt16
    }

    private struct GridBackup {
        var grid: [TermCell]
        var wrapped: [Bool]
        var row: Int, col: Int
    }
    private var mainBackup: GridBackup?
    private(set) var altScreenActive = false

    // Scroll region
    private var scrollTop = 0
    private var scrollBottom: Int

    // Current SGR state
    private var curFg: Int16 = -1
    private var curBg: Int16 = -1
    private var curFgRGB: UInt32 = 0
    private var curBgRGB: UInt32 = 0
    private var curFlags: UInt16 = 0

    // Modes
    private var insertMode = false
    private var originMode = false
    private var autoWrap = true
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var mouseReporting = false
    private(set) var mouseSGR = false

    // Parser
    private enum ParserState {
        case ground, escape, escapeIntermediate, csi, csiIntermediate, osc, dcs, dcsEscape
    }
    private var state: ParserState = .ground
    private var params: [Int] = []
    private var currentParam: Int?
    private var privateMarker: UInt8 = 0
    private var intermediate: UInt8 = 0
    private var oscBuffer: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var lastPrinted: UInt32 = 0

    private(set) var title: String = "终端"

    // MARK: Init

    init(cols: Int, rows: Int) {
        self.cols = max(20, cols)
        self.rows = max(4, rows)
        self.scrollBottom = self.rows - 1
        self.grid = TerminalEmulator.blankGrid(cols: self.cols, rows: self.rows, cell: TermCell())
        self.lineWrapped = [Bool](repeating: false, count: self.rows)
    }

    private static func blankGrid(cols: Int, rows: Int, cell: TermCell) -> [TermCell] {
        var g = [TermCell](repeating: cell, count: cols * rows)
        for i in 0..<g.count { g[i].ch = 32; g[i].isPad = false; g[i].width = 1 }
        return g
    }

    private func blankCell() -> TermCell {
        var c = TermCell()
        c.ch = 32
        c.fgIndex = -1
        c.bgIndex = curBg
        c.bgRGB = curBgRGB
        c.flags = 0
        c.width = 1
        c.isPad = false
        return c
    }

    // MARK: Public queries

    var scrollbackCount: Int { scrollback.count }
    var totalRows: Int { scrollback.count + rows }
    var cursorVirtualRow: Int { scrollback.count + cursorRow }

    func row(_ virtualRow: Int) -> ArraySlice<TermCell> {
        if virtualRow < scrollback.count {
            let line = scrollback[virtualRow]
            return line[0..<line.count]
        }
        let r = virtualRow - scrollback.count
        guard r >= 0, r < rows else { return [][...] }
        return grid[(r * cols)..<((r + 1) * cols)]
    }

    func isWrapped(_ virtualRow: Int) -> Bool {
        if virtualRow < scrollback.count { return false }
        let r = virtualRow - scrollback.count
        guard r >= 0, r < rows else { return false }
        return lineWrapped[r]
    }

    func clearScrollback() {
        scrollback.removeAll()
        onUpdate?()
    }

    func reset() {
        grid = TerminalEmulator.blankGrid(cols: cols, rows: rows, cell: blankCell())
        lineWrapped = [Bool](repeating: false, count: rows)
        cursorRow = 0; cursorCol = 0
        scrollTop = 0; scrollBottom = rows - 1
        curFg = -1; curBg = -1; curFlags = 0
        insertMode = false; originMode = false; autoWrap = true
        altScreenActive = false
        mainBackup = nil
        savedCursor = nil
        onUpdate?()
    }

    // MARK: Feed

    func feed(_ data: Data) {
        for byte in data {
            processByte(byte)
        }
        onUpdate?()
    }

    private func processByte(_ b: UInt8) {
        switch state {
        case .ground: groundByte(b)
        case .escape: escapeByte(b)
        case .escapeIntermediate: state = .ground
        case .csi: csiByte(b)
        case .csiIntermediate: csiIntermediateByte(b)
        case .osc: oscByte(b)
        case .dcs: if b == 0x1B { state = .dcsEscape }
        case .dcsEscape: state = (b == 0x5C) ? .ground : .dcs
        }
    }

    // MARK: Ground

    private func groundByte(_ b: UInt8) {
        switch b {
        case 0x1B:
            state = .escape
            params.removeAll(); currentParam = nil; privateMarker = 0; intermediate = 0
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            cursorCol = 0
        case 0x08:
            if cursorCol > 0 { cursorCol -= 1 }
        case 0x09:
            tabForward()
        case 0x07:
            onBell?()
        case 0x00...0x06, 0x0E...0x1A, 0x1C...0x1F:
            break
        default:
            if b < 0x80 {
                utf8Buffer.removeAll()
                putChar(UInt32(b))
            } else {
                accumulateUTF8(b)
            }
        }
    }

    private func accumulateUTF8(_ b: UInt8) {
        utf8Buffer.append(b)
        let first = utf8Buffer[0]
        let expected: Int
        if first & 0xE0 == 0xC0 { expected = 2 }
        else if first & 0xF0 == 0xE0 { expected = 3 }
        else if first & 0xF8 == 0xF0 { expected = 4 }
        else { utf8Buffer.removeAll(); return }
        if utf8Buffer.count < expected { return }
        if utf8Buffer.count > expected { utf8Buffer.removeFirst(utf8Buffer.count - expected) }
        let bytes = utf8Buffer
        utf8Buffer.removeAll()
        var scalar: UInt32 = 0
        switch expected {
        case 2:
            guard bytes[1] & 0xC0 == 0x80 else { return }
            scalar = UInt32(bytes[0] & 0x1F) << 6 | UInt32(bytes[1] & 0x3F)
        case 3:
            guard bytes[1] & 0xC0 == 0x80, bytes[2] & 0xC0 == 0x80 else { return }
            scalar = UInt32(bytes[0] & 0x0F) << 12 | UInt32(bytes[1] & 0x3F) << 6 | UInt32(bytes[2] & 0x3F)
        case 4:
            guard bytes[1] & 0xC0 == 0x80, bytes[2] & 0xC0 == 0x80, bytes[3] & 0xC0 == 0x80 else { return }
            scalar = UInt32(bytes[0] & 0x07) << 18 | UInt32(bytes[1] & 0x3F) << 12
                | UInt32(bytes[2] & 0x3F) << 6 | UInt32(bytes[3] & 0x3F)
        default: return
        }
        putChar(scalar)
    }

    // MARK: Escape

    private func escapeByte(_ b: UInt8) {
        switch b {
        case 0x5B: // [
            state = .csi
            params.removeAll(); currentParam = nil; privateMarker = 0; intermediate = 0
        case 0x5D: // ]
            state = .osc
            oscBuffer.removeAll()
        case 0x50: // P  (DCS)
            state = .dcs
        case 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F:
            state = .escapeIntermediate
        case 0x4D: // M  reverse index
            reverseIndex(); state = .ground
        case 0x44: // D  index
            lineFeed(); state = .ground
        case 0x45: // E  next line
            lineFeed(); cursorCol = 0; state = .ground
        case 0x37: // 7  save cursor
            saveCursor(); state = .ground
        case 0x38: // 8  restore cursor
            restoreCursor(); state = .ground
        case 0x63: // c  full reset
            hardReset(); state = .ground
        case 0x3D, 0x3E, 0x5C, 0x5A, 0x46, 0x47:
            state = .ground
        default:
            state = .ground
        }
    }

    private func hardReset() {
        curFg = -1; curBg = -1; curFlags = 0
        scrollTop = 0; scrollBottom = rows - 1
        insertMode = false; originMode = false; autoWrap = true
        cursorVisible = true
        altScreenActive = false
        mainBackup = nil
        grid = TerminalEmulator.blankGrid(cols: cols, rows: rows, cell: blankCell())
        cursorRow = 0; cursorCol = 0
    }

    // MARK: CSI

    private func csiByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            currentParam = min(65535, (currentParam ?? 0) * 10 + Int(b - 0x30))
        case 0x3B, 0x3A:
            params.append(currentParam ?? 0)
            currentParam = nil
        case 0x3C...0x3F:
            privateMarker = b
        case 0x20...0x2F:
            intermediate = b
            state = .csiIntermediate
        case 0x40...0x7E:
            if let cp = currentParam { params.append(cp); currentParam = nil }
            dispatchCSI(UnicodeScalar(b))
            state = .ground
        default:
            state = .ground
        }
    }

    private func csiIntermediateByte(_ b: UInt8) {
        if b >= 0x40, b <= 0x7E {
            if let cp = currentParam { params.append(cp); currentParam = nil }
            dispatchCSI(UnicodeScalar(b))
            state = .ground
        } else if b >= 0x30, b <= 0x39 {
            currentParam = min(65535, (currentParam ?? 0) * 10 + Int(b - 0x30))
        }
    }

    private func p(_ i: Int, _ fallback: Int = 0) -> Int {
        guard i < params.count else { return fallback }
        return params[i]
    }

    private func dispatchCSI(_ final: UnicodeScalar) {
        let p0 = p(0)
        switch final {
        case "A": cursorUp(max(1, p0))
        case "B": cursorDown(max(1, p0))
        case "C": cursorForward(max(1, p0))
        case "D": cursorBackward(max(1, p0))
        case "E": cursorDown(max(1, p0)); cursorCol = 0
        case "F": cursorUp(max(1, p0)); cursorCol = 0
        case "G", "`": cursorCol = clampCol((p0 == 0 ? 1 : p0) - 1)
        case "H", "f":
            let r = (p0 == 0 ? 1 : p0) - 1
            let c = (p(1, 1) == 0 ? 1 : p(1, 1)) - 1
            setCursor(row: r, col: c)
        case "d":
            setCursorRow((p0 == 0 ? 1 : p0) - 1)
        case "J": eraseInDisplay(p0)
        case "K": eraseInLine(p0)
        case "L": insertLines(max(1, p0))
        case "M": deleteLines(max(1, p0))
        case "P": deleteChars(max(1, p0))
        case "@": insertChars(max(1, p0))
        case "X": eraseChars(max(1, p0))
        case "S": scrollUpRegion(max(1, p0))
        case "T": scrollDownRegion(max(1, p0))
        case "m": applySGR()
        case "n": deviceStatusReport(p0)
        case "c": onResponse?("\u{1B}[?1;2c")
        case "r":
            let top = (p0 == 0 ? 1 : p0) - 1
            let bottom = (p(1, rows) == 0 ? rows : p(1, rows)) - 1
            if top < bottom {
                scrollTop = max(0, min(top, rows - 1))
                scrollBottom = max(scrollTop, min(bottom, rows - 1))
                setCursor(row: 0, col: 0)
            }
        case "s": saveCursor()
        case "u": restoreCursor()
        case "h": setModes(private: privateMarker == 0x3F, enabled: true)
        case "l": setModes(private: privateMarker == 0x3F, enabled: false)
        case "q":
            if intermediate == 0x20 { cursorShape = p0 }
        case "b":
            let n = max(1, p0)
            if lastPrinted != 0 { for _ in 0..<n { putChar(lastPrinted) } }
        case "g":
            break
        case "t":
            break
        default:
            break
        }
    }

    private func deviceStatusReport(_ mode: Int) {
        switch mode {
        case 5:
            onResponse?("\u{1B}[0n")
        case 6:
            let r = cursorRow + 1
            let c = cursorCol + 1
            onResponse?("\u{1B}[\(r);\(c)R")
        default:
            break
        }
    }

    // MARK: Modes

    private func setModes(private isPrivate: Bool, enabled: Bool) {
        let list = params.isEmpty ? [0] : params
        for mode in list {
            if isPrivate {
                switch mode {
                case 1: applicationCursorKeys = enabled
                case 6: originMode = enabled
                case 7: autoWrap = enabled
                case 25: cursorVisible = enabled
                case 47, 1047: switchAltScreen(enabled)
                case 1049: switchAltScreen(enabled, saveRestoreCursor: true)
                case 1000, 1002, 1003, 1005: mouseReporting = enabled
                case 1006: mouseSGR = enabled
                case 2004: bracketedPaste = enabled
                default: break
                }
            } else {
                switch mode {
                case 4: insertMode = enabled
                default: break
                }
            }
        }
    }

    private func switchAltScreen(_ on: Bool, saveRestoreCursor: Bool = false) {
        if on {
            guard !altScreenActive else { return }
            if saveRestoreCursor { saveCursor() }
            mainBackup = GridBackup(grid: grid, wrapped: lineWrapped, row: cursorRow, col: cursorCol)
            grid = TerminalEmulator.blankGrid(cols: cols, rows: rows, cell: blankCell())
            lineWrapped = [Bool](repeating: false, count: rows)
            cursorRow = 0; cursorCol = 0
            altScreenActive = true
            scrollTop = 0; scrollBottom = rows - 1
        } else {
            guard altScreenActive, let backup = mainBackup else { return }
            grid = backup.grid
            lineWrapped = backup.wrapped
            cursorRow = backup.row
            cursorCol = backup.col
            mainBackup = nil
            altScreenActive = false
            scrollTop = 0; scrollBottom = rows - 1
            if saveRestoreCursor { restoreCursor() }
        }
    }

    // MARK: SGR

    private func applySGR() {
        if params.isEmpty { resetSGR(); return }
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0: resetSGR()
            case 1: curFlags |= TermCell.flagBold
            case 2: curFlags |= TermCell.flagDim
            case 3: curFlags |= TermCell.flagItalic
            case 4: curFlags |= TermCell.flagUnderline
            case 7: curFlags |= TermCell.flagReverse
            case 9: curFlags |= TermCell.flagStrike
            case 21, 22: curFlags &= ~(TermCell.flagBold | TermCell.flagDim)
            case 23: curFlags &= ~TermCell.flagItalic
            case 24: curFlags &= ~TermCell.flagUnderline
            case 27: curFlags &= ~TermCell.flagReverse
            case 29: curFlags &= ~TermCell.flagStrike
            case 30...37: curFg = Int16(code - 30)
            case 39: curFg = -1
            case 40...47: curBg = Int16(code - 40)
            case 49: curBg = -1
            case 90...97: curFg = Int16(code - 90 + 8)
            case 100...107: curBg = Int16(code - 100 + 8)
            case 38, 48:
                let isFg = (code == 38)
                if i + 1 < params.count {
                    let mode = params[i + 1]
                    if mode == 5, i + 2 < params.count {
                        let idx = params[i + 2]
                        if isFg { curFg = Int16(clamping: idx) } else { curBg = Int16(clamping: idx) }
                        i += 2
                    } else if mode == 2, i + 4 < params.count {
                        let r = params[i + 2] & 0xFF
                        let g = params[i + 3] & 0xFF
                        let b = params[i + 4] & 0xFF
                        let rgb = UInt32(r << 16 | g << 8 | b)
                        if isFg { curFgRGB = rgb; curFg = -2 } else { curBgRGB = rgb; curBg = -2 }
                        i += 4
                    }
                }
            default: break
            }
            i += 1
        }
    }

    private func resetSGR() {
        curFg = -1; curBg = -1; curFlags = 0
    }

    // MARK: OSC

    private func oscByte(_ b: UInt8) {
        switch b {
        case 0x07: // BEL terminates the sequence
            finishOSC()
            state = .ground
        case 0x1B:
            state = .escape
            finishOSC()
        default:
            if oscBuffer.count < 4096 { oscBuffer.append(b) }
        }
    }

    private func finishOSC() {
        defer { oscBuffer.removeAll() }
        guard !oscBuffer.isEmpty else { return }
        let text = String(decoding: oscBuffer, as: UTF8.self)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = Int(parts.first ?? "0") else { return }
        let payload = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case 0, 1, 2:
            title = payload.isEmpty ? "终端" : payload
            onTitleChange?(title)
        default:
            break
        }
    }

    // MARK: Cursor movement

    private func clampCol(_ c: Int) -> Int { max(0, min(cols - 1, c)) }
    private func clampRow(_ r: Int) -> Int { max(0, min(rows - 1, r)) }

    private func cursorUp(_ n: Int) {
        let limit = (cursorRow >= scrollTop && cursorRow <= scrollBottom) ? scrollTop : 0
        cursorRow = max(limit, cursorRow - n)
    }

    private func cursorDown(_ n: Int) {
        let limit = (cursorRow >= scrollTop && cursorRow <= scrollBottom) ? scrollBottom : rows - 1
        cursorRow = min(limit, cursorRow + n)
    }

    private func cursorForward(_ n: Int) { cursorCol = clampCol(cursorCol + n) }
    private func cursorBackward(_ n: Int) { cursorCol = clampCol(cursorCol - n) }

    private func setCursor(row: Int, col: Int) {
        let r = originMode ? scrollTop + row : row
        cursorRow = clampRow(r)
        cursorCol = clampCol(col)
    }

    private func setCursorRow(_ row: Int) {
        cursorRow = clampRow(originMode ? scrollTop + row : row)
    }

    private func tabForward() {
        let next = ((cursorCol / 8) + 1) * 8
        cursorCol = clampCol(next)
    }

    private func saveCursor() {
        savedCursor = SavedCursor(row: cursorRow, col: cursorCol, fg: curFg, bg: curBg,
                                  fgRGB: curFgRGB, bgRGB: curBgRGB, flags: curFlags)
    }

    private func restoreCursor() {
        guard let s = savedCursor else { cursorRow = 0; cursorCol = 0; return }
        cursorRow = clampRow(s.row)
        cursorCol = clampCol(s.col)
        curFg = s.fg; curBg = s.bg
        curFgRGB = s.fgRGB; curBgRGB = s.bgRGB
        curFlags = s.flags
    }

    // MARK: Line feed / scroll

    private func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUpRegion(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDownRegion(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUpRegion(_ n: Int) {
        let top = scrollTop
        let bottom = min(scrollBottom, rows - 1)
        guard top <= bottom else { return }
        let count = min(n, bottom - top + 1)

        if top == 0, !altScreenActive {
            for r in 0..<count {
                let start = r * cols
                pushScrollback(Array(grid[start..<(start + cols)]))
            }
        }

        if bottom - count >= top {
            for r in top...(bottom - count) {
                let dst = r * cols
                let src = (r + count) * cols
                for c in 0..<cols { grid[dst + c] = grid[src + c] }
                lineWrapped[r] = lineWrapped[r + count]
            }
        }
        for r in max(top, bottom - count + 1)...bottom {
            clearRow(r)
        }
        if cursorRow > bottom - count, cursorRow >= top {
            cursorRow = max(top, bottom - count + 1)
        }
    }

    private func scrollDownRegion(_ n: Int) {
        let top = scrollTop
        let bottom = min(scrollBottom, rows - 1)
        guard top <= bottom else { return }
        let count = min(n, bottom - top + 1)

        if bottom - count >= top {
            for r in stride(from: bottom - count, through: top, by: -1) {
                let dst = (r + count) * cols
                let src = r * cols
                for c in 0..<cols { grid[dst + c] = grid[src + c] }
                lineWrapped[r + count] = lineWrapped[r]
            }
        }
        for r in top..<min(bottom + 1, top + count) {
            clearRow(r)
        }
    }

    private func pushScrollback(_ line: [TermCell]) {
        scrollback.append(line)
        if scrollback.count > maxScrollbackLines {
            scrollback.removeFirst(scrollback.count - maxScrollbackLines)
        }
    }

    private func clearRow(_ r: Int) {
        let start = r * cols
        let blank = blankCell()
        for c in 0..<cols { grid[start + c] = blank }
        lineWrapped[r] = false
    }

    // MARK: Erase

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows {
                for r in (cursorRow + 1)..<rows { clearRow(r) }
            }
        case 1:
            eraseInLine(1)
            if cursorRow > 0 {
                for r in 0..<cursorRow { clearRow(r) }
            }
        case 2:
            for r in 0..<rows { clearRow(r) }
        case 3:
            scrollback.removeAll()
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        let start = cursorRow * cols
        switch mode {
        case 0:
            for c in cursorCol..<cols { grid[start + c] = blankCell() }
        case 1:
            for c in 0...min(cursorCol, cols - 1) { grid[start + c] = blankCell() }
        case 2:
            for c in 0..<cols { grid[start + c] = blankCell() }
        default:
            break
        }
    }

    private func eraseChars(_ n: Int) {
        let start = cursorRow * cols
        for c in cursorCol..<min(cols, cursorCol + n) { grid[start + c] = blankCell() }
    }

    // MARK: Insert / delete

    private func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(n, scrollBottom - cursorRow + 1)
        for r in stride(from: scrollBottom - count, through: cursorRow, by: -1) {
            let dst = (r + count) * cols
            let src = r * cols
            for c in 0..<cols { grid[dst + c] = grid[src + c] }
        }
        for r in cursorRow..<(cursorRow + count) { clearRow(r) }
    }

    private func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(n, scrollBottom - cursorRow + 1)
        for r in cursorRow...(scrollBottom - count) {
            let dst = r * cols
            let src = (r + count) * cols
            for c in 0..<cols { grid[dst + c] = grid[src + c] }
        }
        for r in max(cursorRow, scrollBottom - count + 1)...scrollBottom { clearRow(r) }
    }

    private func insertChars(_ n: Int) {
        let start = cursorRow * cols
        let count = min(n, cols - cursorCol)
        guard count > 0 else { return }
        for c in stride(from: cols - 1 - count, through: cursorCol, by: -1) {
            grid[start + c + count] = grid[start + c]
        }
        for c in cursorCol..<(cursorCol + count) { grid[start + c] = blankCell() }
    }

    private func deleteChars(_ n: Int) {
        let start = cursorRow * cols
        let count = min(n, cols - cursorCol)
        guard count > 0 else { return }
        for c in cursorCol..<(cols - count) {
            grid[start + c] = grid[start + c + count]
        }
        for c in (cols - count)..<cols { grid[start + c] = blankCell() }
    }

    private func insertCharsAtCursor(_ n: Int) {
        insertChars(n)
    }

    // MARK: Character output

    private func width(of scalar: UInt32) -> Int {
        if scalar == 0 { return 0 }
        if scalar < 0x20 { return 1 }
        // Combining marks: zero width
        if (scalar >= 0x0300 && scalar <= 0x036F) || (scalar >= 0x1AB0 && scalar <= 0x1AFF)
            || (scalar >= 0x20D0 && scalar <= 0x20FF) || (scalar >= 0xFE00 && scalar <= 0xFE0F)
            || (scalar >= 0xFE20 && scalar <= 0xFE2F) {
            return 0
        }
        // East-Asian wide / fullwidth
        if (scalar >= 0x1100 && scalar <= 0x115F)
            || (scalar >= 0x2E80 && scalar <= 0x303E)
            || (scalar >= 0x3041 && scalar <= 0x33FF)
            || (scalar >= 0x3400 && scalar <= 0x4DBF)
            || (scalar >= 0x4E00 && scalar <= 0x9FFF)
            || (scalar >= 0xA000 && scalar <= 0xA4CF)
            || (scalar >= 0xA960 && scalar <= 0xA97F)
            || (scalar >= 0xAC00 && scalar <= 0xD7A3)
            || (scalar >= 0xF900 && scalar <= 0xFAFF)
            || (scalar >= 0xFE10 && scalar <= 0xFE19)
            || (scalar >= 0xFE30 && scalar <= 0xFE6F)
            || (scalar >= 0xFF00 && scalar <= 0xFF60)
            || (scalar >= 0xFFE0 && scalar <= 0xFFE6)
            || (scalar >= 0x1F300 && scalar <= 0x1F64F)
            || (scalar >= 0x1F900 && scalar <= 0x1F9FF)
            || (scalar >= 0x20000 && scalar <= 0x3FFFD) {
            return 2
        }
        return 1
    }

    private func putChar(_ scalar: UInt32) {
        let w = width(of: scalar)
        if w == 0 {
            // Fold combining marks into the preceding cell so they still render.
            var col = cursorCol - 1
            if col < 0 { col = 0 }
            let idx = cursorRow * cols + col
            if idx >= 0, idx < grid.count, grid[idx].isPad, col > 0 {
                let prev = cursorRow * cols + col - 1
                if prev >= 0 { grid[prev].ch = combine(grid[prev].ch, scalar) }
            } else if idx >= 0, idx < grid.count {
                grid[idx].ch = combine(grid[idx].ch, scalar)
            }
            lastPrinted = scalar
            return
        }

        if cursorCol + w > cols {
            if autoWrap {
                cursorCol = 0
                lineFeed()
                cursorCol = 0
            } else {
                cursorCol = max(0, cols - w)
            }
        }
        if cursorCol >= cols { cursorCol = max(0, cols - w) }

        if insertMode { insertCharsAtCursor(w) }

        let idx = cursorRow * cols + cursorCol
        guard idx >= 0, idx + w <= grid.count else { return }
        grid[idx].ch = scalar
        grid[idx].fgIndex = curFg
        grid[idx].bgIndex = curBg
        grid[idx].fgRGB = curFgRGB
        grid[idx].bgRGB = curBgRGB
        grid[idx].flags = curFlags
        grid[idx].width = UInt8(w)
        grid[idx].isPad = false
        if w == 2 {
            grid[idx + 1].ch = 0
            grid[idx + 1].isPad = true
            grid[idx + 1].width = 1
            grid[idx + 1].fgIndex = curFg
            grid[idx + 1].bgIndex = curBg
            grid[idx + 1].bgRGB = curBgRGB
            grid[idx + 1].flags = curFlags
        }
        cursorCol += w
        lineWrapped[cursorRow] = false
        lastPrinted = scalar
    }

    private func combine(_ base: UInt32, _ mark: UInt32) -> UInt32 {
        // Best effort: keep the base glyph. A real implementation would build a
        // grapheme cluster; for a code terminal this is not worth the complexity.
        base
    }

    // MARK: Resize

    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(20, newCols), nr = max(4, newRows)
        guard nc != cols || nr != rows else { return }

        var newGrid = TerminalEmulator.blankGrid(cols: nc, rows: nr, cell: blankCell())
        var newWrapped = [Bool](repeating: false, count: nr)

        // Shrinking vertically: push the rows that fall off the top into history.
        let lostRows = max(0, rows - nr)
        if lostRows > 0, !altScreenActive {
            for r in 0..<lostRows {
                let start = r * cols
                pushScrollback(Array(grid[start..<(start + cols)]))
            }
        }

        let copyRows = min(nr, max(0, rows - lostRows))
        for r in 0..<copyRows {
            let srcRow = r + lostRows
            let dstStart = r * nc
            let srcStart = srcRow * cols
            let copyCols = min(nc, cols)
            for c in 0..<copyCols {
                newGrid[dstStart + c] = grid[srcStart + c]
            }
            newWrapped[r] = lineWrapped[srcRow]
        }

        grid = newGrid
        lineWrapped = newWrapped
        cols = nc
        rows = nr
        scrollTop = 0
        scrollBottom = nr - 1
        cursorRow = clampRow(cursorRow - lostRows)
        cursorCol = clampCol(cursorCol)
        onUpdate?()
    }
}
