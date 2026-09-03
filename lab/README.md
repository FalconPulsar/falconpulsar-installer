# Lab OPC UA simulator

Not started by a default FalconPulsar install. Does not start plant PLCs.

500 variables named like the Gateway commissioning fixture
(`tests/fixtures/opcua_browse_500.json` in falconpulsar-ai-gateway):

`ns=<idx>;s=plant/line{N}/{press|temp}_{iii}` — 500 nodes, lines 1–10.

```bash
docker compose -f lab/compose.yml --profile lab up -d --build
```

Host: `opc.tcp://127.0.0.1:4840`

`docker compose down` in this directory cannot stop the plant stack
(`name: falconpulsar-lab`).

Do not start this against a live plant Core. Map it from Config Hub Discover
on a lab stack, first page only until BrowseNext exists.

Baseline template: `BASELINE.md`.
