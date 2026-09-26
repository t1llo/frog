# Local model sources — build 15

## Catalog and provenance

Frog's original two speech models were OpenAI Whisper Base and Small, distributed as Apple Core ML conversions by **Argmax** at `argmaxinc/whisperkit-coreml` on Hugging Face. Its two text models were Qwen3 0.6B and 1.7B, distributed as MLX conversions by **mlx-community**. The runtime libraries are separate from the downloaded weights.

The catalog now contains:

| Speech | Download repository | Native runtime |
| --- | --- | --- |
| OpenAI Whisper Tiny, Base, Small, Medium, Large v3, Large v3 Turbo | `argmaxinc/whisperkit-coreml` (individual variant folders) | WhisperKit / Core ML |
| NVIDIA Parakeet TDT 0.6B v3 and v2 | `FluidInference/parakeet-tdt-0.6b-v3-coreml` and `FluidInference/parakeet-tdt-0.6b-v2-coreml` | FluidAudio / Core ML |

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

Custom descriptors are included in portable JSON under `localModels`; downloaded weights stay device-local. Removing a source requires deleting its download first and changing any rules/defaults that refer to it. Changing the download folder rescans the configured catalog and preserves old files.

## Defaults and language

- The only installed model of a type is selected automatically, including after restart, deletion or folder changes. Downloading a second model preserves the selected default.
- Default models are visibly marked. Text shows **Local default** if a connected provider remains the active text source; downloading a local text model does not override that existing provider choice.
- Whisper multilingual models detect the language by default. Settings → Recording → Speech language can supply an explicit hint. English-only custom variants force English.
- Parakeet v3 automatically handles its 25 supported European languages, including German and English. It does not use Whisper's language-hint selector.
- Parakeet v2 is English-only. The UI shows the model's language behavior rather than offering an ineffective selector. Rules show the capability of their selected speech override too.

## Primary sources checked September 26, 2026

- [Argmax WhisperKit Core ML model files](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main): confirmed catalog variants exist through the Hugging Face model API.
- [FluidAudio v0.12.4 manifest](https://github.com/FluidInference/FluidAudio/blob/v0.12.4/Package.swift): Swift/macOS compatibility and dependencies.
- [FluidAudio v0.12.4 manual loading](https://github.com/FluidInference/FluidAudio/blob/v0.12.4/Documentation/ASR/ManualModelLoading.md), plus pinned `AsrModels`, `AsrManager` and `ModelNames` source. Frog constructs `AsrModels` from local Core ML components directly because the convenience loader can recover by downloading.
- [Parakeet v3 conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), [v2 conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml): repository file listings and license metadata.
- The text repositories above: public/ungated metadata and MLX-formatted files, checked against the pinned MLX model-type registry.

Metadata checks and automated fixtures do not verify downloaded-weight accuracy, real microphone transcription or native UI rendering. Those require separate installed-build checks.
