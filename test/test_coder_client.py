"""coder.el's client, scripts/coder_client.py, against a Coder of its own:
an HTTP server on this machine that answers as Coder's API does."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "coder_client.py"
spec = importlib.util.spec_from_file_location("coder_client", SOURCE)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)

WORKSPACE = "0f8c0a43-6b47-4e5e-9a4e-6f3c6a2d8e10"


class FakeCoder(http.server.BaseHTTPRequestHandler):
    """Coder's API, as much of it as the client asks: what each request
    was is kept in `seen', and `replies' says what to answer a path with."""
    seen = []
    replies = {}

    def answer(self, body=None):
        self.seen.append(dict(method=self.command, path=self.path, body=body,
                              token=self.headers.get("Coder-Session-Token")))
        status, reply = self.replies.get(self.path, (404, dict(message="Resource not found")))
        if callable(reply):
            status, reply = reply(body)
        data = json.dumps(reply).encode()
        self.send_response(status)
        if status in (301, 302, 307):
            self.send_header("Location", "http://127.0.0.1:1/elsewhere")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.answer()

    def do_POST(self):
        self.answer(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))

    def log_message(self, *args):
        pass


class Client(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coder client '$ ")
        self.root = Path(self.temp.name)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeCoder)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        FakeCoder.seen, FakeCoder.replies = [], {}
        self.token = self.root / "token"
        self.token.write_text("secret-session-token\n")
        self.token.chmod(0o600)
        self.cli = self.root / "coder"
        self.connect(command=[str(self.cli)])

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def connect(self, **fields):
        config = dict(url="http://127.0.0.1:%d" % self.server.server_port, tokenFile=str(self.token),
                      command=["coder"])
        config.update(fields)
        self.connection = self.root / "connection.json"
        self.connection.write_text(json.dumps(config))
        return self.connection

    def run_client(self, action, request=None, *arguments):
        return subprocess.run([sys.executable, "-I", str(SOURCE), action, str(self.connection), *arguments],
                              input=json.dumps(request or {}), text=True, capture_output=True, timeout=30)

    def test_a_request_sends_the_token_in_a_header_only(self):
        FakeCoder.replies["/api/v2/users/me"] = (200, dict(username="dev"))
        reply = self.run_client("validate")
        self.assertEqual(reply.returncode, 0, reply.stdout + reply.stderr)
        self.assertEqual(json.loads(reply.stdout)["result"]["user"], "dev")
        self.assertEqual(FakeCoder.seen[0]["token"], "secret-session-token")
        self.assertNotIn("secret-session-token", reply.stdout + reply.stderr)

    def test_template_gives_its_active_version_and_parameters(self):
        template = "11111111-2222-3333-4444-555555555555"
        version = "66666666-7777-8888-9999-000000000000"
        FakeCoder.replies["/api/v2/templates/" + template] = (200, dict(id=template, active_version_id=version))
        FakeCoder.replies["/api/v2/templateversions/%s/rich-parameters" % version] = (
            200, [dict(name="instance_type", options=[dict(name="GPU", value="g5.xlarge")])])
        reply = json.loads(self.run_client("template", dict(template=template)).stdout)
        self.assertEqual(reply["result"]["version"], version)
        self.assertEqual(reply["result"]["parameters"][0]["name"], "instance_type")

    def test_create_asks_for_the_version_and_values_given(self):
        version = "66666666-7777-8888-9999-000000000000"
        FakeCoder.replies["/api/v2/users/me/workspaces"] = (201, dict(id=WORKSPACE))
        reply = self.run_client("create", dict(name="task-1", version=version, ttl=0,
                                               parameters=[dict(name="profile", value="small")]))
        self.assertTrue(json.loads(reply.stdout)["ok"], reply.stdout)
        self.assertEqual(FakeCoder.seen[0]["body"], dict(name="task-1", template_version_id=version, ttl_ms=0,
                                                         rich_parameter_values=[dict(name="profile", value="small")]))

    def test_coder_s_refusal_is_said_without_the_token(self):
        FakeCoder.replies["/api/v2/workspaces/%s/builds" % WORKSPACE] = (
            403, dict(message="Forbidden for secret-session-token"))
        reply = self.run_client("start", dict(workspace=WORKSPACE))
        self.assertEqual(reply.returncode, 1)
        error = json.loads(reply.stdout)["error"]
        self.assertIn("403", error)
        self.assertNotIn("secret-session-token", error)

    def test_a_redirect_is_refused_not_followed(self):
        FakeCoder.replies["/api/v2/users/me"] = (307, {})
        reply = json.loads(self.run_client("validate").stdout)
        self.assertFalse(reply["ok"])
        self.assertIn("redirected", reply["error"])
        self.assertEqual(len(FakeCoder.seen), 1)

    def test_ids_in_paths_are_ids(self):
        for request in (dict(workspace="../users/me"), dict(workspace="a/b"), dict(workspace="")):
            reply = json.loads(self.run_client("stop", request).stdout)
            self.assertFalse(reply["ok"])
            self.assertIn("Invalid workspace ID", reply["error"])
        self.assertEqual(FakeCoder.seen, [])

    def test_connections_it_refuses(self):
        for fields, said in ((dict(url="http://coder.example.org"), "HTTPS"),
                             (dict(url="https://user:pass@coder.example.org"), "HTTPS"),
                             (dict(command="coder ssh"), "list"),
                             (dict(tokenFile="token"), "absolute")):
            self.connect(**fields)
            with self.assertRaisesRegex(client.ClientError, said):
                client.connection(self.connection)
        self.connect()
        self.token.chmod(0o640)
        with self.assertRaisesRegex(client.ClientError, "chmod 600"):
            client.connection(self.connection)
        self.token.chmod(0o600)
        self.token.write_text("\n")
        with self.assertRaisesRegex(client.ClientError, "empty"):
            client.connection(self.connection)

    def test_a_workspace_by_name_is_none_when_there_is_none(self):
        self.assertIsNone(client.workspace_by_name(self.connection, "roost-0123456789abcdef"))
        FakeCoder.replies["/api/v2/users/me/workspace/roost-0123456789abcdef"] = (500, dict(message="down"))
        with self.assertRaisesRegex(client.ClientError, "500"):
            client.workspace_by_name(self.connection, "roost-0123456789abcdef")

    def test_ssh_refuses_a_workspace_that_is_not_running_and_never_starts_it(self):
        FakeCoder.replies["/api/v2/workspaces/" + WORKSPACE] = (
            200, dict(id=WORKSPACE, name="task-1", owner_name="dev", latest_build=dict(status="stopped")))
        self.cli.write_text("#!/bin/sh\necho started >> %s\n" % shlex.quote(str(self.root / "ran")))
        self.cli.chmod(0o700)
        reply = self.run_client("ssh", None, WORKSPACE)
        self.assertEqual(reply.returncode, 1)
        self.assertIn("isn't running", reply.stderr)
        self.assertFalse((self.root / "ran").exists())
        self.assertEqual([request["method"] for request in FakeCoder.seen], ["GET"])

    def test_ssh_becomes_the_cli_with_the_token_in_its_environment(self):
        FakeCoder.replies["/api/v2/workspaces/" + WORKSPACE] = (
            200, dict(id=WORKSPACE, name="task-1", owner_name="dev", latest_build=dict(status="running")))
        # The CLI here says what it was given: its arguments, and the
        # token and configuration directory it was given in its environment.
        self.cli.write_text('#!/bin/sh\nprintf "%%s\\n" "$@" "$CODER_SESSION_TOKEN" "$CODER_CONFIG_DIR" > %s\n'
                            % shlex.quote(str(self.root / "ran")))
        self.cli.chmod(0o700)
        reply = self.run_client("ssh", None, WORKSPACE)
        self.assertEqual(reply.returncode, 0, reply.stderr)
        self.assertEqual((self.root / "ran").read_text().splitlines(),
                         ["ssh", "--stdio", "--disable-autostart=true", "dev/task-1",
                          "secret-session-token", str(self.root / "cli")])

    def test_an_ssh_stanza_reaches_only_its_alias_through_the_proxy(self):
        stanza = client.ssh_stanza(SOURCE, self.root / "100% private" / "connection.json", "roost-coder-x", WORKSPACE)
        lines = stanza.splitlines()
        self.assertEqual(lines[0], "Host roost-coder-x")
        self.assertIn("100%% private", lines[1])
        self.assertEqual(shlex.split(lines[1].split(" ", 3)[3].replace("%%", "%"))[2:],
                         [str(SOURCE), "ssh", str(self.root / "100% private" / "connection.json"), WORKSPACE])
        with self.assertRaisesRegex(client.ClientError, "alias"):
            client.ssh_stanza(SOURCE, self.connection, "x\n  ProxyCommand evil", WORKSPACE)
        with self.assertRaisesRegex(client.ClientError, "workspace ID"):
            client.ssh_stanza(SOURCE, self.connection, "roost-coder-x", "x; evil")

    def test_input_over_its_limit_is_refused(self):
        reply = subprocess.run([sys.executable, "-I", str(SOURCE), "validate", str(self.connection)],
                               input="x" * (client.REQUEST_LIMIT + 1), text=True, capture_output=True)
        self.assertIn("64 KiB", json.loads(reply.stdout)["error"])
        self.assertEqual(FakeCoder.seen, [])


if __name__ == "__main__":
    unittest.main()
