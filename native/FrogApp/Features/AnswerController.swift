import AppKit
import FrogCore

/// What a selection capture hands to an answer.
struct AnswerCapture: Sendable {
    var text: String
    var context: String?
    /// Cocoa screen coordinates.
    var anchor: CGRect?
    var application: String?
    /// The page address or document path. Never sent.
    var source: String?
}

/// The panel that shows an answer. The controller decides what it shows, the presenter where.
@MainActor protocol AnswerPresenting: AnyObject {
    /// Opens the panel next to the anchor, or at the pointer without one. A pinned panel stays where it is.
    func show(_ session: AnswerSession, anchor: CGRect?, pointer: CGPoint)
    func update(_ session: AnswerSession)
    func close()
    var isKey: Bool { get }
    var isPinned: Bool { get }
}

/// Runs one answer and its follow-ups from start to finish: checks, streaming, hidden reasoning,
/// throttled panel updates, statistics and History. It never uses Writing's processing state, so
/// a Writing rule can run while an answer is open.
@MainActor final class AnswerController {
    /// What the panel offers next to a failure or a stopped answer.
    enum Recovery: Equatable { case retry, editRule }
    /// Save to note, from pressing it until "Saved" goes away.
    enum NoteState: Equatable { case saving, saved, failed(String) }

    static let emptySelection = "Select some text first."
    static let noText = "The model returned no text."

    private(set) var session: AnswerSession?
    /// Set while the session shows a failure the panel can offer a way out of.
    private(set) var recovery: Recovery?
    /// Why the last follow-up was not asked, shown in the follow-up field's place.
    private(set) var followUpMessage: String?
    private(set) var noteState: NoteState?
    var onEditRule: ((UUID) -> Void)?

    private let resolve: (Rule) throws -> ProviderConfiguration
    private let readKey: (UUID) throws -> String?
    private let stream: (AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>
    private let presenter: AnswerPresenting
    private let modelName: (ProviderConfiguration) -> String
    private let pointer: () -> CGPoint
    private let replyLanguage: () -> String
    private let report: (Error) -> Void
    private let recordStatistics: (ActivityRuleKind) -> Void
    private let copy: (String) -> Void
    private let record: (AnswerSession) -> UUID?
    private let updateRecord: (AnswerSession) -> Bool
    private let saveNote: (AnswerNoteContent) async throws -> URL
    private let notesEnabled: () -> Bool
    private let savedDisplay: Duration
    private let updateInterval: Duration

    private var rule: Rule?
    /// The model the running answer streams from.
    private(set) var provider: ProviderConfiguration?
    private var task: Task<Void, Never>?
    /// Identifies the running turn, so events of a cancelled one never reach the session.
    private var turn = UUID()
    private var filter = ReasoningFilter()
    private var recorded = false
    private var updatesRecord = true
    private var lastUpdate: ContinuousClock.Instant?
    private var pendingUpdate: Task<Void, Never>?

    init(resolve: @escaping (Rule) throws -> ProviderConfiguration,
         readKey: @escaping (UUID) throws -> String?,
         stream: @escaping (AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>,
         presenter: AnswerPresenting,
         modelName: @escaping (ProviderConfiguration) -> String,
         pointer: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         replyLanguage: @escaping () -> String = { AnswerPrompt.replyLanguage(preferred: Locale.preferredLanguages) },
         report: @escaping (Error) -> Void,
         recordStatistics: @escaping (ActivityRuleKind) -> Void,
         copy: @escaping (String) -> Void,
         record: @escaping (AnswerSession) -> UUID? = { _ in nil },
         updateRecord: @escaping (AnswerSession) -> Bool = { _ in false },
         saveNote: @escaping (AnswerNoteContent) async throws -> URL = { _ in throw CancellationError() },
         notesEnabled: @escaping () -> Bool = { false },
         savedDisplay: Duration = .seconds(2),
         updateInterval: Duration = .milliseconds(50)) {
        self.resolve = resolve
        self.readKey = readKey
        self.stream = stream
        self.presenter = presenter
        self.modelName = modelName
        self.pointer = pointer
        self.replyLanguage = replyLanguage
        self.report = report
        self.recordStatistics = recordStatistics
        self.copy = copy
        self.record = record
        self.updateRecord = updateRecord
        self.saveNote = saveNote
        self.notesEnabled = notesEnabled
        self.savedDisplay = savedDisplay
        self.updateInterval = updateInterval
    }

    // MARK: Actions

    /// Answers a captured selection, replacing any answer that is open.
    func start(rule: Rule, capture: AnswerCapture) {
        reset()
        self.rule = rule
        let language = replyLanguage()
        func failed(_ message: String, model: String = "", label: String = "", recovery: Recovery?, error: Error? = nil) {
            var session = AnswerSession(rule: rule, modelName: model, modelLabel: label, selection: capture.text, context: capture.context,
                                        application: capture.application, source: capture.source, replyLanguage: language)
            session.fail(message)
            self.session = session
            self.recovery = recovery
            report(error ?? FrogError.message(message))
            presenter.show(session, anchor: capture.anchor, pointer: pointer())
        }
        guard !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failed(Self.emptySelection, recovery: nil); return
        }
        let provider: ProviderConfiguration
        do { provider = try resolve(rule) }
        catch { failed(error.localizedDescription, recovery: .editRule, error: error); return }
        let local = provider.id == AppModel.localProviderID
        let name = modelName(provider)
        let label = AnswerPrompt.modelLabel(modelName: name, providerName: provider.name, local: local)
        let limit = AnswerPrompt.selectionLimit(local: local, kind: provider.kind)
        guard capture.text.count <= limit else {
            failed(AnswerPrompt.selectionTooLong(limit: limit), model: name, label: label, recovery: .editRule); return
        }
        do { _ = try rule.expandedInstructions() }
        catch { failed(error.localizedDescription, model: name, label: label, recovery: .editRule, error: error); return }
        self.provider = provider
        let session = AnswerSession(rule: rule, modelName: name, modelLabel: label, selection: capture.text, context: capture.context,
                                    application: capture.application, source: capture.source, replyLanguage: language)
        self.session = session
        presenter.show(session, anchor: capture.anchor, pointer: pointer())
        send()
    }

    /// A capture that failed: the panel opens at the pointer with the message.
    func fail(rule: Rule?, message: String) {
        reset()
        self.rule = rule
        var session = AnswerSession(rule: rule ?? Rule(name: "Explain"), modelName: "", modelLabel: "", selection: "", context: nil,
                                    application: nil, source: nil, replyLanguage: replyLanguage())
        session.fail(message)
        self.session = session
        report(FrogError.message(message))
        presenter.show(session, anchor: nil, pointer: pointer())
    }

    /// Asks a follow-up about the answer. Returns why it was not asked, which is also `followUpMessage`.
    @discardableResult
    func ask(_ question: String) -> String? {
        guard var session, let rule, provider != nil else { return nil }
        do {
            try session.beginFollowUp(question, instructions: rule.expandedInstructions())
        } catch {
            followUpMessage = error.localizedDescription
            publish(immediately: true)
            return followUpMessage
        }
        followUpMessage = nil
        recovery = nil
        if case .failed = noteState { noteState = nil }
        self.session = session
        publish(immediately: true)
        send()
        return nil
    }

    /// Keeps the text so far.
    func stop() {
        guard let session, task != nil else { return }
        switch session.phase {
        case .loading, .waiting, .thinking, .streaming: break
        case .done, .stopped, .failed: return
        }
        cancelTurn()
        endStopped()
    }

    /// Sends the same messages again, discarding what the failed or stopped turn returned.
    func retry() {
        guard var session, provider != nil else { return }
        switch session.phase {
        case .failed, .stopped: break
        case .loading, .waiting, .thinking, .streaming, .done: return
        }
        cancelTurn()
        session.resetForRetry()
        recovery = nil
        self.session = session
        publish(immediately: true)
        send()
    }

    func close() {
        reset()
        presenter.close()
    }

    /// Copies the latest answer, the visible part of it while it streams. False when there was nothing to copy.
    @discardableResult
    func copyLatest() -> Bool {
        guard let session else { return false }
        let partial = session.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = partial.isEmpty ? session.turns.last?.answer ?? "" : partial
        guard !text.isEmpty else { return false }
        copy(text)
        return true
    }

    func editRule() {
        guard let session else { return }
        onEditRule?(session.ruleID)
    }

    /// Whether the panel offers Save to note.
    var offersNotes: Bool { notesEnabled() }

    /// True once there is an answer to save: a completed turn, or the text a stopped one kept.
    var canSaveNote: Bool {
        guard let session, noteState != .saving else { return false }
        return !AnswerNoteContent(session: session, date: Date()).turns.isEmpty
    }

    /// Saves the conversation so far as a note. It keeps saving when the panel closes meanwhile;
    /// "Saved" or the error shows only while the same answer is open.
    func saveToNote() {
        guard offersNotes, canSaveNote, let session else { return }
        let content = AnswerNoteContent(session: session, date: Date())
        let id = session.id
        noteState = .saving
        publish(immediately: true)
        Task { [weak self, saveNote, savedDisplay] in
            let state: NoteState?
            do {
                _ = try await saveNote(content)
                state = .saved
            } catch is CancellationError {
                state = nil
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard let self, self.session?.id == id else { return }
            self.noteState = state
            self.publish(immediately: true)
            guard state == .saved else { return }
            try? await Task.sleep(for: savedDisplay)
            guard self.session?.id == id, self.noteState == .saved else { return }
            self.noteState = nil
            self.publish(immediately: true)
        }
    }

    // MARK: Streaming

    /// Streams the session's messages as the next turn. The caller has shown the waiting session.
    private func send() {
        guard let session, let rule, let provider else { return }
        let local = provider.id == AppModel.localProviderID
        let key: String?
        do { key = local || provider.kind.localTool != nil ? nil : try readKey(provider.id) }
        catch { fail(error); return }
        let request = AnswerRequest(rule: rule, provider: provider, apiKey: key, instructions: session.instructions,
                                    messages: session.messages, isFrogLocal: local)
        filter = ReasoningFilter()
        let turn = UUID()
        self.turn = turn
        let events = stream(request)
        task = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, self.turn == turn else { return }
                    self.receive(event)
                }
                guard let self, self.turn == turn else { return }
                self.finishTurn()
            } catch {
                guard let self, self.turn == turn else { return }
                // Cancelled by something other than Stop: keep what arrived, as Stop does.
                if Self.isCancellation(error) { self.endStopped() } else { self.fail(error) }
            }
        }
    }

    private func receive(_ event: AnswerEvent) {
        guard var session else { return }
        let before = session.phase
        if case .text(let text) = event {
            let (visible, thinking) = filter.feed(text)
            if !visible.isEmpty { session.apply(.text(visible)) }
            else if thinking { session.apply(.thinking) }
        } else {
            session.apply(event)
        }
        self.session = session
        publish(immediately: session.phase != before)
    }

    private func finishTurn() {
        task = nil
        guard var session else { return }
        let held = filter.finish()
        if !held.isEmpty { session.apply(.text(held)) }
        guard !session.partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(FrogError.message(filter.hidReasoning ? ReasoningFilter.onlyReasoning : Self.noText))
            return
        }
        session.complete()
        if !recorded, let provider {
            recorded = true
            recordStatistics(provider.id == AppModel.localProviderID || provider.kind.isLocal ? .local
                             : provider.kind.localTool != nil ? .cli : .remote)
            session.historyEntryID = record(session)
        } else if session.historyEntryID != nil, updatesRecord {
            updatesRecord = updateRecord(session)
        }
        self.session = session
        publish(immediately: true)
    }

    /// A provider error: shown in the panel with Retry, and logged.
    private func fail(_ error: Error) {
        task = nil
        guard var session else { return }
        session.fail(error.localizedDescription)
        self.session = session
        recovery = .retry
        report(error)
        publish(immediately: true)
    }

    /// Retry runs the turn again, for a stop pressed too early or a stream cut off.
    private func endStopped() {
        task = nil
        guard var session else { return }
        session.stop()
        self.session = session
        recovery = .retry
        publish(immediately: true)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func cancelTurn() {
        turn = UUID()
        task?.cancel(); task = nil
    }

    private func reset() {
        cancelTurn()
        pendingUpdate?.cancel(); pendingUpdate = nil
        lastUpdate = nil
        session = nil; rule = nil; provider = nil
        recovery = nil; followUpMessage = nil; noteState = nil
        recorded = false; updatesRecord = true
    }

    // MARK: Presenter updates

    /// Text updates reach the presenter at most once per interval; phase changes and the end of a turn at once.
    private func publish(immediately: Bool) {
        guard let session else { return }
        let now = ContinuousClock.now
        if immediately || lastUpdate.map({ now - $0 >= updateInterval }) ?? true {
            pendingUpdate?.cancel(); pendingUpdate = nil
            lastUpdate = now
            presenter.update(session)
            return
        }
        guard pendingUpdate == nil, let lastUpdate else { return }
        let wait = updateInterval - (now - lastUpdate)
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pendingUpdate = nil
            self.publish(immediately: true)
        }
    }
}
