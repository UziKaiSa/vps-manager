#!/usr/bin/env python3
"""Reject common deployment-specific and credential-like values in public text."""

import ipaddress
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {"", ".md", ".py", ".ps1", ".sh", ".txt", ".yaml", ".yml", ".json"}
EXCLUDED_PARTS = {".git", "assets", "__pycache__"}


def public_text_files():
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if path.resolve() == Path(__file__).resolve():
            continue
        if any(part in EXCLUDED_PARTS for part in path.relative_to(ROOT).parts):
            continue
        yield path


PRIVATE_KEY_HEADER = re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----")
LOCAL_DOMAIN = re.compile(r"(?i)\b[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.(?:internal|local|lan)\b")
WINDOWS_USER_PATH = re.compile(r"(?i)\b[A-Z]:\\Users\\[A-Za-z0-9._-]+")
UNIX_USER_PATH = re.compile(r"(?<![\w/])/(?:home|Users)/[A-Za-z0-9._-]+(?:/|\b)")
IPV4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
LITERAL_SECRET = re.compile(r'''(?ix)["']?(?:api[_-]?key|client[_-]?secret|access[_-]?token|auth[_-]?token|password|passwd)["']?\s*[:=]\s*["'](?!your-|example|placeholder|<|\$\{|\{)[A-Za-z0-9_./+=-]{8,}["']''')


def is_rfc1918(address: ipaddress.IPv4Address) -> bool:
    value = int(address)
    blocks = (
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
    )
    return any(value >= int(block.network_address) and value <= int(block.broadcast_address) for block in blocks)


def findings(path: Path, text: str):
    checks = (
        ("private-key header", PRIVATE_KEY_HEADER),
        ("local-only domain", LOCAL_DOMAIN),
        ("Windows user path", WINDOWS_USER_PATH),
        ("Unix user path", UNIX_USER_PATH),
        ("hard-coded credential", LITERAL_SECRET),
    )
    for label, pattern in checks:
        for match in pattern.finditer(text):
            if label == "local-only domain" and match.group().casefold().endswith("vps-manager.local"):
                continue
            yield label, text.count("\n", 0, match.start()) + 1

    for match in IPV4.finditer(text):
        try:
            address = ipaddress.ip_address(match.group())
        except ValueError:
            continue
        if isinstance(address, ipaddress.IPv4Address) and is_rfc1918(address):
            yield "private IPv4 address", text.count("\n", 0, match.start()) + 1


problems = []
for file_path in public_text_files():
    content = file_path.read_text(encoding="utf-8", errors="replace")
    for kind, line in findings(file_path, content):
        problems.append(f"{file_path.relative_to(ROOT)}:{line}: {kind}")

if problems:
    raise AssertionError("Deployment-specific values found:\n" + "\n".join(problems))

print("Public privacy regression checks passed")
