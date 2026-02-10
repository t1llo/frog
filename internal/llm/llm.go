package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Provider represents an LLM provider interface
type Provider interface {
	Complete(ctx context.Context, prompt string, systemPrompt string) (string, error)
	Name() string
}

// OpenAIProvider communicates with OpenAI-compatible APIs (also used for local llama-server)
type OpenAIProvider struct {
	endpoint string
	apiKey   string
	model    string
	client   *http.Client
	name     string
}

// NewOpenAIProvider creates a new OpenAI-compatible provider
func NewOpenAIProvider(name, endpoint, apiKey, model string) *OpenAIProvider {
	return &OpenAIProvider{
		name:     name,
		endpoint: endpoint,
		apiKey:   apiKey,
		model:    model,
		client: &http.Client{
			Timeout: 120 * time.Second,
		},
	}
}

func (o *OpenAIProvider) Name() string {
	return fmt.Sprintf("%s (%s)", o.name, o.model)
}

type openAIMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type openAIRequest struct {
	Model    string          `json:"model"`
	Messages []openAIMessage `json:"messages"`
}

type openAIChoice struct {
	Message openAIMessage `json:"message"`
}

type openAIResponse struct {
	Choices []openAIChoice `json:"choices"`
	Error   *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func (o *OpenAIProvider) Complete(ctx context.Context, prompt string, systemPrompt string) (string, error) {
	messages := []openAIMessage{}
	if systemPrompt != "" {
		messages = append(messages, openAIMessage{Role: "system", Content: systemPrompt})
	}
	messages = append(messages, openAIMessage{Role: "user", Content: prompt})

	reqBody := openAIRequest{
		Model:    o.model,
		Messages: messages,
	}

	data, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", o.endpoint+"/chat/completions", bytes.NewReader(data))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if o.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.apiKey)
	}

	resp, err := o.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(body))
	}

	var result openAIResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("unmarshal response: %w", err)
	}

	if result.Error != nil {
		return "", fmt.Errorf("API error: %s", result.Error.Message)
	}

	if len(result.Choices) == 0 {
		return "", fmt.Errorf("no choices in response")
	}

	return result.Choices[0].Message.Content, nil
}

// AnthropicProvider communicates with the Anthropic API
type AnthropicProvider struct {
	endpoint string
	apiKey   string
	model    string
	client   *http.Client
}

// NewAnthropicProvider creates a new Anthropic provider
func NewAnthropicProvider(endpoint, apiKey, model string) *AnthropicProvider {
	return &AnthropicProvider{
		endpoint: endpoint,
		apiKey:   apiKey,
		model:    model,
		client: &http.Client{
			Timeout: 120 * time.Second,
		},
	}
}

func (a *AnthropicProvider) Name() string {
	return fmt.Sprintf("Anthropic (%s)", a.model)
}

type anthropicMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int                `json:"max_tokens"`
	System    string             `json:"system,omitempty"`
	Messages  []anthropicMessage `json:"messages"`
}

type anthropicResponseContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type anthropicResponse struct {
	Content []anthropicResponseContent `json:"content"`
	Error   *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func (a *AnthropicProvider) Complete(ctx context.Context, prompt string, systemPrompt string) (string, error) {
	reqBody := anthropicRequest{
		Model:     a.model,
		MaxTokens: 4096,
		System:    systemPrompt,
		Messages: []anthropicMessage{
			{Role: "user", Content: prompt},
		},
	}

	data, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", a.endpoint+"/v1/messages", bytes.NewReader(data))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", a.apiKey)
	req.Header.Set("anthropic-version", "2023-06-01")

	resp, err := a.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(body))
	}

	var result anthropicResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("unmarshal response: %w", err)
	}

	if result.Error != nil {
		return "", fmt.Errorf("API error: %s", result.Error.Message)
	}

	if len(result.Content) == 0 {
		return "", fmt.Errorf("no content in response")
	}

	return result.Content[0].Text, nil
}
