// Package api is a thin REST client for the FalconPulsar Core server.
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const DefaultBaseURL = "http://localhost:7433"

type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

func New() *Client {
	return &Client{
		BaseURL: DefaultBaseURL,
		HTTP:    &http.Client{Timeout: 10 * time.Second},
	}
}

// Login posts credentials and stores the returned bearer token.
func (c *Client) Login(ctx context.Context, user, pass string) error {
	body, _ := json.Marshal(map[string]string{"username": user, "password": pass})
	req, _ := http.NewRequestWithContext(ctx, "POST", c.BaseURL+"/api/v1/auth/login", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("login failed: HTTP %d", resp.StatusCode)
	}
	var result struct {
		Token string `json:"token"`
	}
	data, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(data, &result); err != nil || result.Token == "" {
		return fmt.Errorf("login failed: no token in response")
	}
	c.Token = result.Token
	return nil
}

// Me returns the authenticated user object, including role.
func (c *Client) Me(ctx context.Context) (map[string]any, error) {
	return c.GetJSON(ctx, "/api/v1/auth/me")
}

// IsAdmin returns true if the current token corresponds to an admin.
func (c *Client) IsAdmin(ctx context.Context) (bool, error) {
	m, err := c.Me(ctx)
	if err != nil {
		return false, err
	}
	if role, ok := m["role"].(string); ok {
		return role == "admin", nil
	}
	if arr, ok := m["roles"].([]any); ok {
		for _, r := range arr {
			if s, _ := r.(string); s == "admin" {
				return true, nil
			}
		}
	}
	return false, nil
}

// Health calls /api/v1/health (public, no auth).
func (c *Client) Health(ctx context.Context) (bool, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", c.BaseURL+"/api/v1/health", nil)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	return resp.StatusCode == 200, nil
}

// GetJSON performs an authenticated GET and parses the JSON body.
func (c *Client) GetJSON(ctx context.Context, path string) (map[string]any, error) {
	body, err := c.GetRaw(ctx, path)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		// Some endpoints return arrays; wrap for caller convenience
		var arr []any
		if err2 := json.Unmarshal(body, &arr); err2 == nil {
			return map[string]any{"items": arr}, nil
		}
		return nil, err
	}
	return out, nil
}

// GetRaw performs an authenticated GET and returns the raw body.
func (c *Client) GetRaw(ctx context.Context, path string) ([]byte, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", c.BaseURL+path, nil)
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("GET %s: HTTP %d", path, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// PostJSON performs an authenticated POST with the given body.
func (c *Client) PostJSON(ctx context.Context, path string, body any) ([]byte, error) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, "POST", c.BaseURL+path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return data, fmt.Errorf("POST %s: HTTP %d", path, resp.StatusCode)
	}
	return data, nil
}
