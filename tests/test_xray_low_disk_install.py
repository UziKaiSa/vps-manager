from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_xray_requests_large_tmpfs_work_area():
    assert "ensure_work_dir $((96 * 1024))" in TEXT
    assert "required_kib > 0 && tmp_available_kib < required_kib" in TEXT
    assert "run_available_kib >= run_required_kib" in TEXT


def test_xray_preserves_root_space_and_treats_geodata_as_optional():
    assert "reserve_kib=4096" in TEXT
    assert "available_kib + existing_binary_kib >= binary_kib + reserve_kib" in TEXT
    assert "for data_file in geoip.dat geosite.dat" in TEXT
    assert "已跳过非必需的 ${data_file}" in TEXT
