#!/usr/bin/env python3
"""Run Roost's tests on every core: `make test`, and `make quick`.

The ERT suite runs in several Emacs at once, each taking a share of the
tests and of each sweep's cases (see `roost-test--share` in roost-test.el),
and the Python suite in several processes beside them. Run in one process
they take about 18 minutes; on four cores, about four.

A Python test that fails is run once more, alone, after the rest: they
wait on real tmux servers, and a wait can run out while every core is
busy. One that passes then is named, so a test that only passes alone is
seen.

    test/run.py                  everything
    test/run.py --quick          one case in twelve of each sweep, and only
                                 the suites that read something changed
                                 since they last passed in full
    test/run.py -k REGEXP        ERT tests matching REGEXP, Python tests
                                 whose names hold it
    test/run.py --ert, --python  one suite only
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ERT_FILES = ["roost-test.el", "roost-sweep.el", "roost-sweep-late.el"]


# What each suite reads: `make quick` leaves out a suite that passed, in
# full, with all of these as they are now.
READS = {
    "ert": ["roost.el", "scripts/roost_remote.py", "test/*.el"],
    "python": ["scripts/roost_remote.py", "test/*.py", "test/captures/**/*"],
}


def stamp(kind, args):
    """A hash of all a suite reads, and of how it is run."""
    digest = hashlib.sha256(repr((args.emacs, args.load_path)).encode() if kind == "ert" else b"")
    for pattern in READS[kind]:
        for path in sorted(ROOT.glob(pattern)):
            if path.is_file():
                digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def passed_file():
    """Where the stamps of suites that passed are kept: in .git, so untracked."""
    found = subprocess.run(["git", "rev-parse", "--absolute-git-dir"], cwd=ROOT, capture_output=True, text=True)
    return Path(found.stdout.strip()) / "roost-tests-passed.json" if found.returncode == 0 else None


def passed():
    path = passed_file()
    try:
        return json.loads(path.read_text()) if path else {}
    except (OSError, ValueError):
        return {}


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def python_tests(pattern):
    """The IDs of the Python tests, those holding PATTERN if it is given."""
    sys.path.insert(0, str(HERE))
    ids = sorted(test.id() for test in flatten(unittest.defaultTestLoader.discover(str(HERE), pattern="test_*.py")))
    broken = [name for name in ids if name.startswith("unittest.loader._FailedTest")]
    if broken:
        sys.exit("Could not load %s" % ", ".join(broken))
    return [name for name in ids if not pattern or pattern in name]


class Recorder(unittest.TextTestResult):
    """A result that also keeps each test's time, for the slowest."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.times = {}

    def startTest(self, test):
        self.started = time.monotonic()
        super().startTest(test)

    def stopTest(self, test):
        self.times[test.id()] = round(time.monotonic() - self.started, 2)
        super().stopTest(test)


def python_worker(names_file, report_file):
    """Run the tests NAMES_FILE lists, and write what happened to REPORT_FILE."""
    sys.path.insert(0, str(HERE))
    names = json.loads(Path(names_file).read_text())
    suite = unittest.defaultTestLoader.loadTestsFromNames(names)
    result = unittest.TextTestRunner(resultclass=Recorder, verbosity=2, stream=sys.stdout).run(suite)
    Path(report_file).write_text(json.dumps({
        "ran": result.testsRun,
        "skipped": len(result.skipped),
        # A subtest's failure is its test's, which is what can be run again.
        "failed": list({getattr(test, "test_case", test).id(): [getattr(test, "test_case", test).id(), text]
                        for test, text in result.failures + result.errors}.values()),
        "times": result.times,
    }))
    return 0 if result.wasSuccessful() else 1


def start_python(names, scratch, label):
    names_file, report, log = (scratch / (label + suffix) for suffix in (".names", ".report", ".log"))
    names_file.write_text(json.dumps(names))
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--worker", str(names_file), str(report)],
                               cwd=ROOT, stdout=log.open("w"), stderr=subprocess.STDOUT)
    return {"kind": "python", "label": label, "process": process, "report": report, "log": log, "names": names}


def start_ert(args, share, of, scratch):
    log = scratch / ("ert-%d.log" % share)
    env = dict(os.environ, ROOST_TEST_SHARE="%d/%d" % (share, of), ROOST_TEST_SAMPLE=str(args.sample),
               ROOST_TEST_MATCH=args.k or "")
    command = [args.emacs, "-Q", "--batch", "-L", str(ROOT), "-L", str(HERE)] + list(args.load_path)
    for name in ERT_FILES:
        command += ["-l", str(HERE / name)]
    command += ["-f", "roost-test-run-share"]
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log.open("w"), stderr=subprocess.STDOUT)
    return {"kind": "ert", "label": "ert-%d" % share, "process": process, "log": log}


SUMMARY = re.compile(r"^Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?", re.M)
ERT_TIME = re.compile(r"^ +(?:passed|FAILED) +\d+/\d+ +(\S+) \(([0-9.]+) sec\)", re.M)
ERT_DONE = re.compile(r"^ +(passed|FAILED|skipped) +\d+/\d+ +(\S+)", re.M)


def ert_outcome(job):
    """What an Emacs's log says: tests run, skipped, the names that failed, times."""
    text = job["log"].read_text(errors="replace")
    summary = SUMMARY.search(text)
    failed = re.findall(r"^ +FAILED +\d+/\d+ +(\S+)", text, re.M)
    if not summary:
        # It died before it finished: say so rather than count nothing.
        failed = failed or ["(Emacs exited with %s before finishing; see %s)" % (job["process"].returncode, job["log"])]
    done = ERT_DONE.findall(text)
    return ({name for _, name in done}, {name for how, name in done if how == "skipped"}, sorted(set(failed)),
            {name: float(seconds) for name, seconds in ERT_TIME.findall(text)})


def ert_failure_text(job, name):
    """The part of an Emacs's log about test NAME."""
    text = job["log"].read_text(errors="replace")
    match = re.search(r"^Test %s (?:backtrace|condition):.*?(?=^ +(?:passed|FAILED|skipped) )" % re.escape(name),
                      text, re.M | re.S)
    return match.group(0).rstrip() if match else ""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs", "-j", type=int, default=int(os.environ.get("JOBS") or os.cpu_count() or 2))
    parser.add_argument("--quick", action="store_true",
                        help="one case in twelve of each sweep, and no suite that passed on what it reads now")
    parser.add_argument("--all", action="store_true", help="with --quick, run a suite that has nothing new to read too")
    parser.add_argument("--sample", type=int, default=1, help="one case in this many of each sweep")
    parser.add_argument("-k", metavar="REGEXP", help="only tests matching it")
    parser.add_argument("--ert", action="store_true", help="only the ERT suite")
    parser.add_argument("--python", action="store_true", help="only the Python suite")
    parser.add_argument("--emacs", default=os.environ.get("EMACS") or "emacs")
    # One argument, as --load-path="-L a -L b": -L would read as an option of ours.
    parser.add_argument("--load-path", default="", metavar="ARGS", type=lambda value: shlex.split(value),
                        help='more arguments for Emacs, in one, as in --load-path="-L ~/src/magit/lisp"')
    parser.add_argument("--slowest", type=int, default=0, metavar="N", help="name the N slowest tests")
    parser.add_argument("--keep", action="store_true", help="keep the logs of a run that passed")
    parser.add_argument("--worker", nargs=2, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        return python_worker(*args.worker)
    if args.quick and args.sample == 1:
        args.sample = 12
    jobs = max(1, args.jobs)
    scratch = Path(tempfile.mkdtemp(prefix="roost-tests-"))
    started = time.monotonic()
    running = []
    # A suite that passed, whole, on what it reads now has nothing new to say.
    stamps = {kind: stamp(kind, args) for kind in READS}
    unchanged = []
    if args.quick and not args.k and not args.all:
        before = passed()
        unchanged = [kind for kind in READS if before.get(kind) == stamps[kind]]
    run_ert = not args.python and "ert" not in unchanged
    run_python = not args.ert and "python" not in unchanged
    if run_ert:
        running += [start_ert(args, share, jobs, scratch) for share in range(jobs)]
    if run_python:
        names = python_tests(args.k)
        for share in range(jobs):
            mine = names[share::jobs]
            if mine:
                running.append(start_python(mine, scratch, "python-%d" % share))
    for job in running:
        job["process"].wait()

    # A sweep runs in every Emacs, a share of its cases in each: count it once.
    counts = {"ert": [set(), set()], "python": [0, 0]}
    failures, flaky, times = [], [], {}
    again = []
    for job in running:
        if job["kind"] == "ert":
            ran, skipped, failed, took = ert_outcome(job)
            failures += [("ert", name, ert_failure_text(job, name), job["log"]) for name in failed]
        else:
            if job["report"].exists():
                report = json.loads(job["report"].read_text())
                ran, skipped, took = report["ran"], report["skipped"], report["times"]
                again += report["failed"]
            else:
                ran, skipped, took = 0, 0, {}
                failures.append(("python", job["label"], "The worker exited with %s before finishing."
                                 % job["process"].returncode, job["log"]))
        if job["kind"] == "ert":
            counts["ert"][0] |= ran
            counts["ert"][1] |= skipped
            for name, seconds in took.items():
                times[name] = times.get(name, 0) + seconds
        else:
            counts["python"][0] += ran
            counts["python"][1] += skipped
            times.update(took)
    # Alone, with every core free: a wait that ran out under load passes now.
    for index, (name, text) in enumerate(again):
        job = start_python([name], scratch, "again-%d" % index)
        job["process"].wait()
        report = json.loads(job["report"].read_text()) if job["report"].exists() else {"failed": [[name, text]]}
        if report["failed"]:
            failures.append(("python", name, report["failed"][0][1], job["log"]))
        else:
            flaky.append(name)

    elapsed = time.monotonic() - started
    if args.slowest:
        print("Slowest:")
        for name, seconds in sorted(times.items(), key=lambda item: -item[1])[:args.slowest]:
            print("  %7.1fs  %s" % (seconds, name))
    for kind, name, text, log in failures:
        print("\n%s\nFAILED (%s): %s\n%s\n%s\n  log: %s" % ("=" * 70, kind, name, "-" * 70, text.rstrip(), log))
    if flaky:
        print("\nPassed only when run again, alone:\n  " + "\n  ".join(flaky))
    parts = []
    if run_ert:
        parts.append("ERT %d tests, %d skipped" % (len(counts["ert"][0]), len(counts["ert"][1])))
    if run_python:
        parts.append("Python %d tests, %d skipped" % (counts["python"][0], counts["python"][1]))
    names = {"ert": "ERT", "python": "Python"}
    for kind in unchanged:
        if not (args.python if kind == "ert" else args.ert):
            print("%s left out: nothing it reads has changed since it passed (--all runs it)" % names[kind])
    if not parts:
        print("Nothing to run.")
        return 0
    if args.k and not failures and not len(counts["ert"][0]) and not counts["python"][0]:
        # An Emacs regexp for the ERT tests: \\| between alternatives.
        print("No test matches %s" % args.k)
        return 1
    # Only a whole suite, every case of it, vouches for what it read.
    if not args.k and args.sample == 1 and passed_file():
        now = passed()
        for kind, ran in (("ert", run_ert), ("python", run_python)):
            if ran and not any(failure[0] == kind for failure in failures):
                now[kind] = stamps[kind]
            elif ran:
                now.pop(kind, None)
        passed_file().write_text(json.dumps(now))
    sampled = ", one case in %d of each sweep" % args.sample if args.sample > 1 else ""
    print("\n%s in %dm%02ds on %d cores%s: %s" % ("; ".join(parts), elapsed // 60, elapsed % 60, jobs, sampled,
                                                 "%d FAILED" % len(failures) if failures else "all passed"))
    if failures or args.keep:
        print("Logs in %s" % scratch)
    else:
        for path in scratch.iterdir():
            path.unlink()
        scratch.rmdir()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
