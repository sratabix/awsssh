package session

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

const (
	pluginBinary = "session-manager-plugin"

	docToInstance   = "AWS-StartPortForwardingSession"
	docToRemoteHost = "AWS-StartPortForwardingSessionToRemoteHost"
)

type Forward struct {
	LocalPort  string
	Host       string
	RemotePort string
}

type Starter struct {
	ssm     *ssm.Client
	region  string
	profile string
}

func New(cfg aws.Config, region, profile string) *Starter {
	return &Starter{
		ssm:     ssm.NewFromConfig(cfg),
		region:  region,
		profile: profile,
	}
}

func Available() error {
	if _, err := exec.LookPath(pluginBinary); err != nil {
		return fmt.Errorf("%s not found in PATH; install the AWS Session Manager plugin", pluginBinary)
	}
	return nil
}

func (s *Starter) StartShell(ctx context.Context, instanceID string) error {
	args, err := s.pluginArgs(ctx, instanceID, "", nil)
	if err != nil {
		return err
	}

	runCtx, stop := shellContext(ctx)
	defer stop()

	cmd := pluginCommand(runCtx, args)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func shellContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.WithoutCancel(ctx), syscall.SIGTERM)
}

func forwardDocument(f Forward) (string, map[string][]string) {
	parameters := map[string][]string{
		"portNumber":      {f.RemotePort},
		"localPortNumber": {f.LocalPort},
	}
	if f.Host == "" {
		return docToInstance, parameters
	}
	parameters["host"] = []string{f.Host}
	return docToRemoteHost, parameters
}

func pluginPayload(target, document string, parameters map[string][]string) map[string]any {
	payload := map[string]any{"Target": target}
	if document != "" {
		payload["DocumentName"] = document
	}
	if parameters != nil {
		payload["Parameters"] = parameters
	}
	return payload
}

func (s *Starter) ForwardCommand(ctx context.Context, instanceID string, f Forward) (*exec.Cmd, error) {
	document, parameters := forwardDocument(f)
	args, err := s.pluginArgs(ctx, instanceID, document, parameters)
	if err != nil {
		return nil, err
	}
	return pluginCommand(ctx, args), nil
}

func pluginCommand(ctx context.Context, args []string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, pluginBinary, args...)
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGINT) }
	cmd.WaitDelay = 5 * time.Second
	return cmd
}

func (s *Starter) pluginArgs(
	ctx context.Context,
	target, document string,
	parameters map[string][]string,
) ([]string, error) {
	params := pluginPayload(target, document, parameters)
	input := &ssm.StartSessionInput{Target: aws.String(target)}
	if document != "" {
		input.DocumentName = aws.String(document)
	}
	if parameters != nil {
		input.Parameters = parameters
	}

	out, err := s.ssm.StartSession(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("start session: %w", err)
	}

	response, err := json.Marshal(map[string]any{
		"SessionId":  aws.ToString(out.SessionId),
		"StreamUrl":  aws.ToString(out.StreamUrl),
		"TokenValue": aws.ToString(out.TokenValue),
	})
	if err != nil {
		return nil, err
	}
	paramsJSON, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}

	endpoint := fmt.Sprintf("https://ssm.%s.amazonaws.com", s.region)
	return []string{
		string(response),
		s.region,
		"StartSession",
		s.profile,
		string(paramsJSON),
		endpoint,
	}, nil
}
