import importlib.util
from pathlib import Path
import socket, struct, ipaddress
import pytest
ROOT=Path(__file__).resolve().parents[1]
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'assets'/file)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
lb=module('listen_native_tests','listen-bind.py')
nb=module('bind_native_tests','native-bind.py')


def execute(raw, context):
    instructions=[struct.unpack('=BBhi',raw[i:i+8]) for i in range(0,len(raw),8)]
    registers={1:0};pc=0
    while True:
        op,regs,offset,imm=instructions[pc];dst=regs & 15;src=regs >> 4
        if op==0x61:registers[dst]=context.get(offset,0)
        elif op==0x55:
            if registers[dst] != imm & 0xffffffff:pc+=offset
        elif op==0x62:context[offset]=imm & 0xffffffff
        elif op==0x63:context[offset]=registers[src] & 0xffffffff
        elif op==0x05:pc+=offset
        elif op==0xb7:registers[dst]=imm
        elif op==0x95:return registers[0],context
        else:raise AssertionError(op)
        pc+=1


@pytest.mark.parametrize('ipv6',[False,True])
@pytest.mark.parametrize('register_store',[False,True])
def test_only_selected_tcp_wildcard_address_changes(ipv6,register_store):
    raw=nb.instructions([3000],ipv6,register_store)
    context={24:socket.htons(3000),32:socket.SOCK_STREAM,36:socket.IPPROTO_TCP}
    ret,result=execute(raw,context)
    assert ret==1
    if ipv6:
        packed=b''.join(result.get(offset,0).to_bytes(4,'little') for offset in [8,12,16,20])
        assert ipaddress.ip_address(packed).ipv4_mapped==ipaddress.ip_address('127.0.0.1')
    else:assert result[4]==int.from_bytes(socket.inet_aton('127.0.0.1'),'little')


@pytest.mark.parametrize('updates',[{24:socket.htons(3001)},{32:socket.SOCK_DGRAM,36:17},{4:0x01020304}])
def test_other_ports_udp_and_explicit_addresses_preserved(updates):
    context={24:socket.htons(3000),32:socket.SOCK_STREAM,36:socket.IPPROTO_TCP};context.update(updates)
    before=dict(context);ret,after=execute(nb.instructions([3000]),context)
    assert ret==1 and before==after


def test_explicit_ipv6_private_preserved():
    context={24:socket.htons(3000),32:socket.SOCK_STREAM,36:socket.IPPROTO_TCP,8:1}
    before=dict(context);assert execute(nb.instructions([3000],True),context)==(1,before)


@pytest.mark.parametrize('unit',['sshd.service','docker.service','systemd-networkd.service','../app.service','app;reboot.service'])
def test_infrastructure_and_injection_units_rejected(unit):
    with pytest.raises(ValueError):nb.valid_unit(unit)


def test_nginx_preserves_routes_tls_and_specific_existing_binds():
    before='''server {
  listen 443 ssl default_server;
  listen [::]:443 ssl default_server;
  listen 192.0.2.20:8080;
  server_name example.com;
  proxy_pass http://127.0.0.1:3000;
}
'''
    result,ports=lb.nginx_rewrite(before,['192.0.2.10'])
    assert ports==[443]
    assert 'listen 127.0.0.1:443 ssl default_server;' in result
    assert 'listen [::1]:443 ssl default_server;' in result
    assert result.count('listen 192.0.2.10:443 ssl default_server;')==1
    assert 'listen 192.0.2.20:8080;' in result
    assert result[result.index('  server_name'):]==before[before.index('  server_name'):]


def test_ipv4_mapped_loopback_reported_as_loopback():
    assert lb.loopback('::ffff:127.0.0.1')
    assert not lb.loopback('::ffff:198.51.100.12')


def test_known_legacy_verifier_uses_equivalent_register_store(monkeypatch):
    calls=[]
    def fake(command,attr):
        assert command==5
        raw=nb.C.string_at(attr.insns,attr.insn_cnt*8);calls.append(raw)
        if len(calls)==1:
            message=b'BPF_ST stores into R1 ctx is not allowed\0'
            nb.C.memmove(attr.log_buf,message,len(message))
            raise OSError(13,'Permission denied')
        return 77
    monkeypatch.setattr(nb,'bpf',fake)
    assert nb.load([12889],False)==77
    assert calls==[nb.instructions([12889],False),nb.instructions([12889],False,True)]


def test_permission_failure_is_not_relaxed(monkeypatch):
    calls=[]
    def fake(command,attr):
        calls.append(command);raise OSError(1,'Operation not permitted')
    monkeypatch.setattr(nb,'bpf',fake)
    with pytest.raises(RuntimeError):nb.load([12889],False)
    assert calls==[5]


@pytest.mark.parametrize('ports',[[],[3000]])
def test_foreign_bind_program_rejected_before_stop(ports):
    from types import SimpleNamespace
    group=SimpleNamespace(exists=lambda:True)
    fake=SimpleNamespace(attached=lambda *a:[123],owned=lambda *a:False)
    with pytest.raises(lb.Error,match='保持服务运行'):
        lb.verify_native_ownership(group,fake,ports)


def test_existing_owned_bind_program_is_allowed():
    from types import SimpleNamespace
    group=SimpleNamespace(exists=lambda:True)
    fake=SimpleNamespace(attached=lambda *a:[123],owned=lambda *a:True)
    lb.verify_native_ownership(group,fake,[3000])
