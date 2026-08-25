from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def test_public_address_detection_tries_ipv4_then_ipv6():
    function = TEXT[TEXT.index("detect_public_address() {"):TEXT.index("\n}\n", TEXT.index("detect_public_address() {"))]
    assert function.index("4|https://api.ipify.org") < function.index("6|https://api64.ipify.org")
    assert 'curl "-${family}"' in function
    assert 'ip -4 route show default' in function
    assert 'ip -6 route show default' in function


def test_public_address_detection_rejects_non_global_addresses():
    assert "address.is_global" in TEXT
    assert "is_public_ip_address" in TEXT
    assert 'printf \'%s\' "${address:-127.0.0.1}"' not in TEXT


def test_xray_configuration_requires_address_when_detection_fails():
    assert "无法可靠检测公网 IPv4/IPv6" in TEXT
    assert 'CFG_PUBLIC_ADDRESS="$(prompt_required "节点公网 IPv4、IPv6 或域名（仅用于客户端 YAML）")"' in TEXT
    assert 'public_address="<服务器公网地址>"' in TEXT
