//go:build !windows

package engine

import "os/exec"

func configureCommand(*exec.Cmd) {}
