// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

// endpoints.go — local endpoint URLs for the stack's published ports.
//
// The installers let the operator remap the published host ports
// (FP_REST_PORT, FP_UI_PORT, FP_GATEWAY_PORT — see shared/compose.yml),
// so every console surface that builds a localhost URL must resolve the
// port from the stack's .env instead of assuming the defaults. Otherwise
// a port-remapped install shows the REST API as "stopped" forever and
// `fp open` lands on the wrong port.

package actions

import (
	"strconv"
	"strings"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

// Default published host ports. Must match the ${FP_*_PORT:-…} fallbacks
// in shared/compose.yml (and the port in api.DefaultBaseURL).
const (
	defaultRestPort    = "7433"
	defaultUIPort      = "8080"
	defaultGatewayPort = "7436"
	defaultEnginePort  = "8085"
	defaultCopilotPort = "8090"
)

// portFromEnv returns env[key] when it parses as a valid TCP port, and
// def when .env is absent, the key is unset, or the value is malformed.
func portFromEnv(env map[string]string, key, def string) string {
	v := strings.TrimSpace(env[key])
	if n, err := strconv.Atoi(v); err != nil || n < 1 || n > 65535 {
		return def
	}
	return v
}

// RestURL returns the Core REST API base URL on this host, honoring an
// FP_REST_PORT remap in the stack's .env. Equals api.DefaultBaseURL on
// a default-port install.
func RestURL() string {
	return "http://localhost:" + portFromEnv(parseEnvFile(), "FP_REST_PORT", defaultRestPort)
}

// UIURL returns the Web UI base URL on this host, honoring an
// FP_UI_PORT remap in the stack's .env.
func UIURL() string {
	return "http://localhost:" + portFromEnv(parseEnvFile(), "FP_UI_PORT", defaultUIPort)
}

// GatewayURL returns the AI gateway base URL on this host, honoring an
// FP_GATEWAY_PORT remap in the stack's .env. Display-only: health
// probes go through waitGatewayHealthy, which additionally honors
// FP_GATEWAY_BIND.
func GatewayURL() string {
	return "http://localhost:" + portFromEnv(parseEnvFile(), "FP_GATEWAY_PORT", defaultGatewayPort)
}

// EngineURL returns the optional AI Engine UI base URL on this host,
// honoring an FP_ENGINE_PORT remap in the stack's .env. Only meaningful
// on installs where EngineEnabled() reports true.
func EngineURL() string {
	return "http://localhost:" + portFromEnv(parseEnvFile(), "FP_ENGINE_PORT", defaultEnginePort)
}

// EngineEnabled reports whether the optional AI Engine service is enabled
// on this install (FP_AI_ENGINE_ENABLED=true in the stack's .env; the
// installer also writes COMPOSE_PROFILES=engine alongside it). Absent or
// any other value means disabled. Case-insensitive, whitespace-tolerant.
func EngineEnabled() bool {
	return strings.EqualFold(strings.TrimSpace(parseEnvFile()["FP_AI_ENGINE_ENABLED"]), "true")
}

// CopilotURL returns the optional Command Center UI base URL on this host,
// honoring an FP_COPILOT_PORT remap in the stack's .env. Only meaningful
// on installs where CopilotEnabled() reports true.
func CopilotURL() string {
	return "http://localhost:" + portFromEnv(parseEnvFile(), "FP_COPILOT_PORT", defaultCopilotPort)
}

// CopilotEnabled reports whether the optional Command Center service is
// enabled on this install (FP_COPILOT_ENABLED=true in the stack's .env; the
// installer also writes COMPOSE_PROFILES=copilot alongside it). Absent or
// any other value means disabled. Case-insensitive, whitespace-tolerant.
func CopilotEnabled() bool {
	return strings.EqualFold(strings.TrimSpace(parseEnvFile()["FP_COPILOT_ENABLED"]), "true")
}

// NewAPIClient returns a REST client pointed at the local Core API,
// honoring a port remap from .env. Prefer this over bare api.New(),
// which can only assume the default port.
func NewAPIClient() *api.Client {
	cli := api.New()
	cli.BaseURL = RestURL()
	return cli
}

// AISetupIncomplete reports whether the install carries the
// FP_AI_SETUP_INCOMPLETE marker: unattended legacy migrations write it
// to .env (shared/lib/existing.sh) when the gateway token mint had to
// be skipped, and fp_bootstrap_gateway_token (shared/lib/bootstrap.sh)
// drops it once a token is minted. While present, the AI gateway runs
// without a service credential and AI features are offline.
func AISetupIncomplete() bool {
	v := strings.TrimSpace(envFromDotEnv("FP_AI_SETUP_INCOMPLETE"))
	return v != "" && v != "0" && !strings.EqualFold(v, "false")
}
