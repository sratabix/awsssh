package forward

import (
	"context"
	"fmt"
	"sync"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/session"
)

type Bundle struct {
	Client  *awsx.Client
	Starter *session.Starter
}

type Provider struct {
	ctx   context.Context
	mu    sync.Mutex
	cache map[string]Bundle
}

func NewProvider(ctx context.Context) *Provider {
	return &Provider{ctx: ctx, cache: map[string]Bundle{}}
}

func (p *Provider) Get(profile, region string) (Bundle, error) {
	key := profile + "|" + region

	p.mu.Lock()
	defer p.mu.Unlock()
	if b, ok := p.cache[key]; ok {
		return b, nil
	}

	client, err := awsx.New(p.ctx, profile, region)
	if err != nil {
		return Bundle{}, err
	}
	if client.Region == "" {
		return Bundle{}, fmt.Errorf("no region for AWS profile %q; set one on the forward or in the profile", client.Profile.Name)
	}
	if err := client.Verify(p.ctx); err != nil {
		return Bundle{}, err
	}

	b := Bundle{
		Client:  client,
		Starter: session.New(client.Config(), client.Region, profile),
	}
	p.cache[key] = b
	return b, nil
}
