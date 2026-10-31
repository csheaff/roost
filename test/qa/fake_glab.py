#!/usr/bin/env python3
"""glab for make qa: GitLab as a journey sets it, in the directory QA_GITLAB.

qa.py puts this first on PATH, as glab.  `api graphql` answers a query
for merge requests with those in list.json from the branch it names, open
ones only when it asks for those, one for issues with issues.json, and
mergeRequestCreate with merge request 4.  Each call is logged in log
there."""
import json
import os
import sys

DIRECTORY = os.environ["QA_GITLAB"]
URL = "https://gitlab.qa.invalid/qa/notes"


def canned(name, default):
    path = os.path.join(DIRECTORY, name)
    if not os.path.exists(path):
        return default
    with open(path) as file:
        return json.load(file)


def main(args):
    with open(os.path.join(DIRECTORY, "log"), "a") as log:
        log.write(json.dumps(args) + "\n")
    if args[:2] == ["auth", "status"]:
        sys.stderr.write("gitlab.qa.invalid\n  Logged in to gitlab.qa.invalid as qa\n")
        return 0
    if args[:2] != ["api", "graphql"]:
        sys.stderr.write("fake glab: nothing canned for glab %s\n" % " ".join(args))
        return 1
    fields = dict(args[i + 1].split("=", 1) for i in range(len(args) - 1) if args[i] == "-f")
    query = fields["query"]
    if "mergeRequestCreate" in query:
        data = dict(mergeRequestCreate=dict(mergeRequest=dict(iid="4", webUrl=URL + "/-/merge_requests/4"), errors=[]))
    elif "issues(" in query:
        data = dict(project=dict(issues=dict(nodes=canned("issues.json", []))))
    else:
        listed = [found for found in canned("list.json", []) if found.get("sourceBranch") == fields["branch"]
                  and ("state: opened" not in query or found.get("state") == "opened")]
        data = dict(project=dict(mergeRequests=dict(nodes=listed)))
    print(json.dumps(dict(data=data)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
