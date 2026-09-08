# MD Viewer

A tiny native macOS Markdown viewer and editor. Double-click a `.md` file and it opens instantly with clean, GitHub-style formatting. Press ⌘E to edit it in place with a live preview.

![MD Viewer editing a document with the live preview beside it](docs/screenshot.png)

## Why another one?

Most Markdown viewers are Electron apps (100+ MB, slow to launch) or closed-source. MD Viewer is:

- **One Objective-C file** — the entire app is [`main.m`](main.m), readable in five minutes
- **Native** — AppKit + WKWebView, launches instantly, ~100 KB binary
- **Fully offline** — the rendering libraries are bundled; no network access, no telemetry, no accounts. Your files never leave your machine.
- **Free and MIT-licensed**

## Features

- GitHub-style rendering: headings, tables, task lists, blockquotes, images, footnote-style links
- Syntax highlighting for fenced code blocks (via highlight.js)
- Automatic dark/light mode following the system theme
- **Built-in editor** (new in 1.1) — edit the Markdown in the same window with a live side-by-side preview; see [Editing](#editing) below
- **Live reload** — edits to the file on disk re-render automatically, preserving scroll position
- YAML front matter shown as a collapsible block instead of raw text
- Links: web links open in your browser; links to other `.md` files open in a new viewer window
- Zoom (⌘+ / ⌘− / ⌘0), reload (⌘R), open dialog (⌘O), tabbed windows

## Editing

Click **Edit** (or press ⌘E) to switch the window into editing mode. The Markdown source appears in a plain-text editor on the left, and the rendered preview on the right updates as you type. Untick **Preview** to hide it and give the editor the full window.

- **Save** (⌘S) writes back to the original file. **Done** returns to reading mode.
- The editor is a native macOS text view: find (⌘F), undo/redo, cut, copy, paste, and Select All all work as expected. Smart quotes, smart dashes, and automatic text replacement are turned off so your Markdown stays exactly as you typed it.
- Unsaved changes are shown in the toolbar and in the window's close button, and you're prompted to save, discard, or cancel on Done, Close, and Quit.
- **Safe saving.** Saves are atomic and check the file on disk first. If the file was changed by another app or has disappeared, your draft stays open instead of overwriting it. **File → Save a Copy…** writes the draft elsewhere without touching the original.
- The original encoding (UTF-8 or Latin-1) is preserved. If a Latin-1 file can't represent a character you typed, you get an error instead of silent data loss (Save a Copy always writes UTF-8).
- **File → Open in Other Editor…** hands the file to any other Mac app. External changes keep refreshing the preview automatically.

## Install

Requires macOS 12+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/DeanAhlgren/md-viewer.git
cd md-viewer
./build.sh
```

This compiles the app and installs it to `~/Applications/MD Viewer.app`. Set `MDVIEWER_APP_PATH` to install somewhere else. If a previous version is installed, it's kept alongside as a timestamped backup. Quit and reopen MD Viewer after updating.

### Make it the default for .md files

Right-click any `.md` file → **Get Info** → **Open With** → choose MD Viewer → **Change All…**

## How it works

`main.m` hosts a WKWebView per document window. The Markdown is parsed in the web view by a bundled copy of [marked.js](https://github.com/markedjs/marked), styled with a small hand-written GitHub-flavored stylesheet ([`Resources/template.html`](Resources/template.html)), and code blocks are highlighted by a bundled [highlight.js](https://github.com/highlightjs/highlight.js). Images referenced by the document are served through a custom `WKURLSchemeHandler`, and a GCD vnode source watches the file for changes to power live reload.

In editing mode an `NSTextView` sits beside the web view in an `NSSplitView`; edits are debounced and pushed into the same renderer, so the preview and the reading view are always identical.

## Tests

`./tests/run.sh` exercises editing, native undo, preview rendering, file conflicts, encoding, and saving against temporary files. It drives the real app, so run it from a logged-in macOS desktop session.

## License

MIT — see [LICENSE](LICENSE).

Bundled third-party libraries (both permissively licensed, see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)):

- [marked.js](https://github.com/markedjs/marked) — MIT
- [highlight.js](https://github.com/highlightjs/highlight.js) — BSD-3-Clause
