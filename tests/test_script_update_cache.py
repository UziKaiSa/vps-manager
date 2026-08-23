#!/usr/bin/env python3
"""Regression checks for cache-safe self updates."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")
start = text.index("update_current_script() {")
end = text.index("\n}\n", start) + 3
function = text[start:end]

required = {
    "vps_manager_nocache=${cache_bust}": "self-update URL has no unique cache key",
    "$(date -u '+%Y%m%d%H%M%S')-$$": "cache key is not unique per update run",
    "'Cache-Control: no-cache'": "curl does not prohibit cached responses",
    "'Pragma: no-cache'": "legacy HTTP caches are not bypassed",
    'wget -O "${candidate}" "${download_url}"': "wget still uses the fixed Raw URL",
    '"${download_url}" -o "${candidate}"': "curl still uses the fixed Raw URL",
}
for fragment, message in required.items():
    if fragment not in function:
        raise AssertionError(message)

if 'wget -O "${candidate}" "${SCRIPT_UPDATE_URL}"' in function:
    raise AssertionError("fixed wget update URL can serve an old transparent-cache response")

print("Self-update cache bypass regression checks passed")
