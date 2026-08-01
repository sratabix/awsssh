package forward

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
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

func TestExitEventDropsACancellation(t *testing.T) {
	wrapped := fmt.Errorf("operation error SSM: StartSession: %w", context.Canceled)

	ev := exitEvent(4, wrapped)
	if ev.Kind != Exited || ev.ID != 4 {
		t.Fatalf("got %+v", ev)
	}
	if ev.Err != "" {
		t.Errorf("a stop the user asked for must not surface as an error, got: %q", ev.Err)
	}
}

func TestExitEventKeepsARealError(t *testing.T) {
	ev := exitEvent(5, errors.New("AWS profile \"ghost\" does not exist"))
	if !strings.Contains(ev.Err, "does not exist") {
		t.Errorf("event err = %q, want the real failure", ev.Err)
	}

	if got := exitEvent(6, nil); got.Err != "" {
		t.Errorf("a clean exit carries no error, got %q", got.Err)
	}
}

func TestLastLine(t *testing.T) {
	cases := map[string]string{
		"single":              "single",
		"first\nlast":         "last",
		"first\nsecond\nlast": "last",
		"":                    "",
		"trailing\n":          "",
		"Port 3308 opened.\nYour session has been terminated.": "Your session has been terminated.",
	}
	for in, want := range cases {
		if got := lastLine(in); got != want {
			t.Errorf("lastLine(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEndedReasonAlwaysExplainsItself(t *testing.T) {
	cases := []struct {
		name   string
		werr   error
		stderr string
		stdout string
		want   string
	}{
		{
			name:   "stderr wins",
			werr:   errors.New("exit status 1"),
			stderr: "ERROR: cannot perform start session\nusage: ...",
			stdout: "Starting session",
			want:   "ERROR: cannot perform start session",
		},
		{
			name:   "a clean exit is still unexplained without output",
			want:   "the session ended on its own, with no message from session-manager-plugin",
			stdout: "",
		},
		{
			name:   "a clean exit reports what the plugin last said",
			stdout: "Port 3308 opened.\nYour session has been terminated.",
			want: "the session ended on its own; last message from session-manager-plugin: " +
				"Your session has been terminated.",
		},
		{
			name:   "a dirty exit pairs the last line with the status",
			werr:   errors.New("exit status 254"),
			stdout: "Waiting for connections...\nCannot perform start session",
			want:   "Cannot perform start session (exit status 254)",
		},
		{
			name: "a dirty exit with nothing to say still names the status",
			werr: errors.New("signal: killed"),
			want: "signal: killed",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := endedReason(c.werr, c.stderr, c.stdout)
			if got == nil {
				t.Fatal("a forward that ends on its own must always carry a reason")
			}
			if got.Error() != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestTailBufferKeepsTheEnd(t *testing.T) {
	b := newTailBuffer(8)
	b.Write([]byte("0123456789"))
	if got := b.String(); got != "23456789" {
		t.Errorf("got %q, want the last 8 bytes", got)
	}

	b.Write([]byte("abc"))
	if got := b.String(); got != "56789abc" {
		t.Errorf("got %q, want the window to slide", got)
	}
}

func TestTailBufferReportsAFullWrite(t *testing.T) {
	b := newTailBuffer(4)
	n, err := b.Write([]byte("much longer than four"))
	if err != nil {
		t.Fatal(err)
	}
	if n != len("much longer than four") {
		t.Errorf("n = %d; a short write would make exec treat this as an error", n)
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

func TestTailBufferOnAFreshBufferIsEmpty(t *testing.T) {
	if got := newTailBuffer(16).String(); got != "" {
		t.Errorf("a fresh buffer must be empty, got %q", got)
	}
}

func TestTailBufferAtExactlyItsCapacity(t *testing.T) {
	b := newTailBuffer(4)
	b.Write([]byte("abcd"))
	if got := b.String(); got != "abcd" {
		t.Errorf("got %q, want the whole write when it exactly fills the window", got)
	}
	b.Write([]byte("e"))
	if got := b.String(); got != "bcde" {
		t.Errorf("got %q, want the window to slide by one", got)
	}
}

func TestTailBufferKeepsOnlyTheTailOfAnOversizedSingleWrite(t *testing.T) {
	b := newTailBuffer(5)
	b.Write([]byte("the message that explains the end comes at the end"))
	got := b.String()
	if len(got) != 5 {
		t.Fatalf("got %d bytes, want the window size", len(got))
	}
	if got != "e end" {
		t.Errorf("got %q, want the last 5 bytes", got)
	}
}

func TestTailBufferAcceptsAnEmptyWrite(t *testing.T) {
	b := newTailBuffer(4)
	b.Write([]byte("ab"))
	n, err := b.Write(nil)
	if err != nil || n != 0 {
		t.Fatalf("Write(nil) = (%d, %v), want (0, nil)", n, err)
	}
	if got := b.String(); got != "ab" {
		t.Errorf("an empty write must not disturb the contents, got %q", got)
	}
}

func TestTailBufferWithAZeroWindowKeepsNothing(t *testing.T) {
	b := newTailBuffer(0)
	n, err := b.Write([]byte("dropped"))
	if err != nil || n != len("dropped") {
		t.Fatalf("Write = (%d, %v), want a full write", n, err)
	}
	if got := b.String(); got != "" {
		t.Errorf("a zero window must keep nothing, got %q", got)
	}
}

func TestTailBufferSurvivesConcurrentWritersAndReaders(t *testing.T) {
	b := newTailBuffer(64)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				b.Write([]byte(strings.Repeat(string(rune('a'+i)), 3)))
			}
		}(i)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for j := 0; j < 400; j++ {
			_ = b.String()
		}
	}()
	wg.Wait()

	if got := len(b.String()); got != 64 {
		t.Errorf("window holds %d bytes, want 64", got)
	}
}

func TestTailBufferNeverGrowsPastItsWindow(t *testing.T) {
	b := newTailBuffer(32)
	for i := 0; i < 500; i++ {
		b.Write([]byte("a forward that runs for hours cannot buffer without bound"))
	}
	if got := len(b.String()); got > 32 {
		t.Errorf("buffer grew to %d bytes, want at most 32", got)
	}
}

func TestLastLineEdges(t *testing.T) {
	cases := map[string]string{
		"only":                 "only",
		"first\nlast":          "last",
		"first\nmiddle\nlast":  "last",
		"trailing newline\n":   "",
		"\n":                   "",
		"":                     "",
		"padded\n   spaced   ": "spaced",
		"first\n\n":            "",
		"a\nb\nc\nd":           "d",
	}
	for in, want := range cases {
		if got := lastLine(in); got != want {
			t.Errorf("lastLine(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEndedReasonPrefersStderrsFirstLine(t *testing.T) {
	err := endedReason(nil, "cannot perform start session\nsecond line", "ignored stdout")
	if err == nil {
		t.Fatal("want a reason")
	}
	if err.Error() != "cannot perform start session" {
		t.Errorf("got %q, want only stderr's first line", err.Error())
	}
}

func TestEndedReasonFallsThroughWhitespaceOnlyStderr(t *testing.T) {
	err := endedReason(nil, "   \n\t\n  ", "Your session has been terminated.")
	if err == nil {
		t.Fatal("want a reason")
	}
	if !strings.Contains(err.Error(), "Your session has been terminated.") {
		t.Errorf("got %q, want it to fall through to stdout", err.Error())
	}
}

func TestEndedReasonUsesStdoutsLastLineNotItsFirst(t *testing.T) {
	err := endedReason(nil, "", "starting\nconnected\nYour session has been terminated.")
	if !strings.Contains(err.Error(), "Your session has been terminated.") {
		t.Errorf("got %q, want the last stdout line", err.Error())
	}
	if strings.Contains(err.Error(), "starting") {
		t.Errorf("got %q, must not carry earlier lines", err.Error())
	}
}

func TestEndedReasonCombinesExitStatusWithTheLastMessage(t *testing.T) {
	werr := errors.New("exit status 1")
	err := endedReason(werr, "", "Cannot perform start session")
	if !strings.Contains(err.Error(), "Cannot perform start session") {
		t.Errorf("got %q, want the plugin message", err.Error())
	}
	if !strings.Contains(err.Error(), "exit status 1") {
		t.Errorf("got %q, want the exit status too", err.Error())
	}
	if !errors.Is(err, werr) {
		t.Error("the wait error must stay unwrappable")
	}
}

func TestEndedReasonWithOnlyAnExitStatusReturnsItUnchanged(t *testing.T) {
	werr := errors.New("signal: interrupt")
	err := endedReason(werr, "", "")
	if !errors.Is(err, werr) {
		t.Errorf("got %v, want the wait error itself", err)
	}
}

func TestEndedReasonWordsACleanRemoteTeardownAsAMessageNotACause(t *testing.T) {
	err := endedReason(nil, "", "Your session has been terminated.")
	if !strings.Contains(err.Error(), "last message from session-manager-plugin") {
		t.Errorf("got %q; a clean exit 0 is the last thing printed, not proof of the cause", err.Error())
	}
}

func TestEndedReasonNeverReturnsNil(t *testing.T) {
	cases := []struct {
		werr           error
		stderr, stdout string
	}{
		{nil, "", ""},
		{nil, "  ", "  "},
		{nil, "boom", ""},
		{nil, "", "boom"},
		{errors.New("exit status 2"), "", ""},
		{errors.New("exit status 2"), "err", "out"},
	}
	for _, c := range cases {
		if err := endedReason(c.werr, c.stderr, c.stdout); err == nil {
			t.Errorf("endedReason(%v, %q, %q) returned nil", c.werr, c.stderr, c.stdout)
		}
	}
}

func TestExitEventDropsAWrappedCancellation(t *testing.T) {
	wrapped := fmt.Errorf("looking up the instance: %w", context.Canceled)
	if ev := exitEvent(7, wrapped); ev.Err != "" {
		t.Errorf("Err = %q; a cancellation must stay silent however deeply it is wrapped", ev.Err)
	}
}

func TestExitEventCarriesTheIDAndKind(t *testing.T) {
	ev := exitEvent(42, errors.New("boom"))
	if ev.ID != 42 || ev.Kind != Exited {
		t.Errorf("got id=%d kind=%q, want 42/exited", ev.ID, ev.Kind)
	}
}

func TestManagerCloseClosesTheEventChannel(t *testing.T) {
	m := NewManager(t.Context(), NewProvider(t.Context()))
	m.Close()

	select {
	case _, open := <-m.Events():
		if open {
			t.Error("the channel must be closed, not merely drained")
		}
	case <-time.After(time.Second):
		t.Error("reading from a closed channel must not block")
	}
}

func TestManagerCloseIsIdempotent(t *testing.T) {
	m := NewManager(t.Context(), NewProvider(t.Context()))
	m.Close()
	m.Close()
	m.Close()
}

func TestManagerCloseAfterAFailedStartStillCompletes(t *testing.T) {
	isolateAWS(t)
	m := NewManager(t.Context(), NewProvider(t.Context()))
	m.Start(1, Spec{Profile: "ghost", Region: "eu-west-1", Instance: "db", LocalPort: "5432"})

	drained := make(chan struct{})
	go func() {
		defer close(drained)
		for range m.Events() {
		}
	}()

	m.Close()
	select {
	case <-drained:
	case <-time.After(5 * time.Second):
		t.Fatal("Close must stop the worker and close the channel")
	}
}

func TestProviderCachesNothingAcrossDistinctKeys(t *testing.T) {
	isolateAWS(t)
	provider := NewProvider(t.Context())
	if _, err := provider.Get("ghost", "eu-west-1"); err == nil {
		t.Fatal("want an error")
	}
	if _, err := provider.Get("ghost", "us-east-1"); err == nil {
		t.Fatal("a different region must be looked up on its own, not served from cache")
	}
}

func TestProviderIsSafeForConcurrentGets(t *testing.T) {
	isolateAWS(t)
	provider := NewProvider(t.Context())
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _ = provider.Get(fmt.Sprintf("ghost-%d", i%4), "eu-west-1")
		}(i)
	}
	wg.Wait()
}

func TestSpecZeroValueIsUsable(t *testing.T) {
	var s Spec
	if s.Profile != "" || s.LocalPort != "" || s.Host != "" {
		t.Error("the zero Spec must be all empty strings")
	}
}

func TestASecondStartWhileTheFirstIsStillRunningIsDropped(t *testing.T) {
	isolateAWS(t)

	mgr := NewManager(t.Context(), NewProvider(t.Context()))
	spec := Spec{Profile: "ghost", Region: "eu-west-1", Instance: "db", LocalPort: "1", RemotePort: "2"}

	mgr.Start(1, spec)
	mgr.Start(1, spec)

	first := awaitEvent(t, mgr)
	if first.ID != 1 || first.Kind != Exited {
		t.Fatalf("got %+v, want an exited event for id 1", first)
	}

	select {
	case extra := <-mgr.Events():
		t.Errorf("got a second event %+v; the re-entrancy guard must drop the duplicate Start", extra)
	case <-time.After(300 * time.Millisecond):
	}
}

func FuzzEndedReasonAlwaysExplainsItself(f *testing.F) {
	f.Add("", "")
	f.Add("boom", "")
	f.Add("", "Your session has been terminated.")
	f.Add("a\nb", "c\nd")
	f.Add("   ", "   ")
	f.Add("\n\n\n", "\n\n\n")

	f.Fuzz(func(t *testing.T, stderrTail, stdoutTail string) {
		for _, werr := range []error{nil, errors.New("exit status 1")} {
			err := endedReason(werr, stderrTail, stdoutTail)
			if err == nil {
				t.Fatalf("endedReason(%v, %q, %q) returned nil", werr, stderrTail, stdoutTail)
			}
			if err.Error() == "" {
				t.Errorf("endedReason(%v, %q, %q) gave an empty message", werr, stderrTail, stdoutTail)
			}
			if strings.Contains(err.Error(), "\n") {
				t.Errorf("endedReason(%v, %q, %q) = %q spans lines; the row shows one line",
					werr, stderrTail, stdoutTail, err.Error())
			}
		}
	})
}

func FuzzFirstAndLastLineStayWithinTheInput(f *testing.F) {
	f.Add("")
	f.Add("one")
	f.Add("one\ntwo")
	f.Add("\n")
	f.Add("trailing\n")

	f.Fuzz(func(t *testing.T, s string) {
		first := firstLine(s)
		if strings.Contains(first, "\n") {
			t.Errorf("firstLine(%q) = %q still contains a newline", s, first)
		}
		if len(first) > len(s) {
			t.Errorf("firstLine(%q) = %q grew the input", s, first)
		}

		last := lastLine(s)
		if strings.Contains(last, "\n") {
			t.Errorf("lastLine(%q) = %q still contains a newline", s, last)
		}
		if len(last) > len(s) {
			t.Errorf("lastLine(%q) = %q grew the input", s, last)
		}
	})
}

func FuzzTailBufferNeverExceedsItsWindow(f *testing.F) {
	f.Add([]byte("short"), 4)
	f.Add([]byte(""), 0)
	f.Add([]byte("exactly-eight!!"), 8)

	f.Fuzz(func(t *testing.T, data []byte, max int) {
		if max < 0 || max > 1<<16 {
			t.Skip()
		}
		b := newTailBuffer(max)
		n, err := b.Write(data)
		if err != nil {
			t.Fatalf("Write returned %v", err)
		}
		if n != len(data) {
			t.Errorf("n = %d, want %d; a short write makes exec treat this as an error", n, len(data))
		}
		if got := len(b.String()); got > max {
			t.Errorf("buffer holds %d bytes, over the %d window", got, max)
		}
	})
}
