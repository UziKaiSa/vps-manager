from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_firewall_has_two_explicit_modes_in_both_menus():
    assert "主站防火墙配置：仅开放 SSH" in TEXT
    assert "代理站防火墙配置/刷新：重新扫描当前监听端口" in TEXT
    assert TEXT.count("9) firewall_management_menu; pause_screen ;;") == 2


def test_managed_table_does_not_flush_foreign_rules():
    assert 'FIREWALL_TABLE="vps_manager_firewall"' in TEXT
    assert "nft flush ruleset" not in TEXT
    assert 'nft delete table inet "${FIREWALL_TABLE}"' in TEXT
    assert 'iifname "CloudflareWARP" counter accept' in TEXT


def test_rules_cover_ipv4_ipv6_and_preserve_ssh():
    assert "table inet ${FIREWALL_TABLE}" in TEXT
    assert "ct state established,related counter accept" in TEXT
    assert "meta l4proto { icmp, ipv6-icmp } counter accept" in TEXT
    assert 'ssh_ports="$(detect_ssh_ports)"' in TEXT
    assert 'counter jump log_drop comment "VPSMGR_DROP_TOTAL"' in TEXT
    assert 'limit rate 6/minute burst 20 packets log prefix' in TEXT


def test_apply_is_checked_and_has_timed_rollback():
    assert 'nft -c -f "${validation_candidate}"' in TEXT
    assert "FIREWALL_ROLLBACK_SECONDS=300" in TEXT
    assert 'nohup "${rollback_script}"' in TEXT


def test_firewall_can_be_maintained_without_nft_syntax():
    assert "manually_update_firewall_ports()" in TEXT
    assert "firewall_configured_ports()" in TEXT
    assert "SSH 端口强制保留" in TEXT
    assert "disable_managed_firewall()" in TEXT


def test_firewall_logs_are_bounded_and_readable():
    assert "FIREWALL_LOG_MAX_BYTES=4194304" in TEXT
    assert "FIREWALL_LOG_ULTRA_MAX_BYTES=524288" in TEXT
    assert "firewall_install_log_collector()" in TEXT
    assert "firewall_show_recent_blocks()" in TEXT
    assert "已拒绝：端口不在白名单" in TEXT
