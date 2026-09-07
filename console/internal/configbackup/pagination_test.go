// SPDX-License-Identifier: AGPL-3.0-only
package configbackup

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

func TestHarvestPaginatedRejectsFailedLaterPage(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Query().Get("offset") == "0" {
			fmt.Fprint(w, `{"series":[{"id":"1"},{"id":"2"}],"has_more":true,"next_offset":2}`)
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprint(w, `{"error":"temporary catalog failure"}`)
	}))
	defer server.Close()
	client := api.New()
	client.BaseURL = server.URL

	raw, err := harvestPaginated(context.Background(), client, "/api/v1/series?include_engineering=true", "series")
	if err == nil {
		t.Fatalf("later-page failure was accepted as a complete section: %s", raw)
	}
	if raw != nil {
		t.Fatalf("failed harvest returned partial rows: %s", raw)
	}
	if !strings.Contains(err.Error(), "offset 2") || !strings.Contains(err.Error(), "HTTP 503") {
		t.Fatalf("error must identify the failed page and HTTP status: %v", err)
	}
	if requests != 2 {
		t.Fatalf("got %d requests, want exactly the first and failed second page", requests)
	}
}

func TestHarvestPaginatedCollectsEveryServerClampedPage(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Query().Get("include_engineering") != "true" || r.URL.Query().Get("limit") != "1000" {
			t.Errorf("pagination dropped the original query or requested page size: %s", r.URL)
		}
		switch r.URL.Query().Get("offset") {
		case "0":
			fmt.Fprint(w, `{"series":[{"id":"1"},{"id":"2"}],"has_more":true,"next_offset":2}`)
		case "2":
			fmt.Fprint(w, `{"series":[{"id":"3"}],"has_more":false}`)
		default:
			t.Errorf("unexpected page: %s", r.URL)
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()
	client := api.New()
	client.BaseURL = server.URL

	raw, err := harvestPaginated(context.Background(), client, "/api/v1/series?include_engineering=true", "series")
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Series []struct{ ID string } `json:"series"`
		Count  int                   `json:"count"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if requests != 2 || result.Count != 3 || len(result.Series) != 3 {
		t.Fatalf("incomplete catalog: requests=%d, response=%s", requests, raw)
	}
	for i, item := range result.Series {
		if item.ID != fmt.Sprint(i+1) {
			t.Errorf("series %d has ID %q", i, item.ID)
		}
	}
}

func TestHarvestPaginatedRejectsIncompleteOrMalformedContinuation(t *testing.T) {
	for _, body := range []string{
		`{"series":[`,
		`{"error":"catalog unavailable"}`,
		`{"series":null}`,
		`{"series":{}}`,
		`{"series":[{"id":"3"}],"has_more":"true"}`,
		`{"series":[{"id":"3"}],"has_more":null}`,
		`{"series":[{"id":"3"}],"has_more":true,"next_offset":2}`,
		`{"series":[{"id":"3"}],"has_more":true,"next_offset":1}`,
		`{"series":[],"has_more":true,"next_offset":3}`,
		`{"series":[{"id":"3"}],"has_more":true,"next_offset":2.5}`,
		`{"series":[{"id":"3"}],"has_more":true,"next_offset":null}`,
	} {
		t.Run(body, func(t *testing.T) {
			requests := 0
			client := api.New()
			client.HTTP.Transport = paginationTransport(func(r *http.Request) (*http.Response, error) {
				requests++
				page := body
				if requests == 1 {
					page = `{"series":[{"id":"1"},{"id":"2"}],"has_more":true,"next_offset":2}`
				}
				return paginationResponse(page), nil
			})
			raw, err := harvestPaginated(context.Background(), client, "/api/v1/series", "series")
			if err == nil || raw != nil {
				t.Fatalf("invalid continuation accepted: response=%s, error=%v", raw, err)
			}
			if requests != 2 {
				t.Fatalf("got %d requests, want exactly two", requests)
			}
		})
	}
}

func TestHarvestPaginatedRetainsLegacyArrayShapes(t *testing.T) {
	for _, body := range []string{
		`[]`,
		`{"series":[]}`,
		`{"series":[],"has_more":false,"next_offset":0}`,
		`{"items":[]}`,
	} {
		t.Run(body, func(t *testing.T) {
			client := api.New()
			client.HTTP.Transport = paginationTransport(func(r *http.Request) (*http.Response, error) {
				return paginationResponse(body), nil
			})
			raw, err := harvestPaginated(context.Background(), client, "/api/v1/series", "series")
			if err != nil {
				t.Fatalf("valid empty catalog rejected: %v", err)
			}
			var result struct{ Count int }
			if err := json.Unmarshal(raw, &result); err != nil || result.Count != 0 {
				t.Fatalf("unexpected response: %s, error=%v", raw, err)
			}
		})
	}
}

func TestHarvestPaginatedRejectsIterationExhaustion(t *testing.T) {
	requests := 0
	client := api.New()
	client.HTTP.Transport = paginationTransport(func(r *http.Request) (*http.Response, error) {
		requests++
		// Keep advancing forever without network I/O or a real application.
		return paginationResponse(`{"series":[{"id":"sample"}],"has_more":true}`), nil
	})
	raw, err := harvestPaginated(context.Background(), client, "/api/v1/series", "series")
	if err == nil || raw != nil || !strings.Contains(err.Error(), "exceeded 10000 pages") {
		t.Fatalf("endless catalog accepted as complete: response=%s, error=%v", raw, err)
	}
	if requests != 10000 {
		t.Fatalf("got %d requests, want bounded limit 10000", requests)
	}
}

type paginationTransport func(*http.Request) (*http.Response, error)

func (transport paginationTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return transport(r)
}

func paginationResponse(body string) *http.Response {
	return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}
