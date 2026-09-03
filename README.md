# MD Viewer

A tiny native macOS Markdown viewer. Double-click a `.md` file and it opens instantly with clean, GitHub-style formatting.

Think "Preview.app, but for Markdown" — a viewer, not an editor.

![MD Viewer rendering a sample document](docs/screenshot.png)

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
- **Live reload** — edits to the file on disk re-render automatically, preserving scroll position
- YAML front matter shown as a collapsible block instead of raw text
- Links: web links open in your browser; links to other `.md` files open in a new viewer window
- Zoom (⌘+ / ⌘− / ⌘0), reload (⌘R), open dialog (⌘O), tabbed windows

## Install

Requires macOS 12+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/DeanAhlgren/md-viewer.git
cd md-viewer
./build.sh
```

This compiles the app and installs it to `~/Applications/MD Viewer.app`.

### Make it the default for .md files

Right-click any `.md` file → **Get Info** → **Open With** → choose MD Viewer → **Change All…**

## How it works

`main.m` hosts a WKWebView per document window. The Markdown is parsed in the web view by a bundled copy of [marked.js](https://github.com/markedjs/marked), styled with a small hand-written GitHub-flavored stylesheet ([`Resources/template.html`](Resources/template.html)), and code blocks are highlighted by a bundled [highlight.js](https://github.com/highlightjs/highlight.js). Images referenced by the document are served through a custom `WKURLSchemeHandler`, and a GCD vnode source watches the file for changes to power live reload.

## License

MIT — see [LICENSE](LICENSE).

Bundled third-party libraries (both permissively licensed, see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)):

- [marked.js](https://github.com/markedjs/marked) — MIT
- [highlight.js](https://github.com/highlightjs/highlight.js) — BSD-3-Clause
