package forward

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func isolateAWS(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("AWS_CONFIG_FILE", filepath.Join(dir, "config"))
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(dir, "credentials"))
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_DEFAULT_PROFILE", "")
	t.Setenv("AWS_REGION", "")
	t.Setenv("AWS_DEFAULT_REGION", "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
}

func TestFirstLine(t *testing.T) {
	cases := map[string]string{
		"single":               "single",
		"first\nsecond":        "first",
		"first\nsecond\nthird": "first",
		"":                     "",
		"\ntrailing":           "",
		"no newline at all":    "no newline at all",
	}
	for in, want := range cases {
		if got := firstLine(in); got != want {
			t.Errorf("firstLine(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProviderRejectsAMissingProfile(t *testing.T) {
	isolateAWS(t)

	provider := NewProvider(t.Context())
	_, err := provider.Get("ghost-profile", "eu-west-1")
	if err == nil {
		t.Fatal("expected an error for a nonexistent profile")
	}
	if !strings.Contains(err.Error(), "does not exist") {
		t.Errorf("want the diagnosed message, got: %v", err)
	}
}

func TestProviderReportsAMissingRegion(t *testing.T) {
	isolateAWS(t)
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config")
	writeFile(t, configPath, "[profile noregion]\n")
	t.Setenv("AWS_CONFIG_FILE", configPath)

	provider := NewProvider(t.Context())
	_, err := provider.Get("noregion", "")
	if err == nil {
		t.Fatal("expected an error when no region resolves")
	}
	if !strings.Contains(err.Error(), "no region") {
		t.Errorf("want a region complaint, got: %v", err)
	}
}

func TestProviderDoesNotCacheFailures(t *testing.T) {
	isolateAWS(t)

	provider := NewProvider(t.Context())
	if _, err := provider.Get("ghost", "eu-west-1"); err == nil {
		t.Fatal("expected the first call to fail")
	}
	if len(provider.cache) != 0 {
		t.Errorf("a failed lookup must not be cached, cache has %d entries", len(provider.cache))
	}
	if _, err := provider.Get("ghost", "eu-west-1"); err == nil {
		t.Error("expected the second call to fail too")
	}
}

func TestManagerEmitsAnExitedEventWhenTheProfileIsBad(t *testing.T) {
	isolateAWS(t)

	mgr := NewManager(t.Context(), NewProvider(t.Context()))
	mgr.Start(7, Spec{Profile: "ghost-profile", Region: "eu-west-1", Instance: "db", LocalPort: "1", RemotePort: "2"})

	ev := awaitEvent(t, mgr)
	if ev.ID != 7 {
		t.Errorf("event id = %d, want 7", ev.ID)
	}
	if ev.Kind != Exited {
		t.Errorf("event kind = %q, want %q", ev.Kind, Exited)
	}
	if !strings.Contains(ev.Err, "does not exist") {
		t.Errorf("event should carry the diagnosed error, got: %q", ev.Err)
	}
}

func TestManagerIgnoresASecondStartForTheSameID(t *testing.T) {
	isolateAWS(t)

	mgr := NewManager(t.Context(), NewProvider(t.Context()))
	spec := Spec{Profile: "ghost", Region: "eu-west-1", Instance: "db", LocalPort: "1", RemotePort: "2"}

	mgr.Start(1, spec)
	first := awaitEvent(t, mgr)
	if first.Kind != Exited {
		t.Fatalf("expected the first attempt to fail, got %+v", first)
	}

	mgr.Start(1, spec)
	second := awaitEvent(t, mgr)
	if second.ID != 1 {
		t.Errorf("expected another event for id 1, got %+v", second)
	}
}

func TestManagerStopOfAnUnknownIDIsHarmless(t *testing.T) {
	mgr := NewManager(t.Context(), NewProvider(t.Context()))
	mgr.Stop(999)
	mgr.Stop(0)
}

func TestManagerStopAllWithNothingRunning(t *testing.T) {
	mgr := NewManager(t.Context(), NewProvider(t.Context()))
	mgr.StopAll()
}

func TestManagerReleasesTheIDAfterFailure(t *testing.T) {
	isolateAWS(t)

	mgr := NewManager(t.Context(), NewProvider(t.Context()))
	mgr.Start(3, Spec{Profile: "ghost", Region: "eu-west-1", Instance: "db", LocalPort: "1", RemotePort: "2"})
	awaitEvent(t, mgr)

	mgr.mu.Lock()
	_, stillTracked := mgr.cancels[3]
	mgr.mu.Unlock()
	if stillTracked {
		t.Error("a finished forward must not stay in the cancel map")
	}
}

func TestEventKindsAreDistinct(t *testing.T) {
	if Started == Exited {
		t.Fatal("Started and Exited must differ")
	}
	if string(Started) != "started" || string(Exited) != "exited" {
		t.Errorf("event kinds are part of the helper protocol: %q %q", Started, Exited)
	}
}

func awaitEvent(t *testing.T, mgr *Manager) Event {
	t.Helper()
	select {
	case ev := <-mgr.Events():
		return ev
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for an event")
		return Event{}
	}
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}
