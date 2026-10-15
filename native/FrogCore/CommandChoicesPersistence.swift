import Foundation

private let commandChoicesLock = NSLock()

/// The command bar's learned choices in a private device-local file, never in the configuration. Every change
/// reads, applies and writes under one lock, so a second copy of Frog loses nothing. A broken or newer file is
/// left as it is until `clear`.
public final class CommandChoicesPersistence: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("command-choices.json") }
    private static let maximumReadBytes = 1_024 * 1_024

    public init(directory: URL? = nil) { self.directory = directory ?? PrivateFile.defaultDirectory }

    /// A missing file is empty; faded choices are left out.
    public func load(now: Date = Date()) throws -> CommandChoices {
        commandChoicesLock.lock(); defer { commandChoicesLock.unlock() }
        var choices = try read()
        choices.prune(now: now)
        return choices
    }

    @discardableResult
    public func record(typed: String, id: String, now: Date = Date()) throws -> CommandChoices {
        commandChoicesLock.lock(); defer { commandChoicesLock.unlock() }
        var choices = try read()
        guard CommandChoices.isRememberable(id) else { return choices }
        choices.record(typed: typed, id: id, now: now)
        return try write(choices, now: now)
    }

    @discardableResult
    public func forget(id: String, now: Date = Date()) throws -> CommandChoices {
        commandChoicesLock.lock(); defer { commandChoicesLock.unlock() }
        let stored = try read()
        var choices = stored
        choices.forget(id: id)
        return choices == stored ? choices : try write(choices, now: now)
    }

    /// Deletes the file, also when it cannot be read.
    public func clear() throws {
        commandChoicesLock.lock(); defer { commandChoicesLock.unlock() }
        if unlink(file.path) != 0 && errno != ENOENT { throw FrogError.message("Unable to forget the learned command bar choices.") }
    }

    private func read() throws -> CommandChoices {
        guard let data = try PrivateFile.read(file, maximumBytes: Self.maximumReadBytes) else { return CommandChoices() }
        guard let choices = try? JSONDecoder().decode(CommandChoices.self, from: data), choices.version == CommandChoices.currentVersion else {
            throw FrogError.message("Learned command bar choices could not be opened. The file was preserved; forget the learned choices to start again.")
        }
        return choices
    }

    /// Drops the weakest pairs, 50 at a time, until the file fits in 512 KB.
    private func write(_ choices: CommandChoices, now: Date) throws -> CommandChoices {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var choices = choices
        var data = try encoder.encode(choices)
        while data.count > CommandChoices.Tuning.maxFileBytes, !(choices.pairs.isEmpty && choices.items.isEmpty) {
            choices.dropWeakest(50, now: now)
            data = try encoder.encode(choices)
        }
        try PrivateFile.write(data, to: file)
        return choices
    }
}
