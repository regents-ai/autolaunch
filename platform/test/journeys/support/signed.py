"""One signed request to the site's agent routes, for a route the regents command line has no
command for yet (support/agent.ts, `Agent.signed`). It signs and sends exactly as a signed
command does, with the command line's own code: the sign-in to Autolaunch this agent's key folder
holds (renewed when due), the signature over the request and its body, one send, no redirect.

  python -I signed.py METHOD PATH   with the JSON body, if any, on stdin

Prints {"status": ..., "json": ...}: the site's status and its JSON answer.
"""

import json
import os
import sys

from regents_cli import siwa
from regents_cli.http import Request, respond
from regents_cli.platforms import DEFAULT_TIMEOUT_MS

method, target = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
base = os.environ["AUTOLAUNCH_BASE_URL"]
request = Request(method, target, body=json.loads(text) if text else None)
siwa.signs_for("autolaunch", base, DEFAULT_TIMEOUT_MS)
receipt = siwa.current("autolaunch", DEFAULT_TIMEOUT_MS)
signed = Request(method, target, body=request.body, headers=siwa.sign(request, receipt, base))
response = respond(base, signed, DEFAULT_TIMEOUT_MS)
print(json.dumps({"status": response.status_code, "json": response.json()}))
