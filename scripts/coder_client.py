#!/usr/bin/env python3
# Copyright (C) 2026 Clay Sheaff
# SPDX-License-Identifier: GPL-3.0-or-later
"""A Coder client of Python 3.9's standard library, for coder.el.

It reads a connection file coder.el writes (the URL, a private token
file's path and the Coder CLI's argv), asks Coder's REST API, and hands
SSH to the CLI with autostart off.  It knows nothing of who calls it:
Roost's controller imports it from the path coder.el gives.

    coder_client.py ACTION CONNECTION < request.json   one JSON reply line
    coder_client.py ssh CONNECTION WORKSPACE-ID          stdio for ssh
"""
import json
import os
from pathlib import Path
import re
import shlex
import sys
import urllib.error
import urllib.parse
import urllib.request

# A request names its workspace or template by ID, which goes in a path.
ID = re.compile(r"[0-9a-fA-F-]{1,64}\Z")
REQUEST_LIMIT = 64 * 1024


class ClientError(Exception):
    pass


def connection(path):
    """The connection in PATH, and its token, checked."""
    config = json.loads(Path(path).read_text())
    url = config.get("url")
    parsed = urllib.parse.urlsplit(url if isinstance(url, str) else "")
    if (parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment
            or (parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"))):
        raise ClientError("Use a Coder HTTPS URL, or HTTP to a tunnel on this machine")
    command = config.get("command")
    if not isinstance(command, list) or not command or not all(isinstance(s, str) and s for s in command):
        raise ClientError("The Coder command must be a list of its arguments")
    token_file = Path(config.get("tokenFile") or "").expanduser()
    if not token_file.is_absolute():
        raise ClientError("Give the Coder token file as an absolute path")
    if token_file.stat().st_mode & 0o077:
        raise ClientError("Make the Coder token file private: chmod 600 %s" % token_file)
    token = token_file.read_text().strip()
    if not token:
        raise ClientError("The Coder token file is empty")
    return config, token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ClientError("Coder redirected the request: give its final URL")


def api(configuration, path, body=None, method=None):
    """Coder's reply to METHOD on PATH under /api/v2, with BODY as JSON."""
    if not isinstance(path, str) or not path.startswith("/") or path.startswith("//") or "/../" in path + "/":
        raise ClientError("Give a Coder API path, such as /workspaces/ID")
    config, token = connection(configuration)
    request = urllib.request.Request(
        config["url"].rstrip("/") + "/api/v2" + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Coder-Session-Token": token, "Content-Type": "application/json",
                 "Accept": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            text = response.read()
            return json.loads(text) if text.strip() else None
    except urllib.error.HTTPError as exc:
        detail = exc.read(4000).decode(errors="replace").replace(token, "[token]")
        try:
            detail = json.loads(detail).get("message") or detail
        except (ValueError, AttributeError):
            pass
        raise ClientError("Coder said %s: %s" % (exc.code, detail)) from None
    except urllib.error.URLError as exc:
        raise ClientError("Coder can't be reached: %s" % exc.reason) from None


def identifier(value, what):
    if not isinstance(value, str) or not ID.match(value):
        raise ClientError("Invalid %s ID" % what)
    return value


def workspace_by_name(configuration, name):
    """Your workspace NAME, or None if you have none by that name."""
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,63}", name):
        raise ClientError("Invalid workspace name")
    try:
        return api(configuration, "/users/me/workspace/" + name)
    except ClientError as exc:
        if str(exc).startswith("Coder said 404:"):
            return None
        raise


def proxy_command(transport, configuration, workspace):
    """The argv of `ssh' through WORKSPACE, as an SSH ProxyCommand runs it."""
    return [sys.executable, "-I", str(transport), "ssh", str(configuration), identifier(workspace, "workspace")]


def ssh_stanza(transport, configuration, alias, workspace):
    """An SSH configuration stanza naming WORKSPACE ALIAS.  The proxy is
    authenticated by Coder, which checks the host for it, as Coder's own
    `config-ssh' has it; ssh's percent escapes are doubled."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", alias):
        raise ClientError("Invalid SSH alias")
    command = shlex.join(proxy_command(transport, configuration, workspace)).replace("%", "%%")
    return ("Host %s\n  ProxyCommand %s\n  StrictHostKeyChecking no\n"
            "  UserKnownHostsFile /dev/null\n  ConnectTimeout 8\n" % (alias, command))


def dispatch(configuration, action, request):
    if action == "validate":
        config = connection(configuration)[0]
        return dict(url=config["url"], user=api(configuration, "/users/me")["username"])
    if action == "request":
        return api(configuration, request["path"], request.get("body"), request.get("method"))
    if action == "templates":
        return api(configuration, "/organizations/%s/templates" % identifier(request["organization"], "organization"))
    if action == "template":
        template = api(configuration, "/templates/" + identifier(request["template"], "template"))
        version = template["active_version_id"]
        return dict(template=template, version=version,
                    parameters=api(configuration, "/templateversions/%s/rich-parameters" % version))
    if action == "create":
        body = dict(name=request["name"], template_version_id=identifier(request["version"], "template version"),
                    rich_parameter_values=request.get("parameters") or [])
        if "ttl" in request:
            body["ttl_ms"] = request["ttl"]
        return api(configuration, "/users/me/workspaces", body)
    if action == "workspace":
        if request.get("id"):
            return api(configuration, "/workspaces/" + identifier(request["id"], "workspace"))
        return workspace_by_name(configuration, request["name"])
    if action in ("start", "stop"):
        return api(configuration, "/workspaces/%s/builds" % identifier(request["workspace"], "workspace"),
                   dict(transition=action))
    raise ClientError("Unknown Coder client action: %s" % action)


def ssh(configuration, workspace):
    """Become `coder ssh --stdio' into WORKSPACE, if it is running: never start it."""
    found = api(configuration, "/workspaces/" + identifier(workspace, "workspace"))
    if found["latest_build"]["status"] != "running":
        raise ClientError("The Coder workspace %s isn't running: start it first" % found["name"])
    config, token = connection(configuration)
    env = dict(os.environ, CODER_URL=config["url"], CODER_SESSION_TOKEN=token,
               CODER_CONFIG_DIR=str(Path(configuration).parent / "cli"), CODER_USE_KEYRING="false",
               CODER_DISABLE_NETWORK_TELEMETRY="true")
    argv = config["command"] + ["ssh", "--stdio", "--disable-autostart=true",
                                found["owner_name"] + "/" + found["name"]]
    os.execvpe(argv[0], argv, env)


def main(argv):
    action, configuration = argv[1:3]
    try:
        if action == "ssh":
            ssh(configuration, argv[3])
            return 0
        text = sys.stdin.read(REQUEST_LIMIT + 1)
        if len(text) > REQUEST_LIMIT:
            raise ClientError("The request is over 64 KiB")
        reply = dict(ok=True, result=dispatch(configuration, action, json.loads(text) if text.strip() else {}))
    except (ClientError, OSError, ValueError, KeyError, TypeError) as exc:
        if action == "ssh":
            print("coder_client: %s" % exc, file=sys.stderr)
            return 1
        reply = dict(ok=False, error=str(exc) or type(exc).__name__)
    print(json.dumps(reply))
    return 0 if reply["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
