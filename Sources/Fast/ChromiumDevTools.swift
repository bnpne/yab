import AppKit
import SwiftUI
import WebKit
import YabCoreClient

/// Chrome's own DevTools for a Chromium tab, in the card, under the card's
/// head. The frontend is a page like any other to the helper (devtools.inc):
/// a ChromiumPage of a Tab no window lists, so pixels, resizing, keys and
/// menus come as a page's do. Its own row of tabs is put away, the head says
/// which panel shows. One for each tab that had the card, as Chromium's.
@MainActor
final class ChromiumDevFrontend {
    weak var owner: Tab?
    let tab: Tab
    let page: ChromiumPage
    private let events = ChromiumDevEvents()
    fileprivate(set) var ready = false
    fileprivate(set) var panels: [DevPanel] = []
    fileprivate(set) var selected = ""
    fileprivate(set) var picking = false
    /// What the head asked for, until the frontend has shown it.
    fileprivate var wanted: String?
    /// Next time the frontend is up, the keyboard goes to it.
    fileprivate var wantsFocus = false
    private var waitingAction: String?
    fileprivate var beat: Task<Void, Never>?
    /// Chrome's whole window in the page's place (Tab.chromeWhole): its own
    /// row of tabs, dock sides and device mode, the page where it says.
    let docked: Bool
    /// Where Chrome puts the page, in the frontend's points from its top
    /// left; nil until it has said, the page over all of it till then.
    private(set) var place: CGRect?
    private var dockBeat: Task<Void, Never>?

    /// A page on this Mac, a dev server's: Chrome's whole DevTools for it.
    static func wholeFor(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
    }

    init?(owner: Tab, browser: Browser, docked: Bool = false) {
        self.owner = owner
        self.docked = docked
        let profile = owner.chromiumProfile
        tab = Tab(shy: owner.shy, configuration: Web.configuration(shy: owner.shy, store: owner.store), engine: .chromium)
        events.browser = browser
        tab.warmProfile = profile
        tab.delegate = events
        guard let page = tab.prepareChromiumPageForAdoption(profile: profile) else { tab.close(); return nil }
        self.page = page
        page.isDevToolsFrontend = true
        page.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        page.onDocumentClosed = { [weak self] in self?.ended() }
    }

    func open(at point: CGPoint?) {
        guard let ownerPage = owner?.builtPage as? ChromiumPage else { return }
        Task { @MainActor [weak self] in
            // Chrome's last window for this page may still be closing.
            for attempt in 1...6 {
                do {
                    let (core, id) = try await ownerPage.endpoint()
                    var params: [String: JSONValue] = ["tab": .string(id)]
                    if self?.docked == true { params["dock"] = .bool(true) }
                    if let point {
                        params["x"] = .number(Double(max(point.x, 1)))
                        params["y"] = .number(Double(max(point.y, 1)))
                    }
                    let reply = try await core.request("devtools.open", params: params)
                    guard let self, let remote = reply["tab"].string else { return }
                    if self.page.remoteID == nil, !self.page.retired { self.page.adoptRemote(remote) }
                    return
                } catch {
                    guard attempt == 6 else {
                        try? await Task.sleep(for: .milliseconds(300))
                        continue
                    }
                    NSLog("Yab DevTools: %@", String(describing: error))
                    self?.ended()
                }
            }
        }
    }

    /// Chrome closed it, with the page or the helper.
    private func ended() {
        beat?.cancel()
        dockBeat?.cancel()
        if owner?.chromiumDev === self { owner?.chromiumDev = nil; owner?.chromeWhole = false }
        tab.close()
    }

    func close() {
        beat?.cancel()
        dockBeat?.cancel()
        (owner?.builtPage as? ChromiumPage)?.command("devtools.close")
        if owner?.chromiumDev === self { owner?.chromiumDev = nil; owner?.chromeWhole = false }
        page.onDocumentClosed = nil
        tab.close()
    }

    /// The panel's script, in the frontend's own document. The row goes as
    /// soon as there is one: nothing of it should ever be seen.
    private static let legacy = "const U = await import('devtools://devtools/bundled/ui/legacy/legacy.js');"
    private static let readState = legacy + """
    const v = U.InspectorView.InspectorView.maybeGetInspectorViewInstance();
    if (!v || !v.tabbedPane) return {ready: false};
    if (!docked) v.tabbedPane.headerElement().style.display = 'none';
    const pane = v.tabbedPane;
    const panels = pane.tabIds().filter(id => id.startsWith('chrome-extension://'))
        .map(id => ({id, title: String(pane.tabView(id)?.title?.() ?? pane.tabs?.find(t => t.id === id)?.title ?? id)}));
    const registry = U.ActionRegistry.ActionRegistry.instance();
    const picker = registry.hasAction('elements.toggle-element-search') ? registry.getAction('elements.toggle-element-search') : null;
    const C = await import('devtools://devtools/bundled/core/sdk/sdk.js');
    const targets = C.TargetManager.TargetManager.instance();
    return {ready: true, selected: pane.selectedTabId || '', panels, picking: !!picker?.toggled(),
            errors: C.ConsoleModel.ConsoleModel.allErrors(targets), warnings: C.ConsoleModel.ConsoleModel.allWarnings(targets)};
    """

    /// Runs in the frontend once it can answer.
    func run(_ body: String) {
        Task { @MainActor [page] in _ = try? await page.call(Self.legacy + body, gesture: false) }
    }

    func show(_ panel: String) {
        wanted = panel
        guard ready else { return }
        run("await U.ViewManager.ViewManager.instance().showView(\(Self.quoted(panel)));")
    }

    /// One of the frontend's own actions, as its keys or its row would run it.
    func action(_ id: String) {
        guard ready else { waitingAction = id; return }
        run("U.ActionRegistry.ActionRegistry.instance().getAction(\(Self.quoted(id))).execute();")
    }

    fileprivate static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]),
              let list = String(data: data, encoding: .utf8) else { return "''" }
        return String(list.dropFirst().dropLast())
    }

    /// Reads the frontend while the card is out on its tab: what it shows,
    /// and which panels extensions gave it. Quick until it is up.
    fileprivate func watch(in browser: Browser) {
        if docked, dockBeat == nil { follow() }
        beat?.cancel()
        beat = Task { @MainActor [weak self, weak browser] in
            while !Task.isCancelled {
                guard let self, let browser, browser.chromiumDevFront?.chromiumDev === self else { return }
                if let state = try? await self.page.call(Self.readState, arguments: ["docked": self.docked], gesture: false) as? [String: Any], !Task.isCancelled {
                    self.heard(state, browser: browser)
                }
                try? await Task.sleep(for: .milliseconds(self.ready ? 400 : 80))
            }
        }
    }

    /// What the docked frontend told its embedder (__yabDock, YabCore's
    /// devtools_files.h), waited for: the page's place, docking, closing.
    private static let dockState = """
    const d = globalThis.__yabDock;
    if (!d) return null;
    if (d.turn === seen) await new Promise(wake => { d.waiting.push(wake); setTimeout(wake, 4000); });
    return {turn: d.turn, bounds: d.bounds, docked: d.docked, closed: d.closed};
    """
    /// Undocked from Chrome's own menu: back to the side it was on. The
    /// frontend has no window of its own to go to here.
    private static let redock = """
    const C = await import('devtools://devtools/bundled/core/common/common.js');
    const last = C.Settings.Settings.instance().createSetting('last-dock-state', 'right').get();
    U.DockController.DockController.instance().setDockSide(last && last !== 'undocked' ? last : 'right');
    """

    private func follow() {
        dockBeat = Task { @MainActor [weak self] in
            var seen = -1, closed = 0
            while !Task.isCancelled {
                guard let self, !self.page.retired else { return }
                guard let state = try? await self.page.call(Self.dockState, arguments: ["seen": seen], gesture: false) as? [String: Any] else {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                guard !Task.isCancelled else { return }
                seen = (state["turn"] as? NSNumber)?.intValue ?? seen
                if let b = state["bounds"] as? [String: Any], let x = (b["x"] as? NSNumber)?.doubleValue, let y = (b["y"] as? NSNumber)?.doubleValue,
                   let width = (b["width"] as? NSNumber)?.doubleValue, let height = (b["height"] as? NSNumber)?.doubleValue {
                    placed(CGRect(x: x, y: y, width: max(0, width), height: max(0, height)))
                }
                if state["docked"] as? Bool == false { run(Self.redock) }
                let asked = (state["closed"] as? NSNumber)?.intValue ?? 0
                if asked > closed {
                    closed = asked
                    // Chrome's own close button: the tools away, as ⌥⌘I.
                    if let browser = events.browser, browser.toolsFront === owner { browser.closeDevTools() } else { close() }
                    return
                }
            }
        }
    }

    /// The page goes where Chrome said, on its stage, at once.
    private func placed(_ rect: CGRect) {
        guard rect != place else { return }
        place = rect
        (owner?.builtPage as? NSView)?.superview?.needsLayout = true
    }

    private func heard(_ state: [String: Any], browser: Browser) {
        guard state["ready"] as? Bool == true else { return }
        panels = (state["panels"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            return DevPanel(id: id, title: title)
        }
        selected = state["selected"] as? String ?? ""
        picking = state["picking"] as? Bool == true
        if !ready {
            ready = true
            owner?.chromiumDevReady += 1
            if let wanted { show(wanted) }
            if let waitingAction { self.waitingAction = nil; action(waitingAction) }
        }
        if wanted == selected { wanted = nil }
        if wantsFocus {
            wantsFocus = false
            page.window?.makeFirstResponder(page)
        }
        browser.chromiumDevHeard(self, errors: state["errors"] as? Int ?? 0, warnings: state["warnings"] as? Int ?? 0)
    }
}

/// The head's panes in the frontend's words.
enum ChromiumDevPanes {
    static func panel(_ pane: DevPane, among panels: [DevPanel]) -> String? {
        switch normal(pane) {
        case .elements: return "elements"
        case .console: return "console"
        case .sources: return "sources"
        case .network: return "network"
        case .performance: return "timeline"
        case .memory: return "heap-profiler"
        case .application: return "resources"
        case .security: return "security"
        case .audit: return "lighthouse"
        case .recorder: return "chrome-recorder"
        case .layers: return "layers"
        case .webkit(.graphics): return "animations"
        case .panel(let title): return panels.first { $0.title == title }?.id
        default: return nil
        }
    }

    /// WebKit's rows and Yab's lists are the same places in Chrome's row.
    static func normal(_ pane: DevPane) -> DevPane {
        switch pane {
        case .errors, .warnings, .webkit(.console): return .console
        case .webkit(.elements): return .elements
        case .webkit(.sources): return .sources
        case .webkit(.requests): return .network
        case .webkit(.timelines): return .performance
        case .webkit(.memory): return .memory
        case .webkit(.storage): return .application
        case .webkit(.layers): return .layers
        case .webkit(.audit): return .audit
        default: return pane
        }
    }

    /// What the head shows lit for what the frontend shows; nil for a panel
    /// the head has no place for (Search, a More Tools panel), left alone.
    static func pane(_ panel: String, among panels: [DevPanel]) -> DevPane? {
        if let extra = panels.first(where: { $0.id == panel }) { return .panel(extra.title) }
        let own: [DevPane] = [.elements, .console, .sources, .network, .performance, .memory, .application, .security, .audit, .recorder, .layers, .webkit(.graphics)]
        return own.first { Self.panel($0, among: []) == panel }
    }
}

extension Tab {
    /// This tab's page is Chromium's: its card holds Chrome's DevTools.
    var usesChromiumDev: Bool { builtPage?.engine == .chromium }
}

extension Browser {
    /// The tab in front, when the card over it is Chrome's.
    var chromiumDevFront: Tab? {
        guard let tab = toolsFront, tab.usesChromiumDev else { return nil }
        return tab
    }

    /// The frontend up for `tab`, on `pane`, or the point to inspect.
    func showChromiumDev(_ tab: Tab, pane: DevPane, inspecting point: CGPoint? = nil, focus: Bool = true) {
        let made = tab.chromiumDev == nil
        if made {
            // A local page gets Chrome's whole window in its place; any other the card.
            let whole = ChromiumDevFrontend.wholeFor(tab.address)
            tab.chromiumDev = ChromiumDevFrontend(owner: tab, browser: self, docked: whole)
            if whole, tab.chromiumDev != nil {
                // Chrome's device mode, not Yab's, emulates in it.
                if tab.device != nil { tab.setDevice(nil, remember: false) }
                tab.chromeWhole = true
            }
        }
        guard let frontend = tab.chromiumDev else { return }
        frontend.watch(in: self)
        if devPanels != frontend.panels { devPanels = frontend.panels }
        // Asked while one is up, ShowDevTools only inspects the point.
        if made || point != nil { frontend.open(at: point) }
        if let panel = ChromiumDevPanes.panel(pane, among: frontend.panels) { frontend.show(panel) }
        guard focus else { return }
        if frontend.ready { frontend.page.window?.makeFirstResponder(frontend.page) }
        else { frontend.wantsFocus = true }
    }

    /// What the frontend said, for the head.
    fileprivate func chromiumDevHeard(_ frontend: ChromiumDevFrontend, errors: Int, warnings: Int) {
        if devPanels != frontend.panels { devPanels = frontend.panels }
        if devPicking != frontend.picking { devPicking = frontend.picking }
        if let tab = frontend.owner { tab.devModel(ConsoleLog.self).counts.set(errors: errors, warnings: warnings) }
        if frontend.wanted == nil, devOpen, let pane = ChromiumDevPanes.pane(frontend.selected, among: frontend.panels), pane != ChromiumDevPanes.normal(devPane) {
            devPane = pane
        }
    }

    /// ⌥⌘C and the head's picker: Chrome's, in the card.
    func pickWithChromium(_ tab: Tab) {
        tab.measure(false)
        if !devOpen, !devComing { openDevTools(.elements) } else { pickDevPane(.elements) }
        tab.chromiumDev?.action("elements.toggle-element-search")
    }

    /// The menu's Inspect Element: that very element, in Elements.
    func inspectChromium(_ tab: Tab, at point: CGPoint) {
        guard tab === toolsFront else { return }
        devPane = .elements
        showChromiumDev(tab, pane: .elements, inspecting: point)
        if !devOpen, !devComing { openDevTools(.elements) }
    }
}

/// The frontend's page, in the card.
struct ChromiumDevHost: NSViewRepresentable {
    let page: NSView?

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ container: NSView, context: Context) {
        guard let page else { container.subviews.forEach { $0.removeFromSuperview() }; return }
        guard page.superview !== container else { return }
        page.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        page.frame = container.bounds
        page.autoresizingMask = [.width, .height]
        container.addSubview(page)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Keys of the frontend's own while it has the keyboard: Search in All
/// Files, Quick Open, Command Menu, Find, Save, clearing the console. Past
/// the window's menus, where they would be the page's.
@MainActor enum ChromiumDevKeys {
    static func take(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let page = event.window?.firstResponder as? ChromiumPage, page.isDevToolsFrontend else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let own: Set<String> = ["f", "g", "k", "o", "p", "s", "l", "\\", "'", ";", "e", "h"]
        // ⌘W, ⌘T, ⌥⌘I and the rest stay the browser's.
        guard flags.subtracting(.shift) == .command || flags == [.command, .option], own.contains(key),
              !(flags == [.command, .option] && key != "f") else { return false }
        page.keyDown(with: event)
        return true
    }
}

/// The frontend has no ordinary tab in Browser.tabs. Its file questions still
/// belong to the window hosting the DevTools card. PageEvents' default answer
/// is cancellation, which silently discarded Import HAR and CEF's save panel.
@MainActor
final class ChromiumDevEvents: NSObject, WKNavigationDelegate, WKUIDelegate, PageEvents {
    weak var browser: Browser?

    func page(_ page: any PageHandle, navigation event: PageNavigationEvent) { }

    func page(_ page: any PageHandle, decide response: PageDocumentResponse,
              reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }

    func page(_ page: any PageHandle, chooseFiles picker: PageFilePicker,
              reply: @escaping @MainActor ([URL]?) -> Void) {
        guard let browser else { reply(nil); return }
        browser.page(page, chooseFiles: picker, reply: reply)
    }

    func page(_ page: any PageHandle, open popup: PagePopup,
              reply: @escaping @MainActor (UUID?) -> Void) {
        if let url = popup.action.request.url, url.scheme == "https" || url.scheme == "http", let browser {
            _ = browser.open(url, foreground: true, atEnd: true)
        }
        reply(nil)
    }
}
