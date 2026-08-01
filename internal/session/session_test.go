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

func TestForwardDocumentAlwaysCarriesBothPorts(t *testing.T) {
	cases := []Forward{
		{LocalPort: "5432", RemotePort: "5432"},
		{LocalPort: "1", RemotePort: "65535"},
		{LocalPort: "5432", Host: "db.internal", RemotePort: "5432"},
	}
	for _, f := range cases {
		_, params := forwardDocument(f)
		if got := params["localPortNumber"]; len(got) != 1 || got[0] != f.LocalPort {
			t.Errorf("localPortNumber = %v, want [%s]", got, f.LocalPort)
		}
		if got := params["portNumber"]; len(got) != 1 || got[0] != f.RemotePort {
			t.Errorf("portNumber = %v, want [%s]", got, f.RemotePort)
		}
	}
}

func TestForwardDocumentOnlySetsHostWhenThereIsOne(t *testing.T) {
	_, params := forwardDocument(Forward{LocalPort: "5432", RemotePort: "5432"})
	if _, present := params["host"]; present {
		t.Error("a forward to the instance itself must not carry a host parameter")
	}

	_, params = forwardDocument(Forward{LocalPort: "5432", Host: "db.internal", RemotePort: "5432"})
	if got := params["host"]; len(got) != 1 || got[0] != "db.internal" {
		t.Errorf("host = %v, want [db.internal]", got)
	}
}

func TestForwardDocumentPicksTheDocumentByHostAlone(t *testing.T) {
	if doc, _ := forwardDocument(Forward{}); doc != docToInstance {
		t.Errorf("doc = %q, want %q for an empty forward", doc, docToInstance)
	}
	if doc, _ := forwardDocument(Forward{Host: " "}); doc != docToRemoteHost {
		t.Errorf("doc = %q; any non-empty host means the remote-host document", doc)
	}
}

func TestPluginPayloadAlwaysCarriesTheTarget(t *testing.T) {
	for _, target := range []string{"i-0abc", "", "some-name"} {
		payload := pluginPayload(target, "", nil)
		if got, ok := payload["Target"].(string); !ok || got != target {
			t.Errorf("Target = %v, want %q", payload["Target"], target)
		}
	}
}

func TestPluginPayloadHasNoUnexpectedKeys(t *testing.T) {
	payload := pluginPayload("i-0abc", docToRemoteHost, map[string][]string{"portNumber": {"5432"}})
	allowed := map[string]bool{"Target": true, "DocumentName": true, "Parameters": true}
	for key := range payload {
		if !allowed[key] {
			t.Errorf("unexpected key %q; this payload is an external contract with session-manager-plugin", key)
		}
	}
}

func TestPluginPayloadIsStableAcrossCalls(t *testing.T) {
	params := map[string][]string{"portNumber": {"5432"}, "localPortNumber": {"15432"}}
	a := pluginPayload("i-0abc", docToRemoteHost, params)
	b := pluginPayload("i-0abc", docToRemoteHost, params)

	left, err := json.Marshal(a)
	if err != nil {
		t.Fatal(err)
	}
	right, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if string(left) != string(right) {
		t.Errorf("payload is not stable:\n%s\n%s", left, right)
	}
}

func TestPluginPayloadMarshalsToTheShapeThePluginParses(t *testing.T) {
	doc, params := forwardDocument(Forward{LocalPort: "15432", Host: "db.internal", RemotePort: "5432"})
	data, err := json.Marshal(pluginPayload("i-0abc123", doc, params))
	if err != nil {
		t.Fatal(err)
	}

	var back struct {
		Target       string              `json:"Target"`
		DocumentName string              `json:"DocumentName"`
		Parameters   map[string][]string `json:"Parameters"`
	}
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	if back.Target != "i-0abc123" {
		t.Errorf("Target = %q", back.Target)
	}
	if back.DocumentName != docToRemoteHost {
		t.Errorf("DocumentName = %q", back.DocumentName)
	}
	if back.Parameters["host"][0] != "db.internal" ||
		back.Parameters["portNumber"][0] != "5432" ||
		back.Parameters["localPortNumber"][0] != "15432" {
		t.Errorf("Parameters = %v", back.Parameters)
	}
}

func TestDocumentNamesAreTheAWSOwnedOnes(t *testing.T) {
	if docToInstance != "AWS-StartPortForwardingSession" {
		t.Errorf("docToInstance = %q; this is an AWS-owned document name", docToInstance)
	}
	if docToRemoteHost != "AWS-StartPortForwardingSessionToRemoteHost" {
		t.Errorf("docToRemoteHost = %q; this is an AWS-owned document name", docToRemoteHost)
	}
}

func TestPluginBinaryNameIsWhatAvailableLooksFor(t *testing.T) {
	if pluginBinary != "session-manager-plugin" {
		t.Errorf("pluginBinary = %q; the cask depends on this name", pluginBinary)
	}
}
