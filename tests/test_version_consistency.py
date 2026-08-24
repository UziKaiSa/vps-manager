#!/usr/bin/env python3
"""Keep the documented version aligned with the self-update payload."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
script = (ROOT / "vps-manager.sh").read_text(encoding="utf-8")
readme = (ROOT / "README.md").read_text(encoding="utf-8")

script_version = re.search(r'^SCRIPT_VERSION="([^"]+)"$', script, re.MULTILINE)
readme_version = re.search(r"^当前版本：`([^`]+)`$", readme, re.MULTILINE)

assert script_version, "SCRIPT_VERSION is missing"
assert readme_version, "README current version is missing"
assert script_version.group(1) == readme_version.group(1), (
    f"version mismatch: script={script_version.group(1)}, "
    f"README={readme_version.group(1)}"
)

print(f"Version consistency check passed: {script_version.group(1)}")
