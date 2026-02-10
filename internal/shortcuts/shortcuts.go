package shortcuts

import (
	"fmt"
	"os/exec"
	"strings"
)

// Manager handles application shortcuts
type Manager struct{}

// NewManager creates a new shortcuts manager
func NewManager() *Manager {
	return &Manager{}
}

// OpenApp opens an application by path or bundle ID
func (m *Manager) OpenApp(appPath string, bundleID string) error {
	if bundleID != "" {
		return m.openByBundleID(bundleID)
	}
	if appPath != "" {
		return m.openByPath(appPath)
	}
	return fmt.Errorf("no app path or bundle ID provided")
}

// openByBundleID opens/focuses an app by its bundle identifier
func (m *Manager) openByBundleID(bundleID string) error {
	// First try to activate an already running app
	script := fmt.Sprintf(`
		tell application "System Events"
			set appList to every process whose bundle identifier is "%s"
			if (count of appList) > 0 then
				set frontmost of item 1 of appList to true
				return "activated"
			end if
		end tell
		return "not_running"
	`, bundleID)

	out, err := exec.Command("osascript", "-e", script).Output()
	if err == nil && strings.TrimSpace(string(out)) == "activated" {
		return nil
	}

	// If not running, open it
	return exec.Command("open", "-b", bundleID).Run()
}

// openByPath opens/focuses an app by its path
func (m *Manager) openByPath(appPath string) error {
	// Try to bring to front if already running
	appName := extractAppName(appPath)
	if appName != "" {
		script := fmt.Sprintf(`
			tell application "System Events"
				set appList to every process whose name is "%s"
				if (count of appList) > 0 then
					set frontmost of item 1 of appList to true
					return "activated"
				end if
			end tell
			return "not_running"
		`, appName)

		out, err := exec.Command("osascript", "-e", script).Output()
		if err == nil && strings.TrimSpace(string(out)) == "activated" {
			return nil
		}
	}

	return exec.Command("open", "-a", appPath).Run()
}

// extractAppName extracts the app name from a path like "/Applications/Safari.app"
func extractAppName(appPath string) string {
	parts := strings.Split(appPath, "/")
	for _, part := range parts {
		if strings.HasSuffix(part, ".app") {
			return strings.TrimSuffix(part, ".app")
		}
	}
	return ""
}

// ListInstalledApps returns a list of installed applications
func (m *Manager) ListInstalledApps() ([]AppInfo, error) {
	script := `
		set appList to {}
		tell application "System Events"
			set installedApps to every application file of folder "/Applications" of startup disk
			repeat with anApp in installedApps
				set appName to displayed name of anApp
				set appPath to POSIX path of (anApp as alias)
				set bundleID to bundle identifier of anApp
				set end of appList to appName & "|" & appPath & "|" & bundleID
			end repeat
		end tell
		set AppleScript's text item delimiters to ";;;"
		return appList as text
	`

	out, err := exec.Command("osascript", "-e", script).Output()
	if err != nil {
		// Fallback: just list /Applications
		return m.listAppsFallback()
	}

	var apps []AppInfo
	entries := strings.Split(strings.TrimSpace(string(out)), ";;;")
	for _, entry := range entries {
		parts := strings.Split(entry, "|")
		if len(parts) >= 3 {
			apps = append(apps, AppInfo{
				Name:     strings.TrimSpace(parts[0]),
				Path:     strings.TrimSpace(parts[1]),
				BundleID: strings.TrimSpace(parts[2]),
			})
		}
	}

	return apps, nil
}

func (m *Manager) listAppsFallback() ([]AppInfo, error) {
	out, err := exec.Command("ls", "/Applications").Output()
	if err != nil {
		return nil, err
	}

	var apps []AppInfo
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasSuffix(line, ".app") {
			apps = append(apps, AppInfo{
				Name: strings.TrimSuffix(line, ".app"),
				Path: "/Applications/" + line,
			})
		}
	}
	return apps, nil
}

// AppInfo holds information about an installed application
type AppInfo struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	BundleID string `json:"bundleId"`
}
