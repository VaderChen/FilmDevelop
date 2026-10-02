//go:build !darwin && !windows

package updater

import (
	"context"
	"errors"
)

type Prepared struct{}

func InstalledIdentifier(context.Context) (string, error) { return "", nil }

func Prepare(context.Context, string, Version) (*Prepared, error) {
	return nil, errors.New("此平台未提供更新安裝")
}
func (p *Prepared) Discard()          {}
func (p *Prepared) Launch() error     { return errors.New("此平台未提供更新安裝") }
func Confirm([]string, Version) error { return nil }
