package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// Config holds all application configuration
type Config struct {
	mu sync.RWMutex

	// LLM settings
	LLM LLMConfig `json:"llm"`

	// App shortcuts (open/focus apps)
	Shortcuts []ShortcutConfig `json:"shortcuts"`

	// Text processing defaults and custom actions
	TextProcessing TextProcessingConfig `json:"textProcessing"`

	// Global hotkey bindings
	GlobalHotkeys []GlobalHotkeyConfig `json:"globalHotkeys"`
}

// LLMConfig holds LLM provider configuration
type LLMConfig struct {
	ActiveProvider  string                 `json:"activeProvider"`
	Local           LocalLLMConfig         `json:"local"`
	RemoteProviders []RemoteProviderConfig `json:"remoteProviders"`
}

// LocalLLMConfig holds settings for the built-in local LLM server
type LocalLLMConfig struct {
	ModelID     string `json:"modelId"`
	ContextSize int    `json:"contextSize"`
	GPULayers   int    `json:"gpuLayers"`
}

// RemoteProviderConfig holds settings for a remote LLM provider
type RemoteProviderConfig struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	APIKey   string `json:"apiKey"`
	Endpoint string `json:"endpoint"`
	Model    string `json:"model"`
	Active   bool   `json:"active"`
}

// ShortcutConfig holds a single app shortcut configuration
type ShortcutConfig struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Hotkey      string `json:"hotkey"`
	AppPath     string `json:"appPath"`
	BundleID    string `json:"bundleId"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
}

// TextProcessingConfig holds default text processing settings
type TextProcessingConfig struct {
	DefaultLanguage string         `json:"defaultLanguage"`
	TranslateTo     string         `json:"translateTo"`
	Actions         []ActionConfig `json:"actions"`
}

// ActionConfig holds a single text processing action (built-in or custom)
type ActionConfig struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Description  string `json:"description"`
	SystemPrompt string `json:"systemPrompt"`
	UserPrompt   string `json:"userPrompt"` // Use {{text}} as placeholder for input
	Builtin      bool   `json:"builtin"`
	Icon         string `json:"icon"`
}

// GlobalHotkeyConfig maps a global hotkey to an action
type GlobalHotkeyConfig struct {
	ID       string `json:"id"`
	Hotkey   string `json:"hotkey"`   // e.g. "Ctrl+Shift+C"
	Action   string `json:"action"`   // e.g. "correct", "translate", "show", or action ID
	Category string `json:"category"` // "text", "app", "system"
	Enabled  bool   `json:"enabled"`
}

// DefaultActions returns the built-in text processing actions
func DefaultActions() []ActionConfig {
	return []ActionConfig{
		{
			ID:           "correct",
			Name:         "Correct Text",
			Description:  "Fix typos & grammar",
			SystemPrompt: "You are a text correction assistant. Your job is to fix typos, grammar errors, and improve readability while preserving the original meaning and tone. Only return the corrected text, nothing else. Do not add explanations or commentary.",
			UserPrompt:   "Please correct the following text:\n\n{{text}}",
			Builtin:      true,
			Icon:         "T",
		},
		{
			ID:           "email",
			Name:         "Fix Email",
			Description:  "Professional email tone",
			SystemPrompt: "You are an email writing assistant. Your job is to correct and improve email text, making it professional, clear, and well-structured. Fix any typos, grammar issues, and improve the tone to be appropriate for professional correspondence. Only return the corrected email text, nothing else.",
			UserPrompt:   "Please correct and improve this email:\n\n{{text}}",
			Builtin:      true,
			Icon:         "E",
		},
		{
			ID:           "outline",
			Name:         "Outline",
			Description:  "Create structured outline",
			SystemPrompt: "You are a writing assistant that creates clear, structured outlines. Given text or a topic, create a well-organized outline with main points and sub-points. Use a clean hierarchical format. Only return the outline, nothing else.",
			UserPrompt:   "Please create an outline for the following:\n\n{{text}}",
			Builtin:      true,
			Icon:         "O",
		},
		{
			ID:           "summarize",
			Name:         "Summarize",
			Description:  "Concise summary",
			SystemPrompt: "You are a summarization assistant. Your job is to create concise, accurate summaries of the provided text. Capture the key points and main ideas. Only return the summary, nothing else.",
			UserPrompt:   "Please summarize the following text:\n\n{{text}}",
			Builtin:      true,
			Icon:         "S",
		},
		{
			ID:           "translate",
			Name:         "Translate",
			Description:  "Translate to language",
			SystemPrompt: "You are a translation assistant. Translate the provided text to {{targetLanguage}}. Preserve the original meaning, tone, and formatting as much as possible. Only return the translated text, nothing else.",
			UserPrompt:   "Please translate the following text to {{targetLanguage}}:\n\n{{text}}",
			Builtin:      true,
			Icon:         "W",
		},
	}
}

// DefaultGlobalHotkeys returns the default global hotkey bindings
func DefaultGlobalHotkeys() []GlobalHotkeyConfig {
	return []GlobalHotkeyConfig{
		{ID: "hk-show", Hotkey: "Ctrl+Shift+Space", Action: "show", Category: "system", Enabled: true},
		{ID: "hk-correct", Hotkey: "Ctrl+Shift+C", Action: "correct", Category: "text", Enabled: true},
		{ID: "hk-translate", Hotkey: "Ctrl+Shift+T", Action: "translate", Category: "text", Enabled: true},
		{ID: "hk-summarize", Hotkey: "Ctrl+Shift+S", Action: "summarize", Category: "text", Enabled: true},
	}
}

// DefaultConfig returns the default configuration
func DefaultConfig() *Config {
	return &Config{
		LLM: LLMConfig{
			ActiveProvider: "local",
			Local: LocalLLMConfig{
				ModelID:     "",
				ContextSize: 4096,
				GPULayers:   -1,
			},
			RemoteProviders: []RemoteProviderConfig{
				{
					ID:       "openai-default",
					Name:     "OpenAI",
					Type:     "openai",
					Endpoint: "https://api.openai.com/v1",
					Model:    "gpt-4o-mini",
					Active:   false,
				},
				{
					ID:       "anthropic-default",
					Name:     "Anthropic",
					Type:     "anthropic",
					Endpoint: "https://api.anthropic.com",
					Model:    "claude-sonnet-4-20250514",
					Active:   false,
				},
			},
		},
		Shortcuts: []ShortcutConfig{},
		TextProcessing: TextProcessingConfig{
			DefaultLanguage: "en",
			TranslateTo:     "de",
			Actions:         DefaultActions(),
		},
		GlobalHotkeys: DefaultGlobalHotkeys(),
	}
}

// DataDir returns the app data directory
func DataDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".config", "frog")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	return dir, nil
}

// ModelsDir returns the models directory
func ModelsDir() (string, error) {
	dataDir, err := DataDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(dataDir, "models")
	os.MkdirAll(dir, 0755)
	return dir, nil
}

// BinDir returns the binary directory (for llama-server)
func BinDir() (string, error) {
	dataDir, err := DataDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(dataDir, "bin")
	os.MkdirAll(dir, 0755)
	return dir, nil
}

func configPath() (string, error) {
	dir, err := DataDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// Load reads the config from disk, or creates a default one
func Load() (*Config, error) {
	path, err := configPath()
	if err != nil {
		return DefaultConfig(), nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			cfg := DefaultConfig()
			_ = cfg.Save()
			return cfg, nil
		}
		return nil, err
	}

	cfg := DefaultConfig()
	if err := json.Unmarshal(data, cfg); err != nil {
		return DefaultConfig(), nil
	}

	// Ensure built-in actions always exist (user may have old config)
	cfg.ensureBuiltinActions()

	return cfg, nil
}

// ensureBuiltinActions makes sure all built-in actions are present
func (c *Config) ensureBuiltinActions() {
	defaults := DefaultActions()
	existing := make(map[string]bool)
	for _, a := range c.TextProcessing.Actions {
		existing[a.ID] = true
	}
	for _, d := range defaults {
		if !existing[d.ID] {
			c.TextProcessing.Actions = append(c.TextProcessing.Actions, d)
		}
	}
}

// Save writes the config to disk
func (c *Config) Save() error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	path, err := configPath()
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}

func (c *Config) UpdateLLM(llm LLMConfig) error {
	c.mu.Lock()
	c.LLM = llm
	c.mu.Unlock()
	return c.Save()
}

func (c *Config) UpdateShortcuts(shortcuts []ShortcutConfig) error {
	c.mu.Lock()
	c.Shortcuts = shortcuts
	c.mu.Unlock()
	return c.Save()
}

func (c *Config) UpdateTextProcessing(tp TextProcessingConfig) error {
	c.mu.Lock()
	c.TextProcessing = tp
	c.mu.Unlock()
	return c.Save()
}

func (c *Config) UpdateGlobalHotkeys(hks []GlobalHotkeyConfig) error {
	c.mu.Lock()
	c.GlobalHotkeys = hks
	c.mu.Unlock()
	return c.Save()
}

func (c *Config) GetLLM() LLMConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.LLM
}

func (c *Config) GetShortcuts() []ShortcutConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.Shortcuts
}

func (c *Config) GetGlobalHotkeys() []GlobalHotkeyConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.GlobalHotkeys
}

func (c *Config) GetActions() []ActionConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.TextProcessing.Actions
}

func (c *Config) SetActiveModel(modelID string) error {
	c.mu.Lock()
	c.LLM.Local.ModelID = modelID
	c.mu.Unlock()
	return c.Save()
}
