# Local model sources

## Catalog and provenance

Frog recommends one speech model and one text model, each with a one-click download, and shows one alternative of each kind. Every other model can be added from Hugging Face.

| Speech | Download | Role | Download source |
| --- | --- | --- | --- |
| Parakeet Ultra — recommended | 632.2 MB | Fast, accurate dictation in 25 European languages | `FluidInference/parakeet-ultra-coreml` |
| Whisper Large v3 Turbo | 629.5 MB | Broad multilingual coverage, 99+ languages | `argmaxinc/whisperkit-coreml` / `openai_whisper-large-v3-v20240930_626MB` |

| Text | Download | Role | Download source |
| --- | --- | --- | --- |
| Qwen3.5 2B · 4-bit — recommended | 1.75 GB | Fast corrections and short rewrites, 201 languages; does not think before answering | `mlx-community/Qwen3.5-2B-4bit` |
| Qwen3.5 0.8B · 4-bit | 652 MB | Smallest and fastest, for spelling and punctuation | `mlx-community/Qwen3.5-0.8B-4bit` |

Parakeet runs through FluidAudio / Core ML, Whisper through WhisperKit / Core ML and the text models through MLX. Parakeet Ultra is a full-precision post-training of NVIDIA Parakeet TDT v3 with the same architecture, vocabulary and languages; FluidAudio measures it at 2.13 % WER on LibriSpeech test-clean against 2.27 % for v3, and 11.67 % against 14.81 % averaged over 24 FLEURS languages, at the same speed. Its int8 encoder runs on macOS 14+. Qwen3.5 2B is a hybrid Gated-DeltaNet model, so long prompts prefill cheaply; the repository also holds vision weights, which the text loader skips. Sizes are the bytes that Frog's download fetches: the variant folder plus the upstream tokenizer for Whisper, the four Core ML components and the vocabulary for Parakeet, and the configuration, tokenizer and SafeTensors files for MLX text models. Compiled caches are not included.

Previously installed or selected models stay available with their original IDs and weights: Parakeet TDT v3, Whisper Tiny, Base, Small and Small · Compact, Medium, full Large v3, the earlier Turbo conversion (listed as **Whisper Large v3 Turbo · earlier build**), English-only Parakeet v2, Qwen3 0.6B, 1.7B and 4B, Llama 3.2 1B and 3B Instruct, and Gemma 3 1B. You can also reveal these models through **Add model…** using their Hugging Face source. Saved selections are preserved.

The catalog data says which models are recommended (`LocalModelDescriptor.recommendedSpeechModelID`, `recommendedTextModelID`, `isRecommended`, `recommendedPair`) and which are shown (`shownModelIDs`), so the interface reads them instead of naming models.

All built-in local inference requires Apple silicon. Sizes in the UI are download sizes, not RAM guarantees. Model licensing differs by family; the info panel shows the available license and model-card link rather than treating every model as identically licensed. Local inference has no per-request API charge. No model weights are bundled with Frog.

Click **ⓘ** on any model to see its exact download repository, variant, runtime, language behavior, license, original model link when known, and a link to the download files. WhisperKit additionally installs a matching tokenizer from the upstream Hugging Face model during the explicit download action.

## Add a Hugging Face link

1. Open **Models → Local models → Add model…**.
2. Paste `owner/model` or `https://huggingface.co/owner/model`.
3. Click **Check source**. Frog reads repository metadata, including the size of each file, and text-model configuration only. The model's download size is the sum of the files it will fetch; a source whose metadata lacks sizes shows none.
4. Select the detected model or WhisperKit variant to add it to the catalog. A source added with an earlier version of Frog has no download size; checking it again and choosing **Show model** saves the size with it.
5. Click **Download** in the catalog to install the weights.

WhisperKit folder links such as `https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base` are supported. Individual file links, non-main revisions and arbitrary download hosts are not. Known built-ins resolve to their existing entry rather than creating duplicates.

Custom text sources need MLX format, SafeTensors weights and tokenizer files. A supported MLX architecture is still required at load time; format inspection alone cannot establish inference correctness. Custom speech sources need complete WhisperKit Core ML variant bundles. Parakeet supports the version-specific catalog sources: Ultra, v3 and v2. Raw PyTorch, GGUF and arbitrary NeMo weights are not interchangeable with these formats. Gated/private repositories need authentication and are not supported by this import flow.

Custom descriptors are included in portable JSON under `localModels`; downloaded weights stay device-local. Removing a source requires deleting its download first and changing references to it. Changing the download folder rescans the configured catalog and preserves old files. A rule whose model is not in the new folder takes an installed model of the same kind from it. When the folder holds none, or cannot be reached at launch, the rule keeps its model, shown as not downloaded, and uses it again once the folder that holds it is chosen in Preferences, including the same folder again after its disk is connected, or is reachable when Frog starts.

## Selection and language

- Each rule selects its own model. The first added compatible model can configure unconfigured built-in rules. Later additions do not reroute configured rules.
- New rules preselect the most recently added compatible model that is still available.
- Whisper multilingual models detect the language by default. Each audio rule can supply a language hint. English-only custom variants force English.
- Parakeet Ultra and v3 automatically handle their 25 supported European languages, including German and English. They do not use Whisper's language-hint selector.
- Parakeet v2 is English-only. The UI shows the model's language behavior rather than offering an ineffective selector. Rules show the capability of their selected speech override too.

## Primary sources

- [Argmax WhisperKit Core ML model files](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main): audio variants checked September 29, 2026 and download sizes of every catalog model on October 14, 2026, through the Hugging Face model API (`?blobs=true`).
- [Argmax v1.1.0 recommended models](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.0/README.md): the `_626MB` Large v3 Turbo conversion is recommended across iOS and macOS.
- [OpenAI Whisper models](https://github.com/openai/whisper#available-models-and-languages) and [NVIDIA Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): model architecture and language coverage.
- [FluidAudio v0.18.0 manifest](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Package@swift-6.2.swift): Swift/macOS compatibility and the `NemoTextProcessing`, `TTS` and `Diarizer` traits, which Frog turns off because it uses speech recognition only. Parakeet Ultra needs FluidAudio 0.17.3 or later.
- FluidAudio v0.18.0 `AsrModels`, `AsrManager`, `TdtDecoderState` and `ModelNames` source. Frog constructs `AsrModels` from local Core ML components directly because the convenience loader can recover by downloading, and gives each transcription a fresh decoder state. Ultra uses `JointDecisionv3.mlmodelc`; v3 and v2 keep the `JointDecision.mlmodelc` they were downloaded with, whose outputs are the same apart from the top-K pair that only a language hint reads.
- [FluidAudio v0.17.3 release notes](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.3) and the [Parakeet Ultra model card](https://huggingface.co/FluidInference/parakeet-ultra-coreml): accuracy and speed of Ultra against v3.
- [Parakeet Ultra conversion](https://huggingface.co/FluidInference/parakeet-ultra-coreml), [v3 conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), [v2 conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml): repository file listings, sizes and license metadata, checked on October 30, 2026 for Ultra.
- [Qwen3.5 2B](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit) and [0.8B](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit) MLX conversions, checked on October 30, 2026: Apache-2.0, `model_type` `qwen3_5`, which mlx-swift-lm 2.31.3 registers (`Qwen35.swift`), dropping the vision weights when it loads.
- The text repositories above: public/ungated metadata and MLX-formatted files, checked against the pinned MLX model-type registry.

Metadata checks and automated fixtures do not verify downloaded-weight accuracy, real microphone transcription or native UI rendering. Those require separate installed-build checks.
