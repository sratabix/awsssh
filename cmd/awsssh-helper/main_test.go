package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/forward"
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

func runServe(t *testing.T, stdin string) []message {
	t.Helper()
	isolateAWS(t)

	mgr := forward.NewManager(t.Context(), forward.NewProvider(t.Context()))
	var out bytes.Buffer
	serve(t.Context(), strings.NewReader(stdin), &out, mgr)

	var messages []message
	decoder := json.NewDecoder(bytes.NewReader(out.Bytes()))
	for decoder.More() {
		var m message
		if err := decoder.Decode(&m); err != nil {
			t.Fatalf("helper wrote something that is not newline JSON: %v", err)
		}
		messages = append(messages, m)
	}
	return messages
}

func firstWithEvent(messages []message, event string) (message, bool) {
	for _, m := range messages {
		if m.Event == event {
			return m, true
		}
	}
	return message{}, false
}

func TestServeAnnouncesReadyFirst(t *testing.T) {
	messages := runServe(t, "")
	if len(messages) == 0 {
		t.Fatal("expected at least a ready message")
	}
	if messages[0].Event != "ready" {
		t.Errorf("first message = %q, want ready", messages[0].Event)
	}
}

func TestServeAnswersProfiles(t *testing.T) {
	dir := t.TempDir()
	config := filepath.Join(dir, "config")
	if err := writeFile(config, "[profile alpha]\n[profile beta]\n"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AWS_CONFIG_FILE", config)
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(dir, "credentials"))

	mgr := forward.NewManager(t.Context(), forward.NewProvider(t.Context()))
	var out bytes.Buffer
	serve(t.Context(), strings.NewReader(`{"cmd":"profiles"}`+"\n"), &out, mgr)

	var messages []message
	decoder := json.NewDecoder(bytes.NewReader(out.Bytes()))
	for decoder.More() {
		var m message
		if err := decoder.Decode(&m); err != nil {
			t.Fatal(err)
		}
		messages = append(messages, m)
	}

	got, ok := firstWithEvent(messages, "profiles")
	if !ok {
		t.Fatalf("no profiles message in %+v", messages)
	}
	if len(got.Profiles) != 2 || got.Profiles[0] != "alpha" {
		t.Errorf("Profiles = %v, want [alpha beta]", got.Profiles)
	}
}

func TestServeRejectsMalformedJSON(t *testing.T) {
	messages := runServe(t, "not json\n")

	got, ok := firstWithEvent(messages, "error")
	if !ok {
		t.Fatalf("expected an error message, got %+v", messages)
	}
	if !strings.Contains(got.Error, "bad command") {
		t.Errorf("Error = %q, want a bad-command complaint", got.Error)
	}
}

func TestServeKeepsGoingAfterABadLine(t *testing.T) {
	messages := runServe(t, "not json\n{\"cmd\":\"profiles\"}\n")

	if _, ok := firstWithEvent(messages, "error"); !ok {
		t.Error("expected the bad line to be reported")
	}
	if _, ok := firstWithEvent(messages, "profiles"); !ok {
		t.Error("a bad line must not stop the following commands")
	}
}

func TestServeIgnoresBlankLines(t *testing.T) {
	messages := runServe(t, "\n\n\n")
	for _, m := range messages {
		if m.Event == "error" {
			t.Errorf("blank lines should be skipped silently, got %q", m.Error)
		}
	}
}

func TestServeReportsAnUnknownCommand(t *testing.T) {
	messages := runServe(t, `{"cmd":"teleport"}`+"\n")

	got, ok := firstWithEvent(messages, "error")
	if !ok {
		t.Fatalf("expected an error, got %+v", messages)
	}
	if !strings.Contains(got.Error, "teleport") {
		t.Errorf("Error = %q, should name the unknown command", got.Error)
	}
}

func TestServeRejectsStartWithoutASpec(t *testing.T) {
	messages := runServe(t, `{"cmd":"start","id":4}`+"\n")

	got, ok := firstWithEvent(messages, "exited")
	if !ok {
		t.Fatalf("expected an exited message, got %+v", messages)
	}
	if got.ID != 4 {
		t.Errorf("ID = %d, want 4 so the app can match the row", got.ID)
	}
	if !strings.Contains(got.Error, "missing forward spec") {
		t.Errorf("Error = %q", got.Error)
	}
}

func TestServeReportsAFailedStartAgainstTheRightID(t *testing.T) {
	messages := runServe(t, `{"cmd":"start","id":11,"forward":{"profile":"ghost","region":"eu-west-1",`+
		`"instance":"db","local":"1","host":"","remote":"2"}}`+"\n")

	got, ok := firstWithEvent(messages, "exited")
	if !ok {
		t.Fatalf("expected an exited message, got %+v", messages)
	}
	if got.ID != 11 {
		t.Errorf("ID = %d, want 11", got.ID)
	}
	if !strings.Contains(got.Error, "does not exist") {
		t.Errorf("Error should be the diagnosed AWS message, got %q", got.Error)
	}
}

func TestServeAcceptsStopAndStopAllForUnknownIDs(t *testing.T) {
	messages := runServe(t, `{"cmd":"stop","id":99}`+"\n"+`{"cmd":"stopAll"}`+"\n")
	for _, m := range messages {
		if m.Event == "error" {
			t.Errorf("stopping something unknown should be harmless, got %q", m.Error)
		}
	}
}

func TestServeOutputIsOneJSONObjectPerLine(t *testing.T) {
	isolateAWS(t)
	mgr := forward.NewManager(t.Context(), forward.NewProvider(t.Context()))
	var out bytes.Buffer
	serve(t.Context(), strings.NewReader(`{"cmd":"profiles"}`+"\n"), &out, mgr)

	for _, line := range strings.Split(strings.TrimRight(out.String(), "\n"), "\n") {
		if line == "" {
			t.Error("no blank lines belong in the stream")
			continue
		}
		var probe map[string]any
		if err := json.Unmarshal([]byte(line), &probe); err != nil {
			t.Errorf("line is not standalone JSON: %q", line)
		}
		if _, ok := probe["event"]; !ok {
			t.Errorf("every message needs an event field: %q", line)
		}
	}
}

func TestMessageOmitsEmptyFields(t *testing.T) {
	encoded, err := json.Marshal(message{Event: "ready"})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(encoded); got != `{"event":"ready"}` {
		t.Errorf("message = %s, want only the event field", got)
	}
}

func TestCommandDecodesTheAppsWireFormat(t *testing.T) {
	var c command
	raw := `{"cmd":"start","id":3,"forward":{"profile":"p","region":"r","instance":"i",` +
		`"local":"1","host":"h","remote":"2"}}`
	if err := json.Unmarshal([]byte(raw), &c); err != nil {
		t.Fatal(err)
	}
	if c.Cmd != "start" || c.ID != 3 || c.Forward == nil {
		t.Fatalf("decoded = %+v", c)
	}
	want := forwardSpec{Profile: "p", Region: "r", Instance: "i", LocalPort: "1", Host: "h", RemotePort: "2"}
	if *c.Forward != want {
		t.Errorf("forward = %+v, want %+v", *c.Forward, want)
	}
}

func TestCommandToleratesUnknownFields(t *testing.T) {
	var c command
	if err := json.Unmarshal([]byte(`{"cmd":"stop","id":1,"somethingNew":true}`), &c); err != nil {
		t.Fatalf("an added field from a newer app must not break the helper: %v", err)
	}
	if c.Cmd != "stop" {
		t.Errorf("Cmd = %q", c.Cmd)
	}
}

func TestOutputIsSafeForConcurrentSenders(t *testing.T) {
	var buf bytes.Buffer
	out := &output{enc: json.NewEncoder(&buf)}

	done := make(chan struct{})
	for i := range 4 {
		go func(id int) {
			defer func() { done <- struct{}{} }()
			for range 25 {
				out.send(message{Event: "started", ID: id})
			}
		}(i)
	}
	for range 4 {
		<-done
	}

	decoder := json.NewDecoder(bytes.NewReader(buf.Bytes()))
	count := 0
	for decoder.More() {
		var m message
		if err := decoder.Decode(&m); err != nil {
			t.Fatalf("interleaved writes corrupted the stream: %v", err)
		}
		count++
	}
	if count != 100 {
		t.Errorf("decoded %d messages, want 100", count)
	}
}

func writeFile(path, contents string) error {
	return os.WriteFile(path, []byte(contents), 0o600)
}

func stubLogins(t *testing.T, found []awsx.Login, run func(context.Context, awsx.LoginRequest) error) {
	t.Helper()
	previousList, previousRun := listLogins, ssoLogin
	listLogins = func() []awsx.Login { return found }
	ssoLogin = run
	t.Cleanup(func() { listLogins, ssoLogin = previousList, previousRun })
}

func stubChecker(t *testing.T, state awsx.LoginState) {
	t.Helper()
	previous := loginChecker
	loginChecker = func(context.Context, awsx.Login) awsx.LoginState { return state }
	t.Cleanup(func() { loginChecker = previous })
}

func TestCheckLoginReportsTheVerdict(t *testing.T) {
	stubLogins(t, sharedSession(), nil)
	stubChecker(t, awsx.LoginExpired)

	m, ok := firstWithEvent(runServe(t, `{"cmd":"checkLogin","login":"company"}`+"\n"), "loginCheck")
	if !ok {
		t.Fatal("no loginCheck message")
	}
	if m.State != "expired" {
		t.Errorf("State = %q, want expired", m.State)
	}
	if m.Detail != "company" {
		t.Errorf("Detail = %q, want the login it was about", m.Detail)
	}
}

func TestCheckLoginOnAnUnknownLabelIsUnknown(t *testing.T) {
	stubLogins(t, sharedSession(), nil)
	stubChecker(t, awsx.LoginValid)

	m, _ := firstWithEvent(runServe(t, `{"cmd":"checkLogin","login":"nope"}`+"\n"), "loginCheck")
	if m.State != "unknown" {
		t.Errorf("State = %q, want unknown rather than a verdict about nothing", m.State)
	}
}

func TestCheckLoginPassesTheVerdictThrough(t *testing.T) {
	for _, want := range []awsx.LoginState{awsx.LoginValid, awsx.LoginExpired, awsx.LoginUnknown} {
		stubLogins(t, sharedSession(), nil)
		stubChecker(t, want)

		m, _ := firstWithEvent(runServe(t, `{"cmd":"checkLogin","login":"company"}`+"\n"), "loginCheck")
		if m.State != string(want) {
			t.Errorf("State = %q, want %q", m.State, want)
		}
	}
}

func sharedSession() []awsx.Login {
	return []awsx.Login{{
		Session:  "company",
		StartURL: "https://example.awsapps.com/start",
		Profiles: []string{"dev", "prod"},
		Expires:  time.Date(2030, 1, 2, 3, 4, 5, 0, time.UTC),
	}}
}

func TestServeListsSSOLogins(t *testing.T) {
	stubLogins(t, sharedSession(), nil)

	m, ok := firstWithEvent(runServe(t, `{"cmd":"logins"}`+"\n"), "logins")
	if !ok {
		t.Fatal("no logins message")
	}
	if len(m.Logins) != 1 {
		t.Fatalf("Logins = %+v, want one", m.Logins)
	}
	if m.Logins[0].Label != "company" {
		t.Errorf("Label = %q, want the session name", m.Logins[0].Label)
	}
	if m.Logins[0].Expires != "2030-01-02T03:04:05Z" {
		t.Errorf("Expires = %q, want RFC3339", m.Logins[0].Expires)
	}
	if len(m.Logins[0].Profiles) != 2 {
		t.Errorf("Profiles = %v, want every profile the one login covers", m.Logins[0].Profiles)
	}
}

func TestALoginWithNoCachedTokenReportsNoExpiry(t *testing.T) {
	stubLogins(t, []awsx.Login{{Session: "company", Profiles: []string{"a"}}}, nil)

	m, _ := firstWithEvent(runServe(t, `{"cmd":"logins"}`+"\n"), "logins")
	if m.Logins[0].Expires != "" {
		t.Errorf("Expires = %q, want empty for a signed-out session", m.Logins[0].Expires)
	}
}

func TestSSOLoginRunsTheMatchingLoginAndRefreshes(t *testing.T) {
	var ran []string
	stubLogins(t, sharedSession(), func(_ context.Context, req awsx.LoginRequest) error {
		ran = append(ran, strings.Join(req.Login.Args(), " "))
		return nil
	})

	messages := runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n")

	if len(ran) != 1 || ran[0] != "sso login --profile dev" {
		t.Fatalf("ran = %v, want one aws sso login for a profile of that session", ran)
	}
	m, ok := firstWithEvent(messages, "ssoLogin")
	if !ok {
		t.Fatal("no ssoLogin message")
	}
	if m.Error != "" {
		t.Errorf("Error = %q, want none", m.Error)
	}
	if _, ok := firstWithEvent(messages, "logins"); !ok {
		t.Error("a completed sign-in should push the refreshed expiry without being asked")
	}
}

func TestSSOLoginReportsAFailure(t *testing.T) {
	stubLogins(t, sharedSession(), func(context.Context, awsx.LoginRequest) error {
		return errors.New("the AWS CLI is not installed")
	})

	m, ok := firstWithEvent(runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n"), "ssoLogin")
	if !ok {
		t.Fatal("no ssoLogin message")
	}
	if m.Error != "the AWS CLI is not installed" {
		t.Errorf("Error = %q, want the runner's message", m.Error)
	}
	if m.Detail != "company" {
		t.Errorf("Detail = %q, want the login it was about", m.Detail)
	}
}

func TestSSOLoginRejectsAnUnknownLabel(t *testing.T) {
	called := false
	stubLogins(t, sharedSession(), func(context.Context, awsx.LoginRequest) error {
		called = true
		return nil
	})

	m, _ := firstWithEvent(runServe(t, `{"cmd":"ssoLogin","login":"nope"}`+"\n"), "ssoLogin")
	if called {
		t.Error("an unknown label must not run the AWS CLI")
	}
	if !strings.Contains(m.Error, "nope") {
		t.Errorf("Error = %q, should name what was asked for", m.Error)
	}
}

func TestServeWaitsForASignInBeforeShuttingDown(t *testing.T) {
	stubLogins(t, sharedSession(), func(context.Context, awsx.LoginRequest) error {
		time.Sleep(20 * time.Millisecond)
		return nil
	})

	if _, ok := firstWithEvent(runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n"), "ssoLogin"); !ok {
		t.Error("stdin EOF must not drop a sign-in that is still running")
	}
}

func stubGrace(t *testing.T, d time.Duration) {
	t.Helper()
	previous := signInGrace
	signInGrace = d
	t.Cleanup(func() { signInGrace = previous })
}

func TestASlowSignInSaysItIsWaitingOnTheUser(t *testing.T) {
	stubGrace(t, time.Millisecond)
	stubLogins(t, sharedSession(), func(context.Context, awsx.LoginRequest) error {
		time.Sleep(30 * time.Millisecond)
		return nil
	})

	messages := runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n")

	m, ok := firstWithEvent(messages, "ssoLoginPending")
	if !ok {
		t.Fatal("a sign-in past its grace period must say so, or a hidden window is invisible")
	}
	if m.Detail != "company" {
		t.Errorf("Detail = %q, want the login it was about", m.Detail)
	}
	if _, ok := firstWithEvent(messages, "ssoLogin"); !ok {
		t.Error("the pending notice must not replace the result")
	}
}

func TestAPromptSignInStaysQuiet(t *testing.T) {
	stubGrace(t, time.Hour)
	stubLogins(t, sharedSession(), func(context.Context, awsx.LoginRequest) error { return nil })

	if _, ok := firstWithEvent(runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n"), "ssoLoginPending"); ok {
		t.Error("a sign-in that completes inside the grace period must not report pending")
	}
}

func TestLoginsReportAnUnscopedSession(t *testing.T) {
	logins := sharedSession()
	logins[0].Scoped = true
	stubLogins(t, logins, nil)

	m, ok := firstWithEvent(runServe(t, `{"cmd":"logins"}`+"\n"), "logins")
	if !ok {
		t.Fatal("no logins message")
	}
	if !m.Logins[0].Scoped {
		t.Error("Scoped must reach the app, it is what decides the config nudge")
	}
}

func TestLoginsCarryTheStartURL(t *testing.T) {
	stubLogins(t, sharedSession(), nil)

	m, ok := firstWithEvent(runServe(t, `{"cmd":"logins"}`+"\n"), "logins")
	if !ok {
		t.Fatal("no logins message")
	}
	if m.Logins[0].StartURL != "https://example.awsapps.com/start" {
		t.Errorf("StartURL = %q, the app resolves its host before an automatic sign-in", m.Logins[0].StartURL)
	}
}

func stubCheck(t *testing.T, run func(forward.Spec) (string, error)) {
	t.Helper()
	previous := checkForward
	checkForward = func(_ context.Context, _ *forward.Manager, s forward.Spec) (string, error) {
		return run(s)
	}
	t.Cleanup(func() { checkForward = previous })
}

const testCommand = `{"cmd":"test","id":6,"forward":{"profile":"prod","region":"eu-central-1",` +
	`"instance":"db","local":"5432","host":"","remote":"5432"}}` + "\n"

func TestATestReportsWhatItFound(t *testing.T) {
	var got forward.Spec
	stubCheck(t, func(s forward.Spec) (string, error) {
		got = s
		return "db (i-0abc) is running in eu-central-1 and its SSM agent is online", nil
	})

	m, ok := firstWithEvent(runServe(t, testCommand), "test")
	if !ok {
		t.Fatal("no test message")
	}
	if m.ID != 6 {
		t.Errorf("ID = %d, want 6 so a stale reply can be dropped", m.ID)
	}
	if m.Error != "" {
		t.Errorf("Error = %q, want none", m.Error)
	}
	if !strings.Contains(m.Detail, "SSM agent is online") {
		t.Errorf("Detail = %q, want the summary", m.Detail)
	}
	if got.Profile != "prod" || got.Instance != "db" || got.Region != "eu-central-1" {
		t.Errorf("spec = %+v, want the draft the app sent", got)
	}
}

func TestATestReportsAFailure(t *testing.T) {
	stubCheck(t, func(forward.Spec) (string, error) {
		return "", errors.New("not signed in to AWS profile \"prod\"")
	})

	m, ok := firstWithEvent(runServe(t, testCommand), "test")
	if !ok {
		t.Fatal("no test message")
	}
	if !strings.Contains(m.Error, "not signed in") {
		t.Errorf("Error = %q, want the reason", m.Error)
	}
	if m.Detail != "" {
		t.Errorf("Detail = %q, want nothing beside a failure", m.Detail)
	}
}

func TestATestWithoutASpecIsRejectedAgainstItsID(t *testing.T) {
	m, ok := firstWithEvent(runServe(t, `{"cmd":"test","id":9}`+"\n"), "test")
	if !ok {
		t.Fatal("no test message")
	}
	if m.ID != 9 || !strings.Contains(m.Error, "missing forward spec") {
		t.Errorf("got %+v, want a complaint against id 9", m)
	}
}

func TestATestThatNeverAnswersGivesUp(t *testing.T) {
	previous := checkTimeout
	checkTimeout = 10 * time.Millisecond
	t.Cleanup(func() { checkTimeout = previous })

	stubCheck(t, func(forward.Spec) (string, error) {
		time.Sleep(80 * time.Millisecond)
		return "", context.DeadlineExceeded
	})

	m, ok := firstWithEvent(runServe(t, testCommand), "test")
	if !ok {
		t.Fatal("no test message; a form waiting for one would spin for ever")
	}
	if !strings.Contains(m.Error, "gave up") {
		t.Errorf("Error = %q, want a timeout the user can read", m.Error)
	}
}

func TestServeWaitsForATestBeforeShuttingDown(t *testing.T) {
	stubCheck(t, func(forward.Spec) (string, error) {
		time.Sleep(20 * time.Millisecond)
		return "fine", nil
	})

	if _, ok := firstWithEvent(runServe(t, testCommand), "test"); !ok {
		t.Error("stdin EOF must not drop a test that is still running")
	}
}

func TestTheAuthorizeURLIsForwardedToTheApp(t *testing.T) {
	const want = "https://oidc.eu-central-1.amazonaws.com/authorize?x=1"
	stubLogins(t, sharedSession(), func(_ context.Context, req awsx.LoginRequest) error {
		req.OnURL(want)
		return nil
	})

	m, ok := firstWithEvent(runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n"), "authorizeURL")
	if !ok {
		t.Fatal("no authorizeURL message; the web view would have nothing to load")
	}
	if m.URL != want {
		t.Errorf("URL = %q, want %q", m.URL, want)
	}
	if m.Detail != "company" {
		t.Errorf("Detail = %q, want the login it belongs to", m.Detail)
	}
}

func TestOnURLIsAlwaysSafeToCall(t *testing.T) {
	stubLogins(t, sharedSession(), func(_ context.Context, req awsx.LoginRequest) error {
		if req.OnURL == nil {
			t.Error("OnURL must never be nil; awsx calls it without checking in the scanner")
		}
		return nil
	})
	runServe(t, `{"cmd":"ssoLogin","login":"company"}`+"\n")
}
