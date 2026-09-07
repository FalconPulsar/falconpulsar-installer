package configbackup

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

type importTransport func(*http.Request) (*http.Response, error)

func (f importTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestImportRefreshesSessionAfterRestoringUsers(t *testing.T) {
	for _, loginWorks := range []bool{true, false} {
		t.Run(map[bool]string{true: "restored-login", false: "failed-login"}[loginWorks], func(t *testing.T) {
			t.Setenv("FP_HOME", t.TempDir())
			archive := writeInspectFixture(t, map[string]string{
				"api/config-bundle.json": `{}`,
				"api/asset-types.json":   `{"asset_types":[{"name":"test-type"}]}`,
			}, "", FormatVersion)
			var calls []string
			cli := api.New()
			cli.Token = "bootstrap-token"
			cli.HTTP = &http.Client{Transport: importTransport(func(req *http.Request) (*http.Response, error) {
				calls = append(calls, req.URL.Path)
				status, body := 200, `{}`
				switch req.URL.Path {
				case "/api/v1/admin/config-bundle":
					if req.Header.Get("Authorization") != "Bearer bootstrap-token" {
						t.Error("bundle did not use bootstrap login")
					}
				case "/api/v1/auth/login":
					if loginWorks {
						body = `{"token":"restored-token"}`
					} else {
						status = 401
					}
				case "/api/v1/asset-types":
					if req.Header.Get("Authorization") != "Bearer restored-token" {
						t.Error("configuration import used stale bootstrap identity")
					}
				default:
					t.Fatalf("unexpected API call: %s", req.URL.Path)
				}
				return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
			})}
			_, err := Import(context.Background(), archive, cli, "fixture-admin", "fixture-password")
			if (err == nil) != loginWorks {
				t.Fatalf("unexpected login outcome: %v", err)
			}
			want := "/api/v1/admin/config-bundle,/api/v1/auth/login"
			if loginWorks {
				want += ",/api/v1/asset-types"
			}
			if strings.Join(calls, ",") != want {
				t.Errorf("unexpected call sequence: %v", calls)
			}
		})
	}
}
