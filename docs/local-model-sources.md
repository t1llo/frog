# Local model sources

## Catalog and provenance

The default audio catalog offers four choices:

| Speech | Approximate download | Role | Download source |
| --- | --- | --- | --- |
| Whisper Tiny | 77 MB | Smallest footprint; multilingual | `argmaxinc/whisperkit-coreml` / `openai_whisper-tiny` |
| Whisper Small · Compact | 217 MB | Compact multilingual option | `argmaxinc/whisperkit-coreml` / `openai_whisper-small_216MB` |
| NVIDIA Parakeet TDT v3 | 483 MB | Fast dictation in 25 European languages | `FluidInference/parakeet-tdt-0.6b-v3-coreml` |
| Whisper Large v3 Turbo — recommended | 627 MB | General-purpose multilingual transcription | `argmaxinc/whisperkit-coreml` / `openai_whisper-large-v3-v20240930_626MB` |

Whisper runs through WhisperKit / Core ML; Parakeet uses FluidAudio / Core ML. These conversions work with Frog's macOS 14+ runtimes. Sizes describe model-file payloads, excluding tokenizers and caches. Compact conversions trade weight precision for smaller downloads; performance depends on your Mac and language.

Previously installed or selected models remain available with their original IDs and weights, including Base, uncompressed Small, Medium, full Large v3, the earlier Turbo conversion, and English-only Parakeet v2. You can also reveal these models through **Add model…** using their Hugging Face source. Saved selections are preserved.

| Text | Download repositories |
| --- | --- |
| Qwen3 0.6B, 1.7B and 4B | `mlx-community/Qwen3-0.6B-4bit`, `mlx-community/Qwen3-1.7B-4bit`, `mlx-community/Qwen3-4B-4bit` |
| Llama 3.2 1B and 3B Instruct | `mlx-community/Llama-3.2-1B-Instruct-4bit`, `mlx-community/Llama-3.2-3B-Instruct-4bit` |
| Gemma 3 1B | `mlx-community/gemma-3-1b-it-4bit` |

All built-in local inference requires Apple silicon. Sizes in the UI are approximate download sizes, not RAM guarantees. Model licensing differs by family; the info panel shows the available license and model-card link rather than treating every model as identically licensed. Local inference has no per-request API charge. No model weights are bundled with Frog.

Click **ⓘ** on any model to see its exact download repository, variant, runtime, language behavior, license, original model link when known, and a link to the download files. WhisperKit additionally installs a matching tokenizer from the upstream Hugging Face model during the explicit download action.

## Add a Hugging Face link

1. Open **Models → Inside Frog → Add model…**.
2. Paste `owner/model` or `https://huggingface.co/owner/model`.
3. Click **Check source**. Frog reads repository metadata and text-model configuration only.
4. Select the detected model or WhisperKit variant to add it to the catalog.
5. Click **Download** in the catalog to install the weights.

WhisperKit folder links such as `https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base` are supported. Individual file links, non-main revisions and arbitrary download hosts are not. Known built-ins resolve to their existing entry rather than creating duplicates.

Custom text sources need MLX format, SafeTensors weights and tokenizer files. A supported MLX architecture is still required at load time; format inspection alone cannot establish inference correctness. Custom speech sources need complete WhisperKit Core ML variant bundles. Parakeet currently supports the two version-specific catalog sources. Raw PyTorch, GGUF and arbitrary NeMo weights are not interchangeable with these formats. Gated/private repositories need authentication and are not supported by this import flow.

Custom descriptors are included in portable JSON under `localModels`; downloaded weights stay device-local. Removing a source requires deleting its download first and changing references to it. Changing the download folder rescans the configured catalog and preserves old files.

## Selection and language

- Each rule selects its own model. The first added compatible model can configure unconfigured built-in rules. Later additions do not reroute configured rules.
- New rules preselect the most recently added compatible model that is still available.
- Whisper multilingual models detect the language by default. Each audio rule can supply a language hint. English-only custom variants force English.
- Parakeet v3 automatically handles its 25 supported European languages, including German and English. It does not use Whisper's language-hint selector.
- Parakeet v2 is English-only. The UI shows the model's language behavior rather than offering an ineffective selector. Rules show the capability of their selected speech override too.

## Primary sources

- [Argmax WhisperKit Core ML model files](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main): audio variants and download sizes checked September 29, 2026 through the Hugging Face model API.
- [Argmax v1.1.0 recommended models](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/README.md): the `_626MB` Large v3 Turbo conversion is recommended across iOS and macOS.
- [OpenAI Whisper models](https://github.com/openai/whisper#available-models-and-languages) and [NVIDIA Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): model architecture and language coverage.
- [FluidAudio v0.12.4 manifest](https://github.com/FluidInference/FluidAudio/blob/v0.12.4/Package.swift): Swift/macOS compatibility and dependencies.
- [FluidAudio v0.12.4 manual loading](https://github.com/FluidInference/FluidAudio/blob/v0.12.4/Documentation/ASR/ManualModelLoading.md), plus pinned `AsrModels`, `AsrManager` and `ModelNames` source. Frog constructs `AsrModels` from local Core ML components directly because the convenience loader can recover by downloading.
- [Parakeet v3 conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), [v2 conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml): repository file listings and license metadata.
- The text repositories above: public/ungated metadata and MLX-formatted files, checked against the pinned MLX model-type registry.

Metadata checks and automated fixtures do not verify downloaded-weight accuracy, real microphone transcription or native UI rendering. Those require separate installed-build checks.
