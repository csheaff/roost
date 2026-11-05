"""The helper killed partway through what it does, as a dropped connection or
a reboot leaves it: see crash_harness.py. `Crashes` holds each crash that went
wrong, for `make test`; `Sweep` kills every action at every step, for
`make crash`."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import crash_harness as harness
from crash_harness import Box
import crash_scenarios as scenarios

# Set by `make crash`: "commands" or "lines", which sweeps every line too.
SWEEP = os.environ.get("ROOST_CRASH_SWEEP")


class Crashes(unittest.TestCase):
    def box(self):
        box = Box()
        self.addCleanup(box.close)
        return box

@unittest.skipUnless(SWEEP, "A sweep takes a while: make crash")
class Sweep(unittest.TestCase):
    workers = int(os.environ.get("ROOST_CRASH_WORKERS", "6"))

    def assert_no_problems(self, outcomes):
        self.assertEqual([], ["%s@%d (%s): %s" % (outcome["mode"], outcome["at"], outcome["step"], problem)
                              for outcome in outcomes for problem in outcome["problems"]])

    def sweep(self, modes):
        for scenario in scenarios.ALL:
            with self.subTest(scenario=scenario.__name__):
                self.assert_no_problems(harness.sweep(scenario, modes=modes, workers=self.workers))

    def test_every_command(self):
        self.sweep(("before", "after", "orphan", "racing", "fail", "inside"))

    def test_a_crash_while_asking_again(self):
        for scenario in (scenarios.Merge, scenarios.MergeSquash, scenarios.Retire, scenarios.Discard):
            with self.subTest(scenario=scenario.__name__):
                self.assert_no_problems(harness.twice(scenario, workers=self.workers))

    @unittest.skipUnless(SWEEP == "lines", "make crash CRASH_SWEEP=lines")
    def test_every_line(self):
        self.sweep(("line",))


if __name__ == "__main__":
    unittest.main()
