# Quick Reader

A read-aloud document reader for iOS and macOS. Import a `.txt` or `.md` file (or
paste text), and Quick Reader speaks it back with sentence-level highlighting,
resumable position, and offline audio export.

Built with SwiftUI and `AVSpeechSynthesizer`. No network access, no accounts,
no third-party services — everything runs on-device.

## Features

- **Multi-document library** — documents persist across launches, each with its
  own reading position and optional bookmark.
- **Sentence-aware playback** — text is split with `NLTokenizer` (Natural
  Language framework), not naive punctuation splitting, so abbreviations and
  decimals don't cause false sentence breaks.
- **Follow-along highlighting** — the active sentence is highlighted and scrolls
  into view as it is spoken. Tap any sentence to jump to it.
- **Natural pacing** — configurable pause after each sentence (`sentencePause`,
  default 0.4s) and a longer pause at paragraph boundaries (`paragraphPause`).
- **Voice picker** — lists all installed system voices and flags the
  Enhanced/Premium quality ones, which sound substantially better than the
  default compact voices.
- **Audio export** — renders the whole document to a `.wav` or `.m4a` file
  offline (faster than real time, no playback), with a progress bar.
- **Resume where you left off** — reading position is saved per document.

## Platforms

| Target | Minimum |
|---|---|
| iOS / iPadOS | 26.5 |
| macOS | 15.0 |

Bundle identifier: `kervian.Quick-Reader`

## Building

Requires Xcode with the iOS and macOS SDKs.

```bash
open "Quick Reader.xcodeproj"
```

Select the `Quick Reader` scheme and choose a run destination (My Mac, or an
iOS Simulator / device), then Run. There are no package dependencies to resolve
and no build scripts — it compiles straight out of the box.

## Project layout

| File | Purpose |
|---|---|
| `Quick Reader/Quick_ReaderApp.swift` | App entry point. Sets the macOS window's default and minimum size. |
| `Quick Reader/ContentView.swift` | The whole UI plus playback engine: sentence parsing, highlighting, voice selection, transport controls. |
| `Quick Reader/Documents.swift` | `Document` model and `DocumentStore` — persistence to `UserDefaults`, plus migration from the old single-document format. |
| `Quick Reader/AudioExport.swift` | Offline synthesis to WAV, optional AAC/M4A transcode, progress reporting. |
| `Quick Reader/PrivacyInfo.xcprivacy` | Privacy manifest (required for App Store submission). |
| `Icon/` | Source icon artwork, including light / dark / tinted variants. |

## Storage and privacy

Documents are stored in `UserDefaults` under the keys `v1_documents` and
`v1_activeID`. On first launch the app migrates any text left over from the
pre-1.0 single-document build (`savedText`, `currentSentenceIndex`) into the new
library format.

Nothing leaves the device. Speech synthesis, sentence parsing, and audio export
all use on-device Apple frameworks.

### A note on the `UserDefaults` backing store

`UserDefaults` is intended for preferences, not bulk content. It is loaded into
memory in full and written out as a single property list, so a large library —
or one long book pasted into a document — will be slow to save and will inflate
the app's memory footprint. It works fine for the current use case (a handful of
articles), but moving `DocumentStore` to a JSON file in Application Support, or
to SwiftData, is the natural next step if the library grows. See `LAUNCH.md`.
