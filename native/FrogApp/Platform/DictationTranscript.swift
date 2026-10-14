import Foundation
import FrogCore

/// Each recording owns its preview progress, even after its UI has been dismissed.
@MainActor
final class DictationTranscript {
    private(set) var completed: [String] = []
    private(set) var offset = 0
    private(set) var partial: (sampleCount: Int, text: String)?
    /// The drained recording, kept only while a failed final pass can be repeated.
    private var audio: [Float]?
    var canRetry: Bool { audio != nil }
    /// What recognition has produced so far. After a failed final pass it lacks the ending.
    var recognized: String { Self.join(completed + [partial?.text ?? ""]) }

    /// Recognition reads the recording in windows of 30 seconds.
    nonisolated static let window = 30 * 16000
    /// A window is final only once a second more has been recorded: neither engine reads a
    /// shorter ending, so a cut with less behind it would lose the last words of a dictation.
    nonisolated static let samplesCompletingWindow = window + 16000
    nonisolated static func completesWindow(uncommittedSamples: Int) -> Bool {
        uncommittedSamples >= samplesCompletingWindow
    }

    func acceptPreview(_ text: String, sampleCount: Int, completesWindow: Bool) {
        if completesWindow, sampleCount == Self.window {
            completed.append(text); offset += sampleCount; partial = nil
        } else { partial = (sampleCount, text) }
    }

    /// Joins recognised pieces with a space, except where both sides are in a script written
    /// without spaces, such as Chinese, Japanese or Thai.
    nonisolated static func join(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !piece.isEmpty {
            if let last = text.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !(writtenWithoutSpaces(last) && writtenWithoutSpaces(first)) { text += " " }
            text += piece
        }
        return text
    }

    private nonisolated static func writtenWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF: true // Thai, Lao, Myanmar, Khmer
        case 0x3000...0x312F, 0x31F0...0x31FF: true // CJK punctuation, kana, Bopomofo
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: true // Han
        case 0xFF00...0xFF9F: true // Full-width punctuation and half-width kana
        default: false
        }
    }

    func finish(recorder: (any DictationRecording)?, samples: AudioSamples,
                pendingPreview: Task<Void, Error>?, models: LocalModels, rule: Rule,
                external: (([Float], Rule) async throws -> String)?,
                captureFinished: () -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            let audio: [Float]
            if let kept = self.audio { audio = kept; self.audio = nil }
            else {
                // Finish drains the final capture buffers even if cancellation arrives first.
                await recorder?.finish()
                samples.endInput()
                audio = samples.snapshot(); samples.clear()
                captureFinished()
                _ = try? await pendingPreview?.value
            }
            try Task.checkCancellation()
            guard audio.count >= 3200 else { throw FrogError.message("No speech recorded. Hold the shortcut longer, or use toggle mode.") }
            let raw: String
            if rule.action?.audioProviderID != nil {
                guard let external else { throw FrogError.message("External speech is unavailable.") }
                do { raw = try await external(audio, rule) }
                catch {
                    // A request that never arrived or met a busy service can be sent again.
                    if !Task.isCancelled, SpeechClient.isTransient(error) { self.audio = audio }
                    throw error
                }
            } else {
                guard let modelID = rule.action?.audioModelID else { throw FrogError.message("Choose a speech model for this rule.") }
                let remaining = Array(audio.dropFirst(offset))
                let ending: String
                if remaining.isEmpty { ending = "" }
                else if let partial, partial.sampleCount == remaining.count { ending = partial.text }
                else {
                    try await models.waitUntilAvailable()
                    try Task.checkCancellation()
                    do { ending = try await models.transcribe(remaining, modelID: modelID, language: rule.action?.transcriptionLanguage) }
                    catch {
                        // Finished windows stay recognised; only this ending needs another pass.
                        if !Task.isCancelled, !(error is CancellationError) { self.audio = audio }
                        throw error
                    }
                }
                raw = Self.join(completed + [ending])
            }
            try Task.checkCancellation()
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("No speech detected.") }
            return raw
        } onCancel: { pendingPreview?.cancel() }
    }
}

struct DictationInterruption {
    let id: UUID
    let rule: Rule
    let text: String
    let reason: HistoryEntry.Interruption
    let transcriptPublished: Bool
}
