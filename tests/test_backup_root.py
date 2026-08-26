from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_operator_backups_do_not_use_system_backup_directory():
    assert 'BACKUP_ROOT="/var/backups/vps-manager"' not in TEXT
    assert 'BACKUP_ROOT="${BACKUP_HOME%/}/backups/vps-manager"' in TEXT


def test_sudo_uses_invoking_users_home_and_root_keeps_root_home():
    assert '"${SUDO_USER}" != "root"' in TEXT
    assert 'getent passwd "${SUDO_USER}"' in TEXT
    assert 'BACKUP_HOME="${HOME:-/root}"' in TEXT
    assert '[[ "${BACKUP_HOME}" == /* ]] || BACKUP_HOME="/root"' in TEXT
