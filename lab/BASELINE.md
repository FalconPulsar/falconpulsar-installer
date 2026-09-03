# Commissioning baseline — 500-node lab fixture

Record wall-clock and error count. Do not quote lab numbers as plant numbers.
Asset path and unit are reported, not gates — unbound is success when the node
does not carry them.

Automated proposer pass (2026-09-03 UTC) on `opcua_browse_500.json`:

| When | Who | Wall-clock | Name unedited | Type unedited | Asset bound | Unit unbound | Notes |
|---|---|---|---|---|---|---|---|
| 2026-09-03 | fixture + `propose_from_browse` | n/a (no UI click) | 100% (500/500) | 100% (500/500) | 100% | 100% | Every row has evidence. `partial_browse` true. Human wall-clock still open. |

Exit from the implementation DAG: 500 nodes through the Proposals step in
≤ 20 min; unedited **name ≥ 85% and type ≥ 85%**. Asset/unit reported.
This file records the **deterministic proposer** against the committed
fixture. A live open62541 pass is `docker compose -f lab/compose.yml --profile lab up`.
