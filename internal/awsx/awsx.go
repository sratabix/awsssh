package awsx

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

type Client struct {
	cfg     aws.Config
	Region  string
	Profile Profile
	ec2     *ec2.Client
	sts     *sts.Client
}

type Instance struct {
	Name         string
	InstanceID   string
	PrivateIP    string
	PublicIP     string
	State        string
	InstanceType string
}

func (i Instance) Key() string {
	if i.Name != "" {
		return i.Name
	}
	return i.InstanceID
}

func New(ctx context.Context, profile, region string) (*Client, error) {
	resolved := ResolveProfile(profile)

	opts := []func(*config.LoadOptions) error{}
	if profile != "" {
		opts = append(opts, config.WithSharedConfigProfile(profile))
	}
	if region != "" {
		opts = append(opts, config.WithRegion(region))
	}

	cfg, err := config.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, Diagnose(resolved, err)
	}

	return &Client{
		cfg:     cfg,
		Region:  cfg.Region,
		Profile: resolved,
		ec2:     ec2.NewFromConfig(cfg),
		sts:     sts.NewFromConfig(cfg),
	}, nil
}

func (c *Client) Verify(ctx context.Context) error {
	_, err := c.sts.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	return Diagnose(c.Profile, err)
}

func (c *Client) Lookup(ctx context.Context, filter string) ([]Instance, error) {
	instances, err := c.DescribeInstances(ctx, filter)
	if err != nil {
		return nil, Diagnose(c.Profile, err)
	}
	if len(instances) == 0 {
		return nil, emptyLookupError(filter, c.Region)
	}
	return instances, nil
}

func (c *Client) LookupRunning(ctx context.Context, filter string) (Instance, error) {
	instances, err := c.Lookup(ctx, filter)
	if err != nil {
		return Instance{}, err
	}
	return firstRunning(instances)
}

func emptyLookupError(filter, region string) error {
	if filter != "" {
		return fmt.Errorf("no instance matched %q in %s", filter, region)
	}
	return fmt.Errorf("no instances found in %s", region)
}

func firstRunning(instances []Instance) (Instance, error) {
	for _, inst := range instances {
		if inst.State == "running" {
			return inst, nil
		}
	}
	if len(instances) == 0 {
		return Instance{}, errors.New("no instances to choose from")
	}
	return Instance{}, NotRunning(instances[0])
}

func NotRunning(i Instance) error {
	return fmt.Errorf("instance %s is %s, not running", i.Key(), i.State)
}

func describeInput(filter string) *ec2.DescribeInstancesInput {
	input := &ec2.DescribeInstancesInput{}
	switch {
	case filter == "":
	case strings.HasPrefix(filter, "i-") && len(filter) > 2:
		input.InstanceIds = []string{filter}
	default:
		input.Filters = []ec2types.Filter{{
			Name:   aws.String("tag:Name"),
			Values: []string{filter},
		}}
	}
	return input
}

func (c *Client) DescribeInstances(ctx context.Context, filter string) ([]Instance, error) {
	input := describeInput(filter)

	var instances []Instance
	paginator := ec2.NewDescribeInstancesPaginator(c.ec2, input)
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, r := range page.Reservations {
			for _, inst := range r.Instances {
				instances = append(instances, flatten(inst))
			}
		}
	}

	sortInstances(instances)
	return instances, nil
}

func sortInstances(instances []Instance) {
	sort.SliceStable(instances, func(i, j int) bool {
		return instances[i].Name < instances[j].Name
	})
}

func flatten(inst ec2types.Instance) Instance {
	out := Instance{
		InstanceID:   aws.ToString(inst.InstanceId),
		PrivateIP:    aws.ToString(inst.PrivateIpAddress),
		PublicIP:     aws.ToString(inst.PublicIpAddress),
		InstanceType: string(inst.InstanceType),
	}
	if inst.State != nil {
		out.State = string(inst.State.Name)
	}
	for _, tag := range inst.Tags {
		if aws.ToString(tag.Key) == "Name" {
			out.Name = aws.ToString(tag.Value)
			break
		}
	}
	return out
}

func (c *Client) Config() aws.Config { return c.cfg }
