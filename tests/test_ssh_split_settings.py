#!/usr/bin/env python3
"""Regression checks for independent SSH port and authentication settings."""

from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def function_body(name: str) -> str:
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


port_body = function_body("configure_ssh_high_port")
auth_body = function_body("disable_ssh_password_login")
assert "配置 SSH 高位端口（不改登录方式）" in text
assert "禁用密码登录（不改 SSH 端口）" in text
assert "configure_ssh_high_port || true" in text
assert "disable_ssh_password_login || true" in text
assert "PasswordAuthentication no" not in port_body
assert "AuthenticationMethods publickey" not in port_body
assert 'sed -i "1iPort ${ssh_port}"' in port_body
assert "认证方式始终未修改" in port_body
assert 'SSH_SOCKET_TRANSITIONED=0' in port_body
assert "PasswordAuthentication no" in auth_body
assert "AuthenticationMethods publickey" in auth_body
assert "backup_and_disable_ssh_ports" not in auth_body
assert "SSH 端口始终未修改" in auth_body
assert 'SSH_SOCKET_TRANSITIONED=0' in auth_body
assert '/usr/sbin/sshd -T -C' in auth_body
assert 'user=${admin_user},host=${host_name}' in auth_body
assert 'reload_ssh_service "${ssh_service}"' in port_body
assert 'reload_ssh_service "${ssh_service}"' in auth_body

print("Independent SSH setting regression checks passed")
