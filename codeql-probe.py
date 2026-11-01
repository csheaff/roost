# Temporary, for csheaff/roost#194: input read from stdin, as the helper
# reads its requests, reaching a shell and a path. CodeQL should flag
# both. Removed before merging.
import json
import subprocess
import sys

request = json.load(sys.stdin)
subprocess.run(request["command"], shell=True)
open(request["path"]).close()
