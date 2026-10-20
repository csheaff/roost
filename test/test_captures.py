"""The helper reads each recorded agent session as it did when recorded.

See test/agent_captures.py. A failure here means the helper now makes
something else of what a real agent sent: if that is meant, write the
captures' expectations again with `python3 test/agent_captures.py` and
check the diff.
"""
import unittest

import agent_captures


class CaptureTest(unittest.TestCase):
    def test_every_capture_reads_as_recorded(self):
        paths = sorted(agent_captures.CAPTURES.glob("*.jsonl"))
        self.assertTrue(paths, "no captures in test/captures")
        for path in paths:
            meta, entries = agent_captures.read(path)
            thens = agent_captures.replay(meta, [{k: v for k, v in entry.items() if k != "then"}
                                                 for entry in entries])
            step = None
            for number, (entry, then) in enumerate(zip(entries, thens), 2):
                step = entry.get("step", step)
                if then is not None:
                    with self.subTest(capture=path.name, line=number, step=step):
                        self.assertEqual(then, entry.get("then"))

    def test_captures_keep_no_tool_output_nor_another_sessions_words(self):
        for path in sorted(agent_captures.CAPTURES.glob("*.jsonl")):
            meta, entries = agent_captures.read(path)
            for number, entry in enumerate(entries, 2):
                with self.subTest(capture=path.name, line=number):
                    self.assertEqual(entry, agent_captures.withhold(entry))

    def test_captures_name_nothing_of_this_machine(self):
        from pathlib import Path
        home = str(Path.home())
        if home == agent_captures.HOME:
            self.skipTest("this home is the captures' stand-in for one")
        for path in sorted(agent_captures.CAPTURES.glob("*.jsonl")):
            with self.subTest(capture=path.name):
                self.assertNotIn(home, path.read_text())


if __name__ == "__main__":
    unittest.main()
