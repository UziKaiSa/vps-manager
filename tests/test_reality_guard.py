#!/usr/bin/env python3
"""Dependency-free regression checks for the embedded Reality Guard generator."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid
import sys


SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"
text = SCRIPT.read_text(encoding="utf-8")


def require(fragment: str, message: str) -> None:
    if fragment not in text:
        raise AssertionError(message)


require('"listen": "127.0.0.1"', "guard helper must only listen on loopback")
require('"protocol": "dokodemo-door"', "guard helper inbound is missing")
require('[f"full:{name}" for name in server_names]', "SNI allowlist must use exact full: rules")
require('"outboundTag": "reality-guard-block"', "guard needs a fail-closed rule")
require('target_fields=set(rs)&{"target","dest"}', "strict import must accept target and dest")
require('len(target_fields)!=1', "strict import must reject ambiguous target/dest")
require('range(39000, 60000)', "guard port allocator range is missing")
require('port not in managed_ports', "guard port must avoid managed inbound conflicts")
require('reality.get("guard", {"enabled": True})', "managed updates must default guard on")
require('elif action=="reality-guard":', "guard toggle mutation is missing")
require('[[ "${current}" == 1 ]] && pending_model_mutate reality-guard 0', "enabled guard must toggle off")
require('"guard": {"enabled": guard_enabled, "port": guard_port}', "guard state is not persisted")
require('CFG_REALITY_GUARD_PORT="$(random_available_port 39000 59999 "${ports[@]}")"', "new guard port must be randomized")
require('guard_port = int(env("CFG_REALITY_GUARD_PORT"))', "generator must consume the randomized guard port")

fixed_port_patterns = (
    r'prompt_default "(?:VLESS-Reality|SOCKS5|Shadowsocks)[^\"]*端口" "?\d',
    r'prompt_default "端口" "?\d',
)
if any(re.search(pattern, text) for pattern in fixed_port_patterns):
    raise AssertionError("fixed public port default returned")

# Prevent the vulnerable Xray keyword-domain rule from returning unnoticed.
if '"domain": server_names' in text:
    raise AssertionError("plain serverNames use keyword matching and can be bypassed")

print("Reality Guard regression checks passed")


def generator_source() -> str:
    marker = 'python3 - "${proxy_input}" "${generated_config}"'
    start = text.index(marker)
    start = text.index("from __future__ import annotations", start)
    end = text.index("\nPY\n", start)
    return text[start:end]


def loader_source() -> str:
    marker = 'python3 - "${config_source}" "${state_source}" "${destination}"'
    start = text.index(marker)
    start = text.index("from __future__ import annotations", start)
    end = text.index("\nPY\n", start)
    return text[start:end]


def mutator_source() -> str:
    marker = 'python3 - "${XRAY_PENDING_MODEL}" "${action}" "$@"'
    start = text.index(marker)
    start = text.index("import json", start)
    end = text.index("\nPY\n", start)
    return text[start:end]


def base_model(enabled: bool, port: int = 39000) -> dict:
    client_id = str(uuid.uuid4())
    return {
        "version": 3,
        "managedBy": "vps-manager",
        "nodeName": "test",
        "publicAddress": "192.0.2.1",
        "publicPorts": {"reality": 58403},
        "directDomainStrategy": "UseIPv6",
        "reality": {
            "port": 443,
            "dest": "[2001:db8::1]:443",
            "serverNames": ["cover.example", "alt.example"],
            "privateKey": "private",
            "publicKey": "public",
            "shortId": "0011223344556677",
            "guard": {"enabled": enabled, "port": port},
        },
        "native": {
            "name": "native",
            "uuid": client_id,
            "email": "local@vps-manager.local",
            "outbound": "direct",
        },
        "proxies": [],
        "optionalInbounds": {},
    }


def generate(model: dict) -> tuple[dict, dict, str, str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        paths = [root / name for name in ("proxies", "config", "state", "info", "yaml", "model")]
        paths[0].write_text("")
        paths[5].write_text(json.dumps(model))
        environment = os.environ.copy()
        environment["CFG_PENDING_MODEL"] = str(paths[5])
        subprocess.run(
            [sys.executable, "-", *(str(path) for path in paths[:5]), "0", ""],
            input=generator_source(), text=True, env=environment, check=True,
            capture_output=True,
        )
        return (
            json.loads(paths[1].read_text()),
            json.loads(paths[2].read_text()),
            paths[3].read_text(),
            paths[4].read_text(),
        )


def load_model(config: dict, state: dict, mode: str = "strict") -> dict:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config_path, state_path, result_path = (root / name for name in ("config", "state", "result"))
        config_text = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
        config_path.write_text(config_text)
        state = dict(state)
        import hashlib
        state["configSha256"] = hashlib.sha256(config_text.encode()).hexdigest()
        state_path.write_text(json.dumps(state))
        subprocess.run(
            [sys.executable, "-", str(config_path), str(state_path), str(result_path), mode, "public"],
            input=loader_source(), text=True, check=True, capture_output=True,
        )
        return json.loads(result_path.read_text())


def mutate_guard(model: dict, enabled: bool) -> dict:
    return mutate(model, "reality-guard", "1" if enabled else "0")


def mutate(model: dict, *args: str) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "model.json"
        path.write_text(json.dumps(model))
        subprocess.run(
            [sys.executable, "-", str(path), *args],
            input=mutator_source(), text=True, check=True, capture_output=True,
        )
        return json.loads(path.read_text())


config, state, info, yaml_text = generate(base_model(True))
main = next(item for item in config["inbounds"] if item["protocol"] == "vless")
helper = next(item for item in config["inbounds"] if item.get("tag") == "reality-guard-in")
assert main["streamSettings"]["realitySettings"]["dest"] == "127.0.0.1:39000"
assert helper["listen"] == "127.0.0.1"
assert helper["settings"]["address"] == "2001:db8::1"
assert config["routing"]["rules"][:2] == [
    {"type": "field", "inboundTag": ["reality-guard-in"], "domain": ["full:cover.example", "full:alt.example"], "outboundTag": "direct"},
    {"type": "field", "inboundTag": ["reality-guard-in"], "outboundTag": "reality-guard-block"},
]
assert state["reality"]["dest"] == "[2001:db8::1]:443"
assert state["publicPorts"] == {"reality": 58403}
assert state["directDomainStrategy"] == "UseIPv6"
assert next(item for item in config["outbounds"] if item["tag"] == "direct")["settings"]["domainStrategy"] == "UseIPv6"
assert "  port: 58403\n" in yaml_text
assert "full: 精确匹配" in info
loaded = load_model(config, state)
assert loaded["reality"]["dest"] == "[2001:db8::1]:443"
assert loaded["reality"]["guard"] == {"enabled": True, "port": 39000}
assert loaded["publicPorts"] == {"reality": 58403}
assert loaded["directDomainStrategy"] == "UseIPv6"
loaded = mutate_guard(loaded, False)
assert loaded["reality"]["guard"] == {"enabled": False, "port": 39000}
loaded = mutate_guard(loaded, True)
assert loaded["reality"]["guard"] == {"enabled": True, "port": 39000}

# Current Xray calls the field target; strict adoption must accept it as the
# sole target spelling without weakening any other managed-structure checks.
main_settings = main["streamSettings"]["realitySettings"]
main_settings["target"] = main_settings.pop("dest")
loaded = load_model(config, state, "adopt-live")
assert loaded["reality"]["dest"] == "[2001:db8::1]:443"

conflicting = base_model(True)
conflicting["optionalInbounds"]["socks5"] = {
    "listen": "127.0.0.1", "port": 39000, "username": "u", "password": "p"
}
config, state, _, _ = generate(conflicting)
helper = next(item for item in config["inbounds"] if item.get("tag") == "reality-guard-in")
assert helper["port"] == 39001
assert state["reality"]["guard"]["port"] == 39001

config, state, _, _ = generate(base_model(False))
main = next(item for item in config["inbounds"] if item["protocol"] == "vless")
assert main["streamSettings"]["realitySettings"]["dest"] == "[2001:db8::1]:443"
assert not any(item.get("tag") == "reality-guard-in" for item in config["inbounds"])
assert not any(item.get("tag") == "reality-guard-block" for item in config["outbounds"])
assert state["reality"]["guard"]["enabled"] is False

print("Reality Guard generator fixtures passed")

# Old state files retain IPv4 defaults and follow internal port changes.
legacy = base_model(False)
legacy.pop("publicPorts")
legacy.pop("directDomainStrategy")
config, state, _, yaml_text = generate(legacy)
assert state["directDomainStrategy"] == "UseIPv4"
assert "  port: 443\n" in yaml_text
state.pop("publicPorts")
state.pop("directDomainStrategy")
restored = load_model(config, state)
changed = mutate(restored, "set", "reality.port", "8443")
assert changed["publicPorts"]["reality"] == 8443
assert mutate(base_model(False), "set", "reality.port", "8443")["publicPorts"]["reality"] == 58403

# Reject extra direct settings instead of silently discarding them on regeneration.
next(x for x in config["outbounds"] if x["tag"] == "direct")["settings"]["redirect"] = "127.0.0.1:9"
try:
    load_model(config, state)
except subprocess.CalledProcessError:
    pass
else:
    raise AssertionError("unmanaged direct settings were accepted")

ss_model = base_model(False)
ss_model["optionalInbounds"]["shadowsocks"] = {
    "listen": "0.0.0.0", "port": 23456,
    "method": "aes-128-gcm", "password": "test-password",
}
ss_model["publicPorts"]["shadowsocks"] = 54321
config, state, info, yaml_text = generate(ss_model)
assert "  port: 54321\n" in yaml_text
assert "公网端口: 54321" in info
assert next(x for x in config["inbounds"] if x["protocol"] == "shadowsocks")["port"] == 23456
restored = load_model(config, state)
assert restored["publicPorts"]["shadowsocks"] == 54321
assert mutate(restored, "inbound-set", "shadowsocks", "port", "23457")["publicPorts"]["shadowsocks"] == 54321
restored["publicPorts"]["shadowsocks"] = 23456
assert mutate(restored, "inbound-set", "shadowsocks", "port", "23457")["publicPorts"]["shadowsocks"] == 23457
disabled = mutate(restored, "inbound-disable", "shadowsocks")
assert "shadowsocks" not in disabled["publicPorts"]
print("Public port and direct strategy compatibility checks passed")
