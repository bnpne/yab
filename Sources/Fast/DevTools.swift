import AppKit
import SwiftUI
import WebKit

// Value-only ownership decision, shared by the request and late attachment.
enum LocalInspectorOwnership {
    enum Route: Equatable { case main, small, stale }
    static func route(page: ObjectIdentifier, main: ObjectIdentifier?, small: ObjectIdentifier?) -> Route {
        if main == page { return .main }
        if small == page { return .small }
        return .stale
    }
}

// Developer Tools: one card on the backdrop, under the page or beside it,
// on ⌥⌘I, for any page. Its head is Chrome's row in Chrome's order
// (DevHead.swift): WebKit's Web Inspector tabs shown inside the card, and
// yab's own Network, Security and Recorder where Chrome has those, the
// errors and warnings counted at the right (DevMode.swift).
//
// WebKit docks its inspector beside whatever view a page names as its
// attachment view (`_setInspectorAttachmentView:`), in that view's
// superview, and splits the two. So the card holds a dock: a view of its
// own with an anchor in it that nobody sees. WebKit docks the inspector in
// the dock, and the dock then gives it all of its room; the page itself is
// never touched. The anchor is large enough for WebKit to agree to dock at
// all (it wants 500 by 334 points), and it never says it has moved, so
// WebKit never lays the two out again after the inspector has arrived.
//
// The inspector's own page is WebKit's too (inspector-resource:). yab puts
// a stylesheet and a small script into it (DevTools.dress): its colors and
// type, its row of tabs and its dock buttons hidden while it is docked
// since yab's head does that, word back to yab when it moves to another tab
// by itself, as it does when an element is picked, and what the page said
// before the card listened.
//
// Everything WebKit answers here through is outside its public framework
// and asked for before use (Inspector.swift): without it the WebKit panes
// stay empty and yab's own lists still work.

enum DevPane: Hashable {
    case errors, warnings, network, security, recorder
    /// Yab's own panels on WebKit's protocol (DevWire.swift), Chrome's.
    case console, elements, sources, performance, memory, application, audit, layers
    case webkit(WebPane)
    /// A panel an extension adds to WebKit's inspector, React Developer
    /// Tools' Components or Profiler, by its title: WebKit's id for it is
    /// new in each page's inspector, the title stays.
    case panel(String)

    /// Shown by WebKit's inspector, docked in the card.
    var isWebKit: Bool {
        switch self {
        case .webkit, .panel: return true
        default: return false
        }
    }
}

extension DevPane {
    /// The pane as a word, to be kept.
    var saved: String {
        switch self {
        case .errors: return "errors"
        case .warnings: return "warnings"
        case .network: return "network"
        case .security: return "security"
        case .recorder: return "recorder"
        case .console: return "console"
        case .elements: return "elements"
        case .sources: return "sources"
        case .performance: return "performance"
        case .memory: return "memory"
        case .application: return "application"
        case .audit: return "audit"
        case .layers: return "layers"
        case .webkit(let pane): return "webkit:" + pane.rawValue
        case .panel(let title): return "panel:" + title
        }
    }

    init?(saved: String) {
        let own: [String: DevPane] = ["errors": .errors, "warnings": .warnings, "network": .network, "security": .security,
                                      "recorder": .recorder, "console": .console, "elements": .elements, "sources": .sources,
                                      "performance": .performance, "memory": .memory, "application": .application,
                                      "audit": .audit, "layers": .layers]
        if let pane = own[saved] { self = pane; return }
        if saved.hasPrefix("webkit:"), let pane = WebPane(rawValue: String(saved.dropFirst(7))) { self = .webkit(pane); return }
        if saved.hasPrefix("panel:"), saved.count > 6 { self = .panel(String(saved.dropFirst(6))); return }
        return nil
    }
}

/// What the developer tools were when they went away, kept for the next
/// time they come out and the next launch, as Chromium keeps them (#383):
/// the pane, the window they were undocked into and where it stood, device
/// mode and the device. Where they dock and their size are kept with the
/// rest of the card (Prefs.devSide, DevSize).
enum DevMemory {
    private static var store: UserDefaults { Store.settings }

    /// An extension's panel comes with its page's inspector: Elements
    /// stands in till then (panelWanted).
    static var pane: DevPane {
        get {
            let pane = store.string(forKey: "dev.pane").flatMap(DevPane.init(saved:)) ?? .errors
            if case .panel = pane { return .webkit(.elements) }
            // Inspect Element used to leave WebKit's Elements here, and ⌥⌘I
            // then opened WebKit's own view: Elements is Yab's.
            if pane == .webkit(.elements) { return .elements }
            return pane
        }
        set { store.set(newValue.saved, forKey: "dev.pane") }
    }

    static var panelWanted: String? {
        guard case .panel(let title)? = store.string(forKey: "dev.pane").flatMap(DevPane.init(saved:)) else { return nil }
        return title
    }

    /// Undocked into a window of their own.
    static var detached: Bool {
        get { store.bool(forKey: "dev.detached") }
        set { store.set(newValue, forKey: "dev.detached") }
    }

    /// The undocked window's frame, on the screen.
    static var window: NSRect? {
        get { store.string(forKey: "dev.window").map(NSRectFromString).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } }
        set { store.set(newValue.map(NSStringFromRect), forKey: "dev.window") }
    }

    /// Device mode was on when they went away.
    static var deviceOn: Bool {
        get { store.bool(forKey: "dev.device.on") }
        set { store.set(newValue, forKey: "dev.device.on") }
    }

    /// The device last shown, its size and zoom, on or off.
    static var device: DeviceMode? {
        get {
            guard let kept = store.dictionary(forKey: "dev.device"), let name = kept["name"] as? String,
                  let width = kept["width"] as? Double, let height = kept["height"] as? Double, width > 0, height > 0 else { return nil }
            return DeviceMode(name: name, width: CGFloat(width), height: CGFloat(height), userAgent: kept["ua"] as? String,
                              zoom: (kept["zoom"] as? Double).map { CGFloat($0) })
        }
        set {
            guard let device = newValue else { store.removeObject(forKey: "dev.device"); return }
            var kept: [String: Any] = ["name": device.name, "width": Double(device.width), "height": Double(device.height)]
            if let ua = device.userAgent { kept["ua"] = ua }
            if let zoom = device.zoom { kept["zoom"] = Double(zoom) }
            store.set(kept, forKey: "dev.device")
        }
    }

    /// A device a hand chose, or device mode turned off by one.
    static func remember(_ device: DeviceMode?) {
        if deviceOn != (device != nil) { deviceOn = device != nil }
        guard var device else { return }
        device.held = nil
        if self.device != device { self.device = device }
    }
}

/// A panel an extension added to the inspector of the page the card looks
/// at, as WebKit names it.
struct DevPanel: Hashable {
    let id: String
    let title: String
}

/// WebKit's own tabs, by the name its inspector gives each. Memory is
/// Timelines with the memory instruments on; Settings and Search are the
/// pinned tabs its own row kept at its end.
enum WebPane: String, CaseIterable {
    case elements = "Elements", console = "Console", sources = "Sources"
    case timelines = "Timelines", memory = "Memory", storage = "Storage", graphics = "Graphics", layers = "Layers", audit = "Audit"
    case requests = "Network", search = "Search", settings = "Settings"

    /// Chrome's names where Chrome has the same thing, for the hand that
    /// knows Chrome's row: Performance, Application.
    var title: String {
        switch self {
        case .timelines: return "Performance"
        case .storage: return "Application"
        case .requests: return "WebKit Network"
        default: return rawValue
        }
    }

    /// The type WebKit's tab says it is (its content view's `Type`).
    var type: String {
        switch self {
        case .timelines, .memory: return "timeline"
        default: return rawValue.lowercased()
        }
    }

    init?(type: String) {
        guard let pane = WebPane.allCases.first(where: { $0.type == type && $0 != .memory }) else { return nil }
        self = pane
    }
}

/// The head's row, in Chrome's order: what is at each place in Chrome's
/// row is at the same place here, WebKit's own extras after it.
enum DevTab: CaseIterable, Hashable {
    case elements, console, sources, network, performance, memory, application, security, audit, recorder, graphics, layers

    /// The design's eight tabs stay in the head; extra tools live in More.
    static let header: [DevTab] = [.elements, .console, .sources, .network, .performance, .memory, .application, .security]
    static let more: [DevTab] = [.audit, .recorder, .graphics, .layers]

    var pane: DevPane {
        switch self {
        case .elements: return .elements
        case .console: return .console
        case .sources: return .sources
        case .network: return .network
        case .performance: return .performance
        case .memory: return .memory
        case .application: return .application
        case .security: return .security
        case .audit: return .audit
        case .recorder: return .recorder
        case .graphics: return .webkit(.graphics)
        case .layers: return .layers
        }
    }

    var title: String {
        switch self {
        case .network: return "Network"
        case .console: return "Console"
        case .security: return "Security"
        case .recorder: return "Recorder"
        case .elements: return "Elements"
        case .sources: return "Sources"
        case .performance: return "Performance"
        case .memory: return "Memory"
        case .application: return "Application"
        case .audit: return "Audit"
        case .layers: return "Layers"
        default:
            if case .webkit(let web) = pane { return web.title }
            return ""
        }
    }
}

// MARK: - the dock

/// Where WebKit docks the inspector: the anchor it is docked beside, and the
/// inspector, given the whole of the dock whatever frame WebKit set.
final class InspectorDock: NSView {
    let anchor: NSView = Anchor()
    private var fitting = false
    private var waitingForWindow: [() -> Void] = []
    var connectionStartedAt: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        anchor.alphaValue = 0
        anchor.postsFrameChangedNotifications = false
        anchor.frame = Self.anchorFrame
        addSubview(anchor)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Large enough for WebKit to dock rather than open a window of its own.
    fileprivate static let anchorFrame = NSRect(x: 0, y: 0, width: 800, height: 600)

    /// The view WebKit docks beside, at that size whatever WebKit sets. As
    /// it docks, WebKit gives it what is left beside the inspector (500 by
    /// 273 was seen, under the 334 high it docks beside), and the size came
    /// back only as the card was laid out: ⌥⌘I after Open in Separate
    /// Window, the card away in between, left WebKit in its window.
    private final class Anchor: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(InspectorDock.anchorFrame.size)
        }
    }

    override var isFlipped: Bool { true }

    /// Told when the dock is in a window again.
    var arrived: (() -> Void)?

    /// Opening a warm inspector can answer before SwiftUI mounts the card.
    /// WebKit must have a window to attach to before it is shown or asked
    /// to inspect the context-menu target.
    func whenInWindow(_ work: @escaping () -> Void) {
        if window != nil { work() }
        else { waitingForWindow.append(work) }
    }

    func cancelWaitingForWindow() { waitingForWindow = [] }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Attaching reparents WebKit's view. Do it after AppKit has finished
        // moving this dock, rather than from inside its move notification.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.arrived?()
            let waiting = self.waitingForWindow
            self.waitingForWindow = []
            waiting.forEach { $0() }
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== anchor else { return }
        subview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(moved(_:)), name: NSView.frameDidChangeNotification, object: subview)
        if let web = subview as? WKWebView { Self.flush(web) }
        fit()
    }

    override func willRemoveSubview(_ subview: NSView) {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: subview)
        super.willRemoveSubview(subview)
    }

    override func layout() {
        super.layout()
        fit()
    }

    @objc private func moved(_ note: Notification) { fit() }

    /// The inspector across the whole dock; the anchor where WebKit can
    /// still measure it, behind.
    private func fit() {
        guard !fitting else { return }
        fitting = true
        defer { fitting = false }
        if anchor.frame != Self.anchorFrame { anchor.frame = Self.anchorFrame }
        for view in subviews where view !== anchor && view.frame != bounds {
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
        }
    }

    /// No room kept at the top for the window's title bar: the card is
    /// below it, and the inspector's first row would stand in empty space.
    private static func flush(_ web: WKWebView) {
        let adjusts = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if web.responds(to: adjusts) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: adjusts), to: Setter.self)(web, adjusts, false)
        }
        if #available(macOS 26.0, *) { web.obscuredContentInsets = NSEdgeInsets() }
    }

    /// Whatever WebKit left here once its inspector was closed: it keeps
    /// the page a while to open again quickly, and docks it anew then.
    func clear() {
        for view in subviews where view !== anchor { view.removeFromSuperview() }
    }

    /// The inspector's own page, docked here now.
    var docked: WKWebView? { subviews.lazy.compactMap { $0 as? WKWebView }.first }
}

struct InspectorDockView: NSViewRepresentable {
    let dock: InspectorDock

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        holder.addSubview(dock)
        dock.frame = holder.bounds
        dock.autoresizingMask = [.width, .height]
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        if dock.superview !== holder {
            dock.removeFromSuperview()
            holder.addSubview(dock)
            dock.frame = holder.bounds
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

// MARK: - word from the inspector's page

final class InspectorRelay: NSObject, WKScriptMessageHandler {
    static let name = "yabInspector"
    weak var browser: Browser?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["k"] as? String else { return }
        MainActor.assumeIsolated {
            guard let browser else { return }
            switch kind {
            case "ready":
                guard browser.inspected != nil, let at = body["at"] as? Double, at >= browser.inspectorDock.connectionStartedAt else { return }
                browser.inspectorReady()
            case "panels":
                // The panels extensions added to this page's inspector.
                let panels = (body["p"] as? [[String: Any]] ?? []).compactMap { item -> DevPanel? in
                    guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
                    return DevPanel(id: id, title: title)
                }
                browser.panelsCame(panels)
            case "tab":
                // The inspector went to another tab by itself: an element
                // picked shows Elements, a log's link shows Sources.
                if let title = body["n"] as? String {
                    if browser.devPanels.contains(where: { $0.title == title }), browser.devPane != .panel(title) { browser.devPane = .panel(title) }
                    return
                }
                guard let type = body["t"] as? String, var pane = WebPane(type: type) else { return }
                // Memory is Timelines too: shown there, it stays Memory.
                if pane == .timelines, browser.devPane == .webkit(.memory) { pane = .memory }
                guard browser.devPane != .webkit(pane), browser.devPane.isWebKit || pane == .elements else { return }
                browser.devPane = pane == .elements ? .elements : .webkit(pane)
            case "agent":
                // Copy for Agent and Ask in Chat, from WebKit's own console.
                guard let tab = browser.inspected else { return }
                let text = body["x"] as? String ?? ""
                switch body["w"] as? String {
                case "one": browser.copyIssues([], console: [text], on: tab)
                case "chat": browser.askInChat(about: tab, selection: text)
                default: browser.copyEverything(tab)
                }
            case "highlight":
                // The node a row or the picker points at (DevHighlight.swift).
                if let json = body["j"] as? String { browser.inspected?.drawHighlight(json) }
            case "wire":
                // A panel module's batch on its channel (DevWire.swift), for
                // the tab the inspector is docked for.
                if let channel = body["c"] as? String, let json = body["j"] as? String, channel != "wire" {
                    browser.inspected?.wireHeard(channel, json)
                }
            case "net":
                // What changed in WebKit's network since the last word
                // (DevNetBridge.swift), for the tab it is docked for.
                if let json = body["j"] as? String { browser.inspected?.netLog.hear(json) }
            case "console":
                // Said before the card was listening, and handed over by
                // the inspector as it connected (DevLog.early).
                guard let level = body["v"] as? String, let text = body["x"] as? String else { return }
                browser.inspected?.devLog.early(level: level, text: text, source: body["u"] as? String ?? "",
                                                line: body["l"] as? Int ?? 0, at: body["ts"] as? Double ?? 0,
                                                copy: body["n"] as? Int ?? 0, stack: body["s"] as? String ?? "")
            default:
                break
            }
        }
    }
}

// MARK: - the browser's side

extension Browser {
    /// The tab whose page the card can look at: in front, with a page, not
    /// in a split or playing full screen.
    var toolsFront: Tab? {
        guard let tab = active, !tab.isBlank, !tab.immersed, !splitShown else { return nil }
        return tab
    }

    /// The card asked for and let out on the next frame (moveDev): what is
    /// done to it meanwhile is done as to a card that is out.
    var devComing: Bool { !devOpen && devMoving && listened != nil }

    /// ⌥⌘I, `</>` and View › Developer Tools: the card, or away. It opens
    /// where it was last, on any page, as Chromium's do (#383): the pane, the
    /// side or its own window, the size, device mode (DevMemory). It used
    /// to open a site on Elements whenever Yab's own lists were empty, and
    /// a local page with errors on Errors, so Network never came back.
    func developerTools() {
        guard toolsFront != nil else { return }
        if devOpen || devComing { closeDevTools(); return }
        openDevTools(devPane)
    }

    /// The card out, on `pane`. WebKit's inspector connects with it, for
    /// the tab in front only: as in Chromium, Network records while the card
    /// is out, whatever pane it shows (DevNet.swift). It is a web content
    /// process of its own for the page, some 140 MB, closed with the card.
    /// As it connects it hands over what the page said before the card
    /// listened, so the counts start from the page's start (DevLog.early);
    /// ⌥⌘I on a page yab hasn't heard opens on Elements, one of its tabs.
    func openDevTools(_ pane: DevPane, then: ((Tab, NSObject) -> Void)? = nil) {
        guard let tab = toolsFront else { return }
        // Restored tabs may not have built their page yet. Resolve its actual
        // engine (including factory fallback) before selecting an inspector.
        if tab.page.engine == .chromium {
            devPane = ChromiumDevPanes.normal(pane)
            listen(tab)
            showChromiumDev(tab, pane: devPane)
            if !devOpen, !devComing { comeBack(tab); moveDev(open: true, side: prefs.devSide) }
            return
        }
        devPane = pane
        if pane == .console { consolePanel.focusPrompt = true }
        if pane == .errors { issueFilter = .errors }
        if pane == .warnings { issueFilter = .warnings }
        if !devOpen, !devComing { comeBack(tab) }
        listen(tab)
        if !devOpen { moveDev(open: true, side: prefs.devSide) }
        showWebPane(then: then)
        netBeat()
    }

    /// Out again as they went away (DevMemory): in their own window if
    /// they were, the page as the device it was shown as.
    private func comeBack(_ tab: Tab) {
        if DevMemory.deviceOn, tab.device == nil, !tab.chromeWhole, let device = DevMemory.device { tab.setDevice(device, remember: false) }
        // Chrome's frontend lives only in the docked card: the separate
        // window is WebKit's own inspector window (DevFloating), which a
        // Chromium page never has. Detached, its card was hidden and
        // nothing showed (#1873).
        if DevMemory.detached, !devDetached, tab.page.engine != .chromium {
            devDetached = true
            devFloating.prepare()
        }
    }

    /// Work that needs the inspector's own page: at once when it is up for
    /// the tab in front, else once it has come up.
    func withInspector(_ work: @escaping (NSObject) -> Void) {
        guard let tab = toolsFront else { return }
        if inspected === tab, inspectorLive, let inspector = Inspector.ofPage(tab.page) { work(inspector); return }
        showWebPane { _, inspector in work(inspector) }
    }

    /// ⋯ › Device Settings: one of WebKit's overrides on the page, or off
    /// again. WebKit drops them all when its inspector goes.
    func toggleDevOverride(_ setting: DevOverride) {
        guard let tab = toolsFront else { return }
        let on = !tab.devOverrides.contains(setting)
        if on { tab.devOverrides.insert(setting) } else { tab.devOverrides.remove(setting) }
        let value = on ? String(setting.value) : "undefined"
        withInspector { DevTools.run("__yab.override('\(setting.rawValue)', \(value))", in: $0) }
    }

    /// ⋯ › Device Settings › Appearance: the page told it is light or dark,
    /// or what the window is again. The page's view is given that look, and
    /// prefers-color-scheme follows it; WebKit's inspector has no say in it
    /// on this Mac.
    func setDevAppearance(_ appearance: String?) {
        guard let tab = toolsFront else { return }
        tab.devAppearance = appearance
        tab.webKitOnly("WebKit inspector lifecycle", build: false)?.appearance = appearance.map { NSAppearance(named: $0 == "Dark" ? .darkAqua : .aqua) } ?? nil
    }

    /// ⋯ › Show Console Drawer: WebKit's console under whichever of its
    /// tabs is up, as Escape does in it.
    func toggleDevDrawer() {
        withInspector { [weak self] inspector in
            DevTools.run("__yab.drawer()", in: inspector) { self?.devDrawer = $0 as? Bool ?? false }
        }
    }

    /// The same native panels in their own window, keeping the inspector transport connected.
    func detachDevTools() {
        guard let engine = toolsFront?.page.engine, engine != .chromium else { return }
        if !devOpen { openDevTools(devPane) }
        devDetached = true
        DevMemory.detached = true
        devFloating.prepare()
        showWebPane()
    }

    /// The chat button: the page asked about in the chat, with what the
    /// card is showing: the element picked, the errors, the failed requests.
    func askAboutDev() {
        guard let tab = toolsFront else { return }
        let log = tab.devLog
        switch devPane {
        case .errors, .warnings:
            let shown = log.issues(issueFilter)
            askInChat(about: tab, selection: shown.isEmpty ? nil : DevCopy.pack(shown, page: tab.address, size: tab.webKitOnly("WebKit inspector lifecycle", build: false)?.bounds.size))
        case .console:
            let log = tab.devModel(ConsoleLog.self)
            let wrong = log.messages.filter { $0.kind == .page && ($0.level == "error" || $0.level == "warning") }.suffix(10)
            if wrong.isEmpty { askInChat(about: tab) } else { consoleAsk(Array(wrong)) }
        case .network:
            let rows = tab.netLog.rows
            let picked = rows.filter { $0.id == netPanel.selected }
            let failed = picked.isEmpty ? Array(rows.filter(\.bad).suffix(5)) : picked
            if failed.isEmpty { askInChat(about: tab) } else { netAsk(failed, question: "") }
        case .elements:
            guard let model = workbench, model.selectedNode != 0 else { askInChat(about: tab); return }
            workCall("elements.html", ["id": model.selectedNode]) { [weak self, weak tab] value in
                guard let self, let tab else { return }
                let html = (value as? [String: Any])?["outerHTML"] as? String ?? ""
                self.askInChat(about: tab, selection: html)
            }
        case .webkit(.elements):
            guard inspected === tab, let inspector = Inspector.ofPage(tab.page) else { askInChat(about: tab); return }
            DevTools.picked(in: inspector) { [weak self, weak tab] html in
                guard let self, let tab else { return }
                self.askInChat(about: tab, selection: html.isEmpty ? nil : html)
            }
        default:
            askInChat(about: tab)
        }
    }

    /// The card away, WebKit's inspector closed with it; as in Chromium, the
    /// page is itself again and a recording stops.
    func closeDevTools() {
        // Also one asked for and not out yet: ⌥⌘I twice in a row.
        guard devOpen || devComing else { return }
        devPicking = false
        // The inspector closed while still docked: its window put away
        // first took the dock out of any window, WebKit undocked it and
        // opened every later one in a window of its own beside ours
        // (feedback #865).
        let detached = devDetached
        if detached {
            // Invalidate a queued opening and clear visibility before changing
            // the host. No SwiftUI pass may see an open docked card here.
            devMoves += 1
            devMoving = false
            Reshape.pace = .reshape
            devOpen = false
            closeWebInspector()
        }
        devFloating.hide(); devDetached = false
        // Every tab the card was over, not only the one in front: it follows
        // the tab in front, and a tab left in device mode would stay a phone.
        // A tab whose own card is put away (devKept) keeps all of it.
        for tab in everyTab where tab.devKept == nil {
            tab.chromiumDev?.close()
            // Device mode is kept to come back with the card (DevMemory).
            if tab.device != nil { tab.setDevice(nil, remember: false) }
            if tab.recorder.recording { tab.recorder.stop() }
            if tab.recorder.playing != nil { tab.recorder.stopPlaying() }
            tab.webKitOnly("WebKit inspector lifecycle", build: false)?.evaluateJavaScript("""
            (()=>{window.__yabNativePicker?.stop();const s=window.__yabSensors;if(s){navigator.geolocation.getCurrentPosition=s.position;navigator.geolocation.watchPosition=s.watch;for(const [key,value] of [['language',s.language],['hardwareConcurrency',s.threads]]){if(value)Object.defineProperty(navigator,key,value);else delete navigator[key]}delete window.__yabSensors}const a=window.__yabAudio;if(a){window.AudioContext=a.original;a.methods.forEach(undo=>undo());delete window.__yabAudio}window.__yabToolAbort?.abort()})()
            """, in: nil, in: .page) { _ in }
            if tab.devAppearance != nil {
                tab.devAppearance = nil
                tab.webKitOnly("WebKit inspector lifecycle", build: false)?.appearance = nil
            }
        }
        closeWebInspector()
        listened?.listenDev(false)
        listened = nil
        if !detached { moveDev(open: false, side: prefs.devSide) }
    }

    /// A pane picked in the head.
    func pickDevPane(_ pane: DevPane) {
        if let tab = chromiumDevFront {
            devPane = ChromiumDevPanes.normal(pane)
            showChromiumDev(tab, pane: devPane)
            return
        }
        if case .panel = pane {} else { panelWanted = nil }
        if pane != .elements, pane != .webkit(.elements) { stopPickingOutsideElements() }
        devPane = pane
        if pane == .console { consolePanel.focusPrompt = true }
        if pane == .errors { issueFilter = .errors }
        if pane == .warnings { issueFilter = .warnings }
        if pane.isWebKit { showWebPane() }
    }

    /// The panels extensions added to the inspector, as its page says them:
    /// one wanted back shown as it comes, one taken away left for Elements.
    func panelsCame(_ panels: [DevPanel]) {
        if panels != devPanels { devPanels = panels }
        // Any of WebKit's tabs stands in till then: a new inspector opens on
        // a tab of its own, by its place in the last one's row.
        if let title = panelWanted, devPane.isWebKit, panels.contains(where: { $0.title == title }) {
            panelWanted = nil
            pickDevPane(.panel(title))
        } else if case .panel(let title) = devPane, !panels.contains(where: { $0.title == title }) {
            pickDevPane(.elements)
        }
    }

    /// WebKit's inspector for the tab in front, docked in the card, on the
    /// pane asked for; `then` once its page can be spoken to.
    func showWebPane(then: ((Tab, NSObject) -> Void)? = nil) {
        if let tab = chromiumDevFront { showChromiumDev(tab, pane: devPane, focus: false); return }
        guard let tab = toolsFront else { return }
        if devDetached { devFloating.prepare() }
        guard devDetached || inspectorDock.window != nil else {
            inspectorDock.whenInWindow { [weak self, weak tab] in
                guard let self, let tab, self.toolsFront === tab, self.devOpen || self.devComing else { return }
                self.showWebPane(then: then)
            }
            return
        }
        guard let inspector = Inspector.ofPage(tab.page) else { return }
        if devDetached { devFloating.prepare(page: DevTools.page(inspector)) }
        if let was = inspected, was !== tab { closeWebInspector(keep: true) }
        inspected = tab
        netWire(tab)
        guard let web = tab.webKitOnly("WebKit Inspector") else { return }
        let attach = NSSelectorFromString("_setInspectorAttachmentView:")
        if web.responds(to: attach) { web.perform(attach, with: inspectorDock.anchor) }
        inspectorDock.arrived = { [weak self] in self?.redock() }
        if !Inspector.asks(inspector, "isVisible") {
            // The old frontend remains readable briefly while WebKit reopens it.
            // Accept readiness only from the document loaded for this connection.
            inspectorDock.connectionStartedAt = Date().timeIntervalSince1970 * 1000
            inspectorLive = false
            // Back on the document it was put away on: everything kept, and
            // found again on the new inspector's numbers (DevReturn).
            let again = tab.devReturn?.document == tab.devDocument
            if !again { tab.devReturn = nil }
            netConnected(tab, again: again)
            tab.wireConnected(again: again)
            Inspector.send(inspector, "show")
        }
        // Docks one already up, in its own window after ⋯ › Open in Separate
        // Window; one just asked for has no page yet to dock, and is docked
        // as WebKit makes it (didAttachLocalInspector).
        Inspector.send(inspector, devDetached ? "detach" : "attach")
        DevTools.dress(inspector, relay: inspectorRelay)
        DevTools.cut(inspector, for: tab)
        whenInspectorLive { [weak self] in
            guard let self, self.inspected === tab else { return }
            // Up in a window of WebKit's own after all, as WebKit opens one
            // it last had undocked: into the card.
            if !self.devDetached, self.inspectorDock.docked == nil, self.inspectorDock.window != nil { Inspector.send(inspector, "attach") }
            if self.devDetached { self.devFloating.show() }
            if case .webkit(let pane) = self.devPane { DevTools.show(pane, in: inspector) }
            if case .panel(let title) = self.devPane, let panel = self.devPanels.first(where: { $0.title == title }) {
                DevTools.showPanel(panel.id, in: inspector)
            }
            then?(tab, inspector)
        }
    }

    /// The card's inspector, undocked by WebKit as the dock left a window
    /// (the card moving between Developer Tools' own window and the main
    /// one), back into the dock once the dock is in a window again.
    private func redock() {
        guard !devDetached, let tab = inspected, inspectorDock.docked == nil, let web = tab.built,
              let inspector = Inspector.of(web), Inspector.asks(inspector, "isVisible") else { return }
        Inspector.send(inspector, "attach")
    }

    func smallInspectorOwner(of tab: Tab) -> LinkWindow? {
        guard let web = tab.webKitOnly("WebKit inspector lifecycle", build: false), let owner = LinkWindow.owning(page: web),
              owner.tab === tab, outside.contains(where: { $0 === tab }),
              !tab.gone, !tab.asleep, owner.window.isVisible,
              web.window === owner.window else { return nil }
        return owner
    }

    func localInspectorRoute(for web: WKWebView) -> LocalInspectorOwnership.Route {
        let owner = LinkWindow.owning(page: web)
        let small = owner.flatMap { smallInspectorOwner(of: $0.tab) }?.tab.webKitOnly("WebKit inspector lifecycle", build: false)
        let main = inspected?.webKitOnly("WebKit inspector lifecycle", build: false)
        return LocalInspectorOwnership.route(page: ObjectIdentifier(web),
            main: main.map { ObjectIdentifier($0) },
            small: small.map { ObjectIdentifier($0) })
    }

    /// WebKit has made the inspector's page for a tab and is about to open
    /// it, docked only if it was docked when last closed: once Open in
    /// Separate Window had been used, every one of its tabs came up in a
    /// window and never in the card, since `show` is answered later and an
    /// `attach` sent with it finds nothing to dock. Docked here, before its
    /// window is made, when it is the card's.
    @objc(_webView:didAttachLocalInspector:)
    func didAttachLocalInspector(_ web: WKWebView, inspector: NSObject) {
        switch localInspectorRoute(for: web) {
        case .main:
            // Set WebKit's own mode before it opens its frontend window.
            // Its detached window is adopted by DevFloating, never duplicated.
            if devDetached { devFloating.prepare(page: DevTools.page(inspector)) }
            DevTools.dress(inspector, relay: inspectorRelay)
            Inspector.send(inspector, devDetached ? "detach" : "attach")
        case .small:
            // The live Small Window owns WebKit's separate inspector.
            return
        case .stale:
            DispatchQueue.main.async { [weak self, weak web] in
                // Ownership may have changed while WebKit made its window.
                guard let self, let web, self.localInspectorRoute(for: web) == .stale,
                      let late = Inspector.of(web) else { return }
                Inspector.send(late, "close")
            }
        }
    }

    /// WebKit's own close button bypasses closeDevTools. Finish our teardown
    /// after WebKit has finished closing, including the device layout and any
    /// cached frontend it left in the dock. Never reenter WebKit's close stack
    /// or put away a different connection opened in the meantime.
    @objc(_webView:willCloseLocalInspector:)
    func willCloseLocalInspector(_ web: WKWebView, inspector: NSObject) {
        guard let tab = inspected, tab.built === web else { return }
        let connection = inspectorDock.connectionStartedAt
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.inspected === tab,
                  self.inspectorDock.connectionStartedAt == connection,
                  !Inspector.asks(inspector, "isVisible") else { return }
            self.closeDevTools()
        }
    }

    /// WebKit's inspector put away, still docked in the card's dock should
    /// it come up after all. `keep`: put away as another tab came in front,
    /// what it held kept for the way back (DevReturn).
    func closeWebInspector(keep: Bool = false) {
        if inspected == nil, !devPanels.isEmpty { devPanels = [] }
        inspectorDock.cancelWaitingForWindow()
        inspectorDock.arrived = nil
        guard let tab = inspected else { return }
        // The picker and highlight live in the inspected page, not WebKit's
        // inspector window. Closing that window alone cannot retire them.
        devPicking = false
        tab.devModel(DevWorkbench.self).picking = false
        tab.drawHighlight("null")
        tab.webKitOnly("WebKit inspector picker teardown", build: false)?.evaluateJavaScript(
            "window.__yabNativePicker?.stop();void 0", in: nil, in: .page) { _ in }
        inspected = nil
        tab.devReturn = keep ? DevReturn(document: tab.devDocument, overrides: tab.devOverrides) : nil
        // Its panels went with it. On one, Elements until the next page's
        // inspector has the same panel, if it comes to have it.
        if !devPanels.isEmpty { devPanels = [] }
        if case .panel(let title) = devPane {
            panelWanted = title
            devPane = .webkit(.elements)
        }
        inspectorLive = false
        inspectorWaiting = []
        // WebKit lets its overrides go with the inspector, and the look
        // goes with them, unless the tab is only left for another (its look
        // is the page's own, WebKit's inspector has no say in it).
        tab.devOverrides = []
        if !keep, tab.devAppearance != nil {
            tab.devAppearance = nil
            tab.webKitOnly("WebKit inspector lifecycle", build: false)?.appearance = nil
        }
        devDrawer = false
        // Closed whether or not it is up yet: one still opening (the card
        // put away, or another tab in front, a moment after ⌥⌘I) came up
        // after this and stayed.
        if let inspector = Inspector.ofPage(tab.page) { Inspector.send(inspector, "close") }
        // The page goes on naming the card's dock as where it is docked,
        // never itself: an inspector that comes up after all docks there,
        // out of sight, and is closed (didAttachLocalInspector). Named
        // back to the page, WebKit docked it beside the page in the stage
        // and kept the page short of its room for good, laying it out
        // again beside an inspector the stage had taken out, at every size
        // the stage gave it (feedback #269: a gray band under the page, or
        // beside it, after the card went away or another tab came in front).
        inspectorDock.clear()
    }

    /// The card is the tab's, as Chromium's DevTools are: another tab in
    /// front puts it away, the tab left keeping the pane it showed (and
    /// its device mode, a recording); back in front, the card comes out
    /// again on that pane, at the size it had. A tab closed takes its card
    /// with it. Put away and brought back at once, as the page changes,
    /// not with the card's own coming and going.
    func devFollows(left: Tab.ID?) {
        let was = tab(id: left)
        // Asked for on the tab left and not out yet (moveDev lets it out a
        // frame later): it is that tab's all the same. It came out over the
        // tab arrived at, on the inspector of the one left, Elements empty,
        // and stayed that tab's.
        let out = devOpen || (devComing && listened === was)
        if out, let was, !was.isBlank { was.devKept = devPane; devPanesLeave(was) }
        guard let tab = toolsFront, let kept = tab.devKept else {
            if out { parkDevTools() }
            return
        }
        tab.devKept = nil
        devPanesArrive(tab)
        devMoves += 1
        devMoving = false
        Reshape.pace = .reshape
        if !devOpen { devOpen = true }
        // Undocked, back in their own window (parkDevTools put it away).
        // Never for Chrome's frontend, which has no window of its own.
        if DevMemory.detached, !devDetached, !tab.usesChromiumDev {
            devDetached = true
            devFloating.prepare()
        }
        if case .panel(let title) = kept { panelWanted = title }
        // As openDevTools, but the keyboard stays where the tab change left it.
        devPane = kept
        if kept == .errors { issueFilter = .errors }
        if kept == .warnings { issueFilter = .warnings }
        listen(tab)
        showWebPane()
        netBeat()
    }

    /// The card away for a tab left, its inspector closed (WebKit keeps
    /// one page's at a time here, 140 MB each), the tab itself left as it
    /// was, to have it back as it was.
    private func parkDevTools() {
        devPicking = false
        // Closed before its window goes, as in closeDevTools.
        closeWebInspector(keep: true)
        devFloating.hide(); devDetached = false
        listened?.listenDev(false)
        listened = nil
        devMoves += 1
        devMoving = false
        Reshape.pace = .reshape
        devOpen = false
    }

    /// The page the card is over heard, and no other.
    private func listen(_ tab: Tab) {
        if let was = listened, was !== tab { was.listenDev(false) }
        listened = tab
        tab.listenDev(true)
    }

    /// Run once the inspector's page has said it is ready, or at once.
    private func whenInspectorLive(_ work: @escaping () -> Void) {
        if inspectorLive { work(); return }
        inspectorWaiting.append(work)
        // A page that loaded before yab's script was put in says nothing:
        // ask it.
        if let web = inspected.flatMap({ Inspector.ofPage($0.page) }).flatMap(DevTools.page) {
            let connection = inspectorDock.connectionStartedAt
            web.evaluateJavaScript("!!(window.__yab && window.__yab.ready && window.__yab.readyAt >= \(connection))") { [weak self] value, _ in
                guard let self, self.inspected != nil, self.inspectorDock.connectionStartedAt == connection else { return }
                if value as? Bool == true { self.inspectorReady() }
            }
        }
    }

    func inspectorReady() {
        // Said again once its page is up: said while it was still loading,
        // it went with the page it was said to.
        if let tab = inspected, let inspector = Inspector.ofPage(tab.page) { DevTools.cut(inspector, for: tab) }
        inspectorLive = true
        workbench?.connectMs = Date().timeIntervalSince1970 * 1000 - inspectorDock.connectionStartedAt
        netApplyConditions()
        netBeat()
        consoleConnected()
        workbench?.error = ""
        // A kept tree is asked for at once below (devReturned), not on the
        // pane's next pass.
        if workbench?.keptTree == nil { workbench?.domRevision += 1 }
        sourcesRefresh()
        if let tab = inspected, let back = tab.devReturn {
            tab.devReturn = nil
            devReturned(tab, back)
        }

        let waiting = inspectorWaiting
        inspectorWaiting = []
        waiting.forEach { $0() }
    }

    /// ⌥⌘C and Inspect Element where WebKit's picker is the one: the card on
    /// Elements, and the next click on the page picks.
    func pickWithWebKit() {
        guard toolsFront != nil else { return }
        active?.measure(false)
        if let tab = active, tab.webPicking, let inspector = Inspector.ofPage(tab.page) {
            Inspector.send(inspector, "toggleElementSelection")
        }
        openDevTools(.elements)
        devPicking = true
        let native = DevPicker.native
        DevPicker.lastStart = "asked"
        workCall("elements.pickStart", ["native": native]) { [weak self] value in
            DevPicker.lastStart = "answered " + (value.map { "\($0)" } ?? "nothing")
            guard let self else { return }
            if value as? Bool != true { self.devPicking = false; return }
            if native, self.devPicking, let web = self.inspected?.webKitOnly("WebKit native picker") { DevPicker.start(web) }
        }
    }

    func stopPickingElement() {
        if let frontend = chromiumDevFront?.chromiumDev {
            if frontend.picking { frontend.action("elements.toggle-element-search") }
            return
        }
        DevPicker.stop()
        devPicking = false
        workbench?.picking = false
        workCall("elements.pickStop")
    }

    /// Inspect mode is Elements' own (its button is only in Elements' head):
    /// another pane ends it, Yab's picker and WebKit's alike, or the page
    /// went on drawing whatever the pointer was over under Console.
    private func stopPickingOutsideElements() {
        if devPicking || workbench?.picking == true { stopPickingElement() }
        if let tab = inspected ?? active, tab.webPicking, let inspector = Inspector.ofPage(tab.page) {
            Inspector.send(inspector, "toggleElementSelection")
        }
    }
}

// MARK: - the inspector's page, dressed

nonisolated(unsafe) private var dressedKey: UInt8 = 0
nonisolated(unsafe) private var selectionKey: UInt8 = 0

@MainActor
enum DevTools {
    /// The inspector's own web view, where WebKit keeps it.
    static func page(_ inspector: NSObject) -> WKWebView? {
        let get = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: get) else { return nil }
        return inspector.perform(get)?.takeUnretainedValue() as? WKWebView
    }

    /// yab's look and word back put into the inspector's page, once for
    /// each page WebKit makes, and at once if it has already loaded.
    static func dress(_ inspector: NSObject, relay: InspectorRelay) {
        guard let web = page(inspector) else { return }
        if objc_getAssociatedObject(web, &dressedKey) == nil {
            objc_setAssociatedObject(web, &dressedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let controller = web.configuration.userContentController
            controller.removeScriptMessageHandler(forName: InspectorRelay.name)
            controller.add(relay, name: InspectorRelay.name)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: DevNet.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            for source in DevWire.scripts {
                controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            awake(web)
        }
        web.evaluateJavaScript(script, completionHandler: nil)
        web.evaluateJavaScript(DevNet.script, completionHandler: nil)
        for source in DevWire.scripts { web.evaluateJavaScript(source, completionHandler: nil) }
        dressed.add(web)
        web.evaluateJavaScript(monoScript(DevMono.current), completionHandler: nil)
    }

    /// Every inspector page dressed so far, for a new Fixed-width font.
    private static let dressed = NSHashTable<WKWebView>.weakObjects()

    /// WebKit's inspector names Menlo in its own rules: those take the
    /// Fixed-width font first, or go back to what they were.
    static func monoScript(_ family: String) -> String {
        let data = try! JSONEncoder().encode(family)
        return """
        (() => {
          const family = \(String(decoding: data, as: UTF8.self));
          const walk = (rules) => { for (const rule of rules) {
            if (rule.cssRules) walk(rule.cssRules);
            const style = rule.style; if (!style) continue;
            const was = rule.__yabMono ?? style.fontFamily;
            if (!/menlo|monospace/i.test(was)) continue;
            rule.__yabMono = was;
            style.fontFamily = family ? JSON.stringify(family) + ', ' + was : was;
          } };
          for (const sheet of document.styleSheets) { try { walk(sheet.cssRules); } catch {} }
        })();
        """
    }

    static func setMono(_ family: String) {
        for web in dressed.allObjects { web.evaluateJavaScript(monoScript(family), completionHandler: nil) }
    }

    /// The inspector's page is hidden behind Yab's own panes, and WebKit
    /// slows a hidden page down: its timers wait longer and longer, up to a
    /// minute, and its process is let sleep. Network hears the page through
    /// it and holds throttled requests in it (DevNetBridge.swift), so it is
    /// kept awake, as a page on screen is. Only the inspector's.
    static func awake(_ web: WKWebView) {
        let preferences = web.configuration.preferences
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        for name in ["_setHiddenPageDOMTimerThrottlingEnabled:", "_setHiddenPageDOMTimerThrottlingAutoIncreases:",
                     "_setPageVisibilityBasedProcessSuppressionEnabled:"] {
            let selector = NSSelectorFromString(name)
            guard preferences.responds(to: selector) else { continue }
            unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, false)
        }
    }

    /// The element `selector` finds, picked in Elements: found in the page
    /// by WebKit's own Runtime and handed to its DOM, as picking would.
    static func select(_ selector: String, in inspector: NSObject) {
        let request = UUID().uuidString
        objc_setAssociatedObject(inspector, &selectionKey, request, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        let js = """
        window.__yabSelectionRequest = request;
        const r = await WI.mainTarget.RuntimeAgent.evaluate.invoke({
          expression: 'document.querySelector(' + JSON.stringify(selector) + ')', objectGroup: 'yab'
        });
        if (!r.result || r.result.subtype !== 'node') return false;
        const id = await new Promise(resolve => WI.RemoteObject.fromPayload(r.result, WI.mainTarget).pushNodeToFrontend(resolve));
        if (window.__yabSelectionRequest !== request) return false;
        const node = WI.domManager.nodeForId(id);
        if (!node || !node.ownerDocument) return false;
        WI.domManager.inspectElement(id);
        return true;
        """
        // Reopening can replace the inspector's page after it first says
        // ready. Keep the bounded restore in the app, so a new page cannot
        // discard its timers. A newer selection supersedes this request.
        func attempt(_ remaining: Int) {
            guard objc_getAssociatedObject(inspector, &selectionKey) as? String == request,
                  Inspector.asks(inspector, "isVisible") else { return }
            page(inspector)?.callAsyncJavaScript(js, arguments: ["selector": selector, "request": request],
                                                in: nil, in: .page) { _ in }
            if remaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(remaining - 1) }
            }
        }
        attempt(10)
    }

    static func show(_ pane: WebPane, in inspector: NSObject) {
        page(inspector)?.evaluateJavaScript("window.__yab && window.__yab.show(\(quoted(pane.type)), \(pane == .memory))", completionHandler: nil)
    }

    /// An extension's panel, by WebKit's id for it in this inspector.
    static func showPanel(_ id: String, in inspector: NSObject) {
        page(inspector)?.evaluateJavaScript("window.__yab && window.__yab.panel(\(quoted(id)))", completionHandler: nil)
    }

    /// When the page's own script began to listen: the inspector's page
    /// hands over only what it kept from before (DevLog.early), and nothing
    /// for a page heard from its start.
    static func cut(_ inspector: NSObject, for tab: Tab) {
        let cutoff = tab.devLog.heardFrom.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
        page(inspector)?.evaluateJavaScript("window.__yabCutoff = \(cutoff)", completionHandler: nil)
    }

    /// Every line WebKit's console has for the page.
    static func consoleLines(in inspector: NSObject, _ done: @escaping ([String]) -> Void) {
        guard let web = page(inspector) else { done([]); return }
        web.callAsyncJavaScript("return window.__yab && window.__yab.linesSoon ? await window.__yab.linesSoon() : []", arguments: [:], in: nil, in: .page) { result in
            done((try? result.get()) as? [String] ?? [])
        }
    }

    /// A file at a line, in WebKit's Sources; false when it hasn't the file.
    static func reveal(_ place: DevPlace, in inspector: NSObject, _ done: @escaping (Bool) -> Void) {
        run("__yab.reveal(\(quoted(place.url)), \(place.line), \(place.column))", in: inspector) { done($0 as? Bool ?? false) }
    }

    /// A line of the inspector's own page run, its answer handed back.
    static func run(_ js: String, in inspector: NSObject, _ done: ((Any?) -> Void)? = nil) {
        page(inspector)?.evaluateJavaScript("window.__yab && (\(js))") { value, _ in done?(value) }
    }

    /// The element picked in Elements, as markup; empty when none is.
    static func picked(in inspector: NSObject, _ done: @escaping (String) -> Void) {
        guard let web = page(inspector) else { done(""); return }
        web.callAsyncJavaScript("return window.__yab ? await window.__yab.picked() : ''", arguments: [:], in: nil, in: .page) { result in
            done((try? result.get()) as? String ?? "")
        }
    }

    private static func quoted(_ text: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    static let script = PageScript.load("dev-tools")
}

/// Device Settings, as WebKit's inspector has them: each one of its
/// overrides of the page's settings, and the value that turns it on.
enum DevOverride: String, CaseIterable, Hashable {
    case images = "ImagesEnabled", styles = "AuthorAndUserStylesEnabled", scripts = "ScriptEnabled"
    case insecureMedia = "MediaCaptureRequiresSecureConnection", ice = "ICECandidateFilteringEnabled", mockCapture = "MockCaptureDevicesEnabled"

    var title: String {
        switch self {
        case .images: return "Disable Images"
        case .styles: return "Disable Styles"
        case .scripts: return "Disable JavaScript"
        case .insecureMedia: return "Allow Media Capture on Insecure Sites"
        case .ice: return "Disable ICE Candidate Restrictions"
        case .mockCapture: return "Use Mock Capture Devices"
        }
    }

    /// Each is a setting turned off, but mock devices, turned on.
    var value: Bool { self == .mockCapture }
}
