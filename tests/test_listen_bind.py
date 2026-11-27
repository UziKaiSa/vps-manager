import importlib.util
from pathlib import Path
import copy
import pytest

P = Path(__file__).resolve().parents[1] / 'assets/listen-bind.py'
spec = importlib.util.spec_from_file_location('listen_bind', P)
lb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lb)


def test_actual_ports_narrow_both_wildcards_and_preserve_private_channel():
    ports = {'8080/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '8080'},
                          {'HostIp': '::', 'HostPort': '8080'},
                          {'HostIp': '192.0.2.10', 'HostPort': '8080'}]}
    result = lb.normalize_ports(ports, {'tcp/8080': ['local', 'gateway']}, [37725])
    assert {x['host_ip'] for x in result} == {'127.0.0.1', '192.0.2.10'}
    assert len(result) == 2


@pytest.mark.parametrize('intent', [['peers'], ['public'], ['gateway', 'peers'], ['keep']])
def test_direct_access_is_not_silently_looped_back(intent):
    p = {'443/tcp': [{'HostIp': '::', 'HostPort': '443'}]}
    assert lb.normalize_ports(p, {'tcp/443': intent}, [37725])[0]['host_ip'] == '::'


def test_unselected_mapping_preserved():
    p = {'80/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '80'}]}
    assert lb.normalize_ports(p, {}, [37725])[0]['host_ip'] == '0.0.0.0'


def test_ssh_rejected():
    with pytest.raises(lb.Error, match='SSH'):
        lb.normalize_ports({'22/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '37725'}]}, {'tcp/37725': ['local']}, [37725])


def test_unknown_port_rejected():
    with pytest.raises(lb.Error, match='不存在'):
        lb.normalize_ports({}, {'tcp/80': ['local']}, [])


@pytest.mark.parametrize('intent', [[], ['typo']])
def test_invalid_intents(intent):
    with pytest.raises(lb.Error, match='用途'):
        lb.normalize_ports({'80/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '80'}]}, {'tcp/80': intent}, [])


SAMPLE = '''services:
  web:
    image: fixed:v1
    ports:
      - "8080:80"
    environment:
      SECRET: unchanged
  peer:
    ports:
      - "1234:1234"
volumes:
  persistent: {}
'''


def test_only_selected_service_ports_change():
    ports = [{'host_ip': '127.0.0.1', 'published': '8080', 'target': 80, 'protocol': 'tcp'}]
    result = lb.replace_ports(SAMPLE, 'web', ports)
    assert '127.0.0.1:8080:80/tcp' in result
    assert result.replace('      - "127.0.0.1:8080:80/tcp"', '      - "8080:80"') == SAMPLE


@pytest.mark.parametrize('text', [SAMPLE.replace('    ports:', '    ports: &shared', 1), SAMPLE.replace('  web:', '  web: &web'), SAMPLE.replace('    image: fixed:v1', '    <<: *base')])
def test_complex_yaml_rejected_without_edits(text):
    with pytest.raises(lb.Error): lb.replace_ports(text, 'web', [])


def test_runtime_projection_ignores_generated_hostname_but_preserves_real_config():
    a = {'Id': 'a'*64, 'Image': 'sha256:fixed', 'Config': {'Hostname': 'a'*12, 'Env': ['KEY=same'], 'Labels': {'com.docker.compose.config-hash': 'old'}}, 'HostConfig': {'PortBindings': {'x': []}}, 'Mounts': []}
    b = copy.deepcopy(a); b['Id'] = 'b'*64; b['Config']['Hostname'] = 'b'*12
    b['HostConfig']['PortBindings'] = {'new': []}
    b['Config']['Labels']['com.docker.compose.config-hash'] = 'new'
    assert lb.projection(a) == lb.projection(b)
    b['Config']['Env'] = ['KEY=changed']
    assert lb.projection(a) != lb.projection(b)


def test_no_firewall_command_in_new_module():
    source = P.read_text()
    assert "['nft'" not in source
    assert 'iptables' not in source
    assert 'vps_port_access' not in source


def test_remote_health_probe_rejected_before_request():
    with pytest.raises(lb.Error, match='本机'):
        lb.healthy('http://example.com/', [{'published': '80'}])
