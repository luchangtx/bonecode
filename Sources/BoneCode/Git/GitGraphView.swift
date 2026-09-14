import AppKit

// MARK: - Graph layout

struct GraphEdge {
    let fromLane: Int
    let toLane: Int
}

struct GraphRow {
    let nodeLane: Int
    let incomingLanes: [String?]
    let outgoingLanes: [String?]
    let edges: [GraphEdge]
    let laneCount: Int
}

/// Assigns each commit to a lane so the history can be drawn as a graph.
///
/// This is the standard "swimlane" algorithm: keep a list of lanes, each waiting
/// for a specific commit hash. When a commit arrives, take over its lane and push
/// its parents into lanes (reusing a free one where possible).
enum GitGraphLayout {

    static func compute(commits: [GitCommit], maxLanes: Int = 12) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []

        for commit in commits {
            var laneIndex = lanes.firstIndex { $0 == commit.hash }
            if laneIndex == nil {
                if let free = lanes.firstIndex(where: { $0 == nil }) {
                    laneIndex = free
                } else {
                    lanes.append(nil)
                    laneIndex = lanes.count - 1
                }
            }
            let nodeLane = laneIndex!
            if nodeLane >= lanes.count { lanes.append(nil) }
            let incoming = lanes

            var outgoing = lanes
            if commit.parents.isEmpty {
                outgoing[nodeLane] = nil
            } else {
                outgoing[nodeLane] = commit.parents[0]
                for parent in commit.parents.dropFirst() {
                    if outgoing.contains(where: { $0 == parent }) { continue }
                    if let free = outgoing.firstIndex(where: { $0 == nil }) {
                        outgoing[free] = parent
                    } else if outgoing.count < maxLanes {
                        outgoing.append(parent)
                    }
                }
            }

            var edges: [GraphEdge] = []
            for (l, h) in outgoing.enumerated() {
                guard let h else { continue }
                if l == nodeLane, commit.parents.first == h { continue }
                if incoming.indices.contains(l), incoming[l] == h { continue }
                edges.append(GraphEdge(fromLane: nodeLane, toLane: l))
            }
            // Parents that already had a lane are connected through that lane.
            for (pi, parent) in commit.parents.enumerated() {
                guard let pl = outgoing.firstIndex(where: { $0 == parent }) else { continue }
                if pl == nodeLane && pi == 0 { continue }
                if !edges.contains(where: { $0.toLane == pl }) {
                    edges.append(GraphEdge(fromLane: nodeLane, toLane: pl))
                }
            }

            while let last = outgoing.last, last == nil { outgoing.removeLast() }

            rows.append(GraphRow(
                nodeLane: nodeLane,
                incomingLanes: incoming,
                outgoingLanes: outgoing,
                edges: edges,
                laneCount: max(incoming.count, outgoing.count, nodeLane + 1)
            ))
            lanes = outgoing
        }
        return rows
    }
}

// MARK: - Cell

/// Draws one row of the commit graph. Adjacent rows line up because each cell
/// only paints the vertical band it owns.
final class GraphCellView: NSView {

    var row: GraphRow? { didSet { needsDisplay = true } }
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isFirstRow: Bool = false
    var laneWidth: CGFloat = 14

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let theme = ThemeManager.shared.current
        let h = bounds.height
        let mid = h / 2

        func x(_ lane: Int) -> CGFloat { CGFloat(lane) * laneWidth + laneWidth / 2 }
        func color(_ lane: Int) -> NSColor {
            theme.graphLanes[lane % theme.graphLanes.count]
        }

        let lineWidth: CGFloat = 1.6

        // 1. lanes that pass straight through this row
        for (l, hash) in row.outgoingLanes.enumerated() {
            guard hash != nil else { continue }
            if row.incomingLanes.indices.contains(l), row.incomingLanes[l] == hash {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x(l), y: 0))
                path.line(to: NSPoint(x: x(l), y: h))
                path.lineWidth = lineWidth
                color(l).setStroke()
                path.stroke()
            }
        }

        // 2. the incoming stub into the node
        let nodePath = NSBezierPath()
        nodePath.move(to: NSPoint(x: x(row.nodeLane), y: 0))
        nodePath.line(to: NSPoint(x: x(row.nodeLane), y: mid))
        nodePath.lineWidth = lineWidth
        color(row.nodeLane).setStroke()
        nodePath.stroke()

        // 3. edges from the node down to its parents
        for edge in row.edges {
            let from = NSPoint(x: x(edge.fromLane), y: mid)
            let to = NSPoint(x: x(edge.toLane), y: h)
            let path = NSBezierPath()
            if edge.fromLane == edge.toLane {
                path.move(to: from)
                path.line(to: to)
            } else {
                let c1 = NSPoint(x: from.x, y: mid + (h - mid) * 0.55)
                let c2 = NSPoint(x: to.x, y: mid + (h - mid) * 0.45)
                path.move(to: from)
                path.curve(to: to, controlPoint1: c1, controlPoint2: c2)
            }
            path.lineWidth = lineWidth
            color(edge.toLane).setStroke()
            path.stroke()
        }

        // 4. the node itself
        let radius: CGFloat = 3.6
        let center = NSPoint(x: x(row.nodeLane), y: mid)
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
        color(row.nodeLane).setFill()
        circle.fill()

        if isSelected {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 2, y: center.y - radius - 2,
                                                   width: radius * 2 + 4, height: radius * 2 + 4))
            ring.lineWidth = 1.2
            theme.text.setStroke()
            ring.stroke()
        }
    }
}
