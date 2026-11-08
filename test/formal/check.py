#!/usr/bin/env python3
"""Model-check Roost's TLA+ models: python3 test/formal/check.py [MODEL...]

Each folder under test/formal holds one model, Name.tla, and its configs:

  Name.cfg            must pass: TLC explores every state and breaks no rule.
  Name.VARIANT.cfg    a broken variant of the code, which must fail.  Its
                      first line says how:  \\* expect: RuleName
                      (an INVARIANT's name, or "deadlock", or "temporal").

A model that passes and a variant that fails as expected both count as OK.
With no MODEL, every folder runs.  TLC 1.7.4 and Java come from mise, the
same versions every time, or from TLA2TOOLS (the jar) and JAVA if set.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TLC_TOOL = (
    "http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/"
    "v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be245"
    "73c45d5aa0ff20a8b96b23d01e050e88]@1.7.4"
)
JAVA_TOOL = "java@temurin-25"


def tools():
    jar, java = os.environ.get("TLA2TOOLS"), os.environ.get("JAVA")
    if jar and java:
        return jar, java
    if not shutil.which("mise"):
        sys.exit("check.py needs mise (brew install mise), "
                 "or TLA2TOOLS and JAVA set")
    env = dict(os.environ, MISE_CEILING_PATHS=str(HERE))

    def mise(*args):
        return subprocess.run(["mise", *args], capture_output=True,
                              text=True, cwd=HERE, env=env)

    where = mise("where", TLC_TOOL)
    if where.returncode != 0:
        got = mise("install", JAVA_TOOL, TLC_TOOL)
        if got.returncode != 0:
            sys.exit("mise install failed:\n" + got.stderr)
        where = mise("where", TLC_TOOL)
    which = mise("which", "java", "--tool", JAVA_TOOL)
    return (jar or str(Path(where.stdout.strip()) / "tla2tools.jar"),
            java or which.stdout.strip())


def expected(cfg):
    first = cfg.read_text().splitlines()[:1]
    m = re.match(r"\\\*\s*expect:\s*(\S+)", first[0]) if first else None
    return m.group(1) if m else None


def outcome(text):
    m = re.search(r"Invariant (\S+) is violated", text)
    if m:
        return m.group(1)
    if "Deadlock reached" in text:
        return "deadlock"
    if "Temporal properties were violated" in text:
        return "temporal"
    if "Model checking completed. No error has been found." in text:
        return "pass"
    return "error"


def run(jar, java, spec, cfg):
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [java, "-XX:+UseParallelGC", f"-Djava.io.tmpdir={tmp}",
               "-cp", jar, "tlc2.TLC", "-workers", "auto", "-cleanup",
               "-metadir", tmp, "-config", str(cfg), spec.name]
        p = subprocess.run(cmd, capture_output=True, text=True,
                           cwd=spec.parent)
    return p.stdout + p.stderr


def main(names):
    folders = ([HERE / n for n in names] if names else
               sorted(p for p in HERE.iterdir() if p.is_dir()
                      and not p.name.startswith(("_", "."))))
    jar, java = tools()
    failures = 0
    for folder in folders:
        for spec in sorted(folder.glob("*.tla")):
            for cfg in sorted([folder / (spec.stem + ".cfg"),
                               *folder.glob(spec.stem + ".*.cfg")]):
                if not cfg.exists():
                    continue
                want = expected(cfg) or "pass"
                start = time.monotonic()
                text = run(jar, java, spec, cfg)
                got = outcome(text)
                states = re.findall(r"(\d+) distinct states found", text)
                took = time.monotonic() - start
                ok = got == want
                failures += not ok
                print(f"{'ok  ' if ok else 'FAIL'} {folder.name}/{cfg.name}: "
                      f"{got} (want {want}), "
                      f"{states[-1] if states else '?'} states, {took:.1f}s")
                if not ok:
                    print(text[-4000:])
    print("all models as expected" if not failures
          else f"{failures} model run(s) not as expected")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
