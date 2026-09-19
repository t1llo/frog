package config

import (
	"encoding/json"
	"fmt"
	"frog/internal/credential"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Preferences struct {
	StartAtLogin         bool `json:"startAtLogin"`
	HistoryEnabled       bool `json:"historyEnabled"`
	HistoryLimit         int  `json:"historyLimit"`
	HistoryRetentionDays int  `json:"historyRetentionDays"`
}

func ValidatePreferences(p Preferences) error {
	if p.HistoryLimit < 1 || p.HistoryLimit > 10000 || p.HistoryRetentionDays < 1 || p.HistoryRetentionDays > 3650 {
		return fmt.Errorf("history limit must be 1–10000 and retention 1–3650 days")
	}
	return nil
}
func (c *Config) GetPreferences() Preferences {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.Preferences
}
func (c *Config) UpdatePreferences(p Preferences) error {
	if err := ValidatePreferences(p); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	old := c.Preferences
	c.Preferences = p
	if err := c.saveLocked(); err != nil {
		c.Preferences = old
		return err
	}
	return nil
}
func (c *Config) GetTextProcessing() TextProcessingConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	v := c.TextProcessing
	v.Actions = append([]ActionConfig{}, v.Actions...)
	return v
}
func (c *Config) Snapshot() *Config {
	c.mu.RLock()
	defer c.mu.RUnlock()
	data, _ := json.Marshal(c)
	v := &Config{}
	_ = json.Unmarshal(data, v)
	return v
}
func (c *Config) Secret(id string) (string, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	s := c.secrets
	if s == nil {
		s = credential.Keyring{}
	}
	value, err := s.Get(id)
	if err != nil {
		return "", fmt.Errorf("cannot access OS credential storage; unlock your keychain or Secret Service")
	}
	return value, nil
}
func (c *Config) importSecrets(l *LLMConfig) error {
	s := c.secrets
	if s == nil {
		s = credential.Keyring{}
	}
	for i := range l.RemoteProviders {
		p := &l.RemoteProviders[i]
		if p.ClearAPIKey {
			if err := s.Delete(p.ID); err != nil {
				return fmt.Errorf("cannot remove key from OS credential storage")
			}
			p.HasAPIKey = false
		} else if p.APIKey != "" {
			if err := s.Set(p.ID, p.APIKey); err != nil {
				return fmt.Errorf("cannot save API key; unlock OS keychain or start Secret Service")
			}
			p.HasAPIKey = true
		} else {
			for _, old := range c.LLM.RemoteProviders {
				if old.ID == p.ID {
					p.HasAPIKey = old.HasAPIKey
				}
			}
		}
		p.APIKey = ""
		p.ClearAPIKey = false
	}
	return nil
}
func (c *Config) saveLocked() error {
	path := c.path
	if path == "" {
		var err error
		path, err = configPath()
		if err != nil {
			return err
		}
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return AtomicWrite(path, data)
}

// AtomicWrite never exposes partially written JSON or world-readable text.
func AtomicWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".frog-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

var placeholders = regexp.MustCompile(`\{\{([^{}]*)\}\}`)

func ValidateActions(actions []ActionConfig) error {
	ids := map[string]bool{}
	for _, a := range actions {
		if strings.TrimSpace(a.ID) == "" || strings.TrimSpace(a.Name) == "" || strings.TrimSpace(a.UserPrompt) == "" {
			return fmt.Errorf("rule ID, name and user prompt are required")
		}
		if ids[a.ID] {
			return fmt.Errorf("duplicate rule ID %q", a.ID)
		}
		ids[a.ID] = true
		combined := a.SystemPrompt + a.UserPrompt
		for _, m := range placeholders.FindAllStringSubmatch(combined, -1) {
			if m[1] != "text" && m[1] != "targetLanguage" {
				return fmt.Errorf("unknown prompt placeholder %q", m[1])
			}
		}
		rest := placeholders.ReplaceAllString(combined, "")
		if strings.Contains(rest, "{{") || strings.Contains(rest, "}}") {
			return fmt.Errorf("malformed prompt placeholder")
		}
		if !strings.Contains(combined, "{{text}}") {
			return fmt.Errorf("rule prompt must include {{text}}")
		}
		if strings.Contains(combined, "{{targetLanguage}}") && strings.TrimSpace(a.TargetLanguage) == "" {
			return fmt.Errorf("target language is required")
		}
	}
	return nil
}
func ValidateLLM(l LLMConfig) error {
	if l.ActiveProvider != "local" && l.ActiveProvider != "remote" {
		return fmt.Errorf("select local or remote provider mode")
	}
	ids := map[string]bool{}
	active := 0
	for _, p := range l.RemoteProviders {
		if p.ID == "" || p.ID == "local" || ids[p.ID] {
			return fmt.Errorf("provider IDs must be unique and cannot be local")
		}
		ids[p.ID] = true
		if err := ValidateProvider(p); err != nil {
			return err
		}
		if p.Active {
			active++
		}
	}
	if active > 1 {
		return fmt.Errorf("only one default remote provider may be active")
	}
	return nil
}
func ValidateProvider(p RemoteProviderConfig) error {
	switch p.Type {
	case "openai", "custom", "anthropic", "gemini", "ollama":
	default:
		return fmt.Errorf("unsupported provider type %q", p.Type)
	}
	if strings.TrimSpace(p.Model) == "" {
		return fmt.Errorf("provider model is required")
	}
	u, err := url.Parse(p.Endpoint)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("endpoint must be an HTTP(S) URL without credentials, query or fragment")
	}
	return nil
}
