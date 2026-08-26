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
    assert 'ssh_ports="$(active_ssh_ports_for_firewall)"' in TEXT
    assert "active_ssh_ports_for_firewall()" in TEXT
    assert 'normalized="$(current_ssh_listener_ports 2>/dev/null || true)"' in TEXT
    assert 'counter jump log_drop comment "VPSMGR_DROP_TOTAL"' in TEXT
    assert 'limit rate 6/minute burst 20 packets log prefix' in TEXT


def test_main_mode_matches_ssh_only_security_group_defaults():
    assert 'external_guard="1"' in TEXT
    assert 'allow_icmp="0"' in TEXT
    assert 'allow_ipv6="0"' in TEXT
    assert 'trust_warp="0"' in TEXT
    assert 'prompt_yes_no "是否信任本机 CloudflareWARP 网卡直接入站" "0"' in TEXT
    assert "detect_external_interfaces()" in TEXT
    assert "type filter hook prerouting priority -150; policy accept;" in TEXT
    assert "ct state established,related counter accept" in TEXT
    assert "VPSMGR_GUARD_RETURN" in TEXT
    assert "counter jump ingress_drop" in TEXT
    assert "VPSMGR_GUARD_DROP" in TEXT


def test_ipv6_new_inbound_toggle_does_not_break_ipv6_return_traffic():
    assert "meta nfproto ipv4 ct state established,related" not in TEXT
    assert "iifname ${external_set} ct state established,related" in TEXT
    assert "nd-router-advert" in TEXT
    assert "nd-neighbor-solicit" in TEXT
    assert "nd-neighbor-advert" in TEXT
    assert "packet-too-big" in TEXT
    assert "VPSMGR_ALLOW_ICMPV6_CONTROL" in TEXT


def test_firewall_features_have_independent_persisted_switches():
    assert "VPSMGR_EXTERNAL_GUARD=" in TEXT
    assert "VPSMGR_ALLOW_ICMP=" in TEXT
    assert "VPSMGR_ALLOW_IPV6=" in TEXT
    assert "VPSMGR_TRUST_WARP=" in TEXT
    assert "firewall_configured_option()" in TEXT
    assert "是否启用 Docker/转发前的统一外部入口隔离" in TEXT
    assert "是否允许公网 ICMP/ICMPv6 主动入站" in TEXT
    assert "是否允许 IPv6 新入站连接" in TEXT
    assert "是否信任本机 CloudflareWARP 网卡直接入站" in TEXT
    assert 'customize_switches="${2:-0}"' in TEXT
    assert 'if [[ "${customize_switches}" == "1" ]]' in TEXT
    assert "自定义主站安全开关（仍仅开放 SSH）" in TEXT
    assert "7) configure_firewall_mode main 1 ;;" in TEXT


def test_prerouting_guard_is_before_docker_dnat_and_environment_agnostic():
    assert "priority -150" in TEXT
    assert "ct status dnat" not in TEXT
    assert 'iifname ${external_set}' in TEXT
    assert "DOCKER-USER" not in TEXT


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
    assert "已拒绝：外部入口不在白名单" in TEXT
    assert "VPSMGR_GUARD_DROP" in TEXT
    assert "外部入口统一隔离" in TEXT


def test_persistent_firewall_orders_before_container_runtimes():
    assert "Before=docker.service podman.service" in TEXT
