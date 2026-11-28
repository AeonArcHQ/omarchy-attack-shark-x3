#!/usr/bin/env python3
"""Read-only listener for the X3 receiver's vendor input reports.

Usage: tools/listen.py [--seconds N]

The receiver node (1d57:fa60, USB interface 2) is found through sysfs the same
way x3-hid finds it. Every line is one report-3 event: power, dpi, polling,
ack, or unknown.
"""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import os
import select
import sys
import time
from pathlib import Path


def load_x3_hid():
    helper = Path(__file__).resolve().parents[1] / "x3-hid"
    loader = importlib.machinery.SourceFileLoader("x3_hid", str(helper))
    spec = importlib.util.spec_from_loader("x3_hid", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


x3_hid = load_x3_hid()


def describe_report(report):
    """(kind, details) for one input report, or None when it is not report 3."""
    if len(report) < 5 or report[0] != x3_hid.REPORT_ID:
        return None
    message = x3_hid.decode(report)
    if message is not None:
        kind = message["event"]
        if kind == "power":
            return kind, f"state={message['state']} level={message['level']}"
        if kind == "dpi":
            return kind, f"stage={message['stage']}"
        if kind == "polling":
            return kind, f"index={message['index']}"
    ack = x3_hid.ack_for(report)
    if ack is not None:
        report_id, status = ack
        return "ack", f"report=0x{report_id:02x} status={status}"
    return "unknown", f"model=0x{report[1]:02x} event=0x{report[2]:02x} data={report[3:].hex(' ')}"


def listen(device, seconds):
    fd = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
    end = None if seconds is None else time.monotonic() + seconds
    try:
        while True:
            timeout = 0.5
            if end is not None:
                left = end - time.monotonic()
                if left <= 0:
                    break
                timeout = min(timeout, left)
            ready, _, _ = select.select([fd], [], [], timeout)
            if not ready:
                continue
            report = os.read(fd, 64)
            if not report:
                break
            described = describe_report(report)
            if described is None:
                continue
            kind, details = described
            print(f"{time.time():.2f} {kind} {report.hex(' ')} {details}", flush=True)
    finally:
        os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--seconds", type=float, default=None,
                        help="stop after N seconds (default: listen until interrupted)")
    args = parser.parse_args(argv)

    device = x3_hid.find_devices()["receiver"]
    if device is None:
        print("listen: X3 receiver vendor interface (1d57:fa60, interface 2) not found", file=sys.stderr)
        return 1
    try:
        listen(device, args.seconds)
    except PermissionError:
        print(f"listen: permission denied on {device}; install the udev rule from the README", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
