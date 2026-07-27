package main

import (
	"context"
	"fmt"
	"os"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/session"
	"github.com/sratabix/awsssh/internal/tui"
)

func run(ctx context.Context, region, profile, instance string) error {
	if err := session.Available(); err != nil {
		return err
	}

	client, err := awsx.New(ctx, profile, region)
	if err != nil {
		return err
	}
	if client.Region == "" {
		return fmt.Errorf("no region for AWS profile %q; pass --region or set one in the profile", client.Profile.Name)
	}
	fmt.Fprintf(os.Stderr, "awsssh: profile %s (%s), region %s\n",
		client.Profile.Name, client.Profile.Source, client.Region)
	debugf("instance=%q", instance)

	if err := client.Verify(ctx); err != nil {
		return err
	}

	target, err := pickInstance(ctx, client, instance)
	if err != nil || target == nil {
		return err
	}

	starter := session.New(client.Config(), client.Region, profile)
	fmt.Fprintf(os.Stderr, "awsssh: connecting to %s (%s)\n", target.Key(), target.InstanceID)
	return starter.StartShell(ctx, target.InstanceID)
}

func pickInstance(ctx context.Context, client *awsx.Client, filter string) (*awsx.Instance, error) {
	if filter != "" {
		target, err := client.LookupRunning(ctx, filter)
		if err != nil {
			return nil, err
		}
		return &target, nil
	}

	instances, err := client.Lookup(ctx, "")
	if err != nil {
		return nil, err
	}
	chosen, err := tui.SelectInstance(instances)
	if err != nil || chosen == nil {
		return nil, err
	}
	if chosen.State != "running" {
		return nil, awsx.NotRunning(*chosen)
	}
	return chosen, nil
}
