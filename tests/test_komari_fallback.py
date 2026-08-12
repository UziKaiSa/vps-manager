from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_versioned_local_agent_is_discovered():
    assert 'komari-agent-linux-${arch}-v*' in TEXT
    assert "sort -V | tail -n 1" in TEXT


def test_failed_official_install_offers_local_fallback():
    assert 'if ! bash "${installer}" "${args[@]}"; then' in TEXT
    assert "komari_install_fallback_after_failure" in TEXT


def test_failed_installer_download_also_offers_fallback():
    assert 'if ! curl -fL --retry 3 --connect-timeout 10' in TEXT
    assert "是否从 VPS Manager 仓库下载并使用兜底 Agent" in TEXT


def test_repo_fallback_is_versioned_and_hash_pinned():
    assert 'KOMARI_FALLBACK_VERSION="1.2.60"' in TEXT
    assert 'KOMARI_FALLBACK_AMD64_SHA256="113af112a914b918' in TEXT
    assert 'KOMARI_FALLBACK_BASE_URL="https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/assets"' in TEXT
    assert "sha256sum -c -" in TEXT
