package llm

// ModelEntry describes a downloadable model
type ModelEntry struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Size        string `json:"size"`
	Parameters  string `json:"parameters"`
	HFRepo      string `json:"hfRepo"`
	HFFile      string `json:"hfFile"`
	DownloadURL string `json:"downloadUrl"`
}

// AvailableModels returns the curated list of models users can download
func AvailableModels() []ModelEntry {
	return []ModelEntry{
		{
			ID:          "llama-3.2-3b-instruct",
			Name:        "Llama 3.2 3B Instruct",
			Description: "Meta's compact instruction-tuned model. Great balance of speed and quality.",
			Size:        "~2.0 GB",
			Parameters:  "3B",
			HFRepo:      "bartowski/Llama-3.2-3B-Instruct-GGUF",
			HFFile:      "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
			DownloadURL: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
		},
		{
			ID:          "llama-3.2-1b-instruct",
			Name:        "Llama 3.2 1B Instruct",
			Description: "Ultra-light model for fast responses. Good for simple corrections.",
			Size:        "~0.8 GB",
			Parameters:  "1B",
			HFRepo:      "bartowski/Llama-3.2-1B-Instruct-GGUF",
			HFFile:      "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
			DownloadURL: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
		},
		{
			ID:          "mistral-7b-instruct",
			Name:        "Mistral 7B Instruct v0.3",
			Description: "Strong general-purpose model. Excellent at writing and translation.",
			Size:        "~4.4 GB",
			Parameters:  "7B",
			HFRepo:      "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
			HFFile:      "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
			DownloadURL: "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
		},
		{
			ID:          "phi-3.5-mini-instruct",
			Name:        "Phi 3.5 Mini Instruct",
			Description: "Microsoft's efficient small model. Strong reasoning for its size.",
			Size:        "~2.4 GB",
			Parameters:  "3.8B",
			HFRepo:      "bartowski/Phi-3.5-mini-instruct-GGUF",
			HFFile:      "Phi-3.5-mini-instruct-Q4_K_M.gguf",
			DownloadURL: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf",
		},
		{
			ID:          "gemma-2-2b-instruct",
			Name:        "Gemma 2 2B Instruct",
			Description: "Google's compact model. Fast and good at text correction.",
			Size:        "~1.6 GB",
			Parameters:  "2B",
			HFRepo:      "bartowski/gemma-2-2b-it-GGUF",
			HFFile:      "gemma-2-2b-it-Q4_K_M.gguf",
			DownloadURL: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf",
		},
		{
			ID:          "qwen-2.5-3b-instruct",
			Name:        "Qwen 2.5 3B Instruct",
			Description: "Alibaba's multilingual model. Excellent for translation tasks.",
			Size:        "~2.0 GB",
			Parameters:  "3B",
			HFRepo:      "Qwen/Qwen2.5-3B-Instruct-GGUF",
			HFFile:      "qwen2.5-3b-instruct-q4_k_m.gguf",
			DownloadURL: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
		},
	}
}

// FindModelByID looks up a model entry by its ID
func FindModelByID(id string) *ModelEntry {
	for _, m := range AvailableModels() {
		if m.ID == id {
			return &m
		}
	}
	return nil
}
