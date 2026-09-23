# Providers and models

In **Providers**, add a connection, choose its service, then select the models you want available in Rules. Cloud services include preselected text models; use the **Get an API key** link to open the service's key page. For other models, enter the exact API model ID and an optional friendly display name. Re-adding an existing ID updates its display name.

Choose a default model for each connection. The **Your defaults** card selects the default provider and its model. In a rule's **Model override** menu, select a configured model grouped under its provider, or use the defaults. Friendly names are for display only; Frog sends the exact model ID to the API. Existing configurations keep their original model choices.

The API-key link is directly beneath the key field (Gemini opens Google AI Studio). Connection cards have configure, duplicate and delete icons. Duplicating opens a new draft with the same model choices; enter its credentials separately. Confirmed deletion removes the key and resets affected rules to the remaining defaults. Deleting the last connection is allowed; rules remain saved and need a new provider before running.

**Try text** has separate rule, provider and model menus. Its provider/model choices apply only to that draft and do not change the saved rule.

For background shortcuts, **Settings → Show processing indicator** controls the floating progress display. If an app does not expose an editable target, the completed result is copied for manual paste instead of inserted automatically.

## Local setup

### Ollama

1. Install and start [Ollama](https://ollama.com/download).
2. Download a text model, for example `ollama pull llama3.2`.
3. Add an **Ollama (local)** provider. The default endpoint is `http://localhost:11434`.
4. Click **Find installed models**, select your models and a default, then test and save the connection.

### LM Studio

1. Install [LM Studio](https://lmstudio.ai/) and download a text model.
2. Start the local server in LM Studio's **Developer** section. See its [server setup guide](https://lmstudio.ai/docs/developer/core/server).
3. Add an **LM Studio (local)** provider. The default endpoint is `http://localhost:1234/v1`.
4. Click **Find installed models**, select a text model, choose a default, then test and save. Enter an API token if you enabled server authentication.

Frog does not install model servers or download model weights. Discovery runs only when you click the button; it sends no writing text. The list reflects models reported by your server, so select models that support text/chat.

## Verified catalog and endpoints

Checked against official documentation on **2026-09-22**. Suggestions are a bundled starting point, not a promise that your API account has access. Custom IDs allow newer models without waiting for an app update.

| Service | Base endpoint | Suggested text models |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `gpt-6-luna` (default), `gpt-6-sol`, `gpt-6-astra` |
| Claude | `https://api.anthropic.com` | `claude-sonnet-5` (default), `claude-haiku-4-5-20251001`, `claude-opus-5-5`, `claude-fable-5-1` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` | `gemini-3.8-flash` (default), `gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`, `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`, `gemini-3.1-pro-preview`, `gemini-3-flash-preview`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`, `gemini-2.5-pro` |
| Ollama | `http://localhost:11434` | Installed models from `/api/tags`; starter suggestion `llama3.2` |
| LM Studio | `http://localhost:1234/v1` | Installed models from `/v1/models` |

The cloud base endpoints are still current; newer model versions do not require changing them. Frog uses OpenAI/LM Studio chat completions, Claude Messages, Gemini `generateContent` and Ollama `/api/chat`.

The Gemini catalog lists text/chat models only, excluding image, audio, embedding and video-only services. Google restricts 2.5 access to existing API users; those choices are labeled accordingly. Models with `preview` in their IDs are previews.

Sources: [OpenAI model catalog](https://developers.openai.com/api/docs/models), [GPT-6 Luna API support](https://developers.openai.com/api/docs/models/gpt-6-luna), [Claude model catalog](https://platform.claude.com/docs/en/about-claude/models/overview), [Gemini model catalog](https://ai.google.dev/gemini-api/docs/models), [Ollama model listing](https://docs.ollama.com/api/tags), [LM Studio OpenAI-compatible endpoints](https://lmstudio.ai/docs/developer/openai-compat).

API keys: [OpenAI](https://platform.openai.com/api-keys), [Claude](https://platform.claude.com/settings/keys), [Google AI Studio](https://aistudio.google.com/apikey). For a custom OpenAI-compatible service, use that service's endpoint, model IDs and credentials.
