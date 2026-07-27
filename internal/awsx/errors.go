package awsx

import (
	"errors"
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/smithy-go"
)

var loginCodes = map[string]bool{
	"ExpiredToken":          true,
	"ExpiredTokenException": true,
	"InvalidGrantException": true,
	"InvalidClientTokenId":  true,
	"UnauthorizedException": true,
}

func profileMissing(err error) bool {
	var missing config.SharedConfigProfileNotExistError
	return errors.As(err, &missing)
}

func needsLogin(err error) bool {
	if err == nil {
		return false
	}
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) && loginCodes[apiErr.ErrorCode()] {
		return true
	}
	msg := err.Error()
	for _, s := range []string{
		"cached SSO token is expired",
		"failed to refresh cached credentials",
		"no EC2 IMDS role found",
		"failed to retrieve credentials",
	} {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}

func Diagnose(profile Profile, err error) error {
	if err == nil {
		return nil
	}

	if profileMissing(err) {
		return fmt.Errorf("AWS profile %q does not exist%s", profile.Name, profileList())
	}

	if needsLogin(err) {
		return fmt.Errorf("not signed in to AWS profile %q%s\n  %s",
			profile.Name, defaulted(profile), loginHint(profile.Name))
	}

	return fmt.Errorf("AWS profile %q: %w", profile.Name, err)
}

func loginHint(name string) string {
	if UsesSSO(name) {
		return "run: aws sso login --profile " + name
	}
	return "its credentials are missing or expired; check ~/.aws/credentials or run: aws configure --profile " + name
}

func defaulted(profile Profile) string {
	if profile.Explicit {
		return ""
	}
	return " (picked by default, no --profile given)"
}

func profileList() string {
	available := Profiles()
	switch {
	case len(available) == 0:
		return "; no profiles found in ~/.aws"
	case len(available) > 8:
		return fmt.Sprintf("; %d profiles available, see: aws configure list-profiles", len(available))
	default:
		return "; available: " + strings.Join(available, ", ")
	}
}
