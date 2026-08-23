#!/usr/bin/env python3
"""Regression checks for BBR setup in restricted containers."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")
start = text.index("enable_bbr() {")
end = text.index("\n}\n", start) + 3
function = text[start:end]

if "sysctl --system" in function:
    raise AssertionError("BBR setup still reloads unrelated host sysctl settings")
if "sysctl -w net.ipv4.tcp_congestion_control=bbr" not in function:
    raise AssertionError("BBR congestion control is not applied directly")
if "基础工具已经安装，BBR 已跳过" not in function:
    raise AssertionError("restricted containers do not receive non-blocking guidance")
if 'rm -f -- "${config}"' not in function:
    raise AssertionError("a rejected new BBR config is left behind")
if "install_base_tools || return 1" not in text:
    raise AssertionError("base tool installation failure is not propagated")
if 'warn "Alpine 基础工具安装失败。"' not in text:
    raise AssertionError("Alpine package installation failure is not explicit")
if "printf '  1) 初始化环境：基础工具和可选 BBR\\n'" not in text:
    raise AssertionError("Alpine menu does not advertise full initialization")
alpine_menu_start = text.index("alpine_main_menu() {")
alpine_menu = text[alpine_menu_start:]
if "1) initialize_environment; pause_screen ;;" not in alpine_menu:
    raise AssertionError("Alpine menu still bypasses base tool installation")

print("Restricted-container BBR regression checks passed")
