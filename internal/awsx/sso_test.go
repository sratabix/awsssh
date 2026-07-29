package awsx

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func ssoCache(t *testing.T, files map[string]string) {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".aws", "sso", "cache")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		writeFile(t, filepath.Join(dir, name), body)
	}
	t.Setenv("HOME", home)
}

func token(startURL, expires string) string {
	return `{"startUrl":"` + startURL + `","accessToken":"secret","region":"eu-central-1",` +
		`"expiresAt":"` + expires + `"}`
}

const sessionConfig = `
[sso-session sacha]
sso_start_url = https://example.awsapps.com/start
sso_region = eu-central-1

[profile Atabase]
sso_session = sacha
sso_account_id = 1

[profile Atabix]
sso_session = sacha
sso_account_id = 2

[profile keys-only]
region = eu-west-1
`

func TestLoginsGroupProfilesBySSOSession(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, nil)

	logins := Logins()
	if len(logins) != 1 {
		t.Fatalf("want one login for one shared session, got %d: %+v", len(logins), logins)
	}
	if logins[0].Label() != "sacha" {
		t.Errorf("Label() = %q, want the session name", logins[0].Label())
	}
	if got := logins[0].Profiles; len(got) != 2 || got[0] != "Atabase" || got[1] != "Atabix" {
		t.Errorf("Profiles = %v, want both SSO profiles and not the keys-only one", got)
	}
}

func TestLoginsIgnoreProfilesWithoutSSO(t *testing.T) {
	awsFiles(t, "[profile keys-only]\nregion = eu-west-1\n", "")
	ssoCache(t, nil)

	if logins := Logins(); len(logins) != 0 {
		t.Errorf("want no logins for a config with no SSO, got %+v", logins)
	}
}

func TestLoginsCoverLegacyProfilesWithAStartURL(t *testing.T) {
	awsFiles(t, `
[profile main]
sso_start_url = https://legacy.awsapps.com/start
sso_region = us-east-1
sso_account_id = 1

[profile main-admin]
sso_start_url = https://legacy.awsapps.com/start
sso_region = us-east-1
sso_account_id = 2
`, "")
	ssoCache(t, nil)

	logins := Logins()
	if len(logins) != 1 {
		t.Fatalf("one start URL is one login, got %d: %+v", len(logins), logins)
	}
	if logins[0].Label() != "main" {
		t.Errorf("Label() = %q, want the first profile when there is no session", logins[0].Label())
	}
	if len(logins[0].Profiles) != 2 {
		t.Errorf("Profiles = %v, want both profiles on that start URL", logins[0].Profiles)
	}
}

func TestLoginsSeparateDistinctStartURLs(t *testing.T) {
	awsFiles(t, `
[sso-session work]
sso_start_url = https://work.awsapps.com/start

[profile w]
sso_session = work

[sso-session side]
sso_start_url = https://side.awsapps.com/start

[profile s]
sso_session = side
`, "")
	ssoCache(t, nil)

	logins := Logins()
	if len(logins) != 2 {
		t.Fatalf("want a login each, got %d: %+v", len(logins), logins)
	}
	if logins[0].Label() != "side" || logins[1].Label() != "work" {
		t.Errorf("logins should be sorted by label, got %q and %q",
			logins[0].Label(), logins[1].Label())
	}
}

func TestArgsUseAProfileTheUserAlreadyHas(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, nil)

	got := Logins()[0].Args()
	want := []string{"sso", "login", "--profile", "Atabase"}
	if len(got) != len(want) {
		t.Fatalf("Args() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Args() = %v, want %v", got, want)
		}
	}
}

func TestArgsFallBackToTheSessionWithoutProfiles(t *testing.T) {
	login := Login{Session: "sacha"}
	got := login.Args()
	if len(got) != 4 || got[2] != "--sso-session" || got[3] != "sacha" {
		t.Errorf("Args() = %v, want an --sso-session login", got)
	}
}

func TestACachedTokenIsMatchedByStartURL(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"cd7f6d727b4f9ea465d517ca229e5798a21327b2.json": token(
			"https://example.awsapps.com/start", "2030-01-02T03:04:05Z"),
	})

	login := Logins()[0]
	if login.Expires.IsZero() {
		t.Fatal("the CLI names the file after the session, so the URL inside is what must match")
	}
	if !login.SignedIn(time.Date(2029, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Error("a token expiring in 2030 is signed in as of 2029")
	}
	if login.SignedIn(time.Date(2031, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Error("a token expiring in 2030 is not signed in as of 2031")
	}
}

func TestAnUnrelatedCachedTokenIsNotUsed(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"other.json": token("https://someone-else.awsapps.com/start", "2030-01-02T03:04:05Z"),
	})

	if !Logins()[0].Expires.IsZero() {
		t.Error("another organisation's token must not count as signed in")
	}
}

func TestClientRegistrationFilesAreSkipped(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"reg.json":  `{"clientId":"x","clientSecret":"y","expiresAt":"2030-01-02T03:04:05Z"}`,
		"junk.json": `not json at all`,
		"notjson":   token("https://example.awsapps.com/start", "2030-01-02T03:04:05Z"),
	})

	if !Logins()[0].Expires.IsZero() {
		t.Error("only a file with both a startUrl and an accessToken is a session token")
	}
}

func TestTheLatestTokenWinsForAStartURL(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"a.json": token("https://example.awsapps.com/start", "2027-01-01T00:00:00Z"),
		"b.json": token("https://example.awsapps.com/start", "2030-01-01T00:00:00Z"),
	})

	if got := Logins()[0].Expires.Year(); got != 2030 {
		t.Errorf("Expires year = %d, want the later of the two tokens", got)
	}
}

func TestParseExpiryAcceptsBothLayoutsTheCLIHasWritten(t *testing.T) {
	want := time.Date(2030, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, value := range []string{"2030-01-02T03:04:05Z", "2030-01-02T03:04:05UTC"} {
		if got := parseExpiry(value); !got.Equal(want) {
			t.Errorf("parseExpiry(%q) = %v, want %v", value, got, want)
		}
	}
	if got := parseExpiry("whenever"); !got.IsZero() {
		t.Errorf("parseExpiry(rubbish) = %v, want the zero time", got)
	}
}

func TestSignedInIsFalseWithoutTheToken(t *testing.T) {
	if (Login{}).SignedIn(time.Now()) {
		t.Error("no cached token means signed out")
	}
}

func TestLastMeaningfulLinePicksTheEnd(t *testing.T) {
	cases := map[string]string{
		"":                          "",
		"\n\n":                      "",
		"one line":                  "one line",
		"first\nlast\n":             "last",
		"first\nreal error\n\n  \n": "real error",
	}
	for in, want := range cases {
		if got := lastMeaningfulLine(in); got != want {
			t.Errorf("lastMeaningfulLine(%q) = %q, want %q", in, got, want)
		}
	}
}
