package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
)

func TestAvailableFindsThePluginOnPath(t *testing.T) {
	dir := t.TempDir()
	plugin := filepath.Join(dir, pluginBinary)
	if err := os.WriteFile(plugin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	if err := Available(); err != nil {
		t.Errorf("Available() = %v, want nil", err)
	}
}

func TestAvailableReportsAMissingPlugin(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	err := Available()
	if err == nil {
		t.Fatal("expected an error when the plugin is absent")
	}
	msg := err.Error()
	if !strings.Contains(msg, pluginBinary) {
		t.Errorf("error should name the binary: %s", msg)
	}
	if !strings.Contains(msg, "install") {
		t.Errorf("error should tell the user to install it: %s", msg)
	}
}

func TestAvailableIgnoresANonExecutableFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, pluginBinary), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	if err := Available(); err == nil {
		t.Error("a non-executable file must not count as the plugin")
	}
}

func TestForwardDocumentToInstance(t *testing.T) {
	document, parameters := forwardDocument(Forward{LocalPort: "5432", RemotePort: "5433"})

	if document != docToInstance {
		t.Errorf("document = %q, want %q", document, docToInstance)
	}
	if !slices.Equal(parameters["portNumber"], []string{"5433"}) {
		t.Errorf("portNumber = %v, want the remote port", parameters["portNumber"])
	}
	if !slices.Equal(parameters["localPortNumber"], []string{"5432"}) {
		t.Errorf("localPortNumber = %v, want the local port", parameters["localPortNumber"])
	}
	if _, ok := parameters["host"]; ok {
		t.Error("no host parameter belongs in an instance-local forward")
	}
}

func TestForwardDocumentToRemoteHost(t *testing.T) {
	document, parameters := forwardDocument(Forward{
		LocalPort:  "3307",
		Host:       "db.internal",
		RemotePort: "3306",
	})

	if document != docToRemoteHost {
		t.Errorf("document = %q, want %q", document, docToRemoteHost)
	}
	if !slices.Equal(parameters["host"], []string{"db.internal"}) {
		t.Errorf("host = %v, want db.internal", parameters["host"])
	}
	if !slices.Equal(parameters["portNumber"], []string{"3306"}) {
		t.Errorf("portNumber = %v, want 3306", parameters["portNumber"])
	}
}

func TestPluginPayloadForAShell(t *testing.T) {
	got := marshal(t, pluginPayload("i-abc", "", nil))
	if got != `{"Target":"i-abc"}` {
		t.Errorf("shell payload = %s", got)
	}
}

func TestPluginPayloadForAForwardToInstance(t *testing.T) {
	document, parameters := forwardDocument(Forward{LocalPort: "3307", RemotePort: "3306"})
	got := marshal(t, pluginPayload("i-abc", document, parameters))

	want := `{"DocumentName":"AWS-StartPortForwardingSession",` +
		`"Parameters":{"localPortNumber":["3307"],"portNumber":["3306"]},"Target":"i-abc"}`
	if got != want {
		t.Errorf("payload mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestPluginPayloadForAForwardToRemoteHost(t *testing.T) {
	document, parameters := forwardDocument(Forward{
		LocalPort:  "3307",
		Host:       "db.internal",
		RemotePort: "3306",
	})
	got := marshal(t, pluginPayload("i-abc", document, parameters))

	want := `{"DocumentName":"AWS-StartPortForwardingSessionToRemoteHost",` +
		`"Parameters":{"host":["db.internal"],"localPortNumber":["3307"],"portNumber":["3306"]},` +
		`"Target":"i-abc"}`
	if got != want {
		t.Errorf("payload mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestPluginPayloadOmitsEmptyDocumentAndParameters(t *testing.T) {
	payload := pluginPayload("i-1", "", nil)
	if _, ok := payload["DocumentName"]; ok {
		t.Error("an empty document must be omitted")
	}
	if _, ok := payload["Parameters"]; ok {
		t.Error("nil parameters must be omitted")
	}
	if payload["Target"] != "i-1" {
		t.Errorf("Target = %v, want i-1", payload["Target"])
	}
}

func TestPluginPayloadKeepsEmptyParameterMap(t *testing.T) {
	payload := pluginPayload("i-1", "Doc", map[string][]string{})
	if _, ok := payload["Parameters"]; !ok {
		t.Error("an explicitly empty parameter map is still sent")
	}
}

func TestNewStarterCarriesRegionAndProfile(t *testing.T) {
	starter := New(awsConfigForTest(), "eu-west-2", "prod")
	if starter.region != "eu-west-2" {
		t.Errorf("region = %q", starter.region)
	}
	if starter.profile != "prod" {
		t.Errorf("profile = %q", starter.profile)
	}
	if starter.ssm == nil {
		t.Error("expected an SSM client")
	}
}

func marshal(t *testing.T, v any) string {
	t.Helper()
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func awsConfigForTest() aws.Config {
	return aws.Config{Region: "eu-west-2"}
}
