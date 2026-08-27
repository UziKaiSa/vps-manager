from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_xray_requests_large_tmpfs_work_area():
    assert "ensure_work_dir $((96 * 1024))" in TEXT
    assert "required_kib > 0 && tmp_available_kib < required_kib" in TEXT
    assert "run_available_kib >= run_required_kib" in TEXT


def test_xray_preserves_root_space_and_treats_geodata_as_optional():
    assert "reserve_kib=4096" in TEXT
    assert 'previous_file="${WORK_DIR}/xray.previous"' in TEXT
    assert "Xray 二进制落盘失败；已恢复安装前状态" in TEXT
    assert "低于 ${reserve_kib} KiB 安全余量；已恢复安装前状态" in TEXT
    assert "for data_file in geoip.dat geosite.dat" in TEXT
    assert 'previous_file="${WORK_DIR}/${data_file}.previous"' in TEXT
