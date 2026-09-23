#!/usr/bin/env python3
"""Small authenticated client for the app's local MCP endpoint."""
import argparse
import json
import sys
from pathlib import Path
from urllib.request import Request, build_opener, ProxyHandler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", nargs="?", default="get_state")
    parser.add_argument("arguments", nargs="?", default="{}", help="Tool arguments as JSON")
    parser.add_argument("--list", action="store_true", help="List available tools")
    parser.add_argument("--config", type=Path, default=Path.home() / "Library/Application Support/PhotoStyleApp/MCP/connection.json")
    options = parser.parse_args()
    connection = json.loads(options.config.read_text())["mcpServers"]["FilmYourPhoto"]
    headers = dict(connection["headers"], **{"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    opener = build_opener(ProxyHandler({}))  # Loopback requests never use a system proxy.

    def rpc(method, params, notification=False):
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            body["id"] = 1
        request = Request(connection["url"], data=json.dumps(body).encode(), headers=headers, method="POST")
        with opener.open(request, timeout=180) as response:
            raw = response.read()
        if not raw:
            return None
        message = json.loads(raw)
        if "error" in message:
            raise ValueError(message["error"])
        return message["result"]

    initialized = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "FilmYourPhotoCLI", "version": "1.0"}})
    headers["MCP-Protocol-Version"] = initialized["protocolVersion"]
    rpc("notifications/initialized", {}, notification=True)
    result = rpc("tools/list", {}) if options.list else rpc("tools/call", {"name": options.tool, "arguments": json.loads(options.arguments)})
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result.get("isError") else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"MCP: {error}", file=sys.stderr)
        sys.exit(1)
