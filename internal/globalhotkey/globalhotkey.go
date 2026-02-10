package globalhotkey

import (
	"context"
	"log"
	"strings"

	"golang.design/x/hotkey"
)

// Binding maps a hotkey combo to a callback
type Binding struct {
	ID     string
	Hotkey string
	Action func()
}

// Manager registers and manages global system-wide hotkeys
type Manager struct {
	registered []*hotkey.Hotkey
	cancel     context.CancelFunc
}

// NewManager creates a new global hotkey manager
func NewManager() *Manager {
	return &Manager{}
}

// Register registers all provided bindings as global hotkeys.
// Must be called AFTER the Wails NSApplication event loop has started (from OnStartup).
func (m *Manager) Register(ctx context.Context, bindings []Binding) {
	m.Unregister() // clean up any previous

	ctx, cancel := context.WithCancel(ctx)
	m.cancel = cancel

	for _, b := range bindings {
		mods, key, ok := parseHotkey(b.Hotkey)
		if !ok {
			log.Printf("globalhotkey: could not parse hotkey %q for %s", b.Hotkey, b.ID)
			continue
		}

		hk := hotkey.New(mods, key)
		if err := hk.Register(); err != nil {
			log.Printf("globalhotkey: failed to register %s (%s): %v", b.ID, b.Hotkey, err)
			continue
		}

		m.registered = append(m.registered, hk)

		action := b.Action // capture for goroutine
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-hk.Keydown():
					action()
				}
			}
		}()

		log.Printf("globalhotkey: registered %s -> %s", b.ID, b.Hotkey)
	}
}

// Unregister unregisters all global hotkeys
func (m *Manager) Unregister() {
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	for _, hk := range m.registered {
		if err := hk.Unregister(); err != nil {
			log.Printf("globalhotkey: unregister error: %v", err)
		}
	}
	m.registered = nil
}

// parseHotkey parses a string like "Ctrl+Shift+C" into hotkey modifiers and key
func parseHotkey(s string) ([]hotkey.Modifier, hotkey.Key, bool) {
	parts := strings.Split(s, "+")
	if len(parts) == 0 {
		return nil, 0, false
	}

	var mods []hotkey.Modifier
	var keyStr string

	for _, p := range parts {
		p = strings.TrimSpace(p)
		switch strings.ToLower(p) {
		case "ctrl", "control":
			mods = append(mods, hotkey.ModCtrl)
		case "shift":
			mods = append(mods, hotkey.ModShift)
		case "alt", "option", "opt":
			mods = append(mods, hotkey.ModOption)
		case "cmd", "command", "meta", "super":
			mods = append(mods, hotkey.ModCmd)
		default:
			keyStr = p
		}
	}

	key, ok := keyMap[strings.ToUpper(keyStr)]
	if !ok {
		return nil, 0, false
	}

	return mods, key, true
}

// keyMap maps key names to hotkey.Key values
var keyMap = map[string]hotkey.Key{
	"A": hotkey.KeyA, "B": hotkey.KeyB, "C": hotkey.KeyC, "D": hotkey.KeyD,
	"E": hotkey.KeyE, "F": hotkey.KeyF, "G": hotkey.KeyG, "H": hotkey.KeyH,
	"I": hotkey.KeyI, "J": hotkey.KeyJ, "K": hotkey.KeyK, "L": hotkey.KeyL,
	"M": hotkey.KeyM, "N": hotkey.KeyN, "O": hotkey.KeyO, "P": hotkey.KeyP,
	"Q": hotkey.KeyQ, "R": hotkey.KeyR, "S": hotkey.KeyS, "T": hotkey.KeyT,
	"U": hotkey.KeyU, "V": hotkey.KeyV, "W": hotkey.KeyW, "X": hotkey.KeyX,
	"Y": hotkey.KeyY, "Z": hotkey.KeyZ,
	"0": hotkey.Key0, "1": hotkey.Key1, "2": hotkey.Key2, "3": hotkey.Key3,
	"4": hotkey.Key4, "5": hotkey.Key5, "6": hotkey.Key6, "7": hotkey.Key7,
	"8": hotkey.Key8, "9": hotkey.Key9,
	"SPACE": hotkey.KeySpace, "RETURN": hotkey.KeyReturn, "ENTER": hotkey.KeyReturn,
	"ESCAPE": hotkey.KeyEscape, "ESC": hotkey.KeyEscape,
	"DELETE": hotkey.KeyDelete, "BACKSPACE": hotkey.KeyDelete,
	"TAB": hotkey.KeyTab,
	"F1":  hotkey.KeyF1, "F2": hotkey.KeyF2, "F3": hotkey.KeyF3, "F4": hotkey.KeyF4,
	"F5": hotkey.KeyF5, "F6": hotkey.KeyF6, "F7": hotkey.KeyF7, "F8": hotkey.KeyF8,
	"F9": hotkey.KeyF9, "F10": hotkey.KeyF10, "F11": hotkey.KeyF11, "F12": hotkey.KeyF12,
	"UP": hotkey.KeyUp, "DOWN": hotkey.KeyDown, "LEFT": hotkey.KeyLeft, "RIGHT": hotkey.KeyRight,
}
