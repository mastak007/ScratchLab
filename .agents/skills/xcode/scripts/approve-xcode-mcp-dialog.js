#!/usr/bin/env osascript -l JavaScript
//
// approve-xcode-mcp-dialog.js
//
// Auto-approves Xcode's MCP permission dialog ("<agent> wants to access
// Xcode?") by clicking "Allow". Run this when an Xcode MCP tool call is
// blocked or failing because that dialog is waiting for a response.
//
// Usage:
//   osascript -l JavaScript path/to/approve-xcode-mcp-dialog.js
//
// Requirements:
//   - Xcode must be running.
//   - The process running this script (Terminal, the agent's shell, etc.)
//     needs macOS Accessibility permission so it can drive System Events:
//     System Settings > Privacy & Security > Accessibility.
//
// Output (returned as stdout):
//   "Allowed N MCP connection(s)." on success,
//   "No MCP dialogs found." if nothing was waiting,
//   "Xcode not running." if Xcode is not open.

function run() {
    var se = Application("System Events");
    try { se.processes.byName("Xcode").name(); } catch (e) { return "Xcode not running."; }

    var count = 0;
    var windows = se.processes.byName("Xcode").windows();
    for (var i = 0; i < windows.length; i++) {
        try {
            var w = windows[i];
            if (w.subrole() !== "AXDialog") continue;
            if (!w.staticTexts().some(function(t) { return (t.value() || "").indexOf("to access Xcode?") !== -1; })) continue;
            w.buttons.byName("Allow").click();
            count++;
        } catch (e) {}
    }
    return count ? "Allowed " + count + " MCP connection(s)." : "No MCP dialogs found.";
}
