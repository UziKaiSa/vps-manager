#!/usr/bin/env python3
"""Regression checks for minimal Alpine WARP package retention."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def function_body(name: str) -> str:
    start = text.index(f"{name}() {{")
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def test_runtime_and_build_packages_are_separated() -> None:
    install = function_body("komari_install_warp_alpine")
    build_install = function_body("install_alpine_warp_build_deps")
    assert "ALPINE_WARP_RUNTIME_PACKAGES=(" in text
    assert "dbus iproute2 nftables" in text
    for unnecessary in ("libcap", "nss-tools", "libpcap"):
        assert unnecessary not in install
    assert 'for package in "${ALPINE_WARP_BUILD_PACKAGES[@]}"' in build_install
    assert 'apk info -e "${package}"' in build_install
    assert "apk add --no-cache --virtual" in build_install
    assert '"${missing_packages[@]}"' in build_install


def test_build_dependencies_are_cleaned_on_success_and_failure() -> None:
    install = function_body("komari_install_warp_alpine")
    build_cleanup = function_body("cleanup_alpine_warp_build_deps")
    global_cleanup = function_body("cleanup")
    assert "apk del" in build_cleanup
    assert "cleanup_alpine_warp_build_deps" in global_cleanup
    assert install.count("cleanup_alpine_warp_build_deps") >= 10
    assert "Alpine WARP 构建依赖已清理" in build_cleanup
    for operation in ("curl -fL", "sha256sum -c -", "extract_deb_to", "extract_deb_members_to"):
        assert f"{operation}" in install
    assert "WARP 包校验失败" in install
    assert "WARP 客户端解包失败" in install


def test_normal_and_ultra_paths_report_disk_usage() -> None:
    install = function_body("komari_install_warp_alpine")
    assert "root_free_before_kib" in install
    assert "root_free_after_kib" in install
    assert "runtime_size_kib" in install
    assert "Alpine WARP 磁盘验证" in install
    assert "if (( ultra_low_disk == 1 )); then" in install


if __name__ == "__main__":
    test_runtime_and_build_packages_are_separated()
    test_build_dependencies_are_cleaned_on_success_and_failure()
    test_normal_and_ultra_paths_report_disk_usage()
    print("Alpine WARP minimal-package regression checks passed")
