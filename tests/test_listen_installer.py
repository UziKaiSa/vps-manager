"""Exercise component installation and rejection of a bad downloaded payload."""
import hashlib
import os
from pathlib import Path
import shlex
import subprocess

ROOT=Path(__file__).resolve().parents[1]
TEXT=(ROOT/'vps-manager.sh').read_text()
START=TEXT.index('install_listen_binding_asset() {')
END=TEXT.index('\n}\n',START)+3
FUNCTION=TEXT[START:END].replace('target="/usr/local/lib/vps-manager/${name}"','target="${TEST_TARGET}/${name}"').replace('install -d -m 0755 /usr/local/lib/vps-manager','install -d -m 0755 "${TEST_TARGET}"')


def invoke(tmp_path,payload,expected,name='listen-bind.py',bundled=False):
    target=tmp_path/'installed';source=tmp_path/'source';source.mkdir(exist_ok=True)
    candidate=tmp_path/'payload';candidate.write_bytes(payload)
    if bundled:
        assets=source/'assets';assets.mkdir(exist_ok=True);(assets/name).write_bytes(payload)
    script='''set -eu
warn() { printf '%s\n' "$*" >&2; }
curl() { printf '%s\n' "$*" >> "$TEST_CURL_LOG"; cp "$TEST_PAYLOAD" "${@: -1}"; }
'''+FUNCTION+'\ninstall_listen_binding_asset '+shlex.quote(name)+' '+shlex.quote(expected)+' '+shlex.quote(str(source))
    env=dict(os.environ,TEST_TARGET=str(target),TEST_PAYLOAD=str(candidate),TEST_CURL_LOG=str(tmp_path/'curl.log'))
    return subprocess.run(['bash','-c',script],env=env,capture_output=True,text=True),target


def test_single_file_install_downloads_and_verifies_companion(tmp_path):
    content=b'#!/usr/bin/env python3\nprint("component")\n';expected=hashlib.sha256(content).hexdigest()
    result,target=invoke(tmp_path,content,expected)
    assert result.returncode==0
    assert (target/'listen-bind.py').read_bytes()==content
    assert (target/'listen-bind.py').stat().st_mode & 0o777==0o755
    args=(tmp_path/'curl.log').read_text()
    assert "--proto =https --tlsv1.2 -fsSL" in args
    assert not (target/'listen-bind.py.candidate').exists()


def test_valid_cached_component_does_not_download(tmp_path):
    content=b'verified';expected=hashlib.sha256(content).hexdigest()
    invoke(tmp_path,content,expected)
    before=(tmp_path/'curl.log').read_text()
    result,target=invoke(tmp_path,b'bad',expected)
    assert result.returncode==0 and (target/'listen-bind.py').read_bytes()==content
    assert (tmp_path/'curl.log').read_text()==before


def test_bad_download_never_replaces_previous_component(tmp_path):
    target=tmp_path/'installed';target.mkdir();(target/'listen-bind.py').write_bytes(b'previous')
    result,target=invoke(tmp_path,b'untrusted',hashlib.sha256(b'expected').hexdigest())
    assert result.returncode!=0
    assert (target/'listen-bind.py').read_bytes()==b'previous'


def test_bundled_component_works_without_network(tmp_path):
    content=b'bundled';result,target=invoke(tmp_path,content,hashlib.sha256(content).hexdigest(),bundled=True)
    assert result.returncode==0 and (target/'listen-bind.py').read_bytes()==content
    assert not (tmp_path/'curl.log').exists()


def test_unexpected_component_name_is_rejected(tmp_path):
    result,target=invoke(tmp_path,b'bad','0'*64,name='../unexpected')
    assert result.returncode!=0 and not target.exists()
