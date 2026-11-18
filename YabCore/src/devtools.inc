// Give the bundled frontend an independent CDP session. Creating it as an
// ordinary page avoids Chrome's late-wrapped DevTools WebContents, which has
// no CEF main frame in the pinned SDK and traps while loading resources.
struct DevToolsRelay {
  std::string owner, front, token;
  NSString* target = @"";
  NSString* session = nil;
  NSString* pageSession = nil;
  CefRefPtr<CefServer> server;
  int connection = -1;
  std::set<std::string> children;
  std::map<int, NSDictionary*> messages;
  bool stopped = false, inspect = false, tabTarget = false;
  // Chrome's docked frontend (can_dock): its own dock sides and device
  // mode, the client placing the page where setInspectedPageBounds says.
  bool dock = false;
  int x = 0, y = 0;
  int extensionTab = 0;
  std::map<std::string, NSString*> savedFiles;
  dispatch_queue_t fileQueue = dispatch_queue_create("devtools.files", DISPATCH_QUEUE_SERIAL);
};
static std::map<std::string, std::shared_ptr<DevToolsRelay>> devToolsRelays;

static void DevToolsSend(const std::shared_ptr<DevToolsRelay>& relay, NSDictionary* message) {
  if (relay->stopped || !relay->server || relay->connection < 0) return;
  NSString* json = JSON(message);
  relay->server->SendWebSocketMessage(relay->connection, json.UTF8String,
                                      [json lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}
static void DevToolsInspect(const std::shared_ptr<DevToolsRelay>& relay) {
  auto owner = tabs.find(relay->owner);
  if (!relay->inspect || relay->stopped || !relay->pageSession || owner == tabs.end()) return;
  relay->inspect = false;
  NSString* pageSession = relay->pageSession;
  CDP(owner->second, @"DOM.getNodeForLocation", @{@"x": @(relay->x), @"y": @(relay->y), @"includeUserAgentShadowDOM": @YES},
    [relay, pageSession](NSDictionary* result, NSString* error) {
      if (!error && result[@"backendNodeId"] && [pageSession isEqual:relay->pageSession]) {
        NSMutableDictionary* event = [@{@"method": @"Overlay.inspectNodeRequested", @"params": @{@"backendNodeId": result[@"backendNodeId"]}} mutableCopy];
        if (![pageSession isEqual:relay->session]) event[@"sessionId"] = pageSession;
        DevToolsSend(relay, event);
      }
    }, pageSession);
}
#include "devtools_files.inc"
static bool DevToolsMessage(CefRefPtr<CefBrowser> browser, NSDictionary* message) {
  if (DevToolsFileMessage(browser, message)) return true;
  auto owner = Find(browser); if (!owner) return false;
  auto found = devToolsRelays.find(owner->devToolsFront);
  if (found == devToolsRelays.end()) return false;
  auto relay = found->second;
  if (message[@"id"]) {
    auto response = relay->messages.find([message[@"id"] intValue]);
    if (response == relay->messages.end()) return false;
    NSMutableDictionary* copy = [message mutableCopy];
    copy[@"id"] = response->second[@"id"];
    if (response->second[@"sessionId"]) copy[@"sessionId"] = response->second[@"sessionId"];
    else [copy removeObjectForKey:@"sessionId"];
    bool document = [S(response->second, @"method") isEqual:@"DOM.getDocument"];
    relay->messages.erase(response);
    DevToolsSend(relay, copy);
    if (document && relay->inspect) dispatch_async(dispatch_get_main_queue(), ^{ DevToolsInspect(relay); });
    return true;
  }
  NSString* session = S(message, @"sessionId");
  if (![session isEqual:relay->session] && !relay->children.count(Key(session))) return false;
  NSString* method = S(message, @"method");
  if ([method isEqual:@"Target.attachedToTarget"]) {
    NSString* child = S(message[@"params"], @"sessionId");
    relay->children.insert(Key(child));
    NSDictionary* info = message[@"params"][@"targetInfo"];
    if (relay->tabTarget && [session isEqual:relay->session] && [S(info, @"type") isEqual:@"page"] && !S(info, @"subtype").length)
      relay->pageSession = child;
  }
  if ([method isEqual:@"Target.detachedFromTarget"]) {
    NSString* child = S(message[@"params"], @"sessionId");
    relay->children.erase(Key(child));
    if ([child isEqual:relay->pageSession]) relay->pageSession = nil;
  }
  NSMutableDictionary* copy = [message mutableCopy];
  if ([session isEqual:relay->session]) [copy removeObjectForKey:@"sessionId"];
  DevToolsSend(relay, copy);
  return true;
}
static void DevToolsClosed(const std::string& tab) {
  std::vector<std::shared_ptr<DevToolsRelay>> closing;
  for (auto& [id, relay] : devToolsRelays)
    if (relay->owner == tab || relay->front == tab) closing.push_back(relay);
  for (auto& relay : closing) {
    relay->stopped = true;
    devToolsRelays.erase(relay->front);
    auto owner = tabs.find(relay->owner);
    if (owner != tabs.end()) {
      // A closing frontend can outlive a quick reopen for the same owner.
      if (owner->second.devToolsFront == relay->front) owner->second.devToolsFront.clear();
      // devtools.close names the live owner too. Only destruction of the
      // inspected browser makes detach unnecessary; closing its frontend
      // must release the independent session (including inspect mode).
      if (relay->session && owner->second.browser && !owner->second.closing)
        CDP(owner->second, @"Target.detachFromTarget", @{@"sessionId": relay->session}, Ignore);
    }
    if (relay->server) { relay->server->Shutdown(); relay->server = nullptr; }
    if (relay->front != tab) {
      auto front = tabs.find(relay->front);
      if (front != tabs.end() && front->second.browser && !front->second.closing)
        front->second.browser->GetHost()->CloseBrowser(true);
    }
  }
}
class DevToolsServer : public CefServerHandler {
  std::shared_ptr<DevToolsRelay> relay_;
  NSString* request_;
 public:
  DevToolsServer(std::shared_ptr<DevToolsRelay> relay, NSString* request) : relay_(relay), request_(request) {}
  void OnServerCreated(CefRefPtr<CefServer> server) override {
    bool running = server->IsRunning();
    std::string address = server->GetAddress();
    auto relay = relay_; NSString* request = request_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (relay->stopped) { server->Shutdown(); return; }
      if (!running) { Reply(request, nil, @"Could not start DevTools transport"); DevToolsClosed(relay->front); return; }
      relay->server = server;
      auto owner = tabs.find(relay->owner);
      if (owner == tabs.end()) { DevToolsClosed(relay->front); return; }
      CDP(owner->second, @"Target.getTargetInfo", @{}, [relay, request, address](NSDictionary* ownerResult, NSString* error) {
        auto owner = tabs.find(relay->owner);
        if (relay->stopped || owner == tabs.end()) return;
        if (error) { Reply(request, nil, error); DevToolsClosed(relay->front); return; }
        auto attach = [relay, request, address, ownerResult](NSDictionary* result, NSString* error) {
          auto owner = tabs.find(relay->owner);
          if (relay->stopped || owner == tabs.end()) return;
          if (error) { Reply(request, nil, error); DevToolsClosed(relay->front); return; }
          NSDictionary* info = result[@"targetInfo"];
          if (relay->target.length) {
            // Explicit popup/worker inspection stays inside the owner's
            // extension and browser context, including private profiles.
            NSDictionary* own = ownerResult[@"targetInfo"];
            NSURL* source = [NSURL URLWithString:Str(owner->second.browser->GetMainFrame()->GetURL())];
            NSURL* destination = [NSURL URLWithString:S(info, @"url")];
            if (![source.scheme isEqual:@"chrome-extension"] ||
                ![destination.scheme isEqual:source.scheme] || ![destination.host isEqual:source.host] ||
                !S(own, @"browserContextId").length ||
                ![S(info, @"browserContextId") isEqual:S(own, @"browserContextId")]) {
              Reply(request, nil, @"DevTools target does not belong to this extension and profile");
              DevToolsClosed(relay->front); return;
            }
            // A worker or action popup has no inspected tab. Never seed
            // DevTools extensions with the unrelated owner tab's identity.
            relay->extensionTab = 0;
          }
          NSString* target = S(info, @"targetId");
          std::string type = Key(S(info, @"type"));
          CDP(owner->second, @"Target.attachToTarget", @{@"targetId": target, @"flatten": @YES},
          [relay, request, address, type, target](NSDictionary* attached, NSString* error) {
            auto front = tabs.find(relay->front);
            if (relay->stopped || front == tabs.end()) return;
            if (error) { Reply(request, nil, error); DevToolsClosed(relay->front); return; }
            relay->session = S(attached, @"sessionId");
            relay->tabTarget = type == "tab";
            if (type != "tab" && type != "service_worker" && type != "shared_worker" && type != "worker")
              relay->pageSession = relay->session;
            bool dock = relay->dock && DevToolsFrontend(type) == "devtools_app.html";
            NSString* url = [NSString stringWithFormat:@"devtools://devtools/bundled/%s?ws=%s/%s%s%s",
              DevToolsFrontend(type).c_str(), address.c_str(), relay->token.c_str(), DevToolsTargetQuery(type).c_str(),
              dock ? "&can_dock=true" : ""];
            auto load = [relay, request, url, target](NSDictionary*, NSString* error) {
              auto front = tabs.find(relay->front);
              if (relay->stopped || front == tabs.end() || front->second.closing) return;
              if (error) { Reply(request, nil, error); DevToolsClosed(relay->front); return; }
              front->second.browser->GetMainFrame()->LoadURL(Key(url));
              Reply(request, @{@"tab": @(relay->front.c_str()), @"extensionTabId": @(relay->extensionTab), @"targetId": target});
            };
            // Install the file host before the compatibility module initializes.
            // Runtime binding events carry the native execution context identity.
            auto source = DevToolsExtensionIdentity(relay->extensionTab) + ";" + DevToolsFileBridge();
            CDP(front->second, @"Runtime.addBinding", @{@"name": @"yabDevToolsFile"},
              [relay, source, load](NSDictionary*, NSString* error) {
                auto front = tabs.find(relay->front);
                if (relay->stopped || front == tabs.end()) return;
                if (error) { load(nil, error); return; }
                CDP(front->second, @"Page.addScriptToEvaluateOnNewDocument", @{@"source": @(source.c_str())}, load);
              });
          });
        };
        if (relay->target.length)
          CDP(owner->second, @"Target.getTargetInfo", @{@"targetId": relay->target}, attach);
        else attach(ownerResult, nil);
      });
    });
  }
  void OnServerDestroyed(CefRefPtr<CefServer>) override {}
  void OnClientConnected(CefRefPtr<CefServer>, int) override {}
  void OnClientDisconnected(CefRefPtr<CefServer>, int connection) override {
    auto relay = relay_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (relay->connection == connection) { relay->connection = -1; relay->messages.clear(); }
    });
  }
  void OnHttpRequest(CefRefPtr<CefServer> server, int connection, const CefString&, CefRefPtr<CefRequest>) override {
    server->SendHttp404Response(connection);
  }
  void OnWebSocketRequest(CefRefPtr<CefServer> server, int connection, const CefString&, CefRefPtr<CefRequest> request, CefRefPtr<CefCallback> callback) override {
    std::string expected = "ws://" + server->GetAddress().ToString() + "/" + relay_->token;
    bool valid = request->GetURL().ToString() == expected && request->GetHeaderByName("Origin") == "devtools://devtools";
    if (!valid) { callback->Cancel(); return; }
    auto relay = relay_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (relay->stopped || relay->connection >= 0) callback->Cancel();
      else { relay->connection = connection; callback->Continue(); }
    });
  }
  void OnWebSocketConnected(CefRefPtr<CefServer>, int) override {}
  void OnWebSocketMessage(CefRefPtr<CefServer>, int connection, const void* bytes, size_t size) override {
    NSDictionary* message = Decode(bytes, size); auto relay = relay_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (relay->stopped || relay->connection != connection || ![message[@"id"] isKindOfClass:NSNumber.class] || !S(message, @"method").length) return;
      auto owner = tabs.find(relay->owner); if (owner == tabs.end() || owner->second.closing) return;
      NSString* session = S(message, @"sessionId");
      if (session.length && !relay->children.count(Key(session))) return;
      NSMutableDictionary* copy = [message mutableCopy];
      int id = ++sequence;
      relay->messages[id] = message;
      copy[@"id"] = @(id); copy[@"sessionId"] = session.length ? session : relay->session;
      NSString* json = JSON(copy);
      if (!owner->second.browser->GetHost()->SendDevToolsMessage(json.UTF8String, [json lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) {
        relay->messages.erase(id);
        DevToolsSend(relay, @{@"id": message[@"id"], @"error": @{@"code": @-32000, @"message": @"Debugger session closed"}});
      }
    });
  }
  IMPLEMENT_REFCOUNTING(DevToolsServer);
};
static bool DevToolsRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"devtools.close"]) {
    DevToolsClosed(t.id);
    Reply(request, @{});
    return true;
  }
  if (![method isEqual:@"devtools.open"]) return false;
  // Native Chrome windows and adopted external pages have no BrowserView.
  // The inspected browser owns CDP regardless of how its pixels are hosted.
  if (t.internal || t.devToolsFrontend || !t.browser) { Reply(request, nil, @"This tab has no DevTools"); return true; }
  auto existing = tabs.find(t.devToolsFront);
  if (existing != tabs.end()) {
    auto relay = devToolsRelays.find(existing->first);
    if (relay != devToolsRelays.end() && ![relay->second->target isEqual:S(p, @"targetId")]) {
      DevToolsClosed(existing->first);
      existing = tabs.end();
    }
  }
  if (existing != tabs.end() && !existing->second.closing) {
    auto relay = devToolsRelays.find(existing->first);
    if (relay != devToolsRelays.end() && p[@"x"] && p[@"y"]) {
      relay->second->x = [p[@"x"] intValue]; relay->second->y = [p[@"y"] intValue]; relay->second->inspect = true;
      DevToolsInspect(relay->second);
    }
    Reply(request, @{@"tab": @(existing->first.c_str())}); return true;
  }
  std::string owner = t.id, profile = t.profile;
  int extensionTab = 0;
#if YABCORE_NATIVE_TAB_MODEL && YABCORE_NATIVE_PAGE
  // Capture before creating another Chrome window can change native state.
  auto native = t.browser->GetHost()->GetExternalPageState();
  auto nativeTab = native ? native->GetValue("extensionTabId") : nullptr;
  if (native && native->GetInt("browserId") == t.browser->GetIdentifier() &&
      nativeTab && nativeTab->GetType() == VTYPE_INT && nativeTab->GetInt() > 0)
    extensionTab = nativeTab->GetInt();
#endif
  auto front = Create(profile, @"about:blank", nil);
  if (front.empty()) { Reply(request, nil, @"Could not create DevTools page"); return true; }
  tabs.at(front).devToolsFrontend = true;
  tabs.at(owner).devToolsFront = front;
  auto relay = std::make_shared<DevToolsRelay>();
  relay->owner = owner; relay->front = front; relay->token = Key(NSUUID.UUID.UUIDString);
  relay->extensionTab = extensionTab;
  relay->target = S(p, @"targetId");
  relay->dock = [p[@"dock"] boolValue];
  if (p[@"x"] && p[@"y"]) { relay->inspect = true; relay->x = [p[@"x"] intValue]; relay->y = [p[@"y"] intValue]; }
  devToolsRelays[front] = relay;
  CefServer::CreateServer("127.0.0.1", 0, 1, new DevToolsServer(relay, request));
  return true;
}
