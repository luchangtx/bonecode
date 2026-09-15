import AppKit

/// A split view whose dividers actually move.
///
/// `NSSplitViewController` derives each item's usable size from its content's
/// Auto Layout priorities, and the limits it hands to a divider drag follow the
/// content's *preferred* size. The practical result is that a dense panel can be
/// neither narrowed nor widened past its natural size, and
/// `setPosition(_:ofDividerAt:)` — the call a drag makes — silently does nothing
/// once an item has a `holdingPriority`.
///
/// This uses a plain `NSSplitView`, which positions its subviews directly. The
/// limits are the ones declared here, nothing else.
final class PanelSplitViewController: NSViewController, NSSplitViewDelegate {

    struct Pane {
        let controller: NSViewController
        let minimum: CGFloat
        let maximum: CGFloat
        /// Size used the first time the view gets a real size.
        let initial: CGFloat
        let canCollapse: Bool
        let initiallyCollapsed: Bool
        /// The pane that absorbs spare space and yields it back first.
        ///
        /// Exactly one pane in a split should be flexible — in an editor that is
        /// the centre column. Without this, slack goes to whichever pane happens
        /// to be widest, so widening the window silently inflates a side panel
        /// up to its maximum and the centre never grows.
        let flexible: Bool

        init(controller: NSViewController, minimum: CGFloat, maximum: CGFloat,
             initial: CGFloat, canCollapse: Bool, initiallyCollapsed: Bool = false,
             flexible: Bool = false) {
            self.controller = controller
            self.minimum = minimum
            self.maximum = maximum
            self.initial = initial
            self.canCollapse = canCollapse
            self.initiallyCollapsed = initiallyCollapsed
            self.flexible = flexible
        }
    }

    private let split = ThemedSplitView()
    private var panes: [Pane]
    private var collapsed: [Bool]
    private var didApplyInitial = false
    private var isApplying = false
    /// The view currently occupying each pane's slot in the split view.
    ///
    /// A pane that starts collapsed gets a lightweight placeholder so its
    /// controller's view is never built until the user actually opens it.
    /// Building all three panels up front costs a terminal emulator, a Git
    /// panel and an AI panel of memory for something nobody is looking at.
    private var installed: [NSView] = []

    /// Exposed for layout assertions.
    var splitView: NSSplitView { split }
    var paneCount: Int { panes.count }

    init(vertical: Bool, panes: [Pane]) {
        self.panes = panes
        self.collapsed = Array(repeating: false, count: panes.count)
        super.init(nibName: nil, bundle: nil)
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // Set the view here rather than in init, so viewDidLoad still runs.
    override func loadView() {
        view = split
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for (index, pane) in panes.enumerated() {
            addChild(pane.controller)
            if pane.initiallyCollapsed {
                collapsed[index] = true
                let placeholder = NSView()
                placeholder.translatesAutoresizingMaskIntoConstraints = true
                placeholder.isHidden = true
                split.addSubview(placeholder)
                installed.append(placeholder)
            } else {
                let paneView = pane.controller.view
                configure(paneView)
                split.addSubview(paneView)
                installed.append(paneView)
            }
        }
        split.adjustSubviews()
    }

    // MARK: - Geometry

    /// Let the split view position this directly. Auto Layout still runs inside
    /// the panel — it just does not get to dictate its outer size.
    private func configure(_ paneView: NSView) {
        paneView.translatesAutoresizingMaskIntoConstraints = true
        paneView.autoresizingMask = split.isVertical ? [.height] : [.width]
    }

    /// Swaps a collapsed pane's placeholder for its real view, building that view
    /// only now.
    @discardableResult
    private func ensureInstalled(at index: Int) -> Bool {
        guard panes.indices.contains(index), installed.indices.contains(index) else { return false }
        let real = panes[index].controller.view        // this is what loads it
        guard installed[index] !== real else { return false }

        let old = installed[index]
        let frame = old.frame
        configure(real)
        split.replaceSubview(old, with: real)          // keeps the slot's z-order
        real.frame = frame
        real.isHidden = false
        installed[index] = real
        return true
    }

    private func extent() -> CGFloat {
        split.isVertical ? split.bounds.width : split.bounds.height
    }

    private func size(of subview: NSView) -> CGFloat {
        split.isVertical ? subview.frame.width : subview.frame.height
    }

    private func currentSizes() -> [CGFloat] {
        split.subviews.map { size(of: $0) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !isApplying else { return }
        let total = extent()
        guard total > 1, split.subviews.count == panes.count else { return }

        if !didApplyInitial {
            didApplyInitial = true
            apply(sizes: panes.map { $0.initial }, total: total)
        } else {
            apply(sizes: currentSizes(), total: total)
        }
    }

    /// The single place that writes geometry.
    ///
    /// Clamps to each pane's limits, then makes the panes fill the available
    /// space **exactly**. Getting this to fill exactly matters: if the frames do
    /// not line up with the split view's edges, `NSSplitView` logs
    /// "left the arranged view frames in an inconsistent state" and works around
    /// it with extra redraws.
    ///
    /// Space is taken from — and given to — the flexible pane first, so the
    /// centre column behaves like an editor: it grows with the window and
    /// shrinks first when the window gets tight.
    private func apply(sizes: [CGFloat], total: CGFloat) {
        guard sizes.count == panes.count, total > 1 else { return }
        let dividers = split.dividerThickness * CGFloat(panes.count - 1)

        var widths = sizes.enumerated().map { index, value -> CGFloat in
            collapsed[index] ? 0 : min(max(value, panes[index].minimum), panes[index].maximum)
        }

        /// Panes that may give up space, flexible first.
        func shrinkCandidates() -> [Int] {
            let usable = widths.indices.filter {
                !collapsed[$0] && widths[$0] - panes[$0].minimum > 0.5
            }
            let flexible = usable.filter { panes[$0].flexible }
            return flexible.isEmpty ? usable : flexible
        }

        var overflow = widths.reduce(0, +) + dividers - total
        while overflow > 0.5 {
            guard let widest = shrinkCandidates().max(by: { widths[$0] < widths[$1] }) else { break }
            let take = min(widths[widest] - panes[widest].minimum, overflow)
            widths[widest] -= take
            overflow -= take
        }

        var slack = total - dividers - widths.reduce(0, +)
        if slack > 0.5 {
            // The flexible pane has no meaningful ceiling — it is the editor.
            if let flexible = widths.indices.first(where: { !collapsed[$0] && panes[$0].flexible }) {
                widths[flexible] += slack
                slack = 0
            } else if let widest = widths.indices.filter({ !collapsed[$0] })
                .max(by: { widths[$0] < widths[$1] }) {
                let room = max(0, panes[widest].maximum - widths[widest])
                let take = min(room, slack)
                widths[widest] += take
                slack -= take
            }
        }

        // Last resort: if a declared maximum stopped us filling the extent, hand
        // the remainder to the last visible pane rather than leaving a gap.
        if slack > 0.5, let last = widths.indices.last(where: { !collapsed[$0] }) {
            widths[last] += slack
        }

        isApplying = true
        var origin: CGFloat = 0
        for (index, subview) in split.subviews.enumerated() where index < widths.count {
            let thickness = widths[index]
            if split.isVertical {
                subview.frame = NSRect(x: origin, y: 0,
                                       width: thickness, height: split.bounds.height)
            } else {
                subview.frame = NSRect(x: 0, y: origin,
                                       width: split.bounds.width, height: thickness)
            }
            origin += thickness + split.dividerThickness
        }
        isApplying = false
    }

    // MARK: - Programmatic control

    func setWidth(_ value: CGFloat, at index: Int) {
        guard panes.indices.contains(index), split.subviews.indices.contains(index) else { return }
        var widths = currentSizes()
        widths[index] = min(max(value, panes[index].minimum), panes[index].maximum)
        apply(sizes: widths, total: extent())
    }

    func width(at index: Int) -> CGFloat {
        guard split.subviews.indices.contains(index) else { return 0 }
        return size(of: split.subviews[index])
    }

    func isCollapsed(at index: Int) -> Bool {
        collapsed.indices.contains(index) ? collapsed[index] : false
    }

    func setCollapsed(_ flag: Bool, at index: Int) {
        guard panes.indices.contains(index), collapsed[index] != flag else { return }
        // Expanding a pane for the first time is when its view gets built.
        if !flag { ensureInstalled(at: index) }
        collapsed[index] = flag
        guard split.subviews.indices.contains(index) else { return }
        split.subviews[index].isHidden = flag

        var widths = currentSizes()
        if !flag { widths[index] = max(panes[index].initial, panes[index].minimum) }
        apply(sizes: widths, total: extent())
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        var minimum: CGFloat = 0
        for index in 0...min(dividerIndex, panes.count - 1) where !collapsed[index] {
            minimum += panes[index].minimum
        }
        minimum += splitView.dividerThickness * CGFloat(dividerIndex)
        return max(proposedMinimumPosition, minimum)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard panes.indices.contains(dividerIndex) else { return proposedMaximumPosition }

        // The pane left of this divider cannot exceed its own maximum.
        var leftStart: CGFloat = 0
        for index in 0..<dividerIndex where !collapsed[index] {
            leftStart += size(of: splitView.subviews[index]) + splitView.dividerThickness
        }
        let leftLimit = leftStart + panes[dividerIndex].maximum

        // Everything to the right must still fit at its minimum.
        var trailing: CGFloat = 0
        for index in (dividerIndex + 1)..<panes.count where !collapsed[index] {
            trailing += panes[index].minimum
        }
        trailing += splitView.dividerThickness * CGFloat(panes.count - 1 - dividerIndex)

        return min(proposedMaximumPosition, min(leftLimit, extent() - trailing))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        guard let index = splitView.subviews.firstIndex(of: subview) else { return false }
        return panes[index].canCollapse
    }

    /// Note the mismatch between the Swift name and the Objective-C selector:
    /// Swift imports this as `forDoubleClickOnDividerAt`, but the selector is
    /// `splitView:shouldCollapseSubview:forDoubleClickOnDividerAt**Index**:`.
    /// That difference is exactly what makes the "did I implement it?" check
    /// below worth having — a selector typo here fails silently at runtime.
    func splitView(_ splitView: NSSplitView,
                   shouldCollapseSubview subview: NSView,
                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        false       // double-clicking must not hide a panel by accident
    }

    /// Called when the split view needs to lay its subviews out for a new size
    /// (window resize, panel toggle). Implementing it means AppKit hands us full
    /// responsibility for the layout, so `apply` must clamp everything itself.
    ///
    /// Note the exact name: `resizeSubviewsWithOldSize`, **not**
    /// `didResizeSubviewsWithOldSize`. The latter nearly matches the optional
    /// requirement and compiles with only a warning, but is never called.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard !isApplying else { return }
        apply(sizes: currentSizes(), total: extent())
    }
}

/// An `NSSplitView` that follows the app theme for its divider.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { ThemeManager.shared.current.border }
    override var dividerThickness: CGFloat { 1 }
}
