package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

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
	serve(strings.NewReader(stdin), &out, mgr)

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
	serve(strings.NewReader(`{"cmd":"profiles"}`+"\n"), &out, mgr)

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
	serve(strings.NewReader(`{"cmd":"profiles"}`+"\n"), &out, mgr)

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
