from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_alpine_guard_uses_cgroup_aware_low_memory_limits():
    assert 'memory_max_bytes="\\$(cat /sys/fs/cgroup/memory.max' in TEXT
    assert "MAX_RSS_KIB=73728" in TEXT
    assert "MAX_RSS_KIB=98304" in TEXT
    assert 'oom_score_adj' in TEXT


def test_alpine_guard_rotates_both_warp_logs_every_minute():
    assert "rotate_log /var/log/cloudflare-warp/warp-svc.log" in TEXT
    assert "rotate_log /var/lib/cloudflare-warp/cfwarp_service_log.txt" in TEXT
    assert "printf '* * * * * %s\\n'" in TEXT


def test_alpine_guard_uses_existing_dcron_service():
    assert "[[ -x /etc/init.d/dcron ]]" in TEXT
    assert "rc-update add dcron default" in TEXT
