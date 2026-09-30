package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/sratabix/awsssh/internal/session"
)

var debug bool

func debugf(format string, args ...any) {
	if debug {
		fmt.Fprintf(os.Stderr, "awsssh debug: "+format+"\n", args...)
	}
}

func main() {
	os.Exit(execute())
}

func execute() int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := rootCmd().ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "awsssh: "+err.Error())
		return 1
	}
	return 0
}

func rootCmd() *cobra.Command {
	var region, profile, instance, forwardSpec string

	cmd := &cobra.Command{
		Use:   "awsssh",
		Short: "Open a shell or forward a port to an EC2 instance over AWS SSM",
		Example: `  awsssh
  awsssh --instance db-01
  awsssh --profile prod --region eu-central-1
  awsssh -L 8080:80
  awsssh -L 5432:db.internal:5432 --instance bastion`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var fwd *session.Forward
			if cmd.Flags().Changed("forward") {
				parsed, err := parseForward(forwardSpec)
				if err != nil {
					return err
				}
				fwd = &parsed
			}
			return run(cmd.Context(), region, profile, instance, fwd)
		},
	}

	f := cmd.Flags()
	f.StringVar(&region, "region", "", "AWS region for queries and sessions")
	f.StringVar(&profile, "profile", "", "AWS CLI/SSO profile to use")
	f.StringVar(&instance, "instance", "", "connect to the first instance matching this Name tag or instance ID")
	f.StringVarP(&forwardSpec, "forward", "L", "", "forward a local port instead of opening a shell: LOCAL:REMOTE or LOCAL:HOST:REMOTE")
	f.BoolVarP(&debug, "debug", "d", false, "enable debug output")

	_ = cmd.RegisterFlagCompletionFunc("profile", completeProfile)
	_ = cmd.RegisterFlagCompletionFunc("region", completeRegion)
	_ = cmd.RegisterFlagCompletionFunc("instance", completeInstance)
	_ = cmd.RegisterFlagCompletionFunc("forward", cobra.NoFileCompletions)

	return cmd
}

func parseForward(spec string) (session.Forward, error) {
	parts := strings.Split(spec, ":")
	var local, host, remote string
	switch len(parts) {
	case 2:
		local, remote = parts[0], parts[1]
	case 3:
		local, host, remote = parts[0], strings.TrimSpace(parts[1]), parts[2]
		if host == "" {
			return session.Forward{}, fmt.Errorf("invalid --forward %q: the host is empty", spec)
		}
	default:
		return session.Forward{}, fmt.Errorf("invalid --forward %q: want LOCAL:REMOTE or LOCAL:HOST:REMOTE", spec)
	}
	localPort, err := parsePort(local)
	if err != nil {
		return session.Forward{}, fmt.Errorf("invalid --forward %q: local %w", spec, err)
	}
	remotePort, err := parsePort(remote)
	if err != nil {
		return session.Forward{}, fmt.Errorf("invalid --forward %q: remote %w", spec, err)
	}
	return session.Forward{LocalPort: localPort, Host: host, RemotePort: remotePort}, nil
}

func parsePort(s string) (string, error) {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || n < 1 || n > 65535 {
		return "", fmt.Errorf("port %q is not a number from 1 to 65535", s)
	}
	return strconv.Itoa(n), nil
}
