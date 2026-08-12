#!/usr/bin/env python3
"""Regression checks for persistent SSH service hardening."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def require(fragment: str, message: str) -> None:
    if fragment not in text:
        raise AssertionError(message)


require(
    'SSHD_TMPFILES_CONFIG="/etc/tmpfiles.d/vps-manager-sshd.conf"',
    "managed sshd tmpfiles rule is missing",
)
require(
    "printf 'd /run/sshd 0755 root root -\\n' > \"${SSHD_TMPFILES_CONFIG}\"",
    "/run/sshd is not persisted through systemd-tmpfiles",
)
require(
    'systemd-tmpfiles --create "${SSHD_TMPFILES_CONFIG}"',
    "sshd runtime directory is not created before validation",
)
require('/usr/sbin/sshd -t', "sshd configuration validation is missing")
require(
    'systemctl enable "${ssh_service}"',
    "SSH service is not enabled for the next boot",
)
require(
    'systemctl is-enabled --quiet "${ssh_service}"',
    "SSH service enabled state is not verified",
)
require(
    'systemctl is-active --quiet "${ssh_service}"',
    "SSH service active state is not verified",
)

if text.count('ensure_ssh_service_persistent "${ssh_service}"') < 4:
    raise AssertionError("SSH hardening and public-key paths must both run persistence checks")

print("SSH persistence regression checks passed")
