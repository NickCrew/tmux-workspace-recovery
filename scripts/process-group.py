#!/usr/bin/env python3
"""Run one command as the leader of a new POSIX process group."""

from __future__ import annotations

import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: process-group.py COMMAND [ARG ...]", file=sys.stderr)
        return 2
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
