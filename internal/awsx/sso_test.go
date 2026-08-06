package awsx

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
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

func TestLabelPrefersTheSessionThenAProfileThenTheURL(t *testing.T) {
	withSession := Login{Session: "company", Profiles: []string{"dev"}, StartURL: "https://x/start"}
	if got := withSession.Label(); got != "company" {
		t.Errorf("got %q, want the session name", got)
	}

	legacy := Login{Profiles: []string{"dev", "prod"}, StartURL: "https://x/start"}
	if got := legacy.Label(); got != "dev" {
		t.Errorf("got %q, want the first profile for a session-less login", got)
	}

	bare := Login{StartURL: "https://x/start"}
	if got := bare.Label(); got != "https://x/start" {
		t.Errorf("got %q, want the start URL as the last resort", got)
	}

	if got := (Login{}).Label(); got != "" {
		t.Errorf("got %q, want empty for a zero Login", got)
	}
}

func TestSignedInMatrix(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name  string
		login Login
		want  bool
	}{
		{"no expiry, not refreshable", Login{}, false},
		{"future expiry", Login{Expires: now.Add(time.Hour)}, true},
		{"past expiry", Login{Expires: now.Add(-time.Hour)}, false},
		{"exactly now is not after now", Login{Expires: now}, false},
		{"refreshable with no expiry", Login{Refreshable: true}, true},
		{"refreshable beats a lapsed access token", Login{Expires: now.Add(-time.Hour), Refreshable: true}, true},
	}
	for _, c := range cases {
		if got := c.login.SignedIn(now); got != c.want {
			t.Errorf("%s: SignedIn = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestArgsNeverProducesAnEmptyTarget(t *testing.T) {
	for _, l := range []Login{
		{Profiles: []string{"dev"}},
		{Session: "company"},
		{Session: "company", Profiles: []string{"dev"}},
	} {
		args := l.Args()
		if len(args) < 2 || args[len(args)-1] == "" {
			t.Errorf("Args() = %v, want a non-empty target", args)
		}
		if args[0] != "sso" || args[1] != "login" {
			t.Errorf("Args() = %v, want it to start with sso login", args)
		}
	}
}

func TestCachedTokensSkipsUnparseableFiles(t *testing.T) {
	now := time.Now().UTC()
	ssoCache(t, map[string]string{
		"broken.json": "{not json at all",
		"empty.json":  "",
		"good.json":   token("https://good.example/start", now.Add(time.Hour).Format(time.RFC3339)),
	})

	tokens := cachedTokens(now)
	if len(tokens) != 1 {
		t.Fatalf("got %d tokens, want only the readable one: %v", len(tokens), tokens)
	}
	if _, ok := tokens["https://good.example/start"]; !ok {
		t.Errorf("tokens = %v, want the good start URL", tokens)
	}
}

func TestCachedTokensIgnoresNonJSONFilesAndDirectories(t *testing.T) {
	now := time.Now().UTC()
	ssoCache(t, map[string]string{
		"notes.txt":  token("https://ignored.example/start", now.Add(time.Hour).Format(time.RFC3339)),
		"token.JSON": token("https://also-ignored.example/start", now.Add(time.Hour).Format(time.RFC3339)),
		"real.json":  token("https://real.example/start", now.Add(time.Hour).Format(time.RFC3339)),
	})
	sub := filepath.Join(os.Getenv("HOME"), ".aws", "sso", "cache", "nested.json")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}

	tokens := cachedTokens(now)
	if len(tokens) != 1 {
		t.Fatalf("got %d tokens, want only real.json: %v", len(tokens), tokens)
	}
}

func TestCachedTokensWithNoCacheDirectoryIsEmpty(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if got := cachedTokens(time.Now()); len(got) != 0 {
		t.Errorf("got %v, want nothing when the cache does not exist", got)
	}
}

func TestCachedTokensSkipsAnEntryMissingTheAccessToken(t *testing.T) {
	now := time.Now().UTC()
	expires := now.Add(time.Hour).Format(time.RFC3339)
	ssoCache(t, map[string]string{
		"reg.json":   `{"startUrl":"https://x.example/start","expiresAt":"` + expires + `"}`,
		"tok.json":   token("https://y.example/start", expires),
		"nourl.json": `{"accessToken":"secret","expiresAt":"` + expires + `"}`,
	})

	tokens := cachedTokens(now)
	if len(tokens) != 1 {
		t.Fatalf("got %d tokens, want only the complete one: %v", len(tokens), tokens)
	}
	if _, ok := tokens["https://y.example/start"]; !ok {
		t.Errorf("tokens = %v, want the entry that had both fields", tokens)
	}
}

func TestParseExpiryRejectsGarbage(t *testing.T) {
	for _, value := range []string{"", "not a date", "2026-13-45T99:99:99Z", "1700000000"} {
		if got := parseExpiry(value); !got.IsZero() {
			t.Errorf("parseExpiry(%q) = %v, want the zero time", value, got)
		}
	}
}

func TestParseExpiryNormalisesToUTC(t *testing.T) {
	got := parseExpiry("2026-07-31T14:00:00+02:00")
	if got.Location() != time.UTC {
		t.Errorf("location = %v, want UTC so comparisons are consistent", got.Location())
	}
	if got.Hour() != 12 {
		t.Errorf("hour = %d, want 12 after the offset is applied", got.Hour())
	}
}

func TestLoginsDropsASessionWithNoProfiles(t *testing.T) {
	awsFiles(t, "[sso-session lonely]\nsso_start_url = https://lonely.example/start\nsso_region = eu-west-1\n", "")
	for _, l := range Logins() {
		if l.Session == "lonely" {
			t.Error("a login that reaches no profile is noise and must be dropped")
		}
	}
}

func TestLoginsSortProfilesSoTheChosenLoginIsDeterministic(t *testing.T) {
	awsFiles(t, `
[sso-session company]
sso_start_url = https://example.awsapps.com/start
sso_region = eu-central-1

[profile zeta]
sso_session = company

[profile alpha]
sso_session = company
`, "")
	logins := Logins()
	if len(logins) != 1 {
		t.Fatalf("got %d logins, want 1", len(logins))
	}
	if !slices.IsSorted(logins[0].Profiles) {
		t.Errorf("profiles = %v, want them sorted so Args() cannot depend on file order", logins[0].Profiles)
	}
	if logins[0].Args()[3] != "alpha" {
		t.Errorf("Args() = %v, want the first sorted profile", logins[0].Args())
	}
}

func TestLoginsAreSortedByLabel(t *testing.T) {
	awsFiles(t, `
[sso-session zebra]
sso_start_url = https://z.example/start

[profile z1]
sso_session = zebra

[sso-session apple]
sso_start_url = https://a.example/start

[profile a1]
sso_session = apple
`, "")
	logins := Logins()
	if len(logins) != 2 {
		t.Fatalf("got %d logins, want 2", len(logins))
	}
	labels := []string{logins[0].Label(), logins[1].Label()}
	if !slices.IsSorted(labels) {
		t.Errorf("labels = %v, want them sorted", labels)
	}
}

func TestLoginsIgnoresADuplicateSessionBlock(t *testing.T) {
	awsFiles(t, `
[sso-session company]
sso_start_url = https://first.example/start

[sso-session company]
sso_start_url = https://second.example/start

[profile p]
sso_session = company
`, "")
	logins := Logins()
	if len(logins) != 1 {
		t.Fatalf("got %d logins, want 1", len(logins))
	}
	if logins[0].StartURL != "https://first.example/start" {
		t.Errorf("StartURL = %q, want the first block to win", logins[0].StartURL)
	}
}

func TestLoginsIgnoresAProfilePointingAtAnUnknownSession(t *testing.T) {
	awsFiles(t, "[profile orphan]\nsso_session = nonexistent\n", "")
	if got := Logins(); len(got) != 0 {
		t.Errorf("got %v, want nothing for a profile whose session is not defined", got)
	}
}

func TestCachedTokensSkipsAFileItCannotRead(t *testing.T) {
	now := time.Now().UTC()
	expires := now.Add(time.Hour).Format(time.RFC3339)
	ssoCache(t, map[string]string{
		"locked.json":   token("https://locked.example/start", expires),
		"readable.json": token("https://readable.example/start", expires),
	})

	locked := filepath.Join(os.Getenv("HOME"), ".aws", "sso", "cache", "locked.json")
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o600) })

	if os.Geteuid() == 0 {
		t.Skip("root can read a 0000 file, so there is nothing to skip over")
	}

	tokens := cachedTokens(now)
	if _, ok := tokens["https://readable.example/start"]; !ok {
		t.Errorf("tokens = %v; one unreadable file must not lose the others", tokens)
	}
	if _, ok := tokens["https://locked.example/start"]; ok {
		t.Error("an unreadable file must be skipped, not guessed at")
	}
}

func TestCheckLoginWalksSeveralProfilesAndStaysUnknownWhenNoneAnswer(t *testing.T) {
	awsFiles(t, "", "")

	login := Login{
		Session:  "company",
		StartURL: "https://example.awsapps.com/start",
		Region:   "eu-central-1",
		Profiles: []string{"ghost-1", "ghost-2", "ghost-3", "ghost-4", "ghost-5"},
	}

	done := make(chan LoginState, 1)
	go func() { done <- CheckLogin(t.Context(), login) }()

	select {
	case got := <-done:
		if got != LoginUnknown {
			t.Errorf("state = %q; profiles that cannot even be resolved prove nothing", got)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("CheckLogin must stop at checkProfileLimit rather than walking every profile")
	}
}

func TestCheckLoginOnALoginWithOneBogusProfileIsUnknown(t *testing.T) {
	awsFiles(t, "", "")
	login := Login{Session: "company", Profiles: []string{"ghost"}, Region: "eu-central-1"}
	if got := CheckLogin(t.Context(), login); got != LoginUnknown {
		t.Errorf("state = %q, want unknown", got)
	}
}

func FuzzParseExpiryNeverPanicsAndIsAlwaysUTC(f *testing.F) {
	f.Add("2026-07-31T12:00:00Z")
	f.Add("2026-07-31T12:00:00UTC")
	f.Add("")
	f.Add("garbage")
	f.Add("2026-07-31T14:00:00+02:00")

	f.Fuzz(func(t *testing.T, value string) {
		if len(value) > 4096 {
			t.Skip()
		}
		got := parseExpiry(value)
		if got.IsZero() {
			return
		}
		if got.Location() != time.UTC {
			t.Errorf("parseExpiry(%q) = %v is not UTC; comparisons rely on it", value, got)
		}
	})
}

func FuzzLoginLabelAndArgsAreAlwaysUsable(f *testing.F) {
	f.Add("company", "https://x.example/start", "dev")
	f.Add("", "https://x.example/start", "dev")
	f.Add("", "", "")
	f.Add("company", "", "")

	f.Fuzz(func(t *testing.T, session, url, profile string) {
		if len(session) > 512 || len(url) > 512 || len(profile) > 512 {
			t.Skip()
		}
		login := Login{Session: session, StartURL: url}
		if profile != "" {
			login.Profiles = []string{profile}
		}

		args := login.Args()
		if len(args) != 4 {
			t.Fatalf("Args() = %v, want four elements", args)
		}
		if args[0] != "sso" || args[1] != "login" {
			t.Errorf("Args() = %v must start with sso login", args)
		}
		if args[2] != "--profile" && args[2] != "--sso-session" {
			t.Errorf("Args() = %v used an unexpected flag", args)
		}
		if args[2] == "--profile" && args[3] != profile {
			t.Errorf("Args() = %v did not pass the profile through", args)
		}
	})
}

func FuzzSignedInAgreesWithItsInputs(f *testing.F) {
	f.Add(int64(0), false)
	f.Add(int64(3600), false)
	f.Add(int64(-3600), true)

	f.Fuzz(func(t *testing.T, offset int64, refreshable bool) {
		if offset < -1<<40 || offset > 1<<40 {
			t.Skip()
		}
		now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
		login := Login{Expires: now.Add(time.Duration(offset) * time.Second), Refreshable: refreshable}

		got := login.SignedIn(now)
		want := refreshable || offset > 0
		if got != want {
			t.Errorf("SignedIn with offset %ds refreshable=%v = %v, want %v",
				offset, refreshable, got, want)
		}
	})
}

const scopedSessionConfig = `
[sso-session company]
sso_start_url = https://example.awsapps.com/start
sso_region = eu-central-1
sso_registration_scopes = sso:account:access

[profile dev]
sso_session = company
sso_account_id = 1
`

func TestLoginsReportWhetherTheSessionIsRegisteredForRefresh(t *testing.T) {
	for _, tc := range []struct {
		name   string
		config string
		want   bool
	}{
		{"with the scope", scopedSessionConfig, true},
		{"without the scope", sessionConfig, false},
		{"legacy start url", "[profile main]\nsso_start_url = https://legacy.awsapps.com/start\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			awsFiles(t, tc.config, "")
			ssoCache(t, nil)

			logins := Logins()
			if len(logins) == 0 {
				t.Fatal("want at least one login")
			}
			if logins[0].Scoped != tc.want {
				t.Errorf("Scoped = %v, want %v", logins[0].Scoped, tc.want)
			}
		})
	}
}

func TestTheLoginHandsTheURLToUsInsteadOfABrowser(t *testing.T) {
	base := []string{"PATH=/usr/bin"}
	got := loginEnviron(base)

	if len(got) != 2 {
		t.Fatalf("got %v, want the base plus one entry", got)
	}
	value, ok := strings.CutPrefix(got[1], browserEnvKey+"=")
	if !ok {
		t.Fatalf("last entry = %q, want a %s assignment", got[1], browserEnvKey)
	}
	if !strings.Contains(value, urlMarker) {
		t.Errorf("%s = %q, must echo the marker we scan for", browserEnvKey, value)
	}
	if !strings.Contains(value, "%s") {
		t.Errorf("%s = %q, must carry %%s or the URL is never substituted", browserEnvKey, value)
	}
	if strings.Contains(value, "open") {
		t.Errorf("%s = %q, no sign-in may reach a real browser any more", browserEnvKey, value)
	}
	if !slices.Equal(base, []string{"PATH=/usr/bin"}) {
		t.Errorf("the caller's environment was mutated: %v", base)
	}
}

func TestOurBrowserSettingWinsOverAnInheritedOne(t *testing.T) {
	got := loginEnviron([]string{browserEnvKey + "=/usr/bin/open"})

	if len(got) != 2 || !strings.Contains(got[1], urlMarker) {
		t.Errorf("ours must come last so exec's dedup keeps it, got %v", got)
	}
}

func TestAuthorizeURLOnlyAcceptsOurOwnMarkerLine(t *testing.T) {
	good := urlMarker + " https://oidc.eu-central-1.amazonaws.com/authorize?x=1"
	if url, ok := authorizeURL(good); !ok || url != "https://oidc.eu-central-1.amazonaws.com/authorize?x=1" {
		t.Errorf("authorizeURL(%q) = %q, %v", good, url, ok)
	}

	for _, line := range []string{
		"",
		"Attempting to open your default browser",
		urlMarker,
		urlMarker + " not-a-url",
		urlMarker + " http://insecure.example",
		urlMarker + " https://ok.example extra",
		"prefix " + urlMarker + " https://ok.example",
	} {
		if url, ok := authorizeURL(line); ok {
			t.Errorf("authorizeURL(%q) accepted %q, want rejected", line, url)
		}
	}
}
