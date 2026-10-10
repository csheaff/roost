#!/usr/bin/env python3
"""A tool for coding agents to show a diagram inline in Roost's reader.

A minimal MCP server over stdio. Calling show_diagram does nothing but
answer that the diagram is shown: the call, with its code, lands in the
agent's session log, and the reader draws it there, between the
paragraphs that explain it."""

import json
import sys

TOOL = {
    "name": "show_diagram",
    "description": (
        "Show the user a diagram inline, right where you are in your explanation. "
        "Use it when a picture explains better than words: architecture, data flow, "
        "state machines, timelines, data structures. The diagram appears exactly where "
        "you call this tool, so call it in the middle of your answer, not before it: "
        "first write the paragraph that introduces the diagram, then call the tool, then "
        "go on writing. Formats: 'svg' (preferred: a "
        "self-contained SVG with explicit colors, drawn on a light card, about 680 px wide), "
        "'mermaid' (flowcharts, sequence and state diagrams), or 'html' (a small "
        "self-contained interactive widget, only when interaction helps)."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "A short title for the diagram."},
            "format": {"type": "string", "enum": ["svg", "mermaid", "html"]},
            "code": {"type": "string", "description": "The SVG, Mermaid or HTML source."},
        },
        "required": ["format", "code"],
    },
}


def reply(request_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        method, request_id = message.get("method"), message.get("id")
        if request_id is None:
            continue  # A notification, such as notifications/initialized.
        if method == "initialize":
            reply(request_id, {"protocolVersion": message.get("params", {}).get("protocolVersion", "2025-06-18"),
                               "capabilities": {"tools": {}},
                               "serverInfo": {"name": "roost-diagram", "version": "0.1"}})
        elif method == "tools/list":
            reply(request_id, {"tools": [TOOL]})
        elif method == "tools/call":
            reply(request_id, {"content": [{"type": "text", "text": "Shown inline in the user's reader."}]})
        elif method == "ping":
            reply(request_id, {})
        else:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                         "error": {"code": -32601, "message": "Unknown method"}}) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
