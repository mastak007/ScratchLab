---
name: xcode
description: "Information and usage guide for Xcode MCP. Use when an agent needs to understand how to install, invoke, and use Xcode 27 MCP tools for windows, schemes, run destinations, project navigator files, builds, tests, logs, debugger commands, SwiftUI previews, device interaction, build settings, Info.plist, entitlements, localization, Apple docs, crash reports, or field performance diagnostics."
---

# Xcode MCP

## Overview

This skill is an information and usage guide for the Xcode MCP server. Xcode MCP talks to an open Xcode workspace tab and can inspect or drive actions that depend on workspace state, project navigator membership, active scheme, run destination, previews, builds, tests, app runtime, or Apple service data.

## When To Invoke

Invoke this skill when the task needs Xcode MCP to inspect, change, run, or verify Xcode-managed state.

- Use for Xcode window, workspace tab, scheme, and run destination discovery.
- Use for project navigator files, groups, generated project structure, and Xcode-managed file membership.
- Use for builds, build logs, Issue Navigator diagnostics, compiler diagnostics, test discovery, and test execution through active Xcode schemes.
- Use for SwiftUI previews, app launches, console logs, LLDB debugger commands, and Swift snippets that require source-file context.
- Use for device or simulator interaction through Xcode MCP sessions.
- Use for target build settings, per-file compiler flags, Info.plist keys, and entitlements.
- Use for String Catalog localization tools after required translation skills are available.
- Use for Apple Developer Documentation search, crash reports, and field performance diagnostics exposed through Xcode MCP.
- Do not invoke for work that does not require Xcode MCP.

## Prerequisites

- Require Xcode to be open first, with the target project or workspace loaded.
- Require Xcode 27 or later; Xcode MCP is only available in Xcode 27.
- Require Xcode to be reachable through MCP. Most Xcode MCP tools require a workspace `tabIdentifier`; use `XcodeListWindows` when the active tab identifier is unknown.
- Expect Xcode to prompt for MCP access before Xcode actions run. If the prompt blocks a tool call, give the user up to 1 minute to click **Allow**; if it is still pending after that, run the auto-approve script (see [Approving Xcode MCP Permission Dialogs](#approving-xcode-mcp-permission-dialogs)).
- Treat Xcode's active scheme and run destination as mutable state. List them before changing them when the task depends on a specific target or simulator.
- Use project-structure tools when Xcode navigator membership, generated project structure, or target/project configuration matters.

## If Xcode MCP Is Not Available

If this skill is invoked but no Xcode MCP tools are available, first check whether the server is already registered (e.g. `claude mcp list` or `codex mcp list`). A server can show as connected while still exposing zero tools — that happens when Xcode itself is not open or has no workspace loaded, per Prerequisites above. In that case, ask the user to open Xcode with the target project/workspace rather than reinstalling the MCP server.

Only install or register the Xcode MCP server if it is missing entirely. After installation, restart or reload the agent session so the MCP tool list refreshes.

- Codex:
  ```bash
  codex mcp add xcode -- xcrun mcpbridge
  ```
- Claude Code:
  ```bash
  claude mcp add --transport stdio xcode -- xcrun mcpbridge
  ```
- Other agents: configure a stdio MCP server named `xcode` that runs:
  ```bash
  xcrun mcpbridge
  ```

## Approving Xcode MCP Permission Dialogs

When an agent connects to Xcode MCP, Xcode shows a modal dialog titled like `"<agent> wants to access Xcode?"` with **Allow** / **Deny** buttons. Until it is dismissed with **Allow**, Xcode MCP tool calls stall or fail — the connection is blocked on that dialog.

When the dialog appears, give the user up to 1 minute to click **Allow** themselves. Only if it is still pending after that should you run the bundled auto-approve script.

If an Xcode MCP tool call is blocked or failing on this access dialog, run the bundled auto-approve script to click **Allow** for any pending Xcode MCP dialogs:

```bash
osascript -l JavaScript scripts/approve-xcode-mcp-dialog.js
```

Run it from the skill directory, or pass the full path to the script if invoked from elsewhere. It prints one of:

- `Allowed N MCP connection(s).` — approved one or more waiting dialogs; retry the blocked Xcode MCP tool call.
- `No MCP dialogs found.` — nothing was waiting; the block is something else (Xcode not connected, wrong `tabIdentifier`, server not registered).
- `Xcode not running.` — open Xcode with the target project first.

Requirements:

- Xcode must be running.
- The process running the script (the agent's shell, Terminal, etc.) needs macOS Accessibility permission so it can drive System Events: System Settings > Privacy & Security > Accessibility. Without it, `osascript` cannot click the button; grant access and rerun.

Use this only to clear the Xcode access dialog that is blocking a legitimate, user-requested Xcode action. Do not use it to suppress other confirmations.

## Workflow

1. Confirm Xcode is open with the intended project or workspace.
2. Call `XcodeListWindows` if no `tabIdentifier` is available.
3. Call `XcodeListSchemes` to inspect the active scheme before build/run/preview/test work.
4. Call `XcodeListRunDestinations` when simulator, device, architecture, OS, or SDK matters.
5. Switch scheme or destination only when needed for the user task.
6. Use the narrowest action:
   - Project structure: `XcodeLS`, `XcodeGlob`, `XcodeGrep`, `XcodeRead`, `XcodeGetCurrentFile`
   - Project edits: `XcodeWrite`, `XcodeUpdate`, `XcodeMakeDir`, `XcodeMV`, `XcodeRM`
   - Build: `BuildProject`, then `GetBuildLog`
   - Tests: `GetTestList`, `RunAllTests`, or `RunSomeTests`
   - Preview UI: `RenderPreview`
   - Run app: `RunProject`, then `GetConsoleOutput`, `InvokeDebuggerCommand`, or `StopProject`
   - Inspect runtime Swift behavior in context: `RunCodeSnippet`
   - Device/simulator UI verification: `DeviceInteractionStartSession`, `DeviceInteractionInstallAndRun`, `DeviceInteractionSynthesize`, `DeviceInteractionEndSession`
   - Configuration: `GetTargetBuildSettings`, `UpdateTargetBuildSetting`, `AddInfoPlist`, `AddEntitlement`
   - Prepare localization: `LocalizationPlanner`
7. Report the Xcode state used: active scheme, active destination, source file, preview index, or test list path when relevant.

## Visible Xcode MCP Tools

### Workspace State

Use these to discover and adjust Xcode state before acting.

- `XcodeListWindows`: list current Xcode windows and workspace information. No input. Use first when `tabIdentifier` is unknown.
- `XcodeListSchemes`: list schemes for a workspace tab. Input: `tabIdentifier`. Output includes active scheme, shared status, container, and `fullSchemeListPath`.
- `XcodeSwitchScheme`: change active scheme. Inputs: `tabIdentifier`, `schemeName`. Use disambiguated names from `XcodeListSchemes` when duplicate names exist.
- `XcodeListRunDestinations`: list destinations for the active scheme. Inputs: `tabIdentifier`, optional `includeIncompatible`. Output includes active destination, eligibility, platform, OS, architecture, SDK, and `fullRunDestinationListPath`.
- `XcodeSwitchRunDestination`: change active run destination for the active scheme. Inputs: `tabIdentifier`, `displayTitle` from `XcodeListRunDestinations` or compatible prior outputs.

### Project Navigator And Files

These operate on Xcode project organization paths, not raw filesystem paths.

- `XcodeGetCurrentFile`: read active editor file path, optional content, and optional selection. Inputs: `tabIdentifier`, optional `includeContent`, `includeSelection`, `offset`, `limit`.
- `XcodeLS`: list files/directories under a project path. Inputs: `tabIdentifier`, `path`, optional `recursive`, `ignore`.
- `XcodeGlob`: find project files by wildcard. Inputs: `tabIdentifier`, optional `path`, `pattern`.
- `XcodeGrep`: regex search in project files. Inputs: `tabIdentifier`, required `pattern`, optional `path`, `glob`, `type`, `ignoreCase`, context lines, `headLimit`, `multiline`, `outputMode`, `showLineNumbers`.
- `XcodeRead`: read project file content with line numbers. Inputs: `tabIdentifier`, `filePath`, optional `offset`, `limit`.
- `XcodeWrite`: create or overwrite a project file and add it to project structure. Inputs: `tabIdentifier`, `filePath`, `content`.
- `XcodeUpdate`: replace text in a project file. Inputs: `tabIdentifier`, `filePath`, `oldString`, `newString`, optional `replaceAll`.
- `XcodeMakeDir`: create directories/groups in the project navigator. Inputs: `tabIdentifier`, `directoryPath`.
- `XcodeMV`: move, copy, or rename project navigator items. Inputs: `tabIdentifier`, `sourcePath`, `destinationPath`, optional `operation`, `overwriteExisting`.
- `XcodeRM`: remove project items and optionally underlying files. Inputs: `tabIdentifier`, `path`, optional `recursive`, `deleteFiles`. Treat as destructive; confirm intent before deleting files.

### Build, Issues, And Tests

Use these when Xcode build state or active test plans matter.

- `BuildProject`: build the current project. Inputs: `tabIdentifier`, optional `buildForTesting`.
- `GetBuildLog`: retrieve current or most recent build log. Inputs: `tabIdentifier`, optional `severity`, `pattern`, `glob`.
- `XcodeListNavigatorIssues`: list issues currently visible in Xcode Issue Navigator. Inputs: `tabIdentifier`, optional `severity`, `pattern`, `glob`.
- `XcodeRefreshCodeIssuesInFile`: refresh compiler diagnostics for one project file. Inputs: `tabIdentifier`, `filePath`.
- `GetTestList`: list tests from the active scheme's active test plan. Input: `tabIdentifier`. Output includes inline tests and `fullTestListPath`.
- `RunAllTests`: run all tests from the active scheme's active test plan. Input: `tabIdentifier`.
- `RunSomeTests`: run selected tests. Inputs: `tabIdentifier`, `tests` array containing `targetName` and `testIdentifier` values from `GetTestList`.

### Runtime, Debugging, And Snippets

Use these for launched apps, logs, LLDB, and narrow Swift runtime inspection.

- `RunProject`: build and run current active scheme. Inputs: `tabIdentifier`, optional `attachDebugger`.
- `StopProject`: stop the currently running app. Input: `tabIdentifier`.
- `GetConsoleOutput`: retrieve stdout, stderr, and OSLog from a launch session. Inputs: `tabIdentifier`, optional `launchSessionReference`, `outputType`, `pattern`, `tailLimit`, `contextLines`, `oslogSeverity`, `includeMetadata`.
- `InvokeDebuggerCommand`: run an LLDB command in Xcode's active debug session. Inputs: `tabIdentifier`, `command`, optional `timeout`. Requires the process to be running with debugger attached.
- `RunCodeSnippet`: run Swift code in the context of a specific Swift source file. Inputs: `tabIdentifier`, `sourceFilePath`, `codeSnippet`, `purpose`, optional `timeout`. Do not use the word `test` in `purpose`; print only decisive values.

### SwiftUI Previews

- `RenderPreview`: build and render a SwiftUI preview snapshot. Inputs: `tabIdentifier`, `sourceFilePath`, optional `previewDefinitionIndexInFile`, `previewLocalizationOverride`, `previewVariantOverrides`, `previewCanvasControlOverrides`, `timeout`. Use returned supported variants/locales/canvas controls for follow-up renders.

### Device Interaction

Use for simulator/device UI verification. Start early only when runtime interaction is truly needed, and always end the session.

- `DeviceInteractionStartSession`: prepare an iOS device/simulator runtime. Inputs: `tabIdentifier`, `sessionIdentifier`, optional `deviceIdentifier`. Do not call when the app cannot build/install on iOS.
- `DeviceInteractionInstallAndRun`: build, install, and start the current app on the targeted device. Inputs: `tabIdentifier`, `interactionSessionKey`, optional `commandLineArguments`, `environmentVariables`.
- `DeviceInteractionSynthesize`: tap, swipe, type, press hardware buttons, change orientation, or capture state. Inputs: `interactSessionKey`, optional `interactionCommand`. Base positions on the latest hierarchy dump, not screenshot guesses.
- `DeviceInteractionEndSession`: close a device interaction session. Input: `interactionSessionKey`. Call when finished.

### Project Configuration

Use these instead of reading or editing `project.pbxproj` directly.

- `GetTargetBuildSettings`: get build settings for a target. Inputs: `tabIdentifier`, `targetName`, optional `projectPath`.
- `UpdateTargetBuildSetting`: update, append, or delete a target build setting. Inputs: `tabIdentifier`, `targetName`, `buildSettingName`, optional `buildSettingValue`, `appendValue`, `projectPath`. Preserve Xcode string values such as `NO`; do not convert them to booleans.
- `GetFileCompilerFlags`: inspect per-file compiler flags for a source in a target. Inputs: `tabIdentifier`, `targetName`, `filePath`, optional `projectPath`.
- `UpdateFileCompilerFlags`: update, append, or delete per-file compiler flags. Inputs: `tabIdentifier`, `targetName`, `filePath`, optional `compilerFlags`, `appendValue`, `projectPath`. Prefer target build settings, especially for Swift.
- `AddInfoPlist`: add or update an Info.plist key. Inputs: `tabIdentifier`, `targetName`, `infoPlistKey`, `infoPlistValueType`, value fields, optional `projectPath`. Use for privacy strings, ATS, orientations, URL schemes, background modes, bundle metadata. Do not edit Info.plist directly.
- `AddEntitlement`: add an entitlement. Inputs: `tabIdentifier`, `targetName`, `entitlementKey`, `entitlementValueType`, value fields, optional `projectPath`. Use only for restricted code-signing capabilities. Do not use for normal framework APIs or privacy usage descriptions.

### Localization And String Catalogs

These tools have mandatory skill prerequisites.

- `LocalizationPlanner`: prepare translations for a locale. Inputs: `tabIdentifier`, `targetLocaleIdentifier`. Before calling, activate and read `xcode-integration:translation-coordinator`.
- `StringCatalogRead`: return string keys grouped by translation state. Inputs: `tabIdentifier`, `filePath`, `targetLocaleIdentifier`, optional `requestedState`, `offset`, `keyLimit`. Before calling, activate and read `xcode-integration:translation-coordinator`.
- `StringCatalogContext`: return context and source-language values for a string key. Inputs: `tabIdentifier`, `filePath`, `stringKey`, `targetLocaleIdentifier`. Before calling, activate and read `xcode-integration:translation`.
- `StringCatalogEdit`: insert a translation into a String Catalog. Inputs: `tabIdentifier`, `filePath`, `stringKey`, `targetLocaleIdentifier`, and one of `translation`, `stringSetTranslation`, `templateTranslation`, or `variationTranslation`. Before calling, activate and read `xcode-integration:translation`.

If the required translation skill is unavailable, explain that blocker before calling the tool.

### Apple Documentation And Field Data

These may depend on Apple account/project availability. Do not present unavailable service data as confirmed.

- `DocumentationSearch`: semantic search Apple Developer Documentation. Inputs: `query`, optional `frameworks`. No `tabIdentifier` required.
- `GetTopCrashIssues`: retrieve top crash signatures for the last 14 days. Inputs: `tabIdentifier`, optional `bundle_id`, `platform`, `app_version`, `is_beta`, `count`.
- `GetCrashIssueLogs`: retrieve detailed crash logs for a crash signature. Inputs: `tabIdentifier`, `signature_name`, optional `bundle_id`, `platform`, `app_version`, `is_beta`. Use after `GetTopCrashIssues`.
- `GetTopFieldPerformanceIssues`: retrieve top field performance diagnostics. Inputs: `tabIdentifier`, `diagnostic_type` (`launches`, `hangs`, `diskwrites`, `energy`), optional `bundle_id`, `platform`, `app_version`, `is_beta`.
- `GetFieldPerformanceIssueLogs`: retrieve detailed logs for a field performance issue. Inputs: `tabIdentifier`, `diagnostic_type`, `signature_name`, `app_version`, optional `bundle_id`, `platform`, `is_beta`. Use after `GetTopFieldPerformanceIssues`.

## Common Sequences

- Find active Xcode context: `XcodeListWindows` -> `XcodeListSchemes` -> `XcodeListRunDestinations`.
- Build and inspect errors: `BuildProject` -> `GetBuildLog` -> `XcodeListNavigatorIssues` or `XcodeRefreshCodeIssuesInFile`.
- Run and inspect behavior: `RunProject` with `attachDebugger` as needed -> `GetConsoleOutput` -> `InvokeDebuggerCommand` -> `StopProject`.
- Run targeted tests: `GetTestList` -> `RunSomeTests`; use `RunAllTests` only when full active test plan is desired.
- Verify UI on device/simulator: `DeviceInteractionStartSession` -> `DeviceInteractionInstallAndRun` -> `DeviceInteractionSynthesize` -> `DeviceInteractionEndSession`.
- Add privacy permission text: `GetTargetBuildSettings` if target is unclear -> `AddInfoPlist`.
- Add restricted capability: confirm entitlement is truly required -> `AddEntitlement`.
- Translate strings: required translation skill -> `LocalizationPlanner` -> `StringCatalogRead` -> `StringCatalogContext` -> `StringCatalogEdit`.

## Boundaries

- Do not invent unavailable Xcode MCP tools. Use only tools visible in the current session.
- Do not assume Xcode is already open. Ask the user to open it when `tabIdentifier` cannot be obtained or Xcode MCP calls cannot connect.
- Clear the Xcode MCP access dialog only to unblock a legitimate, user-requested Xcode action — wait for the user to click **Allow** or run `scripts/approve-xcode-mcp-dialog.js`. Do not suppress or auto-dismiss other confirmation prompts.
- When Xcode MCP output provides full list files, use targeted grep/search on those files for exact scheme, destination, or test names.

## References

- For Apple Xcode agent setup and customization docs, read [references/apple-xcode-agent-docs.md](references/apple-xcode-agent-docs.md).
