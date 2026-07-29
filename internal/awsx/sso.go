package awsx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aws/smithy-go"
)

const (
	awsBinary    = "aws"
	loginTimeout = 3 * time.Minute
)

type Login struct {
	Session     string
	StartURL    string
	Region      string
	Profiles    []string
	Expires     time.Time
	Refreshable bool
}

func (l Login) Label() string {
	if l.Session != "" {
		return l.Session
	}
	if len(l.Profiles) > 0 {
		return l.Profiles[0]
	}
	return l.StartURL
}

func (l Login) Args() []string {
	if len(l.Profiles) > 0 {
		return []string{"sso", "login", "--profile", l.Profiles[0]}
	}
	return []string{"sso", "login", "--sso-session", l.Session}
}

func (l Login) SignedIn(now time.Time) bool {
	return l.Refreshable || (!l.Expires.IsZero() && l.Expires.After(now))
}

func Logins() []Login {
	sections := parseSections(configPath())
	sessions := map[string]*Login{}
	byURL := map[string]*Login{}
	var order []*Login

	for _, s := range sections {
		name, ok := strings.CutPrefix(s.name, "sso-session ")
		if !ok {
			continue
		}
		if name = strings.TrimSpace(name); name == "" || sessions[name] != nil {
			continue
		}
		sessions[name] = &Login{
			Session:  name,
			StartURL: s.keys["sso_start_url"],
			Region:   s.keys["sso_region"],
		}
		order = append(order, sessions[name])
	}

	for _, s := range sections {
		name, ok := configProfileName(s.name)
		if !ok {
			continue
		}
		if session := s.keys["sso_session"]; session != "" {
			if login := sessions[session]; login != nil {
				login.Profiles = append(login.Profiles, name)
			}
			continue
		}
		url := s.keys["sso_start_url"]
		if url == "" {
			continue
		}
		login := byURL[url]
		if login == nil {
			login = &Login{StartURL: url, Region: s.keys["sso_region"]}
			byURL[url] = login
			order = append(order, login)
		}
		login.Profiles = append(login.Profiles, name)
	}

	tokens := cachedTokens(time.Now())
	out := make([]Login, 0, len(order))
	for _, login := range order {
		if len(login.Profiles) == 0 {
			continue
		}
		sort.Strings(login.Profiles)
		token := tokens[login.StartURL]
		login.Expires = token.expires
		login.Refreshable = token.refreshable
		out = append(out, *login)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Label() < out[j].Label() })
	return out
}

type LoginState string

const (
	LoginUnknown LoginState = "unknown"
	LoginValid   LoginState = "valid"
	LoginExpired LoginState = "expired"
)

const checkProfileLimit = 3

var tokenAccepted = map[string]bool{
	"ForbiddenException":    true,
	"AccessDenied":          true,
	"AccessDeniedException": true,
}

var tokenRejected = map[string]bool{
	"UnauthorizedException": true,
	"ExpiredToken":          true,
	"ExpiredTokenException": true,
	"InvalidGrantException": true,
	"InvalidClientTokenId":  true,
}

func CheckLogin(ctx context.Context, login Login) LoginState {
	for i, profile := range login.Profiles {
		if i == checkProfileLimit {
			break
		}
		if state := checkProfile(ctx, profile, login.Region); state != LoginUnknown {
			return state
		}
	}
	return LoginUnknown
}

func checkProfile(ctx context.Context, profile, region string) LoginState {
	client, err := New(ctx, profile, region)
	if err != nil {
		return LoginUnknown
	}
	return classify(client.callerIdentity(ctx))
}

func classify(err error) LoginState {
	if err == nil {
		return LoginValid
	}
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		switch {
		case tokenAccepted[apiErr.ErrorCode()]:
			return LoginValid
		case tokenRejected[apiErr.ErrorCode()]:
			return LoginExpired
		}
	}
	for _, signal := range []string{
		"cached SSO token is expired",
		"failed to refresh cached credentials",
	} {
		if strings.Contains(err.Error(), signal) {
			return LoginExpired
		}
	}
	return LoginUnknown
}

var loginRunning sync.Mutex

func RunSSOLogin(ctx context.Context, login Login) error {
	if !loginRunning.TryLock() {
		return errors.New("a sign-in is already in progress")
	}
	defer loginRunning.Unlock()

	path, err := exec.LookPath(awsBinary)
	if err != nil {
		return errors.New("the AWS CLI is not installed; install it with: brew install awscli")
	}

	timed, cancel := context.WithTimeout(ctx, loginTimeout)
	defer cancel()

	combined, err := exec.CommandContext(timed, path, login.Args()...).CombinedOutput()
	switch {
	case err == nil:
		return nil
	case errors.Is(timed.Err(), context.DeadlineExceeded):
		return fmt.Errorf(
			"sign-in was not completed within %s; approve the page the browser opened",
			loginTimeout)
	case ctx.Err() != nil:
		return errors.New("sign-in was cancelled")
	default:
		if msg := lastMeaningfulLine(string(combined)); msg != "" {
			return errors.New(msg)
		}
		return fmt.Errorf("aws sso login failed: %w", err)
	}
}

func lastMeaningfulLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if line := strings.TrimSpace(lines[i]); line != "" {
			return line
		}
	}
	return ""
}

type cachedToken struct {
	StartURL              string `json:"startUrl"`
	AccessToken           string `json:"accessToken"`
	ExpiresAt             string `json:"expiresAt"`
	RefreshToken          string `json:"refreshToken"`
	RegistrationExpiresAt string `json:"registrationExpiresAt"`
}

type sessionToken struct {
	expires     time.Time
	refreshable bool
}

func ssoCacheDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".aws", "sso", "cache")
}

func cachedTokens(now time.Time) map[string]sessionToken {
	dir := ssoCacheDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	out := map[string]sessionToken{}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		var token cachedToken
		if err := json.Unmarshal(data, &token); err != nil {
			continue
		}
		if token.StartURL == "" || token.AccessToken == "" {
			continue
		}
		found := sessionToken{
			expires: parseExpiry(token.ExpiresAt),
			refreshable: token.RefreshToken != "" &&
				parseExpiry(token.RegistrationExpiresAt).After(now),
		}
		if found.expires.After(out[token.StartURL].expires) {
			out[token.StartURL] = found
		}
	}
	return out
}

func parseExpiry(value string) time.Time {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05UTC"} {
		if t, err := time.Parse(layout, value); err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}
