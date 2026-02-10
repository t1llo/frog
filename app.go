package main

import (
	"context"
	"fmt"
	"frog/internal/clipboard"
	"frog/internal/config"
	"frog/internal/globalhotkey"
	"frog/internal/keysim"
	"frog/internal/llm"
	"frog/internal/shortcuts"
	"frog/internal/textproc"
	"log"

	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct holds the application state
type App struct {
	ctx             context.Context
	config          *config.Config
	processor       *textproc.Processor
	localServer     *llm.LocalServer
	modelDownloader *llm.ModelDownloader
	shortcutManager *shortcuts.Manager
	hotkeyManager   *globalhotkey.Manager
	currentProvider llm.Provider
	isQuitting      bool
}

// NewApp creates a new App application struct
func NewApp() *App {
	cfg, err := config.Load()
	if err != nil {
		log.Printf("Failed to load config, using defaults: %v", err)
		cfg = config.DefaultConfig()
	}

	modelsDir, _ := config.ModelsDir()
	binDir, _ := config.BinDir()

	processor := textproc.NewProcessor(nil)
	processor.SetActions(cfg.GetActions())

	return &App{
		config:          cfg,
		processor:       processor,
		localServer:     llm.NewLocalServer(binDir),
		modelDownloader: llm.NewModelDownloader(modelsDir),
		shortcutManager: shortcuts.NewManager(),
		hotkeyManager:   globalhotkey.NewManager(),
	}
}

// startup is called when the app starts
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.initLLMProvider()
	a.registerGlobalHotkeys()
}

// shutdown is called when the app is closing
func (a *App) shutdown(ctx context.Context) {
	a.hotkeyManager.Unregister()
	a.localServer.Stop()
}

// beforeClose is called when the user tries to close the window
func (a *App) beforeClose(ctx context.Context) (prevent bool) {
	if a.isQuitting {
		return false // Allow close/quit
	}
	wailsruntime.WindowHide(a.ctx)
	return true // Prevent close, just hide
}

// Quit fully quits the application
func (a *App) Quit() {
	a.isQuitting = true
	wailsruntime.Quit(a.ctx)
}

// registerGlobalHotkeys sets up system-wide hotkey bindings from config
func (a *App) registerGlobalHotkeys() {
	// Unregister existing hotkeys before re-registering
	a.hotkeyManager.Unregister()

	var bindings []globalhotkey.Binding

	// Register global hotkeys from config
	hkConfigs := a.config.GetGlobalHotkeys()
	shortcuts := a.config.GetShortcuts()
	for _, hk := range hkConfigs {
		if !hk.Enabled || hk.Hotkey == "" {
			continue
		}

		hkCopy := hk // capture for closure
		binding := globalhotkey.Binding{
			ID:     hkCopy.ID,
			Hotkey: hkCopy.Hotkey,
			Action: func() {
				switch hkCopy.Category {
				case "system":
					// System actions: show window and emit event
					wailsruntime.WindowShow(a.ctx)
					wailsruntime.WindowUnminimise(a.ctx)
					wailsruntime.WindowSetAlwaysOnTop(a.ctx, true)
					wailsruntime.WindowSetAlwaysOnTop(a.ctx, false)
					wailsruntime.EventsEmit(a.ctx, "action:"+hkCopy.Action)

				case "text":
					// Text actions: grab selected text, process with LLM, emit popup:result
					go func() {
						// Get selected text from any app
						originalText, err := keysim.GrabSelectedText()
						if err != nil {
							log.Printf("Failed to grab selected text: %v", err)
							wailsruntime.EventsEmit(a.ctx, "notification", map[string]string{
								"type":    "error",
								"message": "Failed to grab selected text",
							})
							return
						}

						if originalText == "" {
							wailsruntime.EventsEmit(a.ctx, "notification", map[string]string{
								"type":    "warning",
								"message": "No text selected",
							})
							return
						}

						// Prepare options for processing
						opts := make(map[string]string)
						if hkCopy.Action == "translate" {
							opts["targetLanguage"] = a.config.TextProcessing.TranslateTo
						}

						// Process text with LLM
						processedText, err := a.processor.Process(a.ctx, hkCopy.Action, originalText, opts)
						if err != nil {
							log.Printf("Failed to process text: %v", err)
							wailsruntime.EventsEmit(a.ctx, "notification", map[string]string{
								"type":    "error",
								"message": "Failed to process text: " + err.Error(),
							})
							return
						}

						// Emit popup:result event with all necessary data
						result := map[string]interface{}{
							"actionID":       hkCopy.Action,
							"originalText":   originalText,
							"processedText":  processedText,
							"targetLanguage": opts["targetLanguage"],
						}
						wailsruntime.EventsEmit(a.ctx, "popup:result", result)
					}()

				case "app":
					// App actions: find shortcut by action ID and open the app
					go func() {
						// Look up shortcut matching the action ID
						var targetShortcut *config.ShortcutConfig
						for i := range shortcuts {
							if shortcuts[i].ID == hkCopy.Action {
								targetShortcut = &shortcuts[i]
								break
							}
						}

						if targetShortcut == nil {
							log.Printf("App shortcut not found for action: %s", hkCopy.Action)
							wailsruntime.EventsEmit(a.ctx, "notification", map[string]string{
								"type":    "error",
								"message": "App shortcut not found",
							})
							return
						}

						// Open/focus the app
						if err := a.shortcutManager.OpenApp(targetShortcut.AppPath, targetShortcut.BundleID); err != nil {
							log.Printf("Failed to open app: %v", err)
							wailsruntime.EventsEmit(a.ctx, "notification", map[string]string{
								"type":    "error",
								"message": "Failed to open app: " + err.Error(),
							})
							return
						}

						// Show success notification
						wailsruntime.EventsEmit(a.ctx, "notification", map[string]string{
							"type":    "success",
							"message": "Opened " + targetShortcut.Name,
						})
					}()

				default:
					// Unknown category: fallback to showing window
					wailsruntime.WindowShow(a.ctx)
					wailsruntime.EventsEmit(a.ctx, "action:"+hkCopy.Action)
				}
			},
		}
		bindings = append(bindings, binding)
	}

	a.hotkeyManager.Register(a.ctx, bindings)
}

// initLLMProvider sets up the active LLM provider based on config
func (a *App) initLLMProvider() {
	llmCfg := a.config.GetLLM()

	switch llmCfg.ActiveProvider {
	case "local":
		// If we have a local model selected, start the server
		if llmCfg.Local.ModelID != "" {
			modelPath, err := a.modelDownloader.GetModelPath(llmCfg.Local.ModelID)
			if err == nil {
				modelName := llmCfg.Local.ModelID
				if entry := llm.FindModelByID(llmCfg.Local.ModelID); entry != nil {
					modelName = entry.Name
				}
				if err := a.localServer.Start(modelPath, modelName); err != nil {
					log.Printf("Failed to start local server: %v", err)
				} else {
					a.currentProvider = a.localServer.NewProvider()
					a.processor.SetProvider(a.currentProvider)
				}
			}
		}
	case "remote":
		for _, rp := range llmCfg.RemoteProviders {
			if rp.Active {
				switch rp.Type {
				case "openai", "custom":
					a.currentProvider = llm.NewOpenAIProvider(rp.Name, rp.Endpoint, rp.APIKey, rp.Model)
				case "anthropic":
					a.currentProvider = llm.NewAnthropicProvider(rp.Endpoint, rp.APIKey, rp.Model)
				}
				a.processor.SetProvider(a.currentProvider)
				break
			}
		}
	}
}

// --- Text Processing Methods (bound to frontend) ---

// ProcessText processes text with the given action ID
func (a *App) ProcessText(actionID string, text string, opts map[string]string) (string, error) {
	if a.currentProvider == nil {
		return "", fmt.Errorf("no LLM provider configured. Please download a model or set up a remote provider first.")
	}

	// For local provider, check if server is ready
	if a.config.GetLLM().ActiveProvider == "local" && !a.localServer.IsReady() {
		return "", fmt.Errorf("local model is still loading. Please wait a moment and try again.")
	}

	return a.processor.Process(a.ctx, actionID, text, opts)
}

// GetActions returns all configured text processing actions
func (a *App) GetActions() []config.ActionConfig {
	return a.config.GetActions()
}

// SaveAction updates or adds an action in the config
func (a *App) SaveAction(action config.ActionConfig) error {
	actions := a.config.GetActions()
	found := false
	for i, existing := range actions {
		if existing.ID == action.ID {
			actions[i] = action
			found = true
			break
		}
	}
	if !found {
		actions = append(actions, action)
	}

	tp := a.config.TextProcessing
	tp.Actions = actions
	if err := a.config.UpdateTextProcessing(tp); err != nil {
		return err
	}
	a.processor.SetActions(actions)
	return nil
}

// DeleteAction removes a custom (non-builtin) action
func (a *App) DeleteAction(actionID string) error {
	actions := a.config.GetActions()
	var filtered []config.ActionConfig
	for _, action := range actions {
		if action.ID == actionID {
			if action.Builtin {
				return fmt.Errorf("cannot delete built-in action %q", actionID)
			}
			continue
		}
		filtered = append(filtered, action)
	}

	tp := a.config.TextProcessing
	tp.Actions = filtered
	if err := a.config.UpdateTextProcessing(tp); err != nil {
		return err
	}
	a.processor.SetActions(filtered)
	return nil
}

// --- Global Hotkey Methods ---

// GetGlobalHotkeys returns the global hotkey configuration
func (a *App) GetGlobalHotkeys() []config.GlobalHotkeyConfig {
	return a.config.GetGlobalHotkeys()
}

// SaveGlobalHotkeys updates the global hotkeys and re-registers them
func (a *App) SaveGlobalHotkeys(hotkeys []config.GlobalHotkeyConfig) error {
	if err := a.config.UpdateGlobalHotkeys(hotkeys); err != nil {
		return err
	}
	a.registerGlobalHotkeys()
	return nil
}

// --- Clipboard Methods ---

// GetClipboardText reads text from the system clipboard
func (a *App) GetClipboardText() (string, error) {
	return clipboard.ReadText()
}

// SetClipboardText writes text to the system clipboard
func (a *App) SetClipboardText(text string) error {
	return clipboard.Write(text)
}

// --- Local Model Management Methods ---

// GetAvailableModels returns the list of models available for download
func (a *App) GetAvailableModels() []llm.ModelEntry {
	return llm.AvailableModels()
}

// GetLocalModels returns all locally downloaded models
func (a *App) GetLocalModels() ([]llm.LocalModel, error) {
	return a.modelDownloader.ListLocalModels()
}

// IsModelDownloaded checks if a specific model is downloaded
func (a *App) IsModelDownloaded(modelID string) bool {
	return a.modelDownloader.IsModelDownloaded(modelID)
}

// DownloadModel downloads a model by its registry ID
func (a *App) DownloadModel(modelID string) error {
	return a.modelDownloader.DownloadModel(a.ctx, modelID)
}

// DownloadModelFromURL downloads a GGUF model from a custom URL
func (a *App) DownloadModelFromURL(url string, fileName string) error {
	return a.modelDownloader.DownloadFromURL(a.ctx, fileName, url, fileName)
}

// CancelDownload cancels an active model download
func (a *App) CancelDownload(modelID string) {
	a.modelDownloader.CancelDownload(modelID)
}

// GetDownloadStatus returns the status of an active download
func (a *App) GetDownloadStatus(modelID string) *llm.DownloadStatus {
	return a.modelDownloader.GetDownloadStatus(modelID)
}

// GetAllDownloadStatuses returns all active download statuses
func (a *App) GetAllDownloadStatuses() []llm.DownloadStatus {
	return a.modelDownloader.GetAllDownloadStatuses()
}

// DeleteLocalModel removes a downloaded model
func (a *App) DeleteLocalModel(modelID string) error {
	// Stop server if this model is currently loaded
	status := a.localServer.GetStatus()
	if status.Running {
		modelPath, err := a.modelDownloader.GetModelPath(modelID)
		if err == nil && modelPath == status.ModelPath {
			a.localServer.Stop()
			a.currentProvider = nil
			a.processor.SetProvider(nil)
		}
	}
	return a.modelDownloader.DeleteModel(modelID)
}

// SetActiveModel selects a model and starts the local server with it
func (a *App) SetActiveModel(modelID string) error {
	modelPath, err := a.modelDownloader.GetModelPath(modelID)
	if err != nil {
		return fmt.Errorf("model not found: %w", err)
	}

	modelName := modelID
	if entry := llm.FindModelByID(modelID); entry != nil {
		modelName = entry.Name
	}

	// Update config
	if err := a.config.SetActiveModel(modelID); err != nil {
		return err
	}

	// Ensure provider mode is local
	llmCfg := a.config.GetLLM()
	llmCfg.ActiveProvider = "local"
	a.config.UpdateLLM(llmCfg)

	// Start server with this model
	if err := a.localServer.Start(modelPath, modelName); err != nil {
		return fmt.Errorf("failed to start local server: %w", err)
	}

	a.currentProvider = a.localServer.NewProvider()
	a.processor.SetProvider(a.currentProvider)

	return nil
}

// --- Local Server Methods ---

// GetServerStatus returns the current local server status
func (a *App) GetServerStatus() llm.ServerStatus {
	return a.localServer.GetStatus()
}

// IsServerReady checks if the local server is ready to accept requests
func (a *App) IsServerReady() bool {
	return a.localServer.IsReady()
}

// GetServerLogs returns recent log output from the local server
func (a *App) GetServerLogs() []string {
	return a.localServer.GetLogs()
}

// GetServerError returns the last server error if the process crashed
func (a *App) GetServerError() string {
	status := a.localServer.GetStatus()
	return status.Error
}

// StopLocalServer stops the local LLM server
func (a *App) StopLocalServer() {
	a.localServer.Stop()
	if a.config.GetLLM().ActiveProvider == "local" {
		a.currentProvider = nil
		a.processor.SetProvider(nil)
	}
}

// IsBinaryInstalled checks if llama-server is available
func (a *App) IsBinaryInstalled() bool {
	return a.localServer.IsBinaryInstalled()
}

// InstallBinary downloads and installs the llama-server binary
func (a *App) InstallBinary() error {
	return a.localServer.InstallBinary(a.ctx)
}

// --- Shortcuts Methods ---

// OpenApplication opens or focuses an application
func (a *App) OpenApplication(appPath string, bundleID string) error {
	return a.shortcutManager.OpenApp(appPath, bundleID)
}

// ListInstalledApps returns installed applications
func (a *App) ListInstalledApps() ([]shortcuts.AppInfo, error) {
	return a.shortcutManager.ListInstalledApps()
}

// ExecuteShortcut runs a configured shortcut by ID
func (a *App) ExecuteShortcut(shortcutID string) error {
	cfgShortcuts := a.config.GetShortcuts()
	for _, s := range cfgShortcuts {
		if s.ID == shortcutID {
			return a.shortcutManager.OpenApp(s.AppPath, s.BundleID)
		}
	}
	return fmt.Errorf("shortcut %s not found", shortcutID)
}

// --- Configuration Methods ---

// GetConfig returns the full configuration
func (a *App) GetConfig() *config.Config {
	return a.config
}

// GetLLMConfig returns the LLM configuration
func (a *App) GetLLMConfig() config.LLMConfig {
	return a.config.GetLLM()
}

// SaveLLMConfig updates the LLM configuration
func (a *App) SaveLLMConfig(llmCfg config.LLMConfig) error {
	if err := a.config.UpdateLLM(llmCfg); err != nil {
		return err
	}
	a.initLLMProvider()
	return nil
}

// GetShortcuts returns all configured shortcuts
func (a *App) GetShortcuts() []config.ShortcutConfig {
	return a.config.GetShortcuts()
}

// SaveShortcuts updates the shortcuts configuration and re-registers global hotkeys
func (a *App) SaveShortcuts(s []config.ShortcutConfig) error {
	if err := a.config.UpdateShortcuts(s); err != nil {
		return err
	}
	a.registerGlobalHotkeys()
	return nil
}

// GetTextProcessingConfig returns text processing config
func (a *App) GetTextProcessingConfig() config.TextProcessingConfig {
	return a.config.TextProcessing
}

// SaveTextProcessingConfig updates text processing config
func (a *App) SaveTextProcessingConfig(tp config.TextProcessingConfig) error {
	return a.config.UpdateTextProcessing(tp)
}

// GetActiveProviderName returns the name of the active LLM provider
func (a *App) GetActiveProviderName() string {
	if a.currentProvider == nil {
		return "None"
	}
	return a.currentProvider.Name()
}

// --- Popup Action Methods ---

// ReplaceSelectedText replaces the currently selected text with the provided text
// by copying the text to clipboard and simulating Cmd+V paste
func (a *App) ReplaceSelectedText(text string) error {
	if err := keysim.PasteText(text); err != nil {
		return fmt.Errorf("failed to replace selected text: %w", err)
	}
	return nil
}

// PasteBelowCursor moves cursor to end of line, inserts a newline, and pastes the text
func (a *App) PasteBelowCursor(text string) error {
	// Move to end of line (Cmd+Right)
	if err := keysim.SimulateKeys("cmd+right"); err != nil {
		return fmt.Errorf("failed to move to end of line: %w", err)
	}

	// Press Return to create new line
	if err := keysim.SimulateKeys("return"); err != nil {
		return fmt.Errorf("failed to insert newline: %w", err)
	}

	// Paste the text
	if err := keysim.PasteText(text); err != nil {
		return fmt.Errorf("failed to paste text below cursor: %w", err)
	}

	return nil
}

// CopyToClipboard copies the provided text to the system clipboard
func (a *App) CopyToClipboard(text string) error {
	if err := clipboard.Write(text); err != nil {
		return fmt.Errorf("failed to copy text to clipboard: %w", err)
	}
	return nil
}
