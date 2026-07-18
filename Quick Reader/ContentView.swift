import SwiftUI
import AVFoundation
import NaturalLanguage
import UniformTypeIdentifiers

enum PlaybackState { case stopped, playing, paused }

struct ContentView: View {

    // MARK: - Speech Delegate
    class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
        var onFinish: (() -> Void)?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                               didFinish utterance: AVSpeechUtterance) {
            onFinish?()
        }
        // didCancel fires when stopSpeaking is called — do NOT forward to onFinish
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                               didCancel utterance: AVSpeechUtterance) {}
    }
    
    // MARK: - Store
    @StateObject private var store = DocumentStore()

    private var text: String { store.activeDocument?.content ?? "" }

    // MARK: - State
    @AppStorage("speechRate") private var speechRate: Double = 0.5
    @State private var currentSentenceIndex = 0
    @State private var cachedSentences: [String] = []
    @State private var cachedParagraphEnds: Set<Int> = []

    // Silence added after each sentence / paragraph, in seconds.
    @AppStorage("sentencePause") private var sentencePause: Double = 0.4
    @AppStorage("paragraphPause") private var paragraphPause: Double = 0.9
    @State private var showImporter = false
    @State private var showDocuments = false
    @State private var showEditor = false
    @AppStorage("usesDarkMode") private var usesDarkMode = false
    
    @AppStorage("selectedVoiceIdentifier") private var selectedVoiceIdentifier = ""
    @State private var selectedVoiceName = "Voice"
    @State private var availableVoices: [VoiceOption] = []
    @State private var showVoicePicker = false
    
    @State private var playbackState: PlaybackState = .stopped

    @State private var synthesizer = AVSpeechSynthesizer()
    @State private var speechDelegate = SpeechDelegate()

    // MARK: - Audio export
    @StateObject private var exporter = AudioExporter()
    @State private var showExportFormatDialog = false
    @State private var showFileExporter = false
    @State private var exportDocument: AudioFileDocument?
    @State private var exportFilename = "Audio"
    @State private var exportErrorMessage: String?
    @State private var showExportError = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isRegularWidth: Bool { sizeClass == .regular }
    #else
    // macOS has no size class; always use the wide split-view layout.
    private var isRegularWidth: Bool { true }
    #endif

    // MARK: - Body
    var body: some View {
        Group {
            if isRegularWidth {
                NavigationSplitView {
                    DocumentSidebarView(store: store, onImport: { showImporter = true })
                } detail: {
                    VStack(spacing: 0) {
                        iPadDetailHeader
                        readerContent
                    }
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                }
            } else {
                VStack(spacing: 0) {
                    phoneHeader
                    readerContent
                }
            }
        }
        .onAppear {
            synthesizer.delegate = speechDelegate
            speechDelegate.onFinish = {
                DispatchQueue.main.async { autoAdvance() }
            }
            currentSentenceIndex = store.activeDocument?.sentenceIndex ?? 0
            reparse()
            let options = loadVoiceOptions()
            availableVoices = options
            if selectedVoiceIdentifier.isEmpty {
                let best = options.filter { $0.voice.language.hasPrefix(deviceLanguagePrefix) }
                               .sorted { $0.voice.quality.rawValue > $1.voice.quality.rawValue }
                               .first ?? options.first
                selectedVoiceIdentifier = best?.id ?? ""
            }
            selectedVoiceName = options.first(where: { $0.id == selectedVoiceIdentifier })?.voice.name
                ?? options.first?.voice.name
                ?? "Voice"
        }
        .onChange(of: store.activeID) { _, _ in
            synthesizer.stopSpeaking(at: .immediate)
            playbackState = .stopped
            reparse()
            currentSentenceIndex = store.activeDocument?.sentenceIndex ?? 0
        }
        .onChange(of: store.activeDocument?.content) { _, _ in
            reparse()
            let clamp = max(0, cachedSentences.count - 1)
            if currentSentenceIndex > clamp { currentSentenceIndex = clamp }
        }
        .onChange(of: currentSentenceIndex) { _, newIndex in
            if var doc = store.activeDocument {
                doc.sentenceIndex = newIndex
                store.activeDocument = doc
            }
        }
        .preferredColorScheme(usesDarkMode ? .dark : .light)
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                TextEditor(text: Binding(
                    get: { store.activeDocument?.content ?? "" },
                    set: {
                        guard var doc = store.activeDocument else { return }
                        doc.content = $0
                        store.activeDocument = doc
                    }
                ))
                .font(.body)
                .padding(8)
                .navigationTitle("Edit")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showEditor = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 400)
            #endif
        }
        .sheet(isPresented: $showDocuments) {
            DocumentListView(store: store, isPresented: $showDocuments)
                #if os(macOS)
                .frame(minWidth: 360, minHeight: 480)
                #endif
        }
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerSheet(
                availableVoices: $availableVoices,
                selectedVoiceIdentifier: $selectedVoiceIdentifier,
                selectedVoiceName: $selectedVoiceName,
                onRefresh: {
                    availableVoices = loadVoiceOptions()
                }
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        ) { result in
            switch result {
            case .success(let url):
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let title = url.deletingPathExtension().lastPathComponent
                    if var doc = store.activeDocument {
                        doc.title = title
                        doc.content = content
                        doc.sentenceIndex = 0
                        store.activeDocument = doc
                    } else {
                        store.addDocument(title: title, content: content)
                    }
                    synthesizer.stopSpeaking(at: .immediate)
                    playbackState = .stopped
                    currentSentenceIndex = 0
                }
            case .failure:
                break
            }
        }
        .confirmationDialog("Export Audio", isPresented: $showExportFormatDialog, titleVisibility: .visible) {
            Button("M4A — smaller file") { startExport(.m4a) }
            Button("WAV — lossless, larger") { startExport(.wav) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generate spoken audio of “\(store.activeDocument?.title ?? "this document")” using the current voice and speed.")
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: exportDocument?.contentType ?? .wav,
            defaultFilename: exportFilename
        ) { _ in
            exportDocument = nil
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "Something went wrong.")
        }
        .overlay {
            if exporter.isExporting {
                exportProgressOverlay
            }
        }
    }

    // MARK: - Audio Export

    func startExport(_ format: AudioExportFormat) {
        synthesizer.stopSpeaking(at: .immediate)
        playbackState = .stopped

        let segments = cachedSentences.enumerated().map { index, text in
            SpeechSegment(text: text, trailingPause: trailingPause(for: index))
        }
        let rate = Float(speechRate)
        let voiceID = selectedVoiceIdentifier
        let title = store.activeDocument?.title ?? "Quick Reader Audio"

        Task {
            do {
                let url = try await exporter.export(
                    segments: segments,
                    voiceIdentifier: voiceID,
                    rate: rate,
                    format: format,
                    baseName: title
                )
                let data = try Data(contentsOf: url)
                exportDocument = AudioFileDocument(data: data, contentType: format.contentType)
                exportFilename = url.deletingPathExtension().lastPathComponent
                showFileExporter = true
                try? FileManager.default.removeItem(at: url)
            } catch {
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
        }
    }

    var exportProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: exporter.progress)
                    .frame(width: 200)
                Text("Generating audio… \(Int(exporter.progress * 100))%")
                    .font(.callout)
                    .foregroundColor(.primary)
            }
            .padding(28)
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Layout Components

    var phoneHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showImporter = true } label: {
                    Image(systemName: "doc.badge.plus").imageScale(.large)
                }
                Button { showEditor = true } label: {
                    Image(systemName: "pencil").imageScale(.large)
                }
                Button { showExportFormatDialog = true } label: {
                    Image(systemName: "square.and.arrow.up").imageScale(.large)
                }
                .disabled(cachedSentences.isEmpty || exporter.isExporting)
                Spacer()
                Text(store.activeDocument?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { usesDarkMode.toggle() } label: {
                    Image(systemName: usesDarkMode ? "sun.max" : "moon").imageScale(.large)
                }
                Button { showDocuments = true } label: {
                    Image(systemName: "books.vertical").imageScale(.large)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
        }
    }

    var iPadDetailHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showImporter = true } label: {
                    Image(systemName: "doc.badge.plus").imageScale(.large)
                }
                Button { showEditor = true } label: {
                    Image(systemName: "pencil").imageScale(.large)
                }
                Button { showExportFormatDialog = true } label: {
                    Image(systemName: "square.and.arrow.up").imageScale(.large)
                }
                .disabled(cachedSentences.isEmpty || exporter.isExporting)
                Spacer()
                Text(store.activeDocument?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { usesDarkMode.toggle() } label: {
                    Image(systemName: usesDarkMode ? "sun.max" : "moon").imageScale(.large)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
        }
    }

    var readerContent: some View {
        VStack(spacing: 0) {
            ProgressView(value: progressFraction)
                .tint(.accentColor)
                .padding(.horizontal)
                .animation(.easeOut(duration: 0.3), value: progressFraction)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(cachedSentences.enumerated()), id: \.offset) { index, sentence in
                            HStack(alignment: .top, spacing: 6) {
                                Text(sentence)
                                    .fontWeight(index == currentSentenceIndex ? .medium : .regular)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if index == store.activeDocument?.bookmark {
                                    Image(systemName: "bookmark.fill")
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                        .padding(.top, 3)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                index == currentSentenceIndex
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .cornerRadius(7)
                            .id(index)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: isRegularWidth ? 720 : .infinity)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: currentSentenceIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            Divider()

            HStack {
                Text("\(currentSentenceIndex + 1) / \(max(cachedSentences.count, 1))")
                Spacer()
                Text("\(Int(progressFraction * 100))%")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 6)

            HStack(spacing: 36) {
                Button { skipBackward() } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button { toggleSpeech() } label: {
                    Image(systemName: playbackState == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .regular))
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { skipForward() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                Button { handleBookmark() } label: {
                    Image(systemName: hasBookmark ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundColor(hasBookmark ? .accentColor : .secondary)
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "tortoise").foregroundColor(.secondary)
                Slider(value: $speechRate, in: 0.25...0.75)
                Image(systemName: "hare").foregroundColor(.secondary)
                Text(speedDisplay)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .leading)
                Spacer()
                Button { showVoicePicker = true } label: {
                    Label(selectedVoiceName, systemImage: "person.wave.2")
                }
            }
            .padding()
        }
    }

    // MARK: - Speech Control

    func toggleSpeech() {
        switch playbackState {
        case .playing:
            synthesizer.pauseSpeaking(at: .immediate)
            playbackState = .paused
        case .paused:
            synthesizer.continueSpeaking()
            playbackState = .playing
        case .stopped:
            speakCurrentSentence()
        }
    }

    func speakCurrentSentence() {
        let allSentences = cachedSentences
        guard !allSentences.isEmpty, currentSentenceIndex < allSentences.count else {
            playbackState = .stopped
            return
        }
        let utterance = AVSpeechUtterance(string: allSentences[currentSentenceIndex])
        utterance.rate = Float(speechRate)
        utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier)
        utterance.postUtteranceDelay = trailingPause(for: currentSentenceIndex)
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
        playbackState = .playing
    }

    /// Pause to insert after a given sentence: longer at paragraph boundaries.
    func trailingPause(for index: Int) -> TimeInterval {
        cachedParagraphEnds.contains(index) ? paragraphPause : sentencePause
    }

    /// Re-parse the active document into sentences + paragraph boundaries.
    func reparse() {
        let parsed = parseSentences()
        cachedSentences = parsed.sentences
        cachedParagraphEnds = parsed.paragraphEnds
    }

    func skipForward() {
        let allSentences = cachedSentences
        guard currentSentenceIndex < allSentences.count - 1 else { return }
        currentSentenceIndex += 1
        // Only start speaking if already active; if stopped, just move the index
        if playbackState != .stopped { speakCurrentSentence() }
    }

    func skipBackward() {
        guard currentSentenceIndex > 0 else { return }
        currentSentenceIndex -= 1
        if playbackState != .stopped { speakCurrentSentence() }
    }

    func autoAdvance() {
        // Guard: only advance if we're the ones playing (not a stale delegate callback)
        guard playbackState == .playing else { return }
        let allSentences = cachedSentences
        guard currentSentenceIndex < allSentences.count - 1 else {
            playbackState = .stopped
            return
        }
        currentSentenceIndex += 1
        speakCurrentSentence()
    }
    
    // MARK: - Helpers
    
    /// Splits the document into spoken sentences, and records which sentence
    /// indices fall at the end of a block (paragraph, heading, list item,
    /// blockquote) so playback/export can pause longer there.
    func parseSentences() -> (sentences: [String], paragraphEnds: Set<Int>) {
        var result: [String] = []
        var paragraphEnds: Set<Int> = []
        let lines = text.components(separatedBy: "\n")
        var paragraphLines: [String] = []

        // Marks the most recently appended sentence as a block boundary.
        func endBlock(from startCount: Int) {
            if result.count > startCount { paragraphEnds.insert(result.count - 1) }
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let startCount = result.count
            let joined = stripMarkdown(paragraphLines.joined(separator: " "))
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = joined
            tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
                let s = String(joined[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { result.append(s) }
                return true
            }
            paragraphLines.removeAll()
            endBlock(from: startCount)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Horizontal rules
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { continue }

            // Headings: # ## ### etc.
            if trimmed.hasPrefix("#") {
                flushParagraph()
                let start = result.count
                let heading = stripMarkdown(String(trimmed.drop(while: { $0 == "#" || $0 == " " })))
                if !heading.isEmpty { result.append(heading) }
                endBlock(from: start)
                continue
            }

            // Unordered list items: -, *, +
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let start = result.count
                let item = stripMarkdown(String(trimmed.dropFirst(2)))
                if !item.isEmpty { result.append(item) }
                endBlock(from: start)
                continue
            }

            // Ordered list items: "1. " "12. " etc.
            let digits = trimmed.prefix(while: { $0.isNumber })
            if !digits.isEmpty && trimmed.dropFirst(digits.count).hasPrefix(". ") {
                flushParagraph()
                let start = result.count
                let item = stripMarkdown(String(trimmed.dropFirst(digits.count + 2)))
                if !item.isEmpty { result.append(item) }
                endBlock(from: start)
                continue
            }

            // Blockquotes: > text
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                let start = result.count
                let quote = stripMarkdown(String(trimmed.dropFirst(2)))
                if !quote.isEmpty { result.append(quote) }
                endBlock(from: start)
                continue
            }

            paragraphLines.append(trimmed)
        }

        flushParagraph()
        return (result, paragraphEnds)
    }

    private func stripMarkdown(_ input: String) -> String {
        var s = input
        // Images before links so ![...](...) doesn't partially match [...]
        s = s.replacingOccurrences(of: "!\\[.*?\\]\\(.*?\\)", with: "", options: .regularExpression)
        // Links: [text](url) → text
        s = s.replacingOccurrences(of: "\\[(.+?)\\]\\(.*?\\)", with: "$1", options: .regularExpression)
        // Bold before italic so ** is consumed before *
        s = s.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        // Italic
        s = s.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_(.+?)_", with: "$1", options: .regularExpression)
        // Inline code
        s = s.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
    
    var speedDisplay: String {
        String(format: "%.1fx", speechRate / 0.5)
    }

    // MARK: - Progress

    var progressFraction: Double {
        let total = cachedSentences.count
        guard total > 0 else { return 0 }
        return Double(currentSentenceIndex) / Double(total)
    }

    // MARK: - Bookmark

    var hasBookmark: Bool { store.activeDocument?.bookmark != nil }
    var atBookmark: Bool  { store.activeDocument?.bookmark == currentSentenceIndex }

    func handleBookmark() {
        guard var doc = store.activeDocument else { return }
        if let saved = doc.bookmark, saved != currentSentenceIndex {
            currentSentenceIndex = saved
            if playbackState != .stopped { speakCurrentSentence() }
        } else if atBookmark {
            doc.bookmark = nil
            store.activeDocument = doc
        } else {
            doc.bookmark = currentSentenceIndex
            store.activeDocument = doc
        }
    }

    // MARK: - Voice Helpers

    private var deviceLanguagePrefix: String {
        String((Locale.preferredLanguages.first ?? "en").prefix(2))
    }

    /// All system voices as options, excluding Siri voices — third-party apps
    /// can't instantiate those, so selecting one would silently fail to play.
    private func loadVoiceOptions() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.localizedCaseInsensitiveContains("siri") }
            .map { VoiceOption(voice: $0) }
    }
}

// MARK: - Voice Option

private struct VoiceOption: Identifiable {
    let voice: AVSpeechSynthesisVoice
    var id: String { voice.identifier }
    var qualityLabel: String {
        switch voice.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return ""
        }
    }
    var isHighQuality: Bool {
        voice.quality.rawValue >= AVSpeechSynthesisVoiceQuality.enhanced.rawValue
    }
}

// MARK: - Voice Row

private struct VoiceRow: View {
    let option: VoiceOption
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.voice.name)
                Text(option.voice.language)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !option.qualityLabel.isEmpty {
                Text(option.qualityLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(option.voice.quality == .premium
                        ? Color.purple.opacity(0.15)
                        : Color.blue.opacity(0.13))
                    .foregroundColor(option.voice.quality == .premium ? .purple : .blue)
                    .clipShape(Capsule())
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .font(.callout.weight(.semibold))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Voice Picker Sheet

private struct VoicePickerSheet: View {
    @Binding var availableVoices: [VoiceOption]
    @Binding var selectedVoiceIdentifier: String
    @Binding var selectedVoiceName: String
    var onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var deviceLanguagePrefix: String {
        String((Locale.preferredLanguages.first ?? "en").prefix(2))
    }
    private var voiceHelpText: String {
        #if os(macOS)
        "To get better voices, go to:\nSystem Settings → Accessibility → Spoken Content → System Voice"
        #else
        "To get better voices, go to:\nSettings → Accessibility → Spoken Content → Voices"
        #endif
    }
    /// All voices grouped by language. The device's language comes first,
    /// then the rest alphabetically. Within each group, highest-quality first.
    private var voicesByLanguage: [VoiceLanguageGroup] {
        Dictionary(grouping: availableVoices) { $0.voice.language }
            .map { key, value in
                VoiceLanguageGroup(language: key, voices: value.sorted { lhs, rhs in
                    if lhs.voice.quality.rawValue != rhs.voice.quality.rawValue {
                        return lhs.voice.quality.rawValue > rhs.voice.quality.rawValue
                    }
                    return lhs.voice.name < rhs.voice.name
                })
            }
            .sorted { lhs, rhs in
                let lMine = lhs.language.hasPrefix(deviceLanguagePrefix)
                let rMine = rhs.language.hasPrefix(deviceLanguagePrefix)
                if lMine != rMine { return lMine }
                return languageName(lhs.language) < languageName(rhs.language)
            }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(voicesByLanguage) { group in
                    Section(languageName(group.language)) {
                        ForEach(group.voices) { option in
                            Button {
                                selectedVoiceIdentifier = option.id
                                selectedVoiceName = option.voice.name
                                dismiss()
                            } label: {
                                VoiceRow(option: option, isSelected: option.id == selectedVoiceIdentifier)
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                Section {
                    Text(voiceHelpText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

            }
            .navigationTitle("Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { onRefresh() }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }
}

// MARK: - Voice Language Group

private struct VoiceLanguageGroup: Identifiable {
    let language: String
    let voices: [VoiceOption]
    var id: String { language }
}

#Preview {
    ContentView()
}
