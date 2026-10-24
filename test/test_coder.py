"""Coder controller invariants, without network, paid agents or cloud resources."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import test_remote as fixtures

roost = fixtures.roost
CLIENT = Path(__file__).resolve().parents[1] / "scripts" / "coder_client.py"


class CoderState(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="roost coder '$ ")
        self.root = Path(self.temp.name)
        self.store = roost.Store(self.root / "state")
        self.token = self.root / "token"
        self.token.write_text("private-test-token")
        self.token.chmod(0o600)
        self.connection = self.root / "client" / "connection.json"
        self.connection.parent.mkdir()
        self.connection.write_text(json.dumps(dict(url="http://127.0.0.1:9876", tokenFile=str(self.token),
                                                   command=["coder"])))
        self.client = dict(transport=str(CLIENT), configuration=str(self.connection))
        self.coder = roost.Coder(self.store, self.client)
        self.record = dict(id="a" * 32, host="roost-coder-" + "a" * 32, workspaceId="0f8c0a43-6b47-4e5e-9a4e-6f3c6a2d8e10",
                           workspaceName="synthetic", templateId="template-id", guestRoot="~/.local/share/roost",
                           canonical={}, state="stopped", tasks=[dict(id="b" * 16, name="task")])
        self.coder.save(self.record)
        self.workspace = dict(id="0f8c0a43-6b47-4e5e-9a4e-6f3c6a2d8e10", owner_name="owner", name="synthetic", template_id="template-id",
                              latest_build=dict(status="stopped"))

    def tearDown(self):
        self.temp.cleanup()

    def request(self, action, **kwargs):
        return self.coder.dispatch(dict(action=action, environment=self.record["id"], **kwargs))

    def test_the_controller_needs_coder_el_s_client(self):
        for client in (None, dict(transport="coder_client.py", configuration=str(self.connection)),
                       dict(transport=str(CLIENT.with_name("roost_remote.py")), configuration=str(self.connection))):
            with self.assertRaisesRegex(roost.RoostError, "client"):
                roost.Coder(self.store, client)
        reply = roost.rpc(dict(root=str(self.store.root), action="coder-cached"))
        self.assertFalse(reply["ok"])

    def test_poll_is_metadata_only_and_keeps_identity_and_tasks(self):
        with patch.object(self.coder, "api", return_value=self.workspace) as api, \
             patch.object(self.coder, "guest", side_effect=AssertionError("poll connected to guest")):
            result = self.request("coder-status")
        self.assertEqual(api.call_args_list[0].args, ("/workspaces/0f8c0a43-6b47-4e5e-9a4e-6f3c6a2d8e10",))
        self.assertEqual(result["state"], "stopped")
        self.assertEqual(result["tasks"], self.record["tasks"])
        self.assertEqual(self.coder.read(self.record["id"]), self.record)

    def test_stop_refuses_before_api_mutation_when_guest_cannot_quiesce(self):
        with patch.object(self.coder, "guest", side_effect=roost.RoostError("agent is live")), \
             patch.object(self.coder, "workspace", return_value=dict(self.workspace, latest_build=dict(status="running"))), \
             patch.object(self.coder, "api") as api:
            with self.assertRaisesRegex(roost.RoostError, "live"):
                self.request("coder-stop")
        api.assert_not_called()
        self.assertIn("live", self.coder.read(self.record["id"])["error"])

    def test_stop_quiesces_before_build_and_persists_stopped_tasks(self):
        calls = []
        def guest(record, request):
            calls.append(request["action"])
            return [dict(id="b" * 16, live=False)]
        def api(path, body=None):
            calls.append(body["transition"])
        def wait(record, state):
            record["state"] = state
        with patch.object(self.coder, "guest", side_effect=guest), patch.object(self.coder, "api", side_effect=api), \
             patch.object(self.coder, "workspace", return_value=dict(self.workspace, latest_build=dict(status="running"))), \
             patch.object(self.coder, "wait", side_effect=wait):
            result = self.request("coder-stop")
        self.assertEqual(calls, ["quiesce", "stop"])
        self.assertEqual(result["state"], "stopped")
        self.assertIs(result["tasks"][0]["live"], False)

    def test_repeating_stop_on_an_asleep_workspace_never_uses_ssh(self):
        with patch.object(self.coder, "api", return_value=self.workspace) as api, \
             patch.object(self.coder, "guest", side_effect=AssertionError("asleep guest contacted")):
            result = self.request("coder-stop")
        self.assertEqual(result["state"], "stopped")
        self.assertEqual(api.call_args.args, ("/workspaces/0f8c0a43-6b47-4e5e-9a4e-6f3c6a2d8e10",))

    def test_incomplete_guest_setup_is_not_advertised_as_a_ready_environment(self):
        self.record.update(state="running", pending=dict(version="version", parameters=[]))
        self.coder.save(self.record)
        self.workspace["latest_build"]["status"] = "running"
        with patch.object(self.coder, "api", return_value=self.workspace):
            self.assertEqual(self.request("coder-status")["state"], "preparing")
        self.assertEqual(self.request("coder-cached")[0]["state"], "preparing")

    def test_simultaneous_mutations_fail_closed(self):
        with self.coder.operation(self.record["id"]):
            with self.assertRaisesRegex(roost.RoostError, "Something else is starting"):
                self.request("coder-start")

    def test_private_ssh_file_names_only_workspaces_coder_has_given_an_id(self):
        pending = dict(self.record, id="c" * 32, host="roost-coder-" + "c" * 32)
        del pending["workspaceId"]
        self.coder.save(pending)
        self.coder.configure()
        text = self.coder.ssh_config.read_text()
        self.assertTrue(text.startswith("Host roost-coder-include-check\n  ProxyCommand false roost-coder-include-check\n"))
        self.assertIn("Host " + self.record["host"], text)
        self.assertNotIn(pending["host"], text)
        self.assertIn("coder_client.py ssh", text)
        self.assertIn("0f8c0a43-6b47-4e5e-9a4e-6f3c6a2d8e10", text)
        self.assertNotIn("private-test-token", text)
        for path in (self.coder.ssh_config, self.coder.path(self.record["id"])):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_every_request_rewrites_the_ssh_file_for_a_client_that_moved(self):
        moved = self.root / "moved" / "coder_client.py"
        moved.parent.mkdir()
        moved.write_text(CLIENT.read_text())
        with patch.object(roost.Coder, "workspace", return_value=self.workspace):
            roost.Coder(self.store, dict(self.client, transport=str(moved))).dispatch(
                dict(action="coder-status", environment=self.record["id"]))
        self.assertIn("moved/coder_client.py", self.coder.ssh_config.read_text())

    def test_ssh_to_a_workspace_sets_its_tmux_socket_up_as_tmux_control_does(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, json.dumps(dict(ok=True, result=[])), "")
        with patch.object(roost.subprocess, "run", side_effect=run):
            self.coder.guest(self.record, dict(action="list"))
            self.coder.dispatch(dict(action="coder-cached", socketSetup="export TMUX_TMPDIR=$HOME/.tmux-sock"))
            self.coder.guest(self.record, dict(action="list"))
        self.assertTrue(calls[0][-1].startswith("exec python3 -I -c "))
        self.assertTrue(calls[1][-1].startswith("export TMUX_TMPDIR=$HOME/.tmux-sock && exec python3 -I -c "))
        self.assertEqual(calls[1][:4], ["ssh", "-F", str(self.coder.ssh_config), "-T"])

    def test_coder_s_errors_are_the_controller_s(self):
        with self.assertRaisesRegex(roost.RoostError, "reached"):
            self.coder.api("/users/me")

    def test_a_workspace_coder_never_made_is_failed_not_gone_and_start_asks_again(self):
        del self.record["workspaceId"]
        self.record.update(state="pending", pending=dict(version="v", parameters=[], task=dict(directory="/repo")))
        self.coder.save(self.record)
        seed_file = self.coder.root / (self.record["id"] + ".seed.json")
        seed_file.write_text("{}")
        with patch.object(self.coder.client, "workspace_by_name", return_value=None), \
             patch.object(self.coder, "api", side_effect=roost.RoostError("Coder said 400: bad parameter")):
            self.assertEqual(self.request("coder-status")["state"], "pending")
            with self.assertRaisesRegex(roost.RoostError, "bad parameter"):
                self.request("coder-start")
            self.assertEqual(self.request("coder-status")["state"], "failed")
        self.assertEqual(self.coder.read(self.record["id"])["state"], "failed")
        self.assertTrue(seed_file.exists())

    def test_emacs_names_the_environment_it_creates_once(self):
        identity = "d" * 32
        request = dict(action="coder-create", id=identity, template="t", templateName="T", version="v",
                       parameters=[], guestRoot="~/.local/share/roost", canonical={}, seed={},
                       task=dict(name="task", directory="/repo"))
        with patch.object(self.coder, "start", side_effect=lambda record: self.coder.info(record)):
            self.assertEqual(self.coder.dispatch(dict(request))["host"], "roost-coder-" + identity)
            with self.assertRaisesRegex(roost.RoostError, "exists already"):
                self.coder.dispatch(dict(request))
        with self.assertRaisesRegex(roost.RoostError, "identity"):
            self.coder.dispatch(dict(request, id="../x"))

    def test_pending_seed_and_prompt_not_in_cached_result(self):
        self.record.update(seed="private seed", pending=dict(prompt="private prompt"))
        self.coder.save(self.record)
        result = self.request("coder-cached")
        self.assertNotIn("private", json.dumps(result))

    def test_retry_of_guest_setup_reuses_workspace_and_keeps_seed_until_success(self):
        task = dict(id="b" * 16, name="synthetic task")
        self.record.update(state="running", pending=dict(task=dict(directory="/repo")))
        seed_file = self.coder.root / (self.record["id"] + ".seed.json")
        seed_file.write_text(json.dumps(dict(synthetic="seed")))
        self.coder.save(self.record)
        workspace = dict(self.workspace, latest_build=dict(status="running"))
        failed = False
        def guest(record, request, **kwargs):
            nonlocal failed
            if request["action"] == "list":
                return [task]
            if request["action"] == "create":
                if not failed:
                    failed = True
                    raise roost.RoostError("SSH reply lost after create")
                return task
        with patch.object(self.coder, "workspace", return_value=workspace), \
             patch.object(self.coder, "wait", return_value=workspace), \
             patch.object(self.coder, "api", side_effect=AssertionError("retry created another workspace")), \
             patch.object(self.coder, "guest", side_effect=guest):
            with self.assertRaisesRegex(roost.RoostError, "reply lost"):
                self.request("coder-start")
            self.assertTrue(seed_file.exists())
            self.assertIn("pending", self.coder.read(self.record["id"]))
            result = self.request("coder-start")
        self.assertEqual(result["tasks"], [task])
        self.assertNotIn("pending", self.coder.read(self.record["id"]))
        self.assertFalse(seed_file.exists())


class GitReturn(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="roost return '$ ")
        self.root = Path(self.temp.name)
        self.canonical = self.root / "canonical"
        self.canonical.mkdir()
        self.git(self.canonical, "init", "-b", "main")
        self.git(self.canonical, "config", "user.name", "Synthetic Test")
        self.git(self.canonical, "config", "user.email", "synthetic@example.invalid")
        self.git(self.canonical, "config", "commit.gpgsign", "false")
        (self.canonical / "file").write_text("base\n")
        self.git(self.canonical, "add", "file")
        self.git(self.canonical, "commit", "-m", "base")
        self.base = self.git(self.canonical, "rev-parse", "HEAD")
        self.guest = self.root / "guest"
        self.git(self.canonical, "clone", str(self.canonical), str(self.guest))

    def tearDown(self):
        self.temp.cleanup()

    def git(self, repo, *args):
        return roost.git(repo, *args).stdout.strip()

    def test_return_pins_commits_and_leaves_head_index_and_dirty_files_alone(self):
        self.git(self.guest, "config", "user.name", "Synthetic Test")
        self.git(self.guest, "config", "user.email", "synthetic@example.invalid")
        self.git(self.guest, "config", "commit.gpgsign", "false")
        (self.guest / "file").write_text("returned\n")
        self.git(self.guest, "commit", "-am", "Synthetic change")
        (self.guest / "untracked").write_text("do not transfer me")
        bundle = roost.export_bundle(str(self.guest), "HEAD", self.base)
        (self.canonical / "file").write_text("my local edit\n")
        before = self.git(self.canonical, "status", "--porcelain=v1")
        result = roost.import_bundle(dict(directory=str(self.canonical), bundle=bundle))
        self.assertEqual(self.git(self.canonical, "rev-parse", "HEAD"), self.base)
        self.assertEqual(self.git(self.canonical, "status", "--porcelain=v1"), before)
        self.assertEqual(self.git(self.canonical, "rev-parse", result["ref"]), bundle["tip"])
        self.assertIn("+returned", result["diff"])
        self.assertNotIn("do not transfer", result["diff"])
        self.assertEqual(self.git(self.canonical, "ls-files", "--stage"),
                         self.git(self.canonical, "ls-tree", "HEAD").replace("blob ", "").replace("\t", " 0\t"))

    def test_corrupt_bundle_is_refused_before_ref_or_checkout_changes(self):
        bundle = roost.export_bundle(str(self.canonical), "HEAD")
        bundle["sha256"] = "0" * 64
        with self.assertRaisesRegex(roost.RoostError, "checksum"):
            roost.import_bundle(dict(directory=str(self.guest), bundle=bundle))
        self.assertEqual(self.git(self.guest, "for-each-ref", "refs/roost/returns"), "")

    def test_hostile_bundle_options_cannot_write_files_or_change_refs(self):
        bundle = roost.export_bundle(str(self.canonical), "HEAD")
        bundle["base"] = "--output=" + str(self.root / "must-not-exist")
        with self.assertRaisesRegex(roost.RoostError, "object ID"):
            roost.import_bundle(dict(directory=str(self.guest), bundle=bundle))
        self.assertFalse((self.root / "must-not-exist").exists())

    def test_export_from_a_linked_worktree_names_the_primary_checkout(self):
        linked = self.root / "linked"
        self.git(self.canonical, "worktree", "add", "-q", "-b", "side", str(linked))
        bundle = roost.export_bundle(str(linked), "HEAD")
        self.assertEqual(Path(bundle["directory"]).resolve(), self.canonical.resolve())

    def test_export_uses_selected_commit_only_and_cleans_its_temporary_ref(self):
        bundle = roost.export_bundle(str(self.canonical), "HEAD")
        self.assertEqual(bundle["tip"], self.base)
        self.assertEqual(self.git(self.canonical, "for-each-ref", "refs/roost/export"), "")
        roost.import_bundle(dict(directory=str(self.guest), bundle=bundle))
        self.assertEqual(self.git(self.guest, "rev-parse", "HEAD"), self.base)
