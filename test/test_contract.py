"""What a live contract run puts back in Codex's config: see
CodexSession.clean_up in test/agent_contract.py."""
import unittest

import agent_contract

REPO = "/home/user/.local/share/roost-contract/repo"
HOOK = '[hooks.state."/<session-flags>/config.toml:stop:0:0"]\n'


class CodexConfigTest(unittest.TestCase):
    def test_tables_join_to_the_config_again(self):
        config = ('model = "x"\nnotes = """\n[not.a.table]\n"""\npaths = [\n  ["a"],\n]\n'
                  '[mcp_servers."endpoint=dev"]\nurl = "http://h/?a=[1]" # [no]\n')
        tables = agent_contract.toml_tables(config)
        self.assertEqual("".join(text for _, text in tables), config)
        self.assertEqual([header for header, _ in tables], [None, '[mcp_servers."endpoint=dev"]'])

    def test_only_the_runs_tables_are_put_back(self):
        before = ('model = "x"\n\n' + HOOK + 'trusted_hash = "old"\n\n'
                  '[projects."%s-other"]\ntrust_level = "trusted"\n' % REPO)
        after = (before.replace('"old"', '"new"') + '[mcp_servers."endpoint=dev"]\nk = 1\n'
                 '[projects."%s"]\ntrust_level = "trusted"\n'
                 '[projects."/a]b"]\ntrust_level = "untrusted"\n' % REPO)
        restored = agent_contract.restore_codex_tables(after, before, REPO)
        self.assertIn('trusted_hash = "old"', restored)
        self.assertNotIn('"new"', restored)
        for kept in ('[mcp_servers."endpoint=dev"]\nk = 1\n', '[projects."%s-other"]' % REPO,
                     '[projects."/a]b"]\ntrust_level = "untrusted"\n'):
            self.assertIn(kept, restored)
        self.assertNotIn('[projects."%s"]' % REPO, restored)

    def test_a_table_at_the_end_keeps_its_line(self):
        restored = agent_contract.restore_codex_tables(
            'a = 1\n' + HOOK + 'h = "new"\n[other]\nk = 1', 'a = 1\n' + HOOK + 'h = "old"', REPO)
        self.assertEqual(restored, 'a = 1\n' + HOOK + 'h = "old"\n[other]\nk = 1')


if __name__ == "__main__":
    unittest.main()
