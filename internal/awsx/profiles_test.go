package awsx

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
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
	t.Setenv("HOME", dir)
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

func TestEnvOrPrefersTheEnvironmentButIgnoresAnEmptyValue(t *testing.T) {
	t.Setenv("AWSSSH_ENVOR_PROBE", "from-env")
	if got := envOr("AWSSSH_ENVOR_PROBE", "fallback"); got != "from-env" {
		t.Errorf("got %q, want the environment value", got)
	}

	t.Setenv("AWSSSH_ENVOR_PROBE", "")
	if got := envOr("AWSSSH_ENVOR_PROBE", "fallback"); got != "fallback" {
		t.Errorf("got %q; an empty variable must not shadow the default path", got)
	}

	if got := envOr("AWSSSH_ENVOR_DEFINITELY_UNSET", "fallback"); got != "fallback" {
		t.Errorf("got %q, want the fallback", got)
	}
}

func TestConfigProfileNameRejectsMalformedSections(t *testing.T) {
	cases := []string{
		"profile",
		"profile ",
		"profile\t",
		"sso-session company",
		"services",
		"",
		"Profile upper",
	}
	for _, section := range cases {
		if name, ok := configProfileName(section); ok {
			t.Errorf("configProfileName(%q) = (%q, true), want it rejected", section, name)
		}
	}
}

func TestConfigProfileNameTrimsInnerWhitespace(t *testing.T) {
	name, ok := configProfileName("profile   spaced   ")
	if !ok || name != "spaced" {
		t.Errorf("got (%q, %v), want (\"spaced\", true)", name, ok)
	}
}

func TestParseSectionsIgnoresKeysBeforeAnySection(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "orphan = value\n[profile real]\nregion = eu-west-1\n")

	sections := parseSections(path)
	if len(sections) != 1 {
		t.Fatalf("got %d sections, want 1", len(sections))
	}
	if sections[0].keys["region"] != "eu-west-1" {
		t.Errorf("keys = %v, want the region", sections[0].keys)
	}
	if _, present := sections[0].keys["orphan"]; present {
		t.Error("a key before any header must be dropped, not attached to the first section")
	}
}

func TestParseSectionsKeepsValuesContainingEquals(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "[profile p]\nsso_start_url = https://x.example/start?a=1&b=2\n")

	sections := parseSections(path)
	if len(sections) != 1 {
		t.Fatalf("got %d sections", len(sections))
	}
	want := "https://x.example/start?a=1&b=2"
	if got := sections[0].keys["sso_start_url"]; got != want {
		t.Errorf("got %q, want %q — only the first = separates key from value", got, want)
	}
}

func TestParseSectionsSkipsLinesWithNoSeparator(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "[profile p]\ngarbage line\nregion = eu-west-1\n")

	sections := parseSections(path)
	if len(sections[0].keys) != 1 {
		t.Errorf("keys = %v, want only the region", sections[0].keys)
	}
}

func TestParseSectionsAcceptsBothCommentMarkers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "[profile p]\n# hash comment\n; semicolon comment\nregion = eu-west-1\n")

	sections := parseSections(path)
	if len(sections[0].keys) != 1 {
		t.Errorf("keys = %v, want comments dropped", sections[0].keys)
	}
}

func TestParseSectionsKeepsBothOfADuplicatedHeader(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "[profile dup]\nregion = a\n[profile dup]\nregion = b\n")

	sections := parseSections(path)
	if len(sections) != 2 {
		t.Fatalf("got %d sections, want both so the caller decides precedence", len(sections))
	}
	if sections[0].keys["region"] != "a" || sections[1].keys["region"] != "b" {
		t.Errorf("sections = %v, want them kept in file order", sections)
	}
}

func TestParseSectionsOnAMissingFileIsEmptyNotAnError(t *testing.T) {
	if got := parseSections(filepath.Join(t.TempDir(), "nope")); got != nil {
		t.Errorf("got %v, want nil for an unreadable path", got)
	}
}

func TestParseSectionsTolerantOfWhitespaceAroundHeaders(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "   [ profile spaced ]   \n  region  =  eu-west-1  \n")

	sections := parseSections(path)
	if len(sections) != 1 {
		t.Fatalf("got %d sections", len(sections))
	}
	if sections[0].name != "profile spaced" {
		t.Errorf("name = %q, want the brackets and outer spaces stripped", sections[0].name)
	}
	if sections[0].keys["region"] != "eu-west-1" {
		t.Errorf("keys = %v, want key and value trimmed", sections[0].keys)
	}
}

func TestParseSectionsOnAnEmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	writeFile(t, path, "")
	if got := parseSections(path); len(got) != 0 {
		t.Errorf("got %v, want nothing", got)
	}
}

func FuzzParseSectionsNeverPanicsAndStaysWellFormed(f *testing.F) {
	f.Add("[profile a]\nregion = eu-west-1\n")
	f.Add("")
	f.Add("[]\n")
	f.Add("[unclosed\n")
	f.Add("key = value\n")
	f.Add("[a]\n[b]\n[a]\n")
	f.Add("[profile x]\r\nregion = y\r\n")
	f.Add("# only a comment\n")

	f.Fuzz(func(t *testing.T, body string) {
		if len(body) > 1<<16 {
			t.Skip()
		}
		path := filepath.Join(t.TempDir(), "config")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}

		for _, section := range parseSections(path) {
			if section.keys == nil {
				t.Errorf("section %q has a nil key map; callers index it directly", section.name)
			}
			if strings.HasPrefix(section.name, "[") || strings.HasSuffix(section.name, "]") {
				t.Errorf("section name %q kept its brackets", section.name)
			}
			if section.name != strings.TrimSpace(section.name) {
				t.Errorf("section name %q was not trimmed", section.name)
			}
			for key, value := range section.keys {
				if key != strings.TrimSpace(key) {
					t.Errorf("key %q was not trimmed", key)
				}
				if value != strings.TrimSpace(value) {
					t.Errorf("value %q was not trimmed", value)
				}
				if strings.ContainsAny(key, "\n\r") || strings.ContainsAny(value, "\n\r") {
					t.Errorf("key/value spans lines: %q = %q", key, value)
				}
			}
		}
	})
}

func FuzzConfigProfileNameNeverReturnsAnEmptyAcceptedName(f *testing.F) {
	f.Add("profile dev")
	f.Add("default")
	f.Add("profile ")
	f.Add("")
	f.Add("sso-session x")

	f.Fuzz(func(t *testing.T, section string) {
		if len(section) > 4096 {
			t.Skip()
		}
		name, ok := configProfileName(section)
		if !ok {
			if name != "" {
				t.Errorf("configProfileName(%q) rejected but still returned %q", section, name)
			}
			return
		}
		if name == "" {
			t.Errorf("configProfileName(%q) accepted an empty profile name", section)
		}
		if name != strings.TrimSpace(name) {
			t.Errorf("configProfileName(%q) = %q was not trimmed", section, name)
		}
	})
}

func FuzzProfilesAreAlwaysSortedAndUnique(f *testing.F) {
	f.Add("[profile b]\n[profile a]\n", "[c]\n")
	f.Add("", "")
	f.Add("[default]\n", "[default]\n")

	f.Fuzz(func(t *testing.T, config, credentials string) {
		if len(config) > 1<<15 || len(credentials) > 1<<15 {
			t.Skip()
		}
		dir := t.TempDir()
		configPath := filepath.Join(dir, "config")
		credsPath := filepath.Join(dir, "credentials")
		if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(credsPath, []byte(credentials), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("AWS_CONFIG_FILE", configPath)
		t.Setenv("AWS_SHARED_CREDENTIALS_FILE", credsPath)

		got := Profiles()
		if !slices.IsSorted(got) {
			t.Errorf("Profiles() = %v is not sorted", got)
		}
		for i := 1; i < len(got); i++ {
			if got[i] == got[i-1] {
				t.Errorf("Profiles() = %v repeats %q", got, got[i])
			}
		}
		for _, name := range got {
			if name == "" {
				t.Error("Profiles() returned an empty name")
			}
		}
	})
}
