#!/usr/bin/env python3
"""Compatibility entry point; use the common profile-based runner."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
raise SystemExit(subprocess.call([
    sys.executable, str(root / 'scripts/test-postgrest-config.py'),
    str(root / '.local/postgrest-cloudbase.env'),
]))
