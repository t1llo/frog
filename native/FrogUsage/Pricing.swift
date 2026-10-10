// What the logged usage would cost at API list prices, so the Tokens tab can show the value of a
// subscription. Prices are USD per million tokens: Anthropic as published on 2026-09-25, OpenAI
// (Standard tier, prompts under 272K) as published on 2026-09-29. Update the tables when they change.
import Foundation

struct Price {
    let input: Double
    let output: Double
    /// Cache reads are 0.1x input on most models, but cheaper on Claude Opus 5.5 and Fable 5.1.
    let cacheRead: Double
}

/// Keyed by model id without any date suffix. Models not listed here are left unpriced rather
/// than guessed, and the Tokens tab names them.
let apiPrices: [String: Price] = [
    "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1.00),
    "claude-mythos-5": Price(input: 10, output: 50, cacheRead: 1.00),
    "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20),
    "claude-opus-5": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-8": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-7": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-6": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.20),
    "claude-sonnet-5": Price(input: 2, output: 10, cacheRead: 0.20),
    "claude-sonnet-4-6": Price(input: 3, output: 15, cacheRead: 0.30),
    "claude-haiku-4-5": Price(input: 1, output: 5, cacheRead: 0.10),
]

/// USD for one response, or nil for a model missing from the table. Cache writes are billed at
/// 1.25x input for the 5-minute cache and 2x for the 1-hour cache. Fast mode (Opus only) is 2x.
func apiCost(model: String, input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int,
             cacheRead: Int, fast: Bool) -> Double? {
    var id = model
    if let dash = id.lastIndex(of: "-"), id[id.index(after: dash)...].count == 8,
       Int(id[id.index(after: dash)...]) != nil { id = String(id[..<dash]) }
    guard let p = apiPrices[id] else { return nil }
    let usd = (Double(input) * p.input
        + Double(cacheWrite5m) * p.input * 1.25
        + Double(cacheWrite1h) * p.input * 2
        + Double(cacheRead) * p.cacheRead
        + Double(output) * p.output) / 1_000_000
    return fast ? usd * 2 : usd
}

struct OpenAIPrice {
    let input: Double
    let cachedInput: Double
    /// Nil for models that do not bill cache writes separately.
    var cacheWrite: Double?
    let output: Double
}

/// Keyed by model id. Codex and OpenCode both log the id the request was made with.
let openAIPrices: [String: OpenAIPrice] = [
    "gpt-6-astra": OpenAIPrice(input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50),
    "gpt-6-sol": OpenAIPrice(input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 10),
    "gpt-6-luna": OpenAIPrice(input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5),
    "gpt-5.6-sol": OpenAIPrice(input: 4, cachedInput: 0.4, cacheWrite: 5, output: 20),
    "gpt-5.6-terra": OpenAIPrice(input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 12),
    "gpt-5.6-luna": OpenAIPrice(input: 0.2, cachedInput: 0.02, cacheWrite: 0.25, output: 1.2),
    "gpt-5.5": OpenAIPrice(input: 5, cachedInput: 0.5, output: 30),
    "gpt-5.4": OpenAIPrice(input: 2.5, cachedInput: 0.25, output: 15),
    "gpt-5.4-mini": OpenAIPrice(input: 0.75, cachedInput: 0.075, output: 4.5),
    "gpt-5.4-nano": OpenAIPrice(input: 0.2, cachedInput: 0.02, output: 1.25),
    "gpt-5.3-codex": OpenAIPrice(input: 1.75, cachedInput: 0.175, output: 14),
    "gpt-5.2": OpenAIPrice(input: 1.75, cachedInput: 0.175, output: 14),
    "gpt-5.1": OpenAIPrice(input: 1.25, cachedInput: 0.125, output: 10),
    "gpt-5": OpenAIPrice(input: 1.25, cachedInput: 0.125, output: 10),
    "gpt-5-mini": OpenAIPrice(input: 0.25, cachedInput: 0.025, output: 2),
    "gpt-5-nano": OpenAIPrice(input: 0.05, cachedInput: 0.005, output: 0.4),
    "gpt-4.1": OpenAIPrice(input: 2, cachedInput: 0.5, output: 8),
    "gpt-4.1-mini": OpenAIPrice(input: 0.4, cachedInput: 0.1, output: 1.6),
    "o3": OpenAIPrice(input: 2, cachedInput: 0.5, output: 8),
    "o4-mini": OpenAIPrice(input: 1.1, cachedInput: 0.275, output: 4.4),
]

/// USD for one response, or nil for a model missing from the table. `input` is uncached input
/// only; reasoning tokens are part of `output` and billed as output.
func openAICost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double? {
    guard let p = openAIPrices[model] else { return nil }
    return (Double(input) * p.input
        + Double(cacheWrite) * (p.cacheWrite ?? p.input)
        + Double(cacheRead) * p.cachedInput
        + Double(output) * p.output) / 1_000_000
}
