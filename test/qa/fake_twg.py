#!/usr/bin/env python3
"""twg for make qa: Jira as a journey sets it, in the directory QA_JIRA.

qa.py puts this first on PATH, as twg.  `jira workitem query` answers
with the work items in issues.json there, in twg's envelope.  Each call
is logged in log there."""
import json
import os
import sys

DIRECTORY = os.environ["QA_JIRA"]


def main(args):
    with open(os.path.join(DIRECTORY, "log"), "a") as log:
        log.write(json.dumps(args) + "\n")
    if args[:3] == ["jira", "workitem", "query"]:
        path = os.path.join(DIRECTORY, "issues.json")
        issues = []
        if os.path.exists(path):
            with open(path) as file:
                issues = json.load(file)
        print(json.dumps(dict(apiVersion="1", command="jira workitem query", meta={},
                              data=dict(issues=issues, pageInfo=dict(hasNextPage=False)))))
        return 0
    sys.stderr.write("fake twg: nothing canned for twg %s\n" % " ".join(args))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
