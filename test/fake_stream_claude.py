#!/usr/bin/env python3
"""Offline fixture for conversation tasks: Claude Code exchanging JSON
messages on standard input and output, as `--input-format stream-json
--output-format stream-json` makes it, calling the task's hooks.

A prompt of "permission" asks to run a command and waits for the answer;
any other prompt is echoed back as the reply."""
import json
from pathlib import Path
import subprocess
import sys
import uuid

settings_path = sys.argv[sys.argv.index("--settings") + 1]
settings = json.loads(Path(settings_path).read_text())
session = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else str(uuid.uuid4())
transcript = Path(settings_path).with_suffix(".transcript.jsonl")


def event(name, **fields):
    payload = dict(hook_event_name=name, session_id=session, transcript_path=str(transcript), **fields)
    for matcher in settings["hooks"].get(name, []):
        for hook in matcher["hooks"]:
            subprocess.run(hook["command"], input=json.dumps(payload), text=True, shell=True, check=True)


def emit(message, logged=True):
    """Write MESSAGE out, and to the transcript as Claude Code would."""
    message.setdefault("session_id", session)
    if logged:
        message.setdefault("uuid", str(uuid.uuid4()))
        with transcript.open("a") as log:
            log.write(json.dumps(message) + "\n")
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(text):
    emit(dict(type="assistant", message=dict(role="assistant", content=[dict(type="text", text=text)])))
    emit(dict(type="result", subtype="success", is_error=False), logged=False)
    event("Stop", last_assistant_message=text)


def answer(request_id, response=None):
    emit(dict(type="control_response",
              response=dict(subtype="success", request_id=request_id, response=response or {})), logged=False)


event("SessionStart")
for line in sys.stdin:
    message = json.loads(line)
    kind = message.get("type")
    if kind == "control_request":
        subtype = message["request"]["subtype"]
        answer(message["request_id"], dict(models=[dict(value="haiku")], commands=[]) if subtype == "initialize"
               else None)
    elif kind == "user":
        prompt = message["message"]["content"]
        emit(dict(type="user", isReplay=True, message=dict(role="user", content=prompt)))
        event("UserPromptSubmit")
        if prompt != "permission":
            reply("echo: " + prompt)
            continue
        tool = "toolu_" + uuid.uuid4().hex[:12]
        command = dict(command="echo hi", description="Say hi")
        emit(dict(type="assistant", message=dict(role="assistant", content=[
            dict(type="tool_use", id=tool, name="Bash", input=command)])))
        emit(dict(type="control_request", request_id="ask-" + tool,
                  request=dict(subtype="can_use_tool", tool_name="Bash", input=command, tool_use_id=tool)),
             logged=False)
        for answered in sys.stdin:
            answered = json.loads(answered)
            if answered.get("type") == "control_response":
                break
        behavior = answered["response"]["response"]["behavior"]
        emit(dict(type="user", message=dict(role="user", content=[
            dict(type="tool_result", tool_use_id=tool, content="hi" if behavior == "allow" else "declined")])))
        reply("done: " + behavior)
