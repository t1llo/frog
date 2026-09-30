import Foundation
import FrogCore

/// Each recording owns its preview progress, even after its UI has been dismissed.
@MainActor
final class DictationTranscript {
    private(set) var completed: [String] = []
    private(set) var offset = 0
    private(set) var partial: (sampleCount: Int, text: String)?

    func acceptPreview(_ text: String, sampleCount: Int) {
        if sampleCount == 30 * 16000 {
            completed.append(text); offset += sampleCount; partial = nil
        } else { partial = (sampleCount, text) }
    }

    func finish(recorder: (any DictationRecording)?, samples: AudioSamples,
                pendingPreview: Task<Void, Error>?, models: LocalModels, rule: Rule,
                external: (([Float], Rule) async throws -> String)?,
                captureFinished: () -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            // Finish drains the final capture buffers even if cancellation arrives first.
            await recorder?.finish()
            samples.endInput()
            let audio = samples.snapshot(); samples.clear()
            captureFinished()
            _ = try? await pendingPreview?.value
            try Task.checkCancellation()
            guard audio.count >= 3200 else { throw FrogError.message("No speech recorded. Hold the shortcut longer, or use toggle mode.") }
            let raw: String
            if rule.action?.audioProviderID != nil {
                guard let external else { throw FrogError.message("External speech is unavailable.") }
                raw = try await external(audio, rule)
            } else {
                guard let modelID = rule.action?.audioModelID else { throw FrogError.message("Choose a speech model for this rule.") }
                let remaining = Array(audio.dropFirst(offset))
                let ending: String
                if remaining.isEmpty { ending = "" }
                else if let partial, partial.sampleCount == remaining.count { ending = partial.text }
                else {
                    try await models.waitUntilAvailable()
                    try Task.checkCancellation()
                    ending = try await models.transcribe(remaining, modelID: modelID, language: rule.action?.transcriptionLanguage)
                }
                raw = (completed + [ending]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
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
