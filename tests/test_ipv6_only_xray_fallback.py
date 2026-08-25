import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "vps-manager.sh"
ASSET = ROOT / "assets" / "Xray-linux-64-v26.7.28.zip"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_xray_fallback_is_versioned_and_hash_pinned():
    assert 'XRAY_FALLBACK_VERSION="26.7.28"' in TEXT
    assert 'XRAY_FALLBACK_BASE_URL="https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/assets"' in TEXT
    assert 'XRAY_FALLBACK_AMD64_SHA256="8195d909f1109b8' in TEXT
    assert "download_alpine_xray_archive" in TEXT


def test_xray_fallback_asset_matches_pinned_official_digest():
    assert ASSET.is_file()
    assert hashlib.sha256(ASSET.read_bytes()).hexdigest() == (
        "8195d909f1109b8f3d99eefe401a3c451d7bf4af71f24d3815420f77e5dd2a40"
    )


def test_official_release_remains_first_choice():
    official = TEXT.index('https://github.com/XTLS/Xray-core/releases/latest/download/${archive_name}')
    fallback = TEXT.index('fallback_url="${XRAY_FALLBACK_BASE_URL}/Xray-linux-64-v${XRAY_FALLBACK_VERSION}.zip"')
    assert official < fallback
    assert "Xray 官方 Release 和 IPv6-only 固定版本兜底均不可用" in TEXT
