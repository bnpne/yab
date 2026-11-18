#pragma once
#include <string>

namespace yc {
// An ordinary devtools:// page has compatibility bindings, but no
// DevToolsWindow to service save/append. Keep the stock FileManager contract;
// only those two host methods cross our native binding.
inline std::string DevToolsFileBridge() {
  return R"JS((()=>{
    if (self !== top || location.origin !== 'devtools://devtools') return;
    // A docked frontend (can_dock) tells its embedder where the page goes,
    // that it docks or undocks, and its close button; hosted, Chrome's stub
    // drops all three. Kept here for the client to read (__yabDock.turn).
    const dock = {bounds: null, docked: true, closed: 0, turn: 0, waiting: []};
    Object.defineProperty(globalThis, '__yabDock', {value: dock});
    const told = () => { dock.turn++; for (const wake of dock.waiting.splice(0)) wake(); };
    const connect = host => {
      if (!host) return;
      host.setInspectedPageBounds = b => {
        dock.bounds = {x: b.x, y: b.y, width: b.width, height: b.height}; told();
      };
      host.setIsDocked = (docked, done) => { dock.docked = docked; told(); setTimeout(done, 0); };
      host.closeWindow = () => { dock.closed++; told(); };
      host.save = (url, content, forceSaveAs, isBase64) =>
        yabDevToolsFile(JSON.stringify({method:'save', url, content, forceSaveAs, isBase64}));
      host.append = (url, content) =>
        yabDevToolsFile(JSON.stringify({method:'append', url, content}));
    };
    let current = globalThis.InspectorFrontendHost;
    Object.defineProperty(globalThis, 'InspectorFrontendHost', {
      configurable:true, enumerable:true,
      get() { return current; },
      set(host) { current = host; connect(host); }
    });
    connect(current);
  })())JS";
}
}
