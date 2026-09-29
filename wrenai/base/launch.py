"""wren serve mcp を、許可する Host ヘッダを明示して起動する。

wrenai 0.15.0 は FastMCP を既定の host(127.0.0.1)で生成してから settings.host を
書き換えるため、mcp SDK の DNS rebinding 保護が localhost 限定のまま残り、
`--host 0.0.0.0` にしても Service 名でのアクセスが 421 (Invalid Host header) になる。
保護を切らずに、WREN_MCP_ALLOWED_HOSTS(カンマ区切り)だけを追加で許可する。
"""

import os
import sys

from mcp.server.transport_security import TransportSecuritySettings

import wren.mcp_server as mcp_server

_hosts = [h.strip() for h in os.environ["WREN_MCP_ALLOWED_HOSTS"].split(",") if h.strip()]
_build = mcp_server.build_server


def build_server(ctx):
    mcp = _build(ctx)
    mcp.settings.transport_security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["127.0.0.1:*", "localhost:*", *_hosts],
        allowed_origins=[],
    )
    return mcp


mcp_server.build_server = build_server

from wren.cli import app  # noqa: E402

sys.argv = ["wren", "serve", "mcp", *sys.argv[1:]]
app()
