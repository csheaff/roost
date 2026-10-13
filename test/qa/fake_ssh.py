#!/usr/bin/env python3
"""ssh for make qa --remote: the host qa-remote is this machine, as far
away as QA_SSH_LATENCY seconds each way.

Roost and tmux-control run ssh from PATH, and qa.py puts this first.  It
runs the command it is given on this machine, in the home qa.py gives the
run, and relays what goes in and comes out a latency late, in order, as
a network does.  Replies then arrive as late as they do from a host you
reach over SSH, which is where races between them show.  Any other host
can't be reached, as with ssh."""
import os
import pty
import queue
import subprocess
import sys
import threading
import time
import tty

HOST = "qa-remote"
LATENCY = float(os.environ.get("QA_SSH_LATENCY", "0.15"))
# The host's home: short, as tmux's socket paths in it must be.
HOME = os.environ.get("QA_REMOTE_HOME") or os.environ.get("HOME", "/")
ENV = dict(os.environ, HOME=HOME)
# Options that take a value, as `ssh -o ControlPath=...'.
WITH_VALUE = set("BbcDEeFIiJLlmOoPpQRSWw")


def parse(argv):
    """HOST and the remote command in ARGV, ssh's arguments, whether it
    asks the shared connection something (-O) rather than to run one, and
    whether it asks for a terminal (-t), as TRAMP does."""
    control = terminal = False
    remote_command = ""
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if not arg.startswith("-") or arg == "-":
            break
        letters = arg[1:]
        control = control or letters.startswith("O")
        terminal = terminal or (letters.startswith("t") and set(letters) == {"t"})
        if letters == "o" and i + 1 < len(argv) and argv[i + 1].startswith("RemoteCommand="):
            remote_command = argv[i + 1][len("RemoteCommand="):].strip('"')
        for n, letter in enumerate(letters):
            if letter in WITH_VALUE:
                # The value follows, unless it is attached, as in -oX=y.
                if n == len(letters) - 1:
                    i += 1
                break
        i += 1
    host = argv[i] if i < len(argv) else ""
    return host, " ".join(argv[i + 1:]) or remote_command, control, terminal


def relay(source, sink, done):
    """Copy what SOURCE reads to SINK, each chunk LATENCY late, in order;
    then call DONE.  Return the thread that writes."""
    pending = queue.Queue()

    def read():
        while True:
            try:
                data = os.read(source, 65536)
            except OSError:
                data = b""
            pending.put((time.monotonic() + LATENCY, data))
            if not data:
                return

    def write():
        while True:
            due, data = pending.get()
            delay = due - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            if not data:
                done()
                return
            try:
                os.write(sink, data)
            except OSError:
                done()
                return

    threading.Thread(target=read, daemon=True).start()
    # A daemon, as what goes in may never end: ssh exits with the command
    # it ran.  What comes out, its callers wait for.
    writer = threading.Thread(target=write, daemon=True)
    writer.start()
    return writer


def main():
    host, command, control, terminal = parse(sys.argv[1:])
    if host.split("@")[-1] != HOST:
        sys.stderr.write("ssh: Could not resolve hostname %s: nodename nor servname provided, "
                         "or not known\r\n" % host)
        return 255
    # Asked about a shared connection, which this host has no need of.
    if control:
        return 0
    # Connecting takes a round trip or two.
    time.sleep(2 * LATENCY)
    if terminal or not command:
        return with_terminal(command)
    child = subprocess.Popen(["/bin/sh", "-c", command] if command else ["/bin/sh"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             cwd=HOME, env=ENV)

    def close_input():
        try:
            child.stdin.close()
        except OSError:
            pass

    relay(0, child.stdin.fileno(), close_input)
    out = relay(child.stdout.fileno(), 1, lambda: None)
    err = relay(child.stderr.fileno(), 2, lambda: None)
    code = child.wait()
    out.join()
    err.join()
    return code


def with_terminal(command):
    """Run COMMAND, or a shell, on a terminal of its own, as ssh -t does,
    with this end's terminal raw, so that one's echo and editing are the
    far end's."""
    if os.isatty(0):
        tty.setraw(0)
    master, slave = pty.openpty()
    child = subprocess.Popen(["/bin/sh", "-c", command] if command else ["/bin/sh"],
                             stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                             cwd=HOME, env=ENV)
    os.close(slave)
    relay(0, master, lambda: None)
    out = relay(master, 1, lambda: None)
    code = child.wait()
    out.join()
    return code


if __name__ == "__main__":
    sys.exit(main())
