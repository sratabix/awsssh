package awsx

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Profile struct {
	Name     string
	Source   string
	Explicit bool
}

func ResolveProfile(flag string) Profile {
	if flag != "" {
		return Profile{Name: flag, Source: "--profile", Explicit: true}
	}
	for _, key := range []string{"AWS_PROFILE", "AWS_DEFAULT_PROFILE"} {
		if v := os.Getenv(key); v != "" {
			return Profile{Name: v, Source: key, Explicit: true}
		}
	}
	return Profile{Name: "default", Source: "no --profile given"}
}

func Profiles() []string {
	seen := map[string]bool{}
	var out []string
	add := func(name string) {
		if name != "" && !seen[name] {
			seen[name] = true
			out = append(out, name)
		}
	}
	for _, s := range parseSections(configPath()) {
		if name, ok := configProfileName(s.name); ok {
			add(name)
		}
	}
	for _, s := range parseSections(credentialsPath()) {
		add(s.name)
	}
	sort.Strings(out)
	return out
}

func UsesSSO(name string) bool {
	for _, s := range parseSections(configPath()) {
		got, ok := configProfileName(s.name)
		if !ok || got != name {
			continue
		}
		for _, key := range []string{"sso_session", "sso_start_url", "sso_account_id"} {
			if s.keys[key] != "" {
				return true
			}
		}
	}
	return false
}

func configPath() string {
	home, _ := os.UserHomeDir()
	return envOr("AWS_CONFIG_FILE", filepath.Join(home, ".aws", "config"))
}

func credentialsPath() string {
	home, _ := os.UserHomeDir()
	return envOr("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(home, ".aws", "credentials"))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func configProfileName(section string) (string, bool) {
	if section == "default" {
		return section, true
	}
	if rest, ok := strings.CutPrefix(section, "profile "); ok {
		name := strings.TrimSpace(rest)
		return name, name != ""
	}
	return "", false
}

type iniSection struct {
	name string
	keys map[string]string
}

func parseSections(path string) []iniSection {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()

	var out []iniSection
	var current *iniSection
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			out = append(out, iniSection{
				name: strings.TrimSpace(line[1 : len(line)-1]),
				keys: map[string]string{},
			})
			current = &out[len(out)-1]
			continue
		}
		if current == nil {
			continue
		}
		if key, value, ok := strings.Cut(line, "="); ok {
			current.keys[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return out
}
