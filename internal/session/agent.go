package session

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

type Agent struct {
	Registered bool
	Ping       string
}

func (a Agent) Online() bool { return a.Ping == string(ssmtypes.PingStatusOnline) }

func (a Agent) Status() string {
	if a.Ping == "" {
		return "not reporting"
	}
	return a.Ping
}

func (s *Starter) Describe(ctx context.Context, instanceID string) (Agent, error) {
	out, err := s.ssm.DescribeInstanceInformation(ctx, &ssm.DescribeInstanceInformationInput{
		Filters: []ssmtypes.InstanceInformationStringFilter{{
			Key:    aws.String("InstanceIds"),
			Values: []string{instanceID},
		}},
	})
	if err != nil {
		return Agent{}, fmt.Errorf("ssm:DescribeInstanceInformation: %w", err)
	}
	for _, info := range out.InstanceInformationList {
		if aws.ToString(info.InstanceId) != instanceID {
			continue
		}
		return Agent{Registered: true, Ping: string(info.PingStatus)}, nil
	}
	return Agent{}, nil
}
