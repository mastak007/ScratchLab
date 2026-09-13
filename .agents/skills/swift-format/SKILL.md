---
name: swift-format
description: Operate Apple's swift-format to format or lint Swift source. Use when the user asks to format Swift code, fix indentation/style, lint Swift, set up a .swift-format config, or enforce a consistent Swift style across the project. Covers locating the tool, every CLI option, all configuration keys, and safe run recipes.
---

# swift-format

Apple's official Swift formatter/linter. Ships inside Xcode's toolchain. Use it to
**format** (rewrite files to a canonical style) or **lint** (report style issues without
editing). This skill tells an agent how to find it, drive it, configure it, and where its
limits are.

---

## 1. How to find it

Prefer the copy bundled with Xcode — no install needed:

```bash
xcrun --find swift-format      # prints the path, e.g. .../XcodeDefault.xctoolchain/usr/bin/swift-format
xcrun swift-format --version   # confirm it runs
```

If `xcrun` can't find it, check the other common sources in this order:

```bash
which swift-format             # Homebrew / manual install on PATH
swift format --version         # SwiftPM plugin form (note the space), when run inside a package
```

If none resolve, it isn't available. Offer to install it:

```bash
brew install swift-format
```

Throughout this skill, `swift-format` means "the resolved binary" — prepend `xcrun ` when
you're using the Xcode-bundled copy.

---

## 2. How to use it

### Subcommands

| Subcommand | Purpose |
|---|---|
| `format` (default) | Rewrite source to canonical style. Prints to stdout unless `-i`. |
| `lint` | Report style issues as diagnostics; never edits files. |
| `dump-configuration` | Print the full default configuration as JSON (starting point for a config file). |

`swift-format <paths>` with no subcommand runs `format`. With no paths it reads **stdin**.

### Options for `format` and `lint`

| Option | Applies to | Meaning |
|---|---|---|
| `-i`, `--in-place` | format | Overwrite each file with its formatted output. Without this, output goes to stdout (safe for previewing). |
| `--configuration <path-or-json>` | both | Path to a `.swift-format` JSON file, or an inline JSON string. If omitted, swift-format searches parent directories for a `.swift-format` file, then falls back to built-in defaults. |
| `-r`, `--recursive` | both | Recurse into any directory paths, processing every `.swift` file found. |
| `--lines <start:end>` | both | Restrict to 1-based inclusive line ranges. Repeatable. Good for formatting only a hunk. |
| `--offsets <start:end>` | both | Same idea using UTF-8 byte offsets. Repeatable. |
| `--assume-filename <name>` | both | Filename to attribute stdin to in diagnostics. |
| `--ignore-unparsable-files` | both | Skip (don't error on) files with invalid syntax. |
| `-p`, `--parallel` | both | Process files across multiple cores. Use for large batches. |
| `--follow-symlinks` | both | Follow symlinks given on the CLI or found during recursion. |
| `--color-diagnostics` / `--no-color-diagnostics` | both | Force color on/off. Default: color when stderr is a TTY. |
| `--enable-experimental-feature <name>` | both | Turn on an experimental swift-syntax parser feature. Repeatable. |
| `-s`, `--strict` | **lint only** | Treat every finding as an error (nonzero exit), not a warning. Use in CI. |

Exit codes: `0` = success / clean; nonzero = an error occurred, or (for `lint --strict`)
findings were present. Use this to gate commits or CI.

### Configuration keys

Generate the full default set to edit from:

```bash
xcrun swift-format dump-configuration > .swift-format
```

Top-level keys (defaults in parentheses):

| Key | Meaning |
|---|---|
| `version` (`1`) | Config schema version. Leave as-is. |
| `lineLength` (`100`) | Column width the formatter wraps at. |
| `indentation` (`{"spaces": 2}`) | Indent unit. Change the count to match the project's style (e.g. `{"spaces": 4}`). Use `{"tabs": 1}` for tabs. |
| `tabWidth` (`8`) | Assumed visual width of a tab when computing columns. |
| `maximumBlankLines` (`1`) | Cap on consecutive blank lines. |
| `respectsExistingLineBreaks` (`true`) | Keep author line breaks where they're valid. This is why it won't *add* breaks. |
| `lineBreakBeforeControlFlowKeywords` (`false`) | Put `else`/`catch` on their own line. |
| `lineBreakBeforeEachArgument` (`false`) | When wrapping a call, one argument per line. |
| `lineBreakBeforeEachGenericRequirement` (`false`) | Same, for `where` generic requirements. |
| `lineBreakBetweenDeclarationAttributes` (`false`) | Put each attribute (`@…`) on its own line. |
| `lineBreakAroundMultilineExpressionChainComponents` (`false`) | Break around components of a multiline `.chain()`. |
| `prioritizeKeepingFunctionOutputTogether` (`false`) | Try to keep the return clause with the signature when wrapping. |
| `indentConditionalCompilationBlocks` (`true`) | Indent the bodies of `#if` blocks. |
| `indentSwitchCaseLabels` (`false`) | Give `case` labels an extra indent level beyond `switch`. |
| `indentBlankLines` (`false`) | Whether blank lines carry indentation whitespace. |
| `spacesAroundRangeFormationOperators` (`false`) | Spaces around `...` / `..<`. |
| `spacesBeforeEndOfLineComments` (`2`) | Spaces before a trailing `//` comment. |
| `fileScopedDeclarationPrivacy.accessLevel` (`private`) | `private` or `fileprivate` for the FileScopedDeclarationPrivacy rule. |
| `multiElementCollectionTrailingCommas` (`true`) | Add a trailing comma to multi-element array/dict literals. |
| `multilineTrailingCommaBehavior` (`keptAsWritten`) | How to treat trailing commas in multiline collections. |
| `reflowMultilineStringLiterals` (`never`) | Whether to re-wrap multiline string literals. |
| `noAssignmentInExpressions.allowedFunctions` | Functions exempt from the no-assignment-in-expressions rule (e.g. `XCTAssertNoThrow`). |
| `orderedImports.shouldGroupImports` / `.includeConditionalImports` | Grouping behavior for the OrderedImports rule. |
| `rules` | Map of rule name → `true`/`false`. Toggles each lint/format rule below. |

Notable `rules` (all live under the `rules` object; toggle with `true`/`false`):

- `OrderedImports` — sort/group imports.
- `DoNotUseSemicolons` — strip statement-ending `;`.
- `NoParensAroundConditions` — remove `if (x)` parens.
- `OneCasePerLine` / `OneVariableDeclarationPerLine` — one declaration per line.
- `NoCasesWithOnlyFallthrough` — collapse `case` lists that only fall through.
- `UseShorthandTypeNames` — `[Int]` over `Array<Int>`, `Int?` over `Optional<Int>`.
- `UseSingleLinePropertyGetter` — drop the explicit `get {}` for read-only computed props.
- `ReturnVoidInsteadOfEmptyTuple` — `-> Void` over `-> ()`.
- `AlwaysUseLowerCamelCase`, `TypeNamesShouldBeCapitalized` — naming.
- `NeverForceUnwrap`, `NeverUseForceTry`, `NeverUseImplicitlyUnwrappedOptionals` — **off by default**; opt-in safety linters.
- `ReplaceForEachWithForLoop`, `UseEarlyExits`, `OmitExplicitReturns` — structural rewrites; enable deliberately.

Run `xcrun swift-format dump-configuration` for the complete, current rule list — don't
rely on memory, it changes between toolchain versions.

---

## 3. Config file + lint-after-changes workflow

### Whether a `.swift-format` exists

Check the repo root (and parent dirs) for a `.swift-format` file before doing anything:

```bash
ls -a .swift-format 2>/dev/null || find . -maxdepth 2 -name .swift-format
```

**If a `.swift-format` exists:** it is the project's chosen style. After you edit any Swift
files, **offer to run the linter** so changes conform (point the paths at the sources you
touched, or the source root):

```bash
xcrun swift-format lint -r -s <source-dir>   # -s = fail on any finding
```

Report findings back and offer to auto-fix them with `format -i`. Do not silently reformat
files the user didn't ask you to touch — propose it and let them confirm.

**If no `.swift-format` exists:** offer to create one. Start from the defaults and adjust to
match the project's existing style (indent width, line length, which rules to enable):

```bash
xcrun swift-format dump-configuration > .swift-format
```

A minimal, commonly-useful starting file:

```json
{
  "version": 1,
  "lineLength": 100,
  "indentation": { "spaces": 4 },
  "maximumBlankLines": 1,
  "respectsExistingLineBreaks": true,
  "rules": {
    "OrderedImports": true,
    "DoNotUseSemicolons": true,
    "UseShorthandTypeNames": true
  }
}
```

Caveats to state when proposing a first run on an existing codebase:
- The default `indentation` is **2 spaces**. If the project uses a different width, set it in
  the config first, or the run will reflow every file.
- The first `format -i` over an established codebase produces a large diff. Run it once,
  review with `git diff`, and commit separately from feature work.

---

## 4. Example: run it

Preview the formatting for one file without touching it (diff against the original):

```bash
FILE=path/to/Source.swift
xcrun swift-format "$FILE" | diff "$FILE" -
```

Format a source tree in place, then review the result:

```bash
xcrun swift-format format -i -r -p Sources
git diff --stat
```

Lint-only, CI-style (nonzero exit on any finding, uses the repo's `.swift-format`):

```bash
xcrun swift-format lint -r -s Sources
```
