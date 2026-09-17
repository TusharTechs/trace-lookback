#!/usr/bin/env python3
"""Shim so the guard runs identically on Windows, macOS and Linux.

`python3` is not on PATH on a default Windows install and `python` is not
guaranteed to be Python 3 on older Linux images. CoCo invokes this file with
whichever interpreter resolves; it then executes the guard in-process using
that same interpreter, so there is exactly one thing to get right."""

import pathlib
import runpy
import sys

if sys.version_info < (3, 8):  # pragma: no cover
    print('{"decision": "allow"}')
    print("protect-audit: needs Python 3.8+; allowing", file=sys.stderr)
    raise SystemExit(0)

runpy.run_path(str(pathlib.Path(__file__).with_name("protect-audit.py")),
               run_name="__main__")
