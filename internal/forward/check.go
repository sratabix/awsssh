package forward

import (
	"context"
	"fmt"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/session"
)

func (m *Manager) Check(ctx context.Context, s Spec) (string, error) {
	if err := checkLocalPort(s.LocalPort); err != nil {
		return "", err
	}
	if err := session.Available(); err != nil {
		return "", err
	}
	b, err := m.provider.Get(s.Profile, s.Region)
	if err != nil {
		return "", err
	}
	target, err := b.Client.LookupRunning(ctx, s.Instance)
	if err != nil {
		return "", err
	}
	agent, agentErr := b.Starter.Describe(ctx, target.InstanceID)
	if err := agentFailure(target, b.Client.Region, agent, agentErr == nil); err != nil {
		return "", err
	}
	if err := m.probe(ctx, b, target.InstanceID, s); err != nil {
		return "", err
	}
	return checkDetail(target, b.Client.Region, s), nil
}

func instanceLabel(i awsx.Instance) string {
	if i.Name == "" || i.Name == i.InstanceID {
		return i.InstanceID
	}
	return i.Name + " (" + i.InstanceID + ")"
}

func agentFailure(i awsx.Instance, region string, agent session.Agent, checked bool) error {
	label := instanceLabel(i)
	switch {
	case !checked:
		return nil
	case !agent.Registered:
		return fmt.Errorf(
			"%s is running in %s but is not registered with SSM; "+
				"check the SSM agent and the instance profile", label, region)
	case !agent.Online():
		return fmt.Errorf("%s is running in %s but its SSM agent reports %s, not Online",
			label, region, agent.Status())
	default:
		return nil
	}
}

func checkDetail(i awsx.Instance, region string, s Spec) string {
	summary := fmt.Sprintf("%s in %s answered on %s", instanceLabel(i), region, targetName(s))
	if s.LocalPort == "" {
		return summary
	}
	return summary + fmt.Sprintf(", and local port %s is free", s.LocalPort)
}
