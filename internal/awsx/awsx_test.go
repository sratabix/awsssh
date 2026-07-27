package awsx

import (
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

func TestInstanceKeyPrefersName(t *testing.T) {
	cases := []struct {
		name string
		in   Instance
		want string
	}{
		{"name wins", Instance{Name: "web", InstanceID: "i-1"}, "web"},
		{"falls back to id", Instance{InstanceID: "i-1"}, "i-1"},
		{"blank name falls back", Instance{Name: "", InstanceID: "i-2"}, "i-2"},
		{"both empty", Instance{}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.in.Key(); got != c.want {
				t.Errorf("Key() = %q, want %q", got, c.want)
			}
		})
	}
}

func TestDescribeInputByInstanceID(t *testing.T) {
	in := describeInput("i-0abc123")
	if !slices.Equal(in.InstanceIds, []string{"i-0abc123"}) {
		t.Errorf("InstanceIds = %v, want [i-0abc123]", in.InstanceIds)
	}
	if len(in.Filters) != 0 {
		t.Errorf("expected no tag filter, got %v", in.Filters)
	}
}

func TestDescribeInputByNameTag(t *testing.T) {
	in := describeInput("web-prod")
	if len(in.InstanceIds) != 0 {
		t.Errorf("expected no instance ids, got %v", in.InstanceIds)
	}
	if len(in.Filters) != 1 {
		t.Fatalf("expected one filter, got %v", in.Filters)
	}
	if aws.ToString(in.Filters[0].Name) != "tag:Name" {
		t.Errorf("filter name = %q, want tag:Name", aws.ToString(in.Filters[0].Name))
	}
	if !slices.Equal(in.Filters[0].Values, []string{"web-prod"}) {
		t.Errorf("filter values = %v, want [web-prod]", in.Filters[0].Values)
	}
}

func TestDescribeInputEmptyFilterListsEverything(t *testing.T) {
	in := describeInput("")
	if len(in.InstanceIds) != 0 || len(in.Filters) != 0 {
		t.Errorf("expected an unfiltered request, got ids=%v filters=%v", in.InstanceIds, in.Filters)
	}
}

func TestDescribeInputTreatsShortIDLikeAName(t *testing.T) {
	for _, filter := range []string{"i-", "i", "iX-abc"} {
		in := describeInput(filter)
		if len(in.InstanceIds) != 0 {
			t.Errorf("%q was treated as an instance id: %v", filter, in.InstanceIds)
		}
		if len(in.Filters) != 1 {
			t.Errorf("%q did not become a name filter", filter)
		}
	}
}

func TestDescribeInputNameContainingDashI(t *testing.T) {
	in := describeInput("api-gateway")
	if len(in.InstanceIds) != 0 {
		t.Errorf("api-gateway must not be an instance id, got %v", in.InstanceIds)
	}
}

func TestFlattenExtractsNameTag(t *testing.T) {
	got := flatten(ec2types.Instance{
		InstanceId:       aws.String("i-1"),
		PrivateIpAddress: aws.String("10.0.0.1"),
		PublicIpAddress:  aws.String("1.2.3.4"),
		InstanceType:     ec2types.InstanceTypeT3Micro,
		State:            &ec2types.InstanceState{Name: ec2types.InstanceStateNameRunning},
		Tags: []ec2types.Tag{
			{Key: aws.String("env"), Value: aws.String("prod")},
			{Key: aws.String("Name"), Value: aws.String("web-01")},
			{Key: aws.String("Name"), Value: aws.String("ignored-second")},
		},
	})

	want := Instance{
		Name:         "web-01",
		InstanceID:   "i-1",
		PrivateIP:    "10.0.0.1",
		PublicIP:     "1.2.3.4",
		State:        "running",
		InstanceType: "t3.micro",
	}
	if got != want {
		t.Errorf("flatten() = %+v, want %+v", got, want)
	}
}

func TestFlattenToleratesMissingFields(t *testing.T) {
	got := flatten(ec2types.Instance{})
	if got != (Instance{}) {
		t.Errorf("flatten(empty) = %+v, want zero value", got)
	}
}

func TestFlattenWithoutStateLeavesStateBlank(t *testing.T) {
	got := flatten(ec2types.Instance{InstanceId: aws.String("i-9")})
	if got.State != "" {
		t.Errorf("State = %q, want empty", got.State)
	}
	if got.InstanceID != "i-9" {
		t.Errorf("InstanceID = %q, want i-9", got.InstanceID)
	}
}

func TestFlattenWithoutNameTag(t *testing.T) {
	got := flatten(ec2types.Instance{
		InstanceId: aws.String("i-3"),
		Tags:       []ec2types.Tag{{Key: aws.String("team"), Value: aws.String("infra")}},
	})
	if got.Name != "" {
		t.Errorf("Name = %q, want empty", got.Name)
	}
}

func TestSortInstancesIsStableByName(t *testing.T) {
	in := []Instance{
		{Name: "zeta", InstanceID: "i-3"},
		{Name: "", InstanceID: "i-2"},
		{Name: "alpha", InstanceID: "i-1"},
		{Name: "", InstanceID: "i-4"},
	}
	sortInstances(in)

	if in[0].InstanceID != "i-2" || in[1].InstanceID != "i-4" {
		t.Errorf("unnamed instances should sort first in input order, got %v", ids(in))
	}
	if in[2].Name != "alpha" || in[3].Name != "zeta" {
		t.Errorf("named instances out of order: %v", ids(in))
	}
}

func ids(instances []Instance) []string {
	out := make([]string, 0, len(instances))
	for _, i := range instances {
		out = append(out, i.InstanceID)
	}
	return out
}

func TestFirstRunningPicksTheFirstRunning(t *testing.T) {
	got, err := firstRunning([]Instance{
		{InstanceID: "i-1", State: "stopped"},
		{InstanceID: "i-2", State: "running"},
		{InstanceID: "i-3", State: "running"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.InstanceID != "i-2" {
		t.Errorf("chose %s, want i-2", got.InstanceID)
	}
}

func TestFirstRunningReportsTheStateOfTheFirstCandidate(t *testing.T) {
	_, err := firstRunning([]Instance{
		{Name: "db", InstanceID: "i-1", State: "stopped"},
		{Name: "db", InstanceID: "i-2", State: "terminated"},
	})
	if err == nil {
		t.Fatal("expected an error when nothing is running")
	}
	msg := err.Error()
	if !strings.Contains(msg, "db") || !strings.Contains(msg, "stopped") {
		t.Errorf("error should name the instance and its state, got: %s", msg)
	}
}

func TestFirstRunningOnEmptyDoesNotPanic(t *testing.T) {
	if _, err := firstRunning(nil); err == nil {
		t.Error("expected an error for an empty list")
	}
}

func TestNotRunningMessage(t *testing.T) {
	err := NotRunning(Instance{Name: "web", State: "stopping"})
	if got := err.Error(); got != `instance web is stopping, not running` {
		t.Errorf("unexpected message: %s", got)
	}
}

func TestEmptyLookupError(t *testing.T) {
	filtered := emptyLookupError("db-01", "eu-west-1").Error()
	if !strings.Contains(filtered, `"db-01"`) || !strings.Contains(filtered, "eu-west-1") {
		t.Errorf("filtered message should name filter and region: %s", filtered)
	}

	bare := emptyLookupError("", "us-east-1").Error()
	if strings.Contains(bare, `""`) {
		t.Errorf("bare message should not quote an empty filter: %s", bare)
	}
	if !strings.Contains(bare, "us-east-1") {
		t.Errorf("bare message should name the region: %s", bare)
	}
}

func TestNewRejectsAProfileThatDoesNotExist(t *testing.T) {
	awsFiles(t, "", "")

	_, err := New(t.Context(), "missing-profile", "eu-west-1")
	if err == nil {
		t.Fatal("expected an error for a nonexistent profile")
	}
	if !strings.Contains(err.Error(), "does not exist") {
		t.Errorf("error should be the diagnosed one, got: %v", err)
	}
	if errors.Is(err, errors.ErrUnsupported) {
		t.Error("unexpected sentinel")
	}
}

func TestNewRecordsTheResolvedProfileAndRegion(t *testing.T) {
	awsFiles(t, "[profile ok]\nregion = eu-central-1\n", "")

	client, err := New(t.Context(), "ok", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if client.Profile.Name != "ok" || !client.Profile.Explicit {
		t.Errorf("Profile = %+v, want explicit ok", client.Profile)
	}
	if client.Region != "eu-central-1" {
		t.Errorf("Region = %q, want eu-central-1 from the profile", client.Region)
	}
	if client.Config().Region != client.Region {
		t.Error("Config().Region should match the client region")
	}
}

func TestNewFlagRegionOverridesTheProfile(t *testing.T) {
	awsFiles(t, "[profile ok]\nregion = eu-central-1\n", "")

	client, err := New(t.Context(), "ok", "ap-south-1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if client.Region != "ap-south-1" {
		t.Errorf("Region = %q, want the flag value", client.Region)
	}
}
