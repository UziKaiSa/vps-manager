#!/usr/bin/env python3
"""Regression checks for safe APT/dpkg lock handling."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def require(fragment: str, message: str) -> None:
    if fragment not in text:
        raise AssertionError(message)


require("APT_LOCK_WAIT_SECONDS=600", "APT lock timeout must be bounded")
require("apt_lock_holders() {", "APT lock holder discovery is missing")
require("wait_for_apt_locks() {", "APT lock wait helper is missing")
require("/var/lib/dpkg/lock-frontend", "dpkg frontend lock is not checked")
require("/var/cache/apt/archives/lock", "APT archive lock is not checked")
require("未删除锁文件、未终止系统更新", "safe timeout guidance is missing")
require(
    'apt_update_safe || { warn "APT 索引更新失败，已停止 WARP 安装。"; return 1; }',
    "WARP continues after apt update failure",
)
require(
    'DPkg::Lock::Timeout="${APT_LOCK_WAIT_SECONDS}"',
    "apt-get does not have a bounded native lock timeout",
)
require(
    '|| { warn "WARP 依赖安装失败，已停止。"; return 1; }',
    "WARP continues after dependency installation failure",
)
require(
    '|| { warn "WARP 安装包写入失败，已停止。"; return 1; }',
    "WARP continues after package installation failure",
)

print("APT lock wait regression checks passed")
