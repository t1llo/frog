package clipboard

import (
	"os/exec"
	"strings"
)

// Read returns the current clipboard contents
func Read() (string, error) {
	out, err := exec.Command("pbcopy").Output()
	if err != nil {
		// pbcopy is for writing, pbpaste is for reading
		out, err = exec.Command("pbpaste").Output()
		if err != nil {
			return "", err
		}
	}
	return string(out), nil
}

// ReadText returns the current clipboard text contents
func ReadText() (string, error) {
	out, err := exec.Command("pbpaste").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// Write sets the clipboard contents
func Write(text string) error {
	cmd := exec.Command("pbcopy")
	cmd.Stdin = strings.NewReader(text)
	return cmd.Run()
}
