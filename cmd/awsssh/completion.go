package main

import (
	"context"

	"github.com/spf13/cobra"
	"github.com/sratabix/awsssh/internal/awsx"
)

func completeProfile(_ *cobra.Command, _ []string, _ string) ([]string, cobra.ShellCompDirective) {
	return awsx.Profiles(), cobra.ShellCompDirectiveNoFileComp
}

func completeRegion(_ *cobra.Command, _ []string, _ string) ([]string, cobra.ShellCompDirective) {
	return knownRegions, cobra.ShellCompDirectiveNoFileComp
}

func completeInstance(cmd *cobra.Command, _ []string, _ string) ([]string, cobra.ShellCompDirective) {
	profile, _ := cmd.Flags().GetString("profile")
	region, _ := cmd.Flags().GetString("region")

	ctx := context.Background()
	client, err := awsx.New(ctx, profile, region)
	if err != nil || client.Region == "" {
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
	instances, err := client.DescribeInstances(ctx, "")
	if err != nil {
		return nil, cobra.ShellCompDirectiveNoFileComp
	}

	seen := map[string]bool{}
	var out []string
	for _, inst := range instances {
		for _, cand := range []string{inst.Name, inst.InstanceID} {
			if cand != "" && !seen[cand] {
				seen[cand] = true
				out = append(out, cand)
			}
		}
	}
	return out, cobra.ShellCompDirectiveNoFileComp
}

var knownRegions = []string{
	"af-south-1",
	"ap-east-1",
	"ap-northeast-1",
	"ap-northeast-2",
	"ap-northeast-3",
	"ap-south-1",
	"ap-south-2",
	"ap-southeast-1",
	"ap-southeast-2",
	"ap-southeast-3",
	"ap-southeast-4",
	"ca-central-1",
	"ca-west-1",
	"eu-central-1",
	"eu-central-2",
	"eu-north-1",
	"eu-south-1",
	"eu-south-2",
	"eu-west-1",
	"eu-west-2",
	"eu-west-3",
	"il-central-1",
	"me-central-1",
	"me-south-1",
	"sa-east-1",
	"us-east-1",
	"us-east-2",
	"us-west-1",
	"us-west-2",
}
