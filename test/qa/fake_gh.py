#!/usr/bin/env python3
"""gh for make qa: GitHub as a journey sets it, in the directory QA_GITHUB.

qa.py puts this first on PATH, as gh.  `pr list` answers with list.json
there, `api graphql` with reviews.json, by pull request number, and
`pr create` with pull request 21.  Each call is logged in log there."""
import json
import os
import re
import sys

DIRECTORY = os.environ["QA_GITHUB"]


def canned(name, default):
    path = os.path.join(DIRECTORY, name)
    if not os.path.exists(path):
        return default
    with open(path) as file:
        return json.load(file)


def main(args):
    with open(os.path.join(DIRECTORY, "log"), "a") as log:
        log.write(json.dumps(args) + "\n")
    if args[:2] == ["pr", "list"]:
        # Filtered by --state as GitHub would; an entry without one is open.
        state = args[args.index("--state") + 1].upper() if "--state" in args else "OPEN"
        print(json.dumps([pr for pr in canned("list.json", [])
                          if state == "ALL" or pr.get("state", "OPEN") == state]))
    elif args[:2] == ["api", "graphql"]:
        query = next(arg for arg in args if arg.startswith("query="))
        reviews = canned("reviews.json", {})
        print(json.dumps(dict(data=dict(repository={
            "pr" + number: reviews.get(number) for number in re.findall(r"pullRequest\(number: (\d+)\)", query)}))))
    elif args[:2] == ["pr", "create"]:
        print("https://github.com/qa/notes/pull/21")
    elif args[:2] == ["auth", "status"]:
        print("github.com\n  Logged in to github.com account qa (keyring)")
    elif args[:2] == ["issue", "list"]:
        print("[]")
    else:
        sys.stderr.write("fake gh: nothing canned for gh %s\n" % " ".join(args))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
