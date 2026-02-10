package keysim

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// GrabSelectedText simulates Cmd+C to copy current selection, then reads clipboard
func GrabSelectedText() (string, error) {
	// First save current clipboard
	savedClipboard, err := readClipboard()
	if err != nil {
		savedClipboard = ""
	}

	// Simulate Cmd+C
	if err := SimulateKeys("cmd+c"); err != nil {
		return "", fmt.Errorf("failed to simulate Cmd+C: %w", err)
	}

	// Give system a moment to process
	// Small delay to ensure clipboard is updated
	_ = exec.Command("sleep", "0.1").Run()

	// Read clipboard
	text, err := readClipboard()
	if err != nil {
		return "", fmt.Errorf("failed to read clipboard: %w", err)
	}

	// Restore previous clipboard (best effort)
	_ = writeClipboard(savedClipboard)

	return text, nil
}

// PasteText writes text to clipboard, then simulates Cmd+V to paste
func PasteText(text string) error {
	if err := writeClipboard(text); err != nil {
		return fmt.Errorf("failed to write to clipboard: %w", err)
	}

	// Give system a moment to process
	_ = exec.Command("sleep", "0.05").Run()

	if err := SimulateKeys("cmd+v"); err != nil {
		return fmt.Errorf("failed to simulate Cmd+V: %w", err)
	}

	return nil
}

// SimulateKeys simulates pressing key combinations
// Supported keys: "cmd+c", "cmd+v", "cmd+a", "cmd+x", "cmd+z", "left", "right", "up", "down", "return", "delete", "esc", "tab"
func SimulateKeys(keys ...string) error {
	for _, key := range keys {
		if err := simulateKey(key); err != nil {
			return fmt.Errorf("failed to simulate key '%s': %w", key, err)
		}
		// Small delay between keystrokes
		if len(keys) > 1 {
			_ = exec.Command("sleep", "0.05").Run()
		}
	}
	return nil
}

func simulateKey(key string) error {
	key = strings.ToLower(strings.TrimSpace(key))

	// Parse modifier+key combinations
	parts := strings.Split(key, "+")

	if len(parts) == 2 {
		// Handle modifier + key combinations
		modifier := parts[0]
		char := parts[1]

		var modifierScript string
		switch modifier {
		case "cmd", "command":
			modifierScript = "command down"
		case "ctrl", "control":
			modifierScript = "control down"
		case "opt", "option", "alt":
			modifierScript = "option down"
		case "shift":
			modifierScript = "shift down"
		default:
			return fmt.Errorf("unsupported modifier: %s", modifier)
		}

		script := fmt.Sprintf(`tell application "System Events" to keystroke "%s" using {%s}`, escapeAppleScriptString(char), modifierScript)
		return runAppleScript(script)
	}

	// Handle single keys
	switch key {
	case "left":
		return runAppleScript(`tell application "System Events" to key code 123`)
	case "right":
		return runAppleScript(`tell application "System Events" to key code 124`)
	case "down":
		return runAppleScript(`tell application "System Events" to key code 125`)
	case "up":
		return runAppleScript(`tell application "System Events" to key code 126`)
	case "return", "enter":
		return runAppleScript(`tell application "System Events" to key code 36`)
	case "delete", "backspace":
		return runAppleScript(`tell application "System Events" to key code 51`)
	case "forwarddelete", "del":
		return runAppleScript(`tell application "System Events" to key code 117`)
	case "esc", "escape":
		return runAppleScript(`tell application "System Events" to key code 53`)
	case "tab":
		return runAppleScript(`tell application "System Events" to key code 48`)
	case "space":
		return runAppleScript(`tell application "System Events" to keystroke " "`)
	case "home":
		return runAppleScript(`tell application "System Events" to key code 115`)
	case "end":
		return runAppleScript(`tell application "System Events" to key code 119`)
	case "pageup":
		return runAppleScript(`tell application "System Events" to key code 116`)
	case "pagedown":
		return runAppleScript(`tell application "System Events" to key code 121`)
	default:
		// Single character key
		if len(key) == 1 {
			script := fmt.Sprintf(`tell application "System Events" to keystroke "%s"`, escapeAppleScriptString(key))
			return runAppleScript(script)
		}
		return fmt.Errorf("unsupported key: %s", key)
	}
}

// GetCursorPosition gets current mouse position via AppleScript
// Returns 0, 0, nil if unable to get position
func GetCursorPosition() (x, y int, err error) {
	script := `tell application "System Events" to get {first item of (get mouse location), second item of (get mouse location)}`

	out, err := exec.Command("osascript", "-e", script).Output()
	if err != nil {
		// If System Events fails, try using Finder as fallback
		script = `tell application "Finder" to get {first item of (get mouse location), second item of (get mouse location)}`
		out, err = exec.Command("osascript", "-e", script).Output()
		if err != nil {
			return 0, 0, nil // Return 0,0,nil as requested for optional function
		}
	}

	// Parse output like "123, 456"
	result := strings.TrimSpace(string(out))
	result = strings.Trim(result, "{}")
	parts := strings.Split(result, ",")
	if len(parts) != 2 {
		return 0, 0, nil
	}

	x, err = strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil {
		return 0, 0, nil
	}

	y, err = strconv.Atoi(strings.TrimSpace(parts[1]))
	if err != nil {
		return 0, 0, nil
	}

	return x, y, nil
}

// runAppleScript executes an AppleScript command
func runAppleScript(script string) error {
	cmd := exec.Command("osascript", "-e", script)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("applescript error: %w (output: %s)", err, string(output))
	}
	return nil
}

// escapeAppleScriptString properly escapes strings for AppleScript
func escapeAppleScriptString(s string) string {
	// Replace backslashes first, then quotes
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}

// readClipboard reads from system clipboard using pbpaste
func readClipboard() (string, error) {
	out, err := exec.Command("pbpaste").Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// writeClipboard writes to system clipboard using pbcopy
func writeClipboard(text string) error {
	cmd := exec.Command("pbcopy")
	cmd.Stdin = strings.NewReader(text)
	return cmd.Run()
}
