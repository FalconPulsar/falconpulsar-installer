package configbackup

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/api"
)

func TestSeriesRestoreRequiresCompletePerItemResults(t *testing.T) {
	for _, tc := range []struct {
		name, response           string
		created, skipped, failed int
	}{
		{"created and existing", `{"results":[{"status":"created"},{"status":"exists"}]}`, 1, 1, 0},
		{"type rejected", `{"results":[{"status":"created"},{"status":"error","error":"storage type conflict"}]}`, 1, 0, 1},
		{"unknown status", `{"results":[{"status":"updated"},{"status":"exists"}]}`, 0, 1, 1},
		{"missing row", `{"results":[{"status":"created"}]}`, 0, 0, 2},
		{"missing results", `{}`, 0, 0, 2},
		{"malformed body", `{`, 0, 0, 2},
		{"malformed status", `{"results":[{"status":1},{"status":"exists"}]}`, 0, 0, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cli := api.New()
			cli.HTTP = &http.Client{Transport: importTransport(func(req *http.Request) (*http.Response, error) {
				var body struct {
					Series []map[string]any `json:"series"`
				}
				if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if len(body.Series) != 2 || body.Series[0]["data_type"] != "string" || body.Series[0]["asset"] != "plant" {
					t.Fatalf("type or asset lost: %#v", body.Series)
				}
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(tc.response))}, nil
			})}
			items := []any{map[string]any{"name": "grade", "path": "grade@plant", "data_type": "string"}, map[string]any{"name": "temp", "path": "temp@plant", "data_type": "float64"}}
			var stats SectionStats
			var summary ImportSummary
			importSeriesBulk(context.Background(), cli, items, &stats, &summary)
			if stats.Created != tc.created || stats.Skipped != tc.skipped || stats.Errors != tc.failed || summary.TotalErrors != tc.failed {
				t.Fatalf("unexpected restore counts: %+v %+v", stats, summary)
			}
			if tc.failed > 0 && len(stats.ErrorDetails) == 0 {
				t.Fatal("failure has no explanation")
			}
		})
	}
}
