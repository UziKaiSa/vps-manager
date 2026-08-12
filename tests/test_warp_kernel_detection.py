#!/usr/bin/env python3
"""Regression checks for WARP nftables detection on containers."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def require(fragment: str, message: str) -> None:
    if fragment not in text:
        raise AssertionError(message)


start = text.index("komari_check_kernel() {")
end = text.index("\n}\n", start) + 3
function = text[start:end]

require(
    "if nft list ruleset >/dev/null 2>&1; then",
    "nftables capability must be tested before modprobe",
)
require(
    'systemd-detect-virt --container 2>/dev/null || true',
    "container detection is missing",
)
require(
    '[[ -n "${virtualization}" && "${virtualization}" != "none" ]]',
    "container branch is missing",
)
require(
    "容器共享宿主机内核",
    "container guidance must explain why installing a guest kernel cannot help",
)
require("modprobe nf_tables", "bare-metal module loading fallback is missing")
require("return 1", "failed nftables checks must stop the WARP workflow")

if function.index("nft list ruleset") > function.index("modprobe nf_tables"):
    raise AssertionError("modprobe still runs before the authoritative nftables probe")

container_branch = function.index('if is_alpine || [[ -n "${virtualization}"')
kernel_prompt = function.index('prompt_yes_no "安装 linux-image-amd64')
if container_branch > kernel_prompt:
    raise AssertionError("containers can still reach the guest-kernel installation prompt")

print("WARP kernel detection regression checks passed")
