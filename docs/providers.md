# Providers and models

Frog separates **Internal models**, downloaded and run inside the app, from **External providers**, including cloud APIs and locally running Ollama or LM Studio servers.

Each rule selects its own model. There are no global model defaults. The first compatible model can configure unconfigured built-in rules; new rules preselect the most recently added compatible model. Existing configured rules keep their selections.

## External providers

Add a connection, name it, choose its service and endpoint, then select models. API keys are saved in macOS Keychain. Each model has an API ID, a display name and a Text or Speech-to-text category. Display names never change the ID sent to the API.

| Service | Base endpoint |
| --- | --- |
| OpenAI | `https://api.openai.com/v1` |
| Claude | `https://api.anthropic.com` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` |
| Ollama | `http://localhost:11434` |
| LM Studio | `http://localhost:1234/v1` |

Use the model IDs available to your account. Cloud suggestions are starting points, not a guarantee of API access. Custom OpenAI-compatible connections use your service's endpoint and credentials.

Speech-to-text supports OpenAI transcription, Gemini audio input and compatible transcription endpoints. Other provider types offer text models only. Speech models transcribe recordings; they do not generate spoken audio.

Deleting a connection clears affected rule selections rather than silently choosing a replacement. Duplicated connections need their own credentials.

### Ollama

1. Install and start [Ollama](https://ollama.com/download).
2. Download a text model, for example `ollama pull llama3.2`.
3. Add an Ollama connection and click **Find installed models**.
4. Select models, test the connection and save.

### LM Studio

1. Install [LM Studio](https://lmstudio.ai/) and download a text model.
2. Start its local server in the Developer section.
3. Add an LM Studio connection and click **Find installed models**.
4. Select models, test and save. Supply an API token if your server requires one.

Discovery sends a model-list request, not your writing or recordings. Frog does not install or manage external model servers.

## Internal models

Built-in inference requires Apple silicon. Download speech or text models from the catalog, or [add a compatible Hugging Face source](local-model-sources.md). Models load on demand and unload after the idle delay in Settings.

Audio rules own speech language, Toggle/Hold recording, Copy/Copy and paste output, recording-popup visibility and optional transcript cleanup. Cleanup uses a separately selected text model and adds processing time. The built-in Dictate shortcut is **Option–Space**; shortcuts remain editable.

API keys: [OpenAI](https://platform.openai.com/api-keys) · [Claude](https://platform.claude.com/settings/keys) · [Google AI Studio](https://aistudio.google.com/apikey).
