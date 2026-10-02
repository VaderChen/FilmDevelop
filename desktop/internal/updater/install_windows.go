package updater

import (
	"context"
	"os/exec"
)

type Prepared struct{ Path string }

func InstalledIdentifier(context.Context) (string, error) { return "", nil }

func Prepare(ctx context.Context, path string, version Version) (*Prepared, error) {
	return &Prepared{Path: path}, ctx.Err()
}
func (p *Prepared) Discard() {}
func (p *Prepared) Launch() error {
	cmd := exec.Command(p.Path)
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
func Confirm(_ []string, _ Version) error { return nil }
