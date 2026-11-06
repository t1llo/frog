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
        case .openAI: ServiceMark(symbol: "sparkle", tint: .green)
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
        case .claudeCode: ServiceMark(symbol: "terminal.fill", tint: .orange)
        case .codex: ServiceMark(symbol: "curlybraces", tint: .gray)
        case .opencode: ServiceMark(symbol: "chevron.left.forwardslash.chevron.right", tint: .pink)
        }
    }

    /// Local models by runtime: Whisper and Parakeet are both speech, so each has its own mark; text models run
    /// on MLX.
    static func model(_ descriptor: LocalModelDescriptor) -> ServiceMark {
        switch descriptor.backend {
        case .whisperKit: ServiceMark(symbol: "waveform", tint: .red)
        case .parakeet: ServiceMark(symbol: "waveform.badge.mic", tint: .orange)
        case .mlx: ServiceMark(symbol: "text.alignleft", tint: .green)
        }
    }

    var color: Color { tint.color }
}

extension PluginIconTile {
    init(mark: ServiceMark, size: Size = .list) {
        self.init(symbol: mark.symbol, tint: mark.color, size: size)
    }
}
