import SwiftUI
import FrogCore

/// The one icon mapping for what Frog talks to: every provider, coding tool and local model runtime has its own
/// symbol and colour, drawn on a `PluginIconTile` wherever it is listed, so no two services share a tile and no
/// row falls back to a generic computer or terminal. Status (installed, chosen, signed in) never takes the tile's
/// place; it is a trailing `FrogBadge`.
struct ServiceMark: Equatable {
    let symbol: String
    let tint: PluginTint

    static func provider(_ kind: ProviderKind) -> ServiceMark {
        switch kind {
        case .openAI: ServiceMark(symbol: "circle.hexagonpath.fill", tint: .green)
        case .anthropic: ServiceMark(symbol: "asterisk", tint: .orange)
        case .gemini: ServiceMark(symbol: "sparkles", tint: .blue)
        case .ollama: ServiceMark(symbol: "pawprint.fill", tint: .teal)
        case .lmStudio: ServiceMark(symbol: "cube.fill", tint: .purple)
        case .compatible: ServiceMark(symbol: "cloud.fill", tint: .indigo)
        case .claudeCode: tool(.claudeCode)
        case .codex: tool(.codex)
        case .opencode: tool(.opencode)
        }
    }

    static func tool(_ kind: LocalToolKind) -> ServiceMark {
        switch kind {
        case .claudeCode: ServiceMark(symbol: "burst.fill", tint: .orange)
        case .codex: ServiceMark(symbol: "curlybraces", tint: .gray)
        case .opencode: ServiceMark(symbol: "chevron.left.forwardslash.chevron.right", tint: .pink)
        }
    }

    /// Local models by runtime: Whisper and Parakeet are both speech, so each has its own mark. Text models all run
    /// on MLX, so they are told apart by family: Qwen, Llama and Gemma each have their own, any other a text mark.
    static func model(_ descriptor: LocalModelDescriptor) -> ServiceMark {
        switch descriptor.backend {
        case .whisperKit: return ServiceMark(symbol: "waveform", tint: .red)
        case .parakeet: return ServiceMark(symbol: "waveform.badge.mic", tint: .orange)
        case .mlx:
            let repository = (descriptor.originalRepository ?? descriptor.repository).lowercased()
            let name = descriptor.name.lowercased() + " " + repository
            // A family keeps its tint; its smallest sizes (a billion parameters or fewer) wear the hare, so two
            // sizes of one family side by side are told apart at a glance.
            if name.contains("qwen") { return ServiceMark(symbol: isSmall(name) ? "hare.fill" : "brain", tint: .purple) }
            if name.contains("llama") { return ServiceMark(symbol: "mountain.2.fill", tint: .indigo) }
            if name.contains("gemma") { return ServiceMark(symbol: "diamond.fill", tint: .blue) }
            return ServiceMark(symbol: "text.alignleft", tint: .green)
        }
    }

    /// Whether a model's name says it has at most a billion parameters ("0.8B", "1B").
    private static func isSmall(_ name: String) -> Bool {
        guard let range = name.range(of: #"\d+(\.\d+)?\s?b\b"#, options: .regularExpression) else { return false }
        let number = name[range].filter { $0.isNumber || $0 == "." }
        return Double(number).map { $0 <= 1 } ?? false
    }

    var color: Color { tint.color }
}

extension PluginIconTile {
    init(mark: ServiceMark, size: Size = .list) {
        self.init(symbol: mark.symbol, tint: mark.color, size: size)
    }
}
