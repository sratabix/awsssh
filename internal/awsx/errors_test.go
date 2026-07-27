package awsx

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/smithy-go"
)

type apiError struct {
	code string
}

func (e apiError) Error() string                 { return "api: " + e.code }
func (e apiError) ErrorCode() string             { return e.code }
func (e apiError) ErrorMessage() string          { return e.code }
func (e apiError) ErrorFault() smithy.ErrorFault { return smithy.FaultServer }

func TestDiagnoseNil(t *testing.T) {
	if Diagnose(Profile{Name: "x"}, nil) != nil {
		t.Error("Diagnose(nil) must be nil")
	}
}

func TestDiagnoseMissingProfile(t *testing.T) {
	awsFiles(t, "[profile a]\n[profile b]\n", "")

	err := Diagnose(Profile{Name: "nope", Explicit: true},
		fmt.Errorf("wrapped: %w", config.SharedConfigProfileNotExistError{Profile: "nope"}))

	msg := err.Error()
	if !strings.Contains(msg, `profile "nope" does not exist`) {
		t.Errorf("missing the does-not-exist wording: %s", msg)
	}
	if !strings.Contains(msg, "available: a, b") {
		t.Errorf("missing the profile list: %s", msg)
	}
}

func TestDiagnoseMissingProfileWithNoProfilesAtAll(t *testing.T) {
	awsFiles(t, "", "")

	msg := Diagnose(Profile{Name: "nope"}, config.SharedConfigProfileNotExistError{Profile: "nope"}).Error()
	if !strings.Contains(msg, "no profiles found") {
		t.Errorf("want a no-profiles hint, got: %s", msg)
	}
}

func TestDiagnoseListsUpToEightProfilesInline(t *testing.T) {
	var b strings.Builder
	for i := range 8 {
		fmt.Fprintf(&b, "[profile p%d]\n", i)
	}
	awsFiles(t, b.String(), "")

	msg := Diagnose(Profile{Name: "nope"}, config.SharedConfigProfileNotExistError{}).Error()
	if !strings.Contains(msg, "available: p0") {
		t.Errorf("eight profiles should be listed inline: %s", msg)
	}
}

func TestDiagnoseSummarisesMoreThanEightProfiles(t *testing.T) {
	var b strings.Builder
	for i := range 12 {
		fmt.Fprintf(&b, "[profile p%d]\n", i)
	}
	awsFiles(t, b.String(), "")

	msg := Diagnose(Profile{Name: "nope"}, config.SharedConfigProfileNotExistError{}).Error()
	if !strings.Contains(msg, "12 profiles available") {
		t.Errorf("want a count, got: %s", msg)
	}
	if strings.Contains(msg, "p0, p1") {
		t.Errorf("should not inline a long list: %s", msg)
	}
	if !strings.Contains(msg, "aws configure list-profiles") {
		t.Errorf("want a pointer to the AWS CLI: %s", msg)
	}
}

func TestDiagnoseSSOProfileSuggestsSSOLogin(t *testing.T) {
	awsFiles(t, "[profile corp]\nsso_session = s\n", "")

	for _, code := range []string{
		"ExpiredToken",
		"ExpiredTokenException",
		"InvalidGrantException",
		"InvalidClientTokenId",
		"UnauthorizedException",
	} {
		t.Run(code, func(t *testing.T) {
			got := Diagnose(Profile{Name: "corp", Explicit: true}, apiError{code: code}).Error()
			if !strings.Contains(got, "aws sso login --profile corp") {
				t.Errorf("want an sso login hint for %s, got: %s", code, got)
			}
			if !strings.Contains(got, "not signed in") {
				t.Errorf("want the not-signed-in wording, got: %s", got)
			}
		})
	}
}

func TestDiagnoseStaticProfileDoesNotSuggestSSOLogin(t *testing.T) {
	awsFiles(t, "[profile keys]\nregion = eu-west-1\n", "")

	msg := Diagnose(Profile{Name: "keys", Explicit: true}, apiError{code: "InvalidClientTokenId"}).Error()
	if strings.Contains(msg, "aws sso login") {
		t.Errorf("must not suggest sso login for a static profile: %s", msg)
	}
	if !strings.Contains(msg, "aws configure --profile keys") {
		t.Errorf("want an aws configure hint, got: %s", msg)
	}
	if !strings.Contains(msg, "~/.aws/credentials") {
		t.Errorf("want a pointer at the credentials file, got: %s", msg)
	}
}

func TestDiagnoseNotesADefaultedProfile(t *testing.T) {
	awsFiles(t, "[default]\n", "")

	bare := Diagnose(Profile{Name: "default"}, apiError{code: "ExpiredToken"}).Error()
	if !strings.Contains(bare, "picked by default") {
		t.Errorf("want the defaulted note, got: %s", bare)
	}

	explicit := Diagnose(Profile{Name: "default", Explicit: true}, apiError{code: "ExpiredToken"}).Error()
	if strings.Contains(explicit, "picked by default") {
		t.Errorf("must not claim defaulting when explicit: %s", explicit)
	}
}

func TestDiagnoseRecognisesCredentialChainMessages(t *testing.T) {
	awsFiles(t, "[profile corp]\nsso_start_url = https://x\n", "")

	for _, text := range []string{
		"cached SSO token is expired, or not present, and cannot be refreshed",
		"failed to refresh cached credentials",
		"no EC2 IMDS role found",
		"failed to retrieve credentials",
	} {
		t.Run(text[:20], func(t *testing.T) {
			got := Diagnose(Profile{Name: "corp", Explicit: true}, errors.New(text)).Error()
			if !strings.Contains(got, "not signed in") {
				t.Errorf("want not-signed-in for %q, got: %s", text, got)
			}
		})
	}
}

func TestDiagnoseRecognisesAWrappedChainMessage(t *testing.T) {
	awsFiles(t, "[profile corp]\nsso_session = s\n", "")

	cause := fmt.Errorf("operation error STS: %w", errors.New("cached SSO token is expired"))
	if got := Diagnose(Profile{Name: "corp", Explicit: true}, cause).Error(); !strings.Contains(got, "not signed in") {
		t.Errorf("want not-signed-in, got: %s", got)
	}
}

func TestDiagnosePassesThroughUnrelatedErrors(t *testing.T) {
	awsFiles(t, "[default]\n", "")

	cause := apiError{code: "UnauthorizedOperation"}
	msg := Diagnose(Profile{Name: "default", Explicit: true}, cause).Error()
	if strings.Contains(msg, "not signed in") || strings.Contains(msg, "does not exist") {
		t.Errorf("misclassified a permissions error: %s", msg)
	}
	if !strings.Contains(msg, `profile "default"`) {
		t.Errorf("should still name the profile: %s", msg)
	}
	if !errors.Is(Diagnose(Profile{Name: "default"}, cause), cause) {
		t.Error("unrelated errors must stay unwrappable")
	}
}

func TestDiagnoseMissingProfileBeatsLoginClassification(t *testing.T) {
	awsFiles(t, "[profile a]\n", "")

	cause := fmt.Errorf("%w: cached SSO token is expired",
		config.SharedConfigProfileNotExistError{Profile: "ghost"})
	msg := Diagnose(Profile{Name: "ghost", Explicit: true}, cause).Error()
	if !strings.Contains(msg, "does not exist") {
		t.Errorf("a missing profile is the more useful diagnosis: %s", msg)
	}
	if strings.Contains(msg, "not signed in") {
		t.Errorf("should not also claim a sign-in problem: %s", msg)
	}
}

func TestNeedsLoginRejectsNil(t *testing.T) {
	if needsLogin(nil) {
		t.Error("needsLogin(nil) must be false")
	}
}

func TestNeedsLoginIgnoresUnrelatedCodes(t *testing.T) {
	for _, code := range []string{"AccessDeniedException", "UnauthorizedOperation", "Throttling", ""} {
		if needsLogin(apiError{code: code}) {
			t.Errorf("%q must not be treated as a sign-in problem", code)
		}
	}
}

func TestProfileMissingRejectsUnrelatedErrors(t *testing.T) {
	if profileMissing(errors.New("something else")) {
		t.Error("plain errors are not a missing profile")
	}
	if profileMissing(nil) {
		t.Error("nil is not a missing profile")
	}
}
