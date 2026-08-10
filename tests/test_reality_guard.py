#!/usr/bin/env python3
"""Dependency-free regression checks for the embedded Reality Guard generator."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


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


def generate(model: dict) -> tuple[dict, dict, str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        paths = [root / name for name in ("proxies", "config", "state", "info", "yaml", "model")]
        paths[0].write_text("")
        paths[5].write_text(json.dumps(model))
        environment = os.environ.copy()
        environment["CFG_PENDING_MODEL"] = str(paths[5])
        subprocess.run(
            ["python3", "-", *(str(path) for path in paths[:5]), "0", ""],
            input=generator_source(), text=True, env=environment, check=True,
            capture_output=True,
        )
        return (
            json.loads(paths[1].read_text()),
            json.loads(paths[2].read_text()),
            paths[3].read_text(),
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
            ["python3", "-", str(config_path), str(state_path), str(result_path), mode, "public"],
            input=loader_source(), text=True, check=True, capture_output=True,
        )
        return json.loads(result_path.read_text())


def mutate_guard(model: dict, enabled: bool) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "model.json"
        path.write_text(json.dumps(model))
        subprocess.run(
            ["python3", "-", str(path), "reality-guard", "1" if enabled else "0"],
            input=mutator_source(), text=True, check=True, capture_output=True,
        )
        return json.loads(path.read_text())


config, state, info = generate(base_model(True))
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
assert "full: 精确匹配" in info
loaded = load_model(config, state)
assert loaded["reality"]["dest"] == "[2001:db8::1]:443"
assert loaded["reality"]["guard"] == {"enabled": True, "port": 39000}
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
config, state, _ = generate(conflicting)
helper = next(item for item in config["inbounds"] if item.get("tag") == "reality-guard-in")
assert helper["port"] == 39001
assert state["reality"]["guard"]["port"] == 39001

config, state, _ = generate(base_model(False))
main = next(item for item in config["inbounds"] if item["protocol"] == "vless")
assert main["streamSettings"]["realitySettings"]["dest"] == "[2001:db8::1]:443"
assert not any(item.get("tag") == "reality-guard-in" for item in config["inbounds"])
assert not any(item.get("tag") == "reality-guard-block" for item in config["outbounds"])
assert state["reality"]["guard"]["enabled"] is False

print("Reality Guard generator fixtures passed")
