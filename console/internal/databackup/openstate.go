// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

package databackup

import (
	"context"
	"errors"
	"net/http"
)

// CoreOpenState is what Core's open found in a restored data directory: the
// report fp restore gives after restoring a Core copied by an older fp
// backup, which may be torn.
type CoreOpenState struct {
	// CatalogReported is false on a Core too old to report its catalog's
	// open state (no GET /api/v1/_system/catalog).
	CatalogReported bool
	Damaged         bool
	FirstDamage     string
	JournalReplayed bool
	JournalIgnored  bool
	JournalNote     string
	// WAL points replay could not apply and kept (meta/wal-held).
	WALHeldSeries int64
	WALHeldPoints int64
	SeriesCount   int64
}

// ReadCoreOpenState reads it as an admin (both routes are admin-only).
func ReadCoreOpenState(ctx context.Context, baseURL, adminToken string) (CoreOpenState, error) {
	c := newCoreClient(baseURL, adminToken)
	var st CoreOpenState
	var cat struct {
		Catalog struct {
			Open struct {
				Damaged         bool   `json:"damaged"`
				FirstDamage     string `json:"first_damage"`
				JournalReplayed bool   `json:"journal_replayed"`
				JournalIgnored  bool   `json:"journal_ignored"`
				JournalNote     string `json:"journal_note"`
			} `json:"open"`
			WALHeld struct {
				Series int64 `json:"series"`
				Points int64 `json:"points"`
			} `json:"wal_held"`
		} `json:"catalog"`
	}
	err := c.do(ctx, http.MethodGet, "/api/v1/_system/catalog", nil, http.StatusOK, &cat)
	var ae *APIError
	switch {
	case err == nil:
		o := cat.Catalog.Open
		st.CatalogReported = true
		st.Damaged, st.FirstDamage = o.Damaged, o.FirstDamage
		st.JournalReplayed, st.JournalIgnored, st.JournalNote = o.JournalReplayed, o.JournalIgnored, o.JournalNote
		st.WALHeldSeries, st.WALHeldPoints = cat.Catalog.WALHeld.Series, cat.Catalog.WALHeld.Points
	case errors.As(err, &ae) && ae.Status == http.StatusNotFound:
		// an older Core: no catalog report
	default:
		return st, err
	}
	var db struct {
		SeriesCount int64 `json:"series_count"`
	}
	if err := c.do(ctx, http.MethodGet, "/api/v1/_system/database", nil, http.StatusOK, &db); err != nil {
		return st, err
	}
	st.SeriesCount = db.SeriesCount
	return st, nil
}
