# Quick Reader docs

Start with [../README.md](../README.md) for features, building and layout.

## How playback works

1. `parseSentences()` in `ContentView.swift` strips Markdown and splits text into sentences with
   `NLTokenizer`, recording where paragraphs end.
2. `speakCurrentSentence()` speaks one sentence at a time through `AVSpeechSynthesizer`.
3. When a sentence finishes, the delegate calls `autoAdvance()`. A cancel does not advance.

`AudioExport.swift` renders the same sentences to WAV offline, then converts to M4A if asked.

## Storage

`DocumentStore` saves everything in `UserDefaults` under `v1_documents` and `v1_activeID`. That's
fine for articles but will not scale to whole books. Moving to a JSON file or SwiftData is the next
storage step, and it needs a migration from those keys.

## Behavior to keep

- Import always creates a new document. It must never overwrite the active one.
- Siri voices are filtered out because third-party apps can't use them.
- A non-UTF-8 import currently fails silently. It should show an error.
