#!/usr/bin/env python3
"""Synthetic capture pipe for native tests. Never reads or injects OS input."""
import json
import os
from pathlib import Path
import sys
import time

assert (os.environ.get("WK_TARGET_ABSOLUTE") == "1") == (os.environ["WK_TEST_ABSOLUTE"] == "1")
assert os.environ.get("WK_TARGET_IPHONE") != "1"
assert (os.environ.get("WK_INVERT_SCROLL") == "1") == (os.environ["WK_TEST_INVERT_SCROLL"] == "1")
if os.environ.get("WK_TEST_INPUT_ONLY") == "1":
    assert os.environ.get("WK_WIRED_INPUT") == "1"
    assert os.environ.get("WK_WIRED_CLIPBOARD") != "1"
Path(os.environ["WK_TEST_STARTED"]).write_text("started", encoding="utf-8")
for delay, event in json.loads(os.environ.get("WK_TEST_EVENTS", "[]")):
    time.sleep(delay)
    print(event, flush=True)
for command in sys.stdin:
    with open(os.environ["WK_TEST_COMMANDS"], "a", encoding="utf-8") as stream:
        stream.write(json.dumps([time.monotonic(), command.strip()]) + "\n")
