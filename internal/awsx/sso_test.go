package awsx

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/aws/smithy-go"
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

func refreshableToken(startURL, expires, registrationExpires string) string {
	return `{"startUrl":"` + startURL + `","accessToken":"secret","region":"eu-central-1",` +
		`"expiresAt":"` + expires + `","refreshToken":"renew",` +
		`"registrationExpiresAt":"` + registrationExpires + `"}`
}

const sessionConfig = `
[sso-session company]
sso_start_url = https://example.awsapps.com/start
sso_region = eu-central-1

[profile dev]
sso_session = company
sso_account_id = 1

[profile prod]
sso_session = company
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
	if logins[0].Label() != "company" {
		t.Errorf("Label() = %q, want the session name", logins[0].Label())
	}
	if got := logins[0].Profiles; len(got) != 2 || got[0] != "dev" || got[1] != "prod" {
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
	want := []string{"sso", "login", "--profile", "dev"}
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
	login := Login{Session: "company"}
	got := login.Args()
	if len(got) != 4 || got[2] != "--sso-session" || got[3] != "company" {
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

func TestARefreshableTokenIsReportedAsSuch(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"session.json": refreshableToken(
			"https://example.awsapps.com/start", "2030-01-02T03:04:05Z", "2031-01-01T00:00:00Z"),
	})

	if !Logins()[0].Refreshable {
		t.Error("a refreshToken with a live registration means the SDK renews it silently")
	}
}

func TestAnExpiredAccessTokenIsStillSignedInWhenItCanRenew(t *testing.T) {
	login := Login{
		Expires:     time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
		Refreshable: true,
	}
	if !login.SignedIn(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Error("expiresAt is the access token, not the session; connecting still works")
	}
}

func TestARefreshTokenWithADeadRegistrationDoesNotCount(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"session.json": refreshableToken(
			"https://example.awsapps.com/start", "2020-01-02T03:04:05Z", "2020-06-01T00:00:00Z"),
	})

	login := Logins()[0]
	if login.Refreshable {
		t.Error("the renewal cannot work once the client registration has lapsed")
	}
	if login.SignedIn(time.Now()) {
		t.Error("an expired token that cannot renew is signed out")
	}
}

func TestATokenWithNoRefreshTokenIsNotRefreshable(t *testing.T) {
	awsFiles(t, sessionConfig, "")
	ssoCache(t, map[string]string{
		"session.json": token("https://example.awsapps.com/start", "2030-01-02T03:04:05Z"),
	})

	login := Logins()[0]
	if login.Refreshable {
		t.Error("without a refreshToken the expiry really is the cutoff")
	}
	if !login.SignedIn(time.Date(2029, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Error("still signed in until then, though")
	}
}

func TestForbiddenProvesTheTokenWasAccepted(t *testing.T) {
	err := fmt.Errorf("operation error STS: GetCallerIdentity, failed to retrieve credentials: %w",
		&smithy.GenericAPIError{Code: "ForbiddenException", Message: "No access"})

	if got := classify(err); got != LoginValid {
		t.Errorf("classify(ForbiddenException) = %q, want valid — SSO answered, so the token is live", got)
	}
	if !needsLogin(err) {
		t.Error(
			"this is exactly why classify cannot reuse needsLogin: the wrapper says " +
				"'failed to retrieve credentials' for a profile the user simply has no access to")
	}
}

func TestARejectedTokenIsExpired(t *testing.T) {
	for _, code := range []string{
		"UnauthorizedException", "ExpiredToken", "ExpiredTokenException",
		"InvalidGrantException", "InvalidClientTokenId",
	} {
		err := fmt.Errorf("failed to retrieve credentials: %w",
			&smithy.GenericAPIError{Code: code, Message: "nope"})
		if got := classify(err); got != LoginExpired {
			t.Errorf("classify(%s) = %q, want expired", code, got)
		}
	}
}

func TestAnExpiredCachedTokenIsExpired(t *testing.T) {
	if got := classify(errors.New("cached SSO token is expired")); got != LoginExpired {
		t.Errorf("classify = %q, want expired", got)
	}
	if got := classify(errors.New("failed to refresh cached credentials")); got != LoginExpired {
		t.Errorf("classify = %q, want expired", got)
	}
}

func TestSuccessIsValidAndAnythingElseIsUnknown(t *testing.T) {
	if got := classify(nil); got != LoginValid {
		t.Errorf("classify(nil) = %q, want valid", got)
	}
	for _, err := range []error{
		errors.New("dial tcp: lookup sts.eu-central-1.amazonaws.com: no such host"),
		errors.New("context deadline exceeded"),
		fmt.Errorf("%w", &smithy.GenericAPIError{Code: "Throttling", Message: "slow down"}),
	} {
		if got := classify(err); got != LoginUnknown {
			t.Errorf("classify(%v) = %q, want unknown — being offline is not being signed out", err, got)
		}
	}
}

func TestCheckLoginWithNoProfilesIsUnknown(t *testing.T) {
	if got := CheckLogin(t.Context(), Login{Session: "empty"}); got != LoginUnknown {
		t.Errorf("CheckLogin = %q, want unknown with nothing to try", got)
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
