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


def test_systemd_working_directory_is_unquoted_and_verified():
    assert "WorkingDirectory=${install_dir}" in TEXT
    assert 'WorkingDirectory="${install_dir}"' not in TEXT
    assert 'systemd-analyze verify "${service_file}"' in TEXT


def test_komari_ip_mode_defaults_to_agent_managed_auto_follow():
    assert "公网 IPv4 上报方式" in TEXT
    assert "1) 自动跟随（推荐，适合动态 IP）" in TEXT
    assert "2) 固定覆盖（适合固定 IP、特殊出口）" in TEXT
    assert 'local disable_ssh=1 gpu=1 ip_mode="auto"' in TEXT
    assert '[[ "${ip_mode}" == "fixed" ]] && args+=(--custom-ipv4 "${public_ip}")' in TEXT


def test_fixed_ip_is_preserved_for_local_and_download_fallbacks():
    assert 'printf \'  IPv4: 自动跟随（由 Komari Agent 定期探测）\\n\'' in TEXT
    assert 'printf \'  IPv4: 固定覆盖 %s\\n\' "${public_ip}"' in TEXT
    assert '"${disable_ssh}" "${gpu}" "${public_ip}"' in TEXT
    assert "detect_ip" not in TEXT
