//go:build !darwin && !windows

package engine

import "os"

func publish(source, target string) error { return os.Link(source, target) }
