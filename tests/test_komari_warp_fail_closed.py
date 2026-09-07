from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_trixie_uses_dedicated_pinned_package():
    # Both the dispatcher and installer must accept Debian 13.
    for name in ("komari_install_warp_client", "komari_install_warp_legacy"):
        body = TEXT.split(name + "() {", 1)[1].split("\n}\n", 1)[0]
        assert "^(bullseye|bookworm|trixie)$" in body
    assert 'trixie)\n      package_url="${KOMARI_WARP_LEGACY_TRIXIE_URL}"\n      package_sha256="${KOMARI_WARP_LEGACY_TRIXIE_SHA256}"' in TEXT
    assert 'https://downloads.cloudflareclient.com/v1/download/trixie-intel/version/2026.1.150.0' in TEXT
    assert '233e5ff40bfae457477ed9ddfb7c647f89bb61ad8164c7302cdf7bc393502dfc' in TEXT


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
    assert "systemctl show komari-agent --property=MainPID --value" in TEXT


def test_running_endpoint_arguments_are_exact_and_private():
    import sys
    from unittest.mock import patch
    code = TEXT.split("<<'PY_AGENT_ENDPOINT'\n", 1)[1].split("\nPY_AGENT_ENDPOINT", 1)[0]
    cases = [
        (["agent", "-e", "http://localhost:18080", "-t", "secret"], 0),
        (["agent", "--endpoint=http://localhost:18080"], 0),
        (["agent", "--endpoint", "http://localhost:18080"], 0),
        (["agent", "-e", "http://localhost:18080.evil"], 1),
        (["agent", "-e", "wrong", "-t", "http://localhost:18080"], 1),
        (["agent", "-e", "http://localhost:18080", "-e", "wrong"], 1),
        (["bash", "/root/y/run-agent.sh"], 1),
    ]
    for args, expected in cases:
        with patch.object(sys, "argv", ["check", "123", "http://localhost:18080"]), patch.object(Path, "read_bytes", return_value=b"\0".join(x.encode() for x in args)):
            try:
                exec(compile(code, "endpoint-check", "exec"), {})
            except SystemExit as result:
                assert result.code == expected, args
            else:
                raise AssertionError("endpoint check did not exit")
    with patch.object(sys, "argv", ["check", "123", "http://localhost:18080"]), patch.object(Path, "read_bytes", side_effect=FileNotFoundError):
        try:
            exec(compile(code, "endpoint-check", "exec"), {})
        except SystemExit as result:
            assert result.code == 1
