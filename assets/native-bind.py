#!/usr/bin/env python3
"""Per-systemd-service bind-address adaptation; no packet filtering or app hooks.

Attach only to the current service cgroup in ExecStartPre. The kernel releases
the programs when that cgroup disappears; no pinned BPF objects are created.
"""
import ctypes as C
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import struct
import sys

CONFIG = Path('/etc/vps-manager/listen-bind/native-units')


def valid_unit(unit):
    if not re.fullmatch(r'[A-Za-z0-9_.@-]{1,100}\.service', unit):
        raise ValueError('invalid systemd unit')
    if re.match(r'(?:ssh|docker|containerd|systemd|network|warp|cloudflared)', unit):
        raise ValueError('infrastructure unit is protected')


def instructions(ports, ipv6=False, register_store=False):
    """Build auditable eBPF instructions for bpf_sock_addr (Linux UAPI).

    r1=context; only TCP wildcard binds on explicitly selected ports change.
    Explicit private/public addresses, other ports and outbound connect calls
    are untouched. IPv6 dual-stack sockets use an IPv4-mapped loopback address.
    """
    ports = sorted(set(ports))
    if not ports or len(ports) > 32 or any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
        raise ValueError('one to 32 explicit TCP ports required')
    code = []; labels = {}; jumps = []
    def emit(op, dst=0, src=0, off=0, imm=0): code.append([op, dst | (src << 4), off, imm])
    def jne(reg, value, label):
        jumps.append((len(code), label)); emit(0x55, reg, imm=value)
    def store(offset, value):
        # Older verifiers require register stores to writable socket context.
        if register_store:
            emit(0xb7, 3, imm=value)
            emit(0x63, 1, 3, off=offset)
        else:emit(0x62, 1, off=offset, imm=value)
    emit(0x61, 2, 1, 32)  # r2 = ctx->type
    jne(2, socket.SOCK_STREAM, 'allow')
    emit(0x61, 2, 1, 36)  # r2 = ctx->protocol
    jne(2, socket.IPPROTO_TCP, 'allow')
    for offset in ([8, 12, 16, 20] if ipv6 else [4]):
        emit(0x61, 2, 1, offset)
        jne(2, 0, 'allow')
    emit(0x61, 2, 1, 24)  # ctx->user_port, network byte order
    for index, port in enumerate(ports):
        jne(2, socket.htons(port), f'next{index}')
        if ipv6:
            # ::ffff:127.0.0.1; preserves IPv4 callers of dual-stack Node servers.
            store(16, int.from_bytes(b'\x00\x00\xff\xff', sys.byteorder))
            store(20, int.from_bytes(socket.inet_aton('127.0.0.1'), sys.byteorder))
        else:
            store(4, int.from_bytes(socket.inet_aton('127.0.0.1'), sys.byteorder))
        jumps.append((len(code), 'allow')); emit(0x05)
        labels[f'next{index}'] = len(code)
    labels['allow'] = len(code)
    emit(0xb7, 0, imm=1)  # allow bind, after address rewrite
    emit(0x95)           # exit
    for index, label in jumps: code[index][2] = labels[label] - index - 1
    return b''.join(struct.pack('=BBhi', op, regs, off, C.c_int32(imm).value) for op, regs, off, imm in code)


class Load(C.Structure):
    _fields_ = [('prog_type', C.c_uint32), ('insn_cnt', C.c_uint32),
                ('insns', C.c_uint64), ('license', C.c_uint64),
                ('log_level', C.c_uint32), ('log_size', C.c_uint32),
                ('log_buf', C.c_uint64), ('kern_version', C.c_uint32),
                ('prog_flags', C.c_uint32), ('prog_name', C.c_char * 16),
                ('prog_ifindex', C.c_uint32), ('expected_attach_type', C.c_uint32)]


class Attach(C.Structure):
    _fields_ = [('target_fd', C.c_uint32), ('attach_bpf_fd', C.c_uint32),
                ('attach_type', C.c_uint32), ('attach_flags', C.c_uint32),
                ('replace_bpf_fd', C.c_uint32)]


class Query(C.Structure):
    _fields_ = [('target_fd', C.c_uint32), ('attach_type', C.c_uint32),
                ('query_flags', C.c_uint32), ('attach_flags', C.c_uint32),
                ('prog_ids', C.c_uint64), ('prog_cnt', C.c_uint32)]


class ProgramId(C.Structure):
    _fields_ = [('prog_id',C.c_uint32),('next_id',C.c_uint32),('open_flags',C.c_uint32)]


class Info(C.Structure):
    _fields_ = [('bpf_fd',C.c_uint32),('info_len',C.c_uint32),('info',C.c_uint64)]


class ProgramInfo(C.Structure):
    _fields_ = [('type',C.c_uint32),('id',C.c_uint32),('tag',C.c_ubyte*8)]


def bpf(command, attr):
    machine = platform.machine()
    number = {'x86_64': 321, 'aarch64': 280}.get(machine)
    if number is None or sys.byteorder != 'little': raise RuntimeError('unsupported BPF platform')
    libc = C.CDLL(None, use_errno=True)
    result = libc.syscall(C.c_long(number), C.c_int(command), C.byref(attr), C.c_uint(C.sizeof(attr)))
    if result < 0:
        err = C.get_errno(); raise OSError(err, os.strerror(err))
    return result


def load(ports, ipv6, register_store=False):
    raw = instructions(ports, ipv6, register_store); buffer = C.create_string_buffer(raw)
    license = C.create_string_buffer(b'GPL'); log = C.create_string_buffer(65536)
    attr = Load(prog_type=18, insn_cnt=len(raw)//8, insns=C.addressof(buffer),
                license=C.addressof(license), log_level=1, log_size=len(log),
                log_buf=C.addressof(log), prog_name=b'vps_bind6' if ipv6 else b'vps_bind4',
                expected_attach_type=9 if ipv6 else 8)
    try: return bpf(5, attr)  # BPF_PROG_LOAD
    except OSError as exc:
        detail=log.value.decode(errors='replace')
        if not register_store and 'BPF_ST stores into R1 ctx is not allowed' in detail:
            return load(ports,ipv6,register_store=True)
        raise RuntimeError('BPF verifier rejected bind adapter: ' + str(exc) + ' ' + detail[:1600]) from exc


def attached(cgroup, kind):
    fd = os.open(cgroup, os.O_RDONLY | os.O_DIRECTORY)
    try:
        ids = (C.c_uint32 * 64)()
        attr = Query(target_fd=fd, attach_type=kind, prog_ids=C.addressof(ids), prog_cnt=64)
        bpf(16, attr)  # BPF_PROG_QUERY
        return list(ids)[:attr.prog_cnt]
    finally: os.close(fd)


def attach(cgroup, ports):
    if attached(cgroup, 8) or attached(cgroup, 9):
        if owned(cgroup,ports):return
        raise RuntimeError('foreign bind BPF programs detected; refusing to replace them')
    cfd = os.open(cgroup, os.O_RDONLY | os.O_DIRECTORY)
    loaded = []; applied = []
    try:
        for ipv6 in (False, True):
            fd = load(ports, ipv6); loaded.append(fd)
            kind = 9 if ipv6 else 8
            attr = Attach(target_fd=cfd, attach_bpf_fd=fd, attach_type=kind)
            bpf(8, attr); applied.append(attr)  # BPF_PROG_ATTACH
        if not attached(cgroup, 8) or not attached(cgroup, 9): raise RuntimeError('bind attachment missing')
    except BaseException:
        for attr in reversed(applied): bpf(9, attr)  # BPF_PROG_DETACH
        raise
    finally:
        for fd in loaded: os.close(fd)
        os.close(cfd)


def tag(fd):
    info=ProgramInfo();bpf(15,Info(bpf_fd=fd,info_len=C.sizeof(info),info=C.addressof(info)))
    return bytes(info.tag)


def owned(cgroup,ports):
    for kind in (8,9):
        ids=attached(cgroup,kind)
        if len(ids)!=1:return False
        expected=load(ports,kind==9);actual=bpf(13,ProgramId(prog_id=ids[0]))
        try:
            if tag(expected)!=tag(actual):return False
        finally:os.close(expected);os.close(actual)
    return True


def detach(cgroup,ports):
    if not Path(cgroup).exists():return
    if not attached(cgroup,8) and not attached(cgroup,9):return
    if not owned(cgroup,ports):raise RuntimeError('refusing to detach foreign bind BPF programs')
    cfd=os.open(cgroup,os.O_RDONLY|os.O_DIRECTORY)
    try:
        for kind in (8,9):
            for id in attached(cgroup,kind):
                fd=bpf(13,ProgramId(prog_id=id))
                try:bpf(9,Attach(target_fd=cfd,attach_bpf_fd=fd,attach_type=kind))
                finally:os.close(fd)
    finally:os.close(cfd)


def main():
    if len(sys.argv) != 3 or sys.argv[1] != '--attach-unit': raise ValueError('use --attach-unit UNIT.service')
    unit = sys.argv[2]; valid_unit(unit)
    config = json.loads((CONFIG / (unit + '.json')).read_text())
    if config.get('unit') != unit: raise ValueError('unit mismatch')
    relative = next(line.split(':', 2)[2] for line in Path('/proc/self/cgroup').read_text().splitlines() if line.startswith('0::'))
    if Path(relative).name != unit: raise ValueError('must execute inside the target service ExecStartPre')
    cgroup = Path('/sys/fs/cgroup') / relative.lstrip('/')
    attach(cgroup, config['tcp_ports'])
    print('Actual bind-address adaptation attached for ' + unit)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, RuntimeError) as exc:
        print('Native bind: ' + str(exc), file=sys.stderr); raise SystemExit(1)
