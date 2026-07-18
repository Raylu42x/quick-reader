import Foundation
import AVFoundation
import SwiftUI
import Combine
import UniformTypeIdentifiers

enum AudioExportFormat {
    case wav
    case m4a

    var fileExtension: String { self == .wav ? "wav" : "m4a" }
    var contentType: UTType { self == .wav ? .wav : .mpeg4Audio }
}

/// One sentence to speak plus how much silence to append after it.
struct SpeechSegment {
    let text: String
    let trailingPause: TimeInterval
}

enum AudioExportError: LocalizedError {
    case noAudio
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .noAudio:        return "No audio could be generated from this document."
        case .conversionFailed: return "Audio conversion failed."
        }
    }
}

/// Synthesizes a document to an audio file offline (no playback), then optionally
/// transcodes to M4A. Reports progress so the UI can show a bar.
final class AudioExporter: ObservableObject {
    @Published var isExporting = false
    @Published var progress: Double = 0

    private let synthesizer = AVSpeechSynthesizer()

    /// Returns a temporary file URL containing the finished audio.
    func export(segments: [SpeechSegment],
                voiceIdentifier: String,
                rate: Float,
                format: AudioExportFormat,
                baseName: String) async throws -> URL {
        isExporting = true
        progress = 0
        defer { isExporting = false }

        let tmp = FileManager.default.temporaryDirectory
        let wavURL = tmp.appendingPathComponent(UUID().uuidString + ".wav")
        let voice = voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        let writer = WAVWriter(url: wavURL)

        let usable = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let total = max(usable.count, 1)

        for (i, segment) in usable.enumerated() {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = rate
            try await writeUtterance(utterance, with: writer)
            // Append silence so paragraph/sentence pauses are baked into the file.
            if segment.trailingPause > 0 {
                try writer.writeSilence(segment.trailingPause)
            }
            // Reserve the last 10% of the bar for M4A transcoding.
            let done = Double(i + 1) / Double(total)
            progress = (format == .wav) ? done : done * 0.9
        }

        writer.close()
        guard writer.didWriteAudio else { throw AudioExportError.noAudio }

        let safeName = sanitized(baseName)
        switch format {
        case .wav:
            let dest = tmp.appendingPathComponent(safeName + ".wav")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: wavURL, to: dest)
            progress = 1
            return dest
        case .m4a:
            let dest = tmp.appendingPathComponent(safeName + ".m4a")
            try? FileManager.default.removeItem(at: dest)
            try await convertToM4A(from: wavURL, to: dest)
            try? FileManager.default.removeItem(at: wavURL)
            progress = 1
            return dest
        }
    }

    private func writeUtterance(_ utterance: AVSpeechUtterance, with writer: WAVWriter) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // A zero-length buffer signals the end of this utterance.
                if pcm.frameLength == 0 {
                    if !finished { finished = true; cont.resume() }
                    return
                }
                do {
                    try writer.write(pcm)
                } catch {
                    if !finished { finished = true; cont.resume(throwing: error) }
                }
            }
        }
    }

    private func convertToM4A(from source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExportError.conversionFailed
        }
        try await session.export(to: dest, as: .m4a)
    }

    private func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        return cleaned.isEmpty ? "Quick Reader Audio" : String(cleaned.prefix(80))
    }
}

/// Incrementally writes PCM buffers to a WAV file. The file's format is locked
/// to the first buffer it receives (one voice = one consistent format).
private final class WAVWriter {
    private let url: URL
    private var file: AVAudioFile?
    private(set) var didWriteAudio = false

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil {
            file = try AVAudioFile(forWriting: url,
                                   settings: buffer.format.settings,
                                   commonFormat: buffer.format.commonFormat,
                                   interleaved: buffer.format.isInterleaved)
        }
        try file?.write(from: buffer)
        didWriteAudio = true
    }

    /// Writes `seconds` of silence in the file's established format.
    /// No-op until at least one real buffer has set the format.
    func writeSilence(_ seconds: TimeInterval) throws {
        guard seconds > 0, let file else { return }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        // Zero every underlying buffer (works for any sample format / channel layout).
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        try file.write(from: buffer)
    }

    func close() { file = nil }
}

/// Lightweight FileDocument used only to drive SwiftUI's `.fileExporter`
/// (native Save dialog on macOS, save sheet on iOS/iPadOS).
struct AudioFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav, .mpeg4Audio] }

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .wav
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
