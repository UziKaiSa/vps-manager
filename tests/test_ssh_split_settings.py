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
key_body = function_body("generate_local_ssh_key")
status_body = function_body("show_ssh_listener_status")
config_body = function_body("show_effective_ssh_config")
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
assert 'ssh_backend="$(detect_ssh_backend)"' in port_body
assert 'case "${ssh_backend}" in' in port_body
assert 'systemd-socket)' in port_body
assert 'configure_ssh_socket_port "${ssh_port}" "${ssh_service}"' in port_body
assert 'switch_ssh_socket_to_service' not in port_body
assert 'prepare_managed_firewall_ssh_transition' in port_body
assert 'finalize_managed_firewall_ssh_transition' in port_body
assert 'rollback_managed_firewall_ssh_transition' in port_body
assert 'reload_ssh_backend_auth "${ssh_backend}" "${ssh_service}"' in auth_body
assert 'systemctl show ssh.socket -p Listen --value' in text
assert 'shortcut_default_port="$(current_ssh_listener_ports 2>/dev/null | cut -d, -f1)"' in key_body
assert 'prompt_default "SSH 端口" "22"' not in key_body
assert 'prompt_default "SSH 端口" "${shortcut_default_port}"' in key_body
assert 'read -r -p "SSH 端口: " shortcut_port' in key_body
assert "查看当前 SSH 端口与监听状态" in text
assert "查看 SSH 完整生效配置" in text
assert "show_ssh_listener_status || true" in text
assert "show_effective_ssh_config || true" in text
assert 'listener_ports="$(current_ssh_listener_ports 2>/dev/null || true)"' in status_body
assert 'systemctl show ssh.socket -p Listen --value' in status_body
assert '"${sshd_binary}" -T -C' in config_body
assert "sshd 完整生效配置" in config_body
assert "/etc/ssh/ssh_host" not in config_body

print("Independent SSH setting regression checks passed")
