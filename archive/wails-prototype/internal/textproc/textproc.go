package textproc

import (
	"context"
	"fmt"
	"frog/internal/config"
	"frog/internal/llm"
	"strings"
)

// Processor handles text processing using an LLM provider
type Processor struct {
	provider llm.Provider
	actions  []config.ActionConfig
}

// NewProcessor creates a new text processor
func NewProcessor(provider llm.Provider) *Processor {
	return &Processor{
		provider: provider,
		actions:  config.DefaultActions(),
	}
}

// SetProvider updates the LLM provider
func (p *Processor) SetProvider(provider llm.Provider) {
	p.provider = provider
}

// SetActions updates the available actions
func (p *Processor) SetActions(actions []config.ActionConfig) {
	p.actions = actions
}

// Process applies the specified action to the given text
func (p *Processor) Process(ctx context.Context, actionID string, text string, opts map[string]string) (string, error) {
	if p.provider == nil {
		return "", fmt.Errorf("no LLM provider configured")
	}

	// Find the action by ID
	var action *config.ActionConfig
	for _, a := range p.actions {
		if a.ID == actionID {
			action = &a
			break
		}
	}

	if action == nil {
		return "", fmt.Errorf("unknown action: %s", actionID)
	}

	systemPrompt := expandTemplate(action.SystemPrompt, text, opts)
	userPrompt := expandTemplate(action.UserPrompt, text, opts)

	return p.provider.Complete(ctx, userPrompt, systemPrompt)
}

// expandTemplate replaces {{text}}, {{targetLanguage}}, and other placeholders
func expandTemplate(tmpl string, text string, opts map[string]string) string {
	result := strings.ReplaceAll(tmpl, "{{text}}", text)
	if opts != nil {
		for k, v := range opts {
			result = strings.ReplaceAll(result, "{{"+k+"}}", v)
		}
	}
	// Default targetLanguage if not provided
	result = strings.ReplaceAll(result, "{{targetLanguage}}", "English")
	return result
}
