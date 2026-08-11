package forward

import (
	"errors"
	"fmt"
	"net"
	"os"
	"syscall"
)

func localPortError(port string, err error) error {
	switch {
	case errors.Is(err, syscall.EACCES) || errors.Is(err, os.ErrPermission):
		return fmt.Errorf("local port %s is reserved and needs root; pick one above 1023", port)
	case errors.Is(err, syscall.EADDRINUSE):
		return fmt.Errorf("local port %s is already in use by something else on this machine", port)
	default:
		return fmt.Errorf("local port %s cannot be opened: %w", port, err)
	}
}

func checkLocalPort(port string) error {
	if port == "" {
		return nil
	}
	l, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		return localPortError(port, err)
	}
	_ = l.Close()
	return nil
}
