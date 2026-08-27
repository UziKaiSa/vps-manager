from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_warp_dns_immutable_file_is_handled_explicitly():
    assert "komari_prepare_warp_dns" in TEXT
    assert "lsattr /etc/resolv.conf" in TEXT
    assert 'chattr -i /etc/resolv.conf' in TEXT
    assert "WARP 无法更新 DNS" in TEXT


def test_warp_connection_and_private_endpoint_fail_closed():
    assert 'komari_connect_warp || return 1' in TEXT
    assert 'komari_verify_warp "${endpoint}" || return 1' in TEXT
    assert 'grep -q "Status update: Connected"' in TEXT
    assert 'curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null "${endpoint}"' in TEXT


def test_conflicting_agent_dropins_are_disabled_before_reinstall():
    assert 'komari_disable_conflicting_agent_overrides "${endpoint}" || return 1' in TEXT
    assert '/etc/systemd/system/komari-agent.service.d/*.conf' in TEXT
    assert '.disabled-' in TEXT


def test_post_install_check_verifies_effective_agent_endpoint():
    assert 'komari_effective_agent_uses_endpoint "${endpoint}"' in TEXT
    assert "systemctl show komari-agent --property=ExecStart --value" in TEXT
