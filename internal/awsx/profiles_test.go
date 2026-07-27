package awsx

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func awsFiles(t *testing.T, config, credentials string) {
	t.Helper()
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config")
	credsPath := filepath.Join(dir, "credentials")
	if config != "" {
		writeFile(t, configPath, config)
	}
	if credentials != "" {
		writeFile(t, credsPath, credentials)
	}
	t.Setenv("AWS_CONFIG_FILE", configPath)
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", credsPath)
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_DEFAULT_PROFILE", "")
	t.Setenv("AWS_REGION", "")
	t.Setenv("AWS_DEFAULT_REGION", "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
}

func TestProfilesSkipsNonProfileSections(t *testing.T) {
	awsFiles(t, `[default]
region = eu-central-1

[sso-session corp]
sso_region = eu-central-1

[profile prod]
region = eu-west-1
sso_session = corp

[services shared]
ec2 =

[profile  spaced  ]
region = us-east-1
`, "[legacy]\naws_access_key_id = x\n")

	got := Profiles()
	want := []string{"default", "legacy", "prod", "spaced"}
	if !slices.Equal(got, want) {
		t.Fatalf("Profiles() = %v, want %v", got, want)
	}

	if !UsesSSO("prod") {
		t.Error("UsesSSO(prod) = false, want true (it has sso_session)")
	}
	for _, name := range []string{"default", "spaced", "legacy", "corp"} {
		if UsesSSO(name) {
			t.Errorf("UsesSSO(%s) = true, want false", name)
		}
	}
}

func TestProfilesWithNoFilesIsEmpty(t *testing.T) {
	awsFiles(t, "", "")
	if got := Profiles(); len(got) != 0 {
		t.Errorf("Profiles() = %v, want empty", got)
	}
}

func TestProfilesIgnoresCommentsAndBlankLines(t *testing.T) {
	awsFiles(t, `# a comment
; another comment

[profile one]
region = eu-west-1

# [profile commented-out]
[profile two]
`, "")

	if got := Profiles(); !slices.Equal(got, []string{"one", "two"}) {
		t.Errorf("Profiles() = %v, want [one two]", got)
	}
}

func TestProfilesDeduplicatesAcrossFiles(t *testing.T) {
	awsFiles(t, "[profile shared]\n", "[shared]\naws_access_key_id = x\n")
	if got := Profiles(); !slices.Equal(got, []string{"shared"}) {
		t.Errorf("Profiles() = %v, want [shared]", got)
	}
}

func TestProfilesHandlesMissingTrailingNewline(t *testing.T) {
	awsFiles(t, "[profile last]", "")
	if got := Profiles(); !slices.Equal(got, []string{"last"}) {
		t.Errorf("Profiles() = %v, want [last]", got)
	}
}

func TestProfilesIgnoresProfileWithNoName(t *testing.T) {
	awsFiles(t, "[profile ]\n[profile real]\n", "")
	if got := Profiles(); !slices.Equal(got, []string{"real"}) {
		t.Errorf("Profiles() = %v, want [real]", got)
	}
}

func TestProfilesAreSorted(t *testing.T) {
	awsFiles(t, "[profile zeta]\n[profile alpha]\n[default]\n", "")
	if got := Profiles(); !slices.Equal(got, []string{"alpha", "default", "zeta"}) {
		t.Errorf("Profiles() = %v, want sorted", got)
	}
}

func TestUsesSSORecognisesEveryMarker(t *testing.T) {
	for _, key := range []string{"sso_session", "sso_start_url", "sso_account_id"} {
		t.Run(key, func(t *testing.T) {
			awsFiles(t, "[profile p]\n"+key+" = value\n", "")
			if !UsesSSO("p") {
				t.Errorf("UsesSSO should be true when %s is set", key)
			}
		})
	}
}

func TestUsesSSOIgnoresEmptyValues(t *testing.T) {
	awsFiles(t, "[profile p]\nsso_session =\n", "")
	if UsesSSO("p") {
		t.Error("an empty sso_session must not count as SSO")
	}
}

func TestUsesSSODoesNotLeakBetweenProfiles(t *testing.T) {
	awsFiles(t, "[profile sso]\nsso_session = corp\n\n[profile keys]\nregion = eu-west-1\n", "")
	if !UsesSSO("sso") {
		t.Error("UsesSSO(sso) should be true")
	}
	if UsesSSO("keys") {
		t.Error("UsesSSO(keys) must not inherit the previous section")
	}
}

func TestUsesSSOForUnknownProfile(t *testing.T) {
	awsFiles(t, "[profile p]\nsso_session = corp\n", "")
	if UsesSSO("nope") {
		t.Error("an unknown profile does not use SSO")
	}
}

func TestUsesSSOForDefaultProfile(t *testing.T) {
	awsFiles(t, "[default]\nsso_start_url = https://example.awsapps.com/start\n", "")
	if !UsesSSO("default") {
		t.Error("the default section should be recognised")
	}
}

func TestResolveProfilePrecedence(t *testing.T) {
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_DEFAULT_PROFILE", "")

	if got := ResolveProfile("flagged"); got.Name != "flagged" || !got.Explicit {
		t.Errorf("flag: got %+v, want explicit flagged", got)
	}

	got := ResolveProfile("")
	if got.Name != "default" || got.Explicit {
		t.Errorf("bare: got %+v, want non-explicit default", got)
	}
	if got.Source == "" {
		t.Error("a defaulted profile still needs a source description")
	}

	t.Setenv("AWS_PROFILE", "from-env")
	if got := ResolveProfile(""); got.Name != "from-env" || got.Source != "AWS_PROFILE" {
		t.Errorf("env: got %+v, want from-env via AWS_PROFILE", got)
	}
	if got := ResolveProfile(""); !got.Explicit {
		t.Error("an env-provided profile counts as explicitly chosen")
	}
	if got := ResolveProfile("flagged"); got.Name != "flagged" {
		t.Errorf("flag must beat env, got %+v", got)
	}
}

func TestResolveProfileFallsBackToDefaultProfileEnv(t *testing.T) {
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_DEFAULT_PROFILE", "legacy-env")

	got := ResolveProfile("")
	if got.Name != "legacy-env" || got.Source != "AWS_DEFAULT_PROFILE" {
		t.Errorf("got %+v, want legacy-env via AWS_DEFAULT_PROFILE", got)
	}
}

func TestResolveProfilePrefersAWSProfileOverDefaultProfile(t *testing.T) {
	t.Setenv("AWS_PROFILE", "primary")
	t.Setenv("AWS_DEFAULT_PROFILE", "secondary")

	if got := ResolveProfile(""); got.Name != "primary" {
		t.Errorf("got %+v, want primary", got)
	}
}

func TestConfigProfileName(t *testing.T) {
	cases := []struct {
		section string
		want    string
		ok      bool
	}{
		{"default", "default", true},
		{"profile prod", "prod", true},
		{"profile  padded  ", "padded", true},
		{"sso-session corp", "", false},
		{"services shared", "", false},
		{"profile", "", false},
		{"profile ", "", false},
		{"", "", false},
		{"Default", "", false},
	}
	for _, c := range cases {
		t.Run(c.section, func(t *testing.T) {
			got, ok := configProfileName(c.section)
			if ok != c.ok || got != c.want {
				t.Errorf("configProfileName(%q) = (%q, %v), want (%q, %v)", c.section, got, ok, c.want, c.ok)
			}
		})
	}
}
