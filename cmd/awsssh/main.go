package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"
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
	var region, profile, instance string

	cmd := &cobra.Command{
		Use:   "awsssh",
		Short: "Open a shell on an EC2 instance over AWS SSM",
		Example: `  awsssh
  awsssh --instance db-01
  awsssh --profile prod --region eu-central-1`,
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return run(cmd.Context(), region, profile, instance)
		},
	}

	f := cmd.Flags()
	f.StringVar(&region, "region", "", "AWS region for queries and sessions")
	f.StringVar(&profile, "profile", "", "AWS CLI/SSO profile to use")
	f.StringVar(&instance, "instance", "", "connect to the first instance matching this Name tag or instance ID")
	f.BoolVarP(&debug, "debug", "d", false, "enable debug output")

	_ = cmd.RegisterFlagCompletionFunc("profile", completeProfile)
	_ = cmd.RegisterFlagCompletionFunc("region", completeRegion)
	_ = cmd.RegisterFlagCompletionFunc("instance", completeInstance)

	return cmd
}
