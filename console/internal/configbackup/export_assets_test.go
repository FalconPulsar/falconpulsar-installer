package configbackup

import (
	"context"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

func TestExportIncludesInternalParentsForTelemetrySeries(t *testing.T) {
	home := t.TempDir()
	t.Setenv("FP_HOME", home)
	cli := api.New()
	cli.HTTP = &http.Client{Transport: importTransport(func(req *http.Request) (*http.Response, error) {
		key := strings.TrimPrefix(req.URL.Path, "/api/v1/")
		body := `{"` + key + `":[]}`
		switch key {
		case "assets":
			body = `{"assets":[{"path":"plant"}]}`
			if req.URL.Query().Get("include_system") == "1" {
				body = `{"assets":[{"path":"plant"},{"path":"_system/core"}]}`
			}
		case "series":
			body = `{"series":[{"path":"cpu@_system/core"}]}`
		case "admin/config-bundle":
			body = `{}`
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
	})}
	archive := filepath.Join(home, "export.fpconfig")
	err := Export(context.Background(), archive, cli, "fixture-admin", "fixture-password")
	var incomplete *IncompleteExportError
	if err != nil && !errors.As(err, &incomplete) {
		t.Fatal(err)
	}
	// This fixture has no companion DBs; verify the exported API definitions.
	res, err := Inspect(archive, "fixture-admin", "fixture-password")
	if err != nil {
		t.Fatal(err)
	}
	for _, section := range res.Sections {
		if section.Name == "assets" {
			if section.Count != 2 {
				t.Fatalf("telemetry parent omitted: %d assets", section.Count)
			}
			return
		}
	}
	t.Fatal("assets section missing")
}
