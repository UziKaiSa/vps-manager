#!/usr/bin/env python3
"""Regression checks for persistent SSH service hardening."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def function_body(name: str) -> str:
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def require(fragment: str, message: str) -> None:
    if fragment not in text:
        raise AssertionError(message)


require(
    'SSHD_TMPFILES_CONFIG="/etc/tmpfiles.d/vps-manager-sshd.conf"',
    "managed sshd tmpfiles rule is missing",
)
require(
    'SSHD_MANAGED_CONFIG="${SSHD_DROPIN_DIR}/00-00-vps-manager-hardening.conf"',
    "managed SSH drop-in must sort before provider 00-* overrides",
)
require(
    'SSHD_LEGACY_MANAGED_CONFIG="${SSHD_DROPIN_DIR}/00-vps-manager-hardening.conf"',
    "legacy managed SSH drop-in path must remain identifiable for migration",
)
require(
    'rm -f -- "${SSHD_LEGACY_MANAGED_CONFIG}"',
    "legacy managed SSH drop-in must be removed after effective validation",
)
require(
    "passwordauthentication=${effective_password:-未知}",
    "SSH effective-config failure must report the mismatched authentication values",
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
require('printf \'sshd\'', "Alpine OpenRC sshd service is not detected")
require(
    'rc-update add "${ssh_service}" default',
    "Alpine SSH service is not enabled for the next boot",
)
require(
    'install -d -o root -g root -m 0755 /run/sshd',
    "Alpine SSH runtime directory is not created before validation",
)
require(
    'rc-service "${ssh_service}" status',
    "Alpine SSH active state is not verified",
)
require(
    '5) ssh_key_helper_menu; pause_screen ;;',
    "Alpine menu hides SSH key and hardening management",
)

if text.count('ensure_ssh_service_persistent "${ssh_service}"') < 4:
    raise AssertionError("SSH hardening and public-key paths must both run persistence checks")

ensure_body = function_body("ensure_ssh_service_persistent")
if ensure_body.index('install -d -o root -g root -m 0755 /run/sshd') > ensure_body.index('/usr/sbin/sshd -t'):
    raise AssertionError("/run/sshd must exist before the first sshd syntax check")

switch_body = function_body("switch_ssh_socket_to_service")
if switch_body.index('systemctl stop ssh.socket') > switch_body.index('systemctl stop "${ssh_service}"'):
    raise AssertionError("ssh.socket must stop before ssh.service to avoid socket reactivation")

restore_body = function_body("restore_ssh_socket_state")
socket_start = restore_body.index('systemctl start ssh.socket')
service_start = restore_body.index('systemctl start "${ssh_service}"')
if "return 0" not in restore_body[socket_start:service_start]:
    raise AssertionError("socket-mode rollback must not also force-start ssh.service")

print("SSH persistence regression checks passed")
