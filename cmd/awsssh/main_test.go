package main

import (
	"bytes"
	"os"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

func execHelp(t *testing.T, args ...string) (string, error) {
	t.Helper()
	cmd := rootCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs(args)
	err := cmd.Execute()
	return out.String(), err
}

func TestRootCommandExposesTheDocumentedFlags(t *testing.T) {
	cmd := rootCmd()
	for _, name := range []string{"region", "profile", "instance", "debug"} {
		if cmd.Flags().Lookup(name) == nil {
			t.Errorf("missing --%s flag", name)
		}
	}
	if cmd.Flags().ShorthandLookup("d") == nil {
		t.Error("--debug should have a -d shorthand")
	}
}

func TestRootCommandFlagsDefaultToEmpty(t *testing.T) {
	cmd := rootCmd()
	for _, name := range []string{"region", "profile", "instance"} {
		if got := cmd.Flags().Lookup(name).DefValue; got != "" {
			t.Errorf("--%s defaults to %q, want empty", name, got)
		}
	}
	if got := cmd.Flags().Lookup("debug").DefValue; got != "false" {
		t.Errorf("--debug defaults to %q, want false", got)
	}
}

func TestRootCommandTakesNoPositionalArguments(t *testing.T) {
	cmd := rootCmd()
	if err := cmd.Args(cmd, []string{"unexpected"}); err == nil {
		t.Error("positional arguments should be rejected")
	}
	if err := cmd.Args(cmd, nil); err != nil {
		t.Errorf("no arguments should be accepted, got %v", err)
	}
}

func TestRootCommandSilencesCobrasOwnErrorReporting(t *testing.T) {
	cmd := rootCmd()
	if !cmd.SilenceErrors {
		t.Error("SilenceErrors should be set; main prints the error itself")
	}
	if !cmd.SilenceUsage {
		t.Error("SilenceUsage should be set; a runtime failure is not a usage problem")
	}
}

func TestHelpMentionsEveryFlagAndStaysShort(t *testing.T) {
	out, err := execHelp(t, "--help")
	if err != nil {
		t.Fatalf("--help returned %v", err)
	}
	for _, want := range []string{"--region", "--profile", "--instance", "--debug"} {
		if !strings.Contains(out, want) {
			t.Errorf("help does not mention %s", want)
		}
	}
	if lines := strings.Count(out, "\n"); lines > 25 {
		t.Errorf("help is %d lines; it is meant to stay brief", lines)
	}
}

func TestHelpDoesNotCarryStaleGuidance(t *testing.T) {
	out, err := execHelp(t, "--help")
	if err != nil {
		t.Fatal(err)
	}
	for _, unwanted := range []string{"menubar app, not this CLI", "Port forwarding lives"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("help still contains stale text: %q", unwanted)
		}
	}
}

func TestUnknownFlagIsRejected(t *testing.T) {
	if _, err := execHelp(t, "--nope"); err == nil {
		t.Error("an unknown flag should be an error")
	}
}

func TestShortDescriptionIsASingleLine(t *testing.T) {
	short := rootCmd().Short
	if short == "" {
		t.Fatal("Short must be set")
	}
	if strings.Contains(short, "\n") {
		t.Errorf("Short should be one line, got %q", short)
	}
}

func TestLongDescriptionIsNotUsed(t *testing.T) {
	if rootCmd().Long != "" {
		t.Error("the CLI deliberately has no Long description; help stays short")
	}
}

func TestExamplesAreRunnableShapes(t *testing.T) {
	example := rootCmd().Example
	if !strings.Contains(example, "awsssh") {
		t.Fatalf("examples should show the binary name: %q", example)
	}
	for _, line := range strings.Split(strings.TrimSpace(example), "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" && !strings.HasPrefix(trimmed, "awsssh") {
			t.Errorf("example line should start with awsssh: %q", trimmed)
		}
	}
}

func TestCompletionSubcommandStillWorks(t *testing.T) {
	for _, shell := range []string{"bash", "zsh", "fish"} {
		t.Run(shell, func(t *testing.T) {
			cmd := rootCmd()
			var out bytes.Buffer
			cmd.SetOut(&out)
			cmd.SetErr(&out)
			cmd.SetArgs([]string{"completion", shell})
			if err := cmd.Execute(); err != nil {
				t.Fatalf("completion %s failed: %v", shell, err)
			}
			if out.Len() == 0 {
				t.Errorf("completion %s produced nothing", shell)
			}
		})
	}
}

func TestKnownRegionsAreSortedAndUnique(t *testing.T) {
	if !sort.StringsAreSorted(knownRegions) {
		t.Error("knownRegions should be sorted so completion output is stable")
	}
	seen := map[string]bool{}
	for _, r := range knownRegions {
		if seen[r] {
			t.Errorf("duplicate region %q", r)
		}
		seen[r] = true
	}
}

func TestKnownRegionsLookLikeRegions(t *testing.T) {
	for _, r := range knownRegions {
		parts := strings.Split(r, "-")
		if len(parts) < 3 {
			t.Errorf("%q does not look like an AWS region", r)
		}
		if r != strings.ToLower(r) {
			t.Errorf("%q should be lower case", r)
		}
	}
}

func TestKnownRegionsCoverTheCommonOnes(t *testing.T) {
	for _, r := range []string{"eu-central-1", "eu-west-1", "us-east-1", "us-west-2"} {
		if !slices.Contains(knownRegions, r) {
			t.Errorf("expected %q in knownRegions", r)
		}
	}
}

func TestCompleteRegionReturnsTheStaticList(t *testing.T) {
	got, directive := completeRegion(nil, nil, "")
	if !slices.Equal(got, knownRegions) {
		t.Error("completeRegion should return knownRegions verbatim")
	}
	if directive != cobra.ShellCompDirectiveNoFileComp {
		t.Errorf("directive = %v, want NoFileComp", directive)
	}
}

func TestCompleteProfileReadsTheAWSConfig(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir+"/config", "[profile alpha]\n[profile beta]\n")
	t.Setenv("AWS_CONFIG_FILE", dir+"/config")
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", dir+"/credentials")

	got, directive := completeProfile(nil, nil, "")
	if !slices.Equal(got, []string{"alpha", "beta"}) {
		t.Errorf("completeProfile() = %v, want [alpha beta]", got)
	}
	if directive != cobra.ShellCompDirectiveNoFileComp {
		t.Errorf("directive = %v, want NoFileComp", directive)
	}
}

func TestCompleteInstanceFailsQuietlyWithoutCredentials(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("AWS_CONFIG_FILE", dir+"/config")
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", dir+"/credentials")
	t.Setenv("AWS_REGION", "")
	t.Setenv("AWS_DEFAULT_REGION", "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")

	cmd := rootCmd()
	if err := cmd.Flags().Set("profile", "does-not-exist"); err != nil {
		t.Fatal(err)
	}

	got, directive := completeInstance(cmd, nil, "")
	if got != nil {
		t.Errorf("completion should stay silent on failure, got %v", got)
	}
	if directive != cobra.ShellCompDirectiveNoFileComp {
		t.Errorf("directive = %v, want NoFileComp", directive)
	}
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}
