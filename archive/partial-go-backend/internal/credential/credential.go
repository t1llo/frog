package credential

import (
	"errors"
	"github.com/zalando/go-keyring"
)

type Store interface {
	Get(string) (string, error)
	Set(string, string) error
	Delete(string) error
}
type Keyring struct{}

func (Keyring) Get(id string) (string, error) {
	v, e := keyring.Get("frog", id)
	if errors.Is(e, keyring.ErrNotFound) {
		return "", nil
	}
	return v, e
}
func (Keyring) Set(id, value string) error { return keyring.Set("frog", id, value) }
func (Keyring) Delete(id string) error {
	e := keyring.Delete("frog", id)
	if errors.Is(e, keyring.ErrNotFound) {
		return nil
	}
	return e
}
