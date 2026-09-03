#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors
"""Lab OPC UA server: 500 variables named like the Gateway commissioning fixture.

NodeIds: ns=<idx>;s=plant/line{N}/{press|temp}_{iii}
  i = 0..499
  line N = (i % 10) + 1          # plant/line1 .. plant/line10
  press when i % 5 == 0 else temp
  types cycle Double, Float, Int32, Boolean, String

Not started by a default stack. Bind 4840 inside the container; compose
publishes 127.0.0.1:4840 only.
"""

from __future__ import annotations

import asyncio
import logging
import math
import time

from asyncua import Server, ua

log = logging.getLogger("opcua-500")

ENDPOINT = "opc.tcp://0.0.0.0:4840"
NAMESPACE_URI = "urn:falconpulsar:lab:opcua-500"
NODE_COUNT = 500
LINE_COUNT = 10
UPDATE_S = 1.0

_TYPES = (
    ua.VariantType.Double,
    ua.VariantType.Float,
    ua.VariantType.Int32,
    ua.VariantType.Boolean,
    ua.VariantType.String,
)


def _kind(i: int) -> str:
    return "press" if i % 5 == 0 else "temp"


def _line(i: int) -> int:
    return (i % LINE_COUNT) + 1


def _display(browse: str) -> str:
    return browse.replace("_", " ")


def _value(i: int, t: float):
    k = i % 5
    if k == 0:
        return 100.0 + 10.0 * math.sin(t / 15.0 + i * 0.01)
    if k == 1:
        return 20.0 + 5.0 * math.sin(t / 12.0 + i * 0.01)
    if k == 2:
        return int(50 + 10 * math.sin(t / 20.0 + i * 0.01))
    if k == 3:
        return (int(t) + i) % 20 < 10
    return f"state-{(int(t) + i) % 4}"


async def _set_display(node, text: str) -> None:
    await node.write_attribute(
        ua.AttributeIds.DisplayName, ua.DataValue(ua.LocalizedText(text))
    )


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("asyncua").setLevel(logging.WARNING)
    server = Server()
    await server.init()
    server.set_endpoint(ENDPOINT)
    server.set_server_name("FalconPulsar lab OPC UA 500")
    # Lab only: None. Do not advertise Sign without a certificate.
    server.set_security_policy([ua.SecurityPolicyType.NoSecurity])
    idx = await server.register_namespace(NAMESPACE_URI)
    log.info("namespace %s -> ns=%s", NAMESPACE_URI, idx)

    plant = await server.nodes.objects.add_object(ua.NodeId("plant", idx), "plant")

    lines: dict[int, object] = {}
    for n in range(1, LINE_COUNT + 1):
        node = await plant.add_object(ua.NodeId(f"plant/line{n}", idx), f"line{n}")
        await _set_display(node, f"Line {n}")
        lines[n] = node

    variables: list[tuple[object, ua.VariantType, int]] = []
    for i in range(NODE_COUNT):
        line_n = _line(i)
        browse = f"{_kind(i)}_{i:03d}"
        node_id = ua.NodeId(f"plant/line{line_n}/{browse}", idx)
        vtype = _TYPES[i % 5]
        var = await lines[line_n].add_variable(
            node_id, browse, _value(i, 0.0), varianttype=vtype
        )
        await _set_display(var, _display(browse))
        await var.set_writable(False)
        variables.append((var, vtype, i))

    log.info("listening on %s — %d variables under plant/line1..line%d", ENDPOINT, NODE_COUNT, LINE_COUNT)

    async with server:
        while True:
            t = time.time()
            for var, vtype, i in variables:
                await var.write_value(ua.Variant(_value(i, t), vtype))
            await asyncio.sleep(UPDATE_S)


if __name__ == "__main__":
    asyncio.run(main())
