from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_versioned_local_agent_is_discovered():
    assert 'komari-agent-linux-${arch}-v*' in TEXT
    assert "sort -V | tail -n 1" in TEXT


def test_failed_official_install_offers_local_fallback():
    assert 'if ! bash "${installer}" "${args[@]}"; then' in TEXT
    assert "是否改用本机兜底 Agent" in TEXT
    assert 'komari_install_local_agent "${local_agent}"' in TEXT


def test_failed_installer_download_also_offers_fallback():
    assert 'if ! curl -fL --retry 3 --connect-timeout 10' in TEXT
    assert "是否使用本机兜底 Agent" in TEXT
