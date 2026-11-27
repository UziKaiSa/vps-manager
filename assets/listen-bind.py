#!/usr/bin/env python3
"""Manage real listener bindings. Never installs or modifies firewall rules."""
from __future__ import annotations
import argparse, contextlib, copy, fcntl, hashlib, ipaddress, json, os
from pathlib import Path
import re, shutil, socket, subprocess, sys, time, uuid, urllib.request, importlib.util
STATE = Path('/etc/vps-manager/listen-bind')
IDENT = re.compile(r'^[A-Za-z0-9_.:-]{1,80}$')
class Error(RuntimeError): pass

def run(args, text=None, check=True, timeout=30):
    p = subprocess.run(args, input=text, text=True, capture_output=True, timeout=timeout)
    if check and p.returncode:
        # Do not echo docker compose configuration or environment on failures.
        detail = f'exit={p.returncode}'
        raise Error(f'{args[0]} {args[1] if len(args) > 1 else ""}: {detail}')
    return p


def read_json(path, default=None):
    return json.loads(path.read_text()) if path.is_file() else copy.deepcopy(default)


def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.new-' + uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(value)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def save(path, obj):
    write(path, json.dumps(obj, ensure_ascii=False, indent=2) + '\n')


@contextlib.contextmanager
def locked():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def ident(value):
    if not isinstance(value, str) or not IDENT.fullmatch(value):
        raise Error('网卡或服务名称不合法')
    return json.dumps(value)


def endpoint(value):
    address, port = value.rsplit(':', 1)
    return address.strip('[]').split('%')[0], int(port)


def loopback(address):
    try:
        value = ipaddress.ip_address(address)
        return value.is_loopback or bool(getattr(value, 'ipv4_mapped', None) and value.ipv4_mapped.is_loopback)
    except ValueError:
        return False


def scan():
    entries = {}
    ssh = set()
    listeners = run(['ss', '-H', '-lntup']).stdout
    for line in listeners.splitlines():
        f = line.split(None, 6)
        if len(f) < 6 or f[0] not in ('tcp', 'udp'):
            continue
        try:
            address, port = endpoint(f[4])
        except (ValueError, IndexError):
            continue
        owners = sorted(set(re.findall(r'\("([^"\n]+)",pid=', f[6] if len(f) > 6 else '')))
        if f[0] == 'tcp' and any(x in ('sshd', 'sshd-session', 'sshd-auth') for x in owners):
            ssh.add(port)
        # Outbound QUIC sockets and DHCP are not public server applications.
        infrastructure = f[0] == 'udp' and (
            (port in (68, 546) and any(x in ('dhclient', 'systemd-network') for x in owners))
            or 'cloudflared' in owners)
        if infrastructure:
            continue
        key = f'{f[0]}/{port}'
        e = entries.setdefault(key, {'key': key, 'protocol': f[0], 'port': port,
                                     'services': [], 'addresses': [], 'containers': [],
                                     'modes': [], 'sources': []})
        e['addresses'] = sorted(set(e['addresses'] + [address]))
        e['services'] = sorted(set(e['services'] + owners))
        units = set(e.get('units', []))
        for pid in re.findall(r'pid=(\d+)', f[6] if len(f) > 6 else ''):
            try:
                for part in Path(f'/proc/{pid}/cgroup').read_text().split('/'):
                    if part.strip().endswith('.service'): units.add(part.strip())
            except OSError: pass
        e['units'] = sorted(units)
    containers = []
    if shutil.which('docker'):
        ids = run(['docker', 'ps', '-q'], check=False).stdout.split()
        for cid in ids:
            # docker inspect is read in memory; only the safe projection leaves here.
            p = run(['docker', 'inspect', cid], check=False)
            if p.returncode:
                continue
            d = json.loads(p.stdout)[0]
            name = d['Name'].lstrip('/')
            containers.append({'name': name, 'id': d['Id'], 'network': d['HostConfig']['NetworkMode']})
            for target, bindings in (d['NetworkSettings'].get('Ports') or {}).items():
                for b in bindings or []:
                    proto = target.split('/')[1]
                    port = int(b['HostPort'])
                    key = f'{proto}/{port}'
                    e = entries.setdefault(key, {'key': key, 'protocol': proto, 'port': port,
                                                 'services': [], 'addresses': [], 'containers': [],
                                                 'modes': [], 'sources': []})
                    e['containers'] = sorted(set(e['containers'] + [name]))
                    e['addresses'] = sorted(set(e['addresses'] + [b.get('HostIp') or '0.0.0.0']))
    interfaces = json.loads(run(['ip', '-j', 'address', 'show']).stdout)
    protected = ['lo']
    for it in interfaces:
        name = it['ifname']
        tunnel = it.get('link_type') == 'none' and re.fullmatch(r'(?:tun|wg)[A-Za-z0-9_.-]*', name)
        if name == 'CloudflareWARP' or name == 'docker0' or name.startswith('br-') or tunnel:
            protected.append(name)
    for e in entries.values():
        e['protected'] = e['protocol'] == 'tcp' and e['port'] in ssh
    return {'schema': 1, 'hostname': socket.gethostname(), 'ssh_ports': sorted(ssh),
            'protected_interfaces': sorted(set(protected)),
            'entries': sorted(entries.values(), key=lambda e: (e['port'], e['protocol'])),
            'containers': containers}


def sha(data):
    return hashlib.sha256(data.encode()).hexdigest()


def inspect(container):
    ident(container)
    return json.loads(run(['docker', 'inspect', container]).stdout)[0]


def context(container):
    d = inspect(container)
    if d['HostConfig']['NetworkMode'] in ('host', 'none'):
        raise Error('host/none 网络需应用自身的监听配置；未修改')
    labels = d['Config'].get('Labels') or {}
    project = labels.get('com.docker.compose.project', '')
    service = labels.get('com.docker.compose.service', '')
    ident(project); ident(service)
    files = labels.get('com.docker.compose.project.config_files', '').split(',')
    if len(files) != 1 or not Path(files[0]).is_absolute() or not Path(files[0]).is_file():
        raise Error('目前只自动修改单一 Compose 原文件；普通 docker run / 多文件项目未修改')
    path = Path(files[0]).resolve()
    root = labels.get('com.docker.compose.project.working_dir', '')
    if not Path(root).is_absolute() or not Path(root).is_dir():
        raise Error('Compose 工作目录不可用')
    cmd = ['docker', 'compose', '--project-directory', root, '-p', project, '-f', str(path)]
    config = json.loads(run(cmd + ['config', '--format', 'json']).stdout)
    hashes = run(cmd + ['config', '--hash', service]).stdout.split()
    if labels.get('com.docker.compose.config-hash') not in hashes:
        raise Error('Compose 文件已偏离运行配置，拒绝重建')
    effective = config['services'][service]
    image = effective.get('image')
    if not image or json.loads(run(['docker', 'image', 'inspect', image]).stdout)[0]['Id'] != d['Image']:
        raise Error('镜像标签漂移，拒绝顺带更新业务版本')
    if effective.get('network_mode') == 'host':
        raise Error('host 网络项目未自动处理')
    return d, service, path, cmd, config


def normalize_ports(bindings, choices, ssh_ports):
    """Choices are per-host-port intents; retain every explicit internal bind."""
    result = []
    known = set()
    for target, values in bindings.items():
        inner, proto = target.split('/')
        if proto not in ('tcp', 'udp'):
            raise Error('只支持 TCP/UDP 映射')
        for v in values or []:
            port = int(v['HostPort']); host = v.get('HostIp') or '0.0.0.0'
            key = f'{proto}/{port}'; known.add(key)
            intent = choices.get(key, ['keep'])
            if not intent or set(intent) - {'local', 'gateway', 'peers', 'public', 'keep'}:
                raise Error('用途必须为 local/gateway/peers/public/keep，可组合')
            narrow = set(intent) <= {'local', 'gateway'}
            if proto == 'tcp' and port in ssh_ports and narrow:
                raise Error('禁止自动回环 SSH')
            if narrow and host in ('0.0.0.0', '::', ''):
                host = '127.0.0.1'
            elif narrow and not ipaddress.ip_address(host).is_loopback:
                # An existing specific address may be a remote gateway's internal path.
                pass
            row = {'target': int(inner), 'published': str(port), 'host_ip': host, 'protocol': proto}
            if row not in result:
                result.append(row)
    if set(choices) - known:
        raise Error('用途包含该容器不存在的映射，未修改')
    return sorted(result, key=lambda p: (p['published'], p['target'], p['protocol'], p['host_ip']))


def replace_ports(text, service, ports):
    """Edit only a plain service ports block, preserving the rest byte-for-byte."""
    lines = text.splitlines(keepends=True)
    services = [i for i, x in enumerate(lines) if re.fullmatch(r'services:\s*(?:#.*)?\n?', x)]
    if len(services) != 1:
        raise Error('无法安全定位 services 块')
    top = services[0]
    end = next((i for i in range(top + 1, len(lines)) if lines[i].strip() and not lines[i][0].isspace() and not lines[i].startswith('#')), len(lines))
    headers = [i for i in range(top + 1, end) if re.fullmatch(r'  [A-Za-z0-9_.-]+:\s*(?:#.*)?\n?', lines[i])]
    start = next((i for i in headers if lines[i].split(':')[0].strip() == service), None)
    if start is None:
        raise Error('服务不是可安全改写的普通 YAML 块')
    stop = next((i for i in headers if i > start), end)
    block = [i for i in range(start + 1, stop) if re.fullmatch(r'    ports:\s*\n?', lines[i])]
    if len(block) != 1 or any(re.search(r'\s<<:|[&*][A-Za-z_]', x) for x in lines[start:stop]):
        raise Error('端口块缺失或存在 YAML 继承，未修改')
    a = block[0]
    b = next((i for i in range(a + 1, stop) if lines[i].strip() and len(lines[i])-len(lines[i].lstrip()) <= 4 and not lines[i].lstrip().startswith('#')), stop)
    content = '    ports:\n'
    for p in ports:
        host = p['host_ip']
        if ':' in host: host = '[' + host + ']'
        mapping = f'{host}:{p["published"]}:{p["target"]}/{p["protocol"]}'
        content += '      - ' + json.dumps(mapping) + '\n'
    return ''.join(lines[:a]) + content + ''.join(lines[b:])


def projection(d):
    # Compare all runtime settings apart from the intended bindings and Compose labels.
    config = copy.deepcopy(d['Config']); labels = config.get('Labels') or {}
    if config.get('Hostname') == d['Id'][:12]: config.pop('Hostname', None)
    config['Labels'] = {k: v for k, v in labels.items() if not k.startswith('com.docker.compose.')}
    host = copy.deepcopy(d['HostConfig']); host.pop('PortBindings', None)
    mounts = sorted((m['Type'], m['Source'], m['Destination'], m['RW']) for m in d.get('Mounts', []))
    return {'image': d['Image'], 'config': config, 'host': host, 'mounts': mounts}


def prepare(container, choices):
    d, service, path, cmd, config = context(container)
    ports = normalize_ports(d['HostConfig'].get('PortBindings') or {}, choices, scan()['ssh_ports'])
    if not ports: raise Error('没有发布端口')
    before = path.read_text()
    after = replace_ports(before, service, ports)
    return d, service, path, cmd, config, ports, before, after


def plan(container, choices):
    d, service, path, cmd, config, ports, before, after = prepare(container, choices)
    return {'host': socket.gethostname(), 'container': container, 'service': service,
            'config_file': str(path), 'config_sha256': sha(before), 'image': d['Image'],
            'ports_before': d['HostConfig'].get('PortBindings'), 'ports_after': ports,
            'restart': '仅重建该 Compose 服务；保持镜像，不拉取、不构建',
            'firewall_changes': False, 'private_bindings_preserved': True}


def recreate(cmd, service):
    run(cmd + ['up', '-d', '--no-deps', '--no-build', '--pull', 'never', '--force-recreate', service], timeout=120)
    cid = run(cmd + ['ps', '-q', service]).stdout.strip()
    time.sleep(2)
    d = inspect(cid)
    if not d['State']['Running'] or d['State'].get('Restarting'):
        raise Error('容器没有稳定运行')
    return d


def healthy(url, ports):
    if not url: return
    from urllib.parse import urlparse
    u = urlparse(url)
    if u.scheme != 'http' or u.hostname not in ('127.0.0.1', '::1') or u.username or u.password or u.query:
        raise Error('健康检查仅接受无凭据的本机 HTTP URL')
    if (u.port or 80) not in {int(p['published']) for p in ports}:
        raise Error('健康检查端口不属于该服务')
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args): return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    for _ in range(30):
        try:
            with opener.open(url, timeout=2) as response:
                if response.status == 200: return
        except Exception: pass
        time.sleep(1)
    raise Error('重建后本机健康检查失败')


def apply(container, choices, url=None):
    with locked():
        d, service, path, cmd, config, ports, before, after = prepare(container, choices)
        if url:
            healthy(url, ports)  # Validate the probe and baseline before writing anything.
        tx = uuid.uuid4().hex; directory = STATE / 'transactions' / tx
        save(directory / 'transaction.json', {'status': 'prepared', 'host': socket.gethostname(),
             'container': container, 'service': service, 'path': str(path), 'command': cmd,
             'before_sha256': sha(before), 'after_sha256': sha(after), 'choices': choices, 'ports': ports,
             'intents_before': read_json(STATE / 'intents.json', {})})
        write(directory / 'before.yaml', before)
        original_stat = path.stat(); started = False
        def put(text):
            write(path, text); os.chmod(path, original_stat.st_mode & 0o7777); os.chown(path, original_stat.st_uid, original_stat.st_gid)
        try:
            if path.read_text() != before: raise Error('配置被并发修改')
            put(after)
            candidate = json.loads(run(cmd + ['config', '--format', 'json']).stdout)
            expected = copy.deepcopy(config); expected['services'][service]['ports'] = candidate['services'][service]['ports']
            if candidate != expected: raise Error('除端口外的 Compose 配置发生变化')
            actual = candidate['services'][service]['ports']
            proj = lambda p: (int(p['target']), str(p['published']), p.get('host_ip', '0.0.0.0'), p.get('protocol', 'tcp'))
            if sorted(map(proj, actual)) != sorted(map(proj, ports)): raise Error('最终端口与预期不一致')
            started = True; new = recreate(cmd, service)
            if projection(new) != projection(d): raise Error('重建后非端口运行配置发生变化')
            current = normalize_ports(new['HostConfig'].get('PortBindings') or {}, {}, [])
            if current != ports: raise Error('实际监听映射与预期不同')
            healthy(url, ports)
            meta = read_json(directory / 'transaction.json'); meta.update(status='applied', result_container=new['Id'], health_url=url)
            save(directory / 'transaction.json', meta)
            intents = read_json(STATE / 'intents.json', {}); intents.update(choices); save(STATE / 'intents.json', intents)
            print(json.dumps({'transaction': tx, 'status': 'applied', 'ports': ports}))
        except BaseException:
            if path.read_text() != after:
                raise Error('检测到并发改动，停止自动覆盖；恢复记录已保留')
            put(before)
            restored = False
            if started:
                restored = projection(recreate(cmd, service)) == projection(d)
            meta = read_json(directory / 'transaction.json'); meta.update(status='failed_restored' if restored or not started else 'restore_failed')
            save(directory / 'transaction.json', meta)
            raise


def rollback(tx):
    if not re.fullmatch('[0-9a-f]{32}', tx): raise Error('事务编号无效')
    with locked():
        directory = STATE / 'transactions' / tx; meta = read_json(directory / 'transaction.json')
        if not meta or meta['host'] != socket.gethostname() or meta['status'] != 'applied': raise Error('事务不可回滚')
        if meta.get('adapter') in ('native', 'nginx'):
            restore_native(directory, meta)
            return
        path = Path(meta['path']); before = (directory / 'before.yaml').read_text()
        if sha(path.read_text()) != meta['after_sha256']: raise Error('配置已更新，拒绝覆盖后续修改')
        cid = run(meta['command'] + ['ps', '-q', meta['service']]).stdout.strip()
        d = inspect(cid)
        if d['Id'] != meta['result_container']: raise Error('容器已更新，拒绝覆盖')
        st = path.stat(); after = path.read_text()
        write(path, before); os.chmod(path, st.st_mode & 0o7777); os.chown(path, st.st_uid, st.st_gid)
        try:
            restored = recreate(meta['command'], meta['service'])
            if projection(restored) != projection(d): raise Error('恢复后非端口配置不一致')
        except BaseException:
            write(path, after); os.chmod(path, st.st_mode & 0o7777); os.chown(path, st.st_uid, st.st_gid)
            recreate(meta['command'], meta['service']); raise
        intents = read_json(STATE / 'intents.json', {})
        for key, value in meta['choices'].items():
            if intents.get(key) == value:
                if key in meta.get('intents_before', {}): intents[key] = meta['intents_before'][key]
                else: intents.pop(key, None)
        save(STATE / 'intents.json', intents)
        meta['status'] = 'rolled_back'; save(directory / 'transaction.json', meta)
        print('已恢复原监听映射；原防火墙未改')


def show():
    data = scan(); intents = read_json(STATE / 'intents.json', {})
    print('真实监听管理：本功能不安装、不修改防火墙；扫描不会自动回环。')
    for e in data['entries']:
        addresses = e['addresses']; local = all(loopback(x) for x in addresses)
        state = '已回环' if local else ('通配监听' if any(a in ('*','0.0.0.0','::') for a in addresses) else '明确地址绑定，保留内网/指定接口')
        adapter = 'Compose 可预览' if e['containers'] else 'systemd bind 可预览：' + ','.join(e.get('units', []))
        if 'nginx' in e['services']: adapter = 'Nginx 配置可预览'
        if not e['containers'] and not e.get('units'): adapter = '无 systemd 归属；保留现状'
        if e['protected']: adapter = 'SSH 保护，禁止自动修改'
        print(f'{e["key"]:12} {",".join(e["services"] + e["containers"]):35} {",".join(addresses)} | {state} | {adapter} | 用途={intents.get(e["key"], ["待选择"])}')
    for p in sorted((STATE / 'transactions').glob('*/transaction.json')):
        t = read_json(p); print(f'事务 {p.parent.name}: {t.get("container", t.get("unit", t.get("adapter")))} {t["status"]}')


NATIVE_HELPER = Path('/usr/local/lib/vps-manager/native-bind.py')
NATIVE_SHA256 = '8cb67526298a2745c297edd8c0b4a80781fa6f1e222555b38dd2ee779ba534db'


def native_module():
    if not NATIVE_HELPER.is_file() or hashlib.sha256(NATIVE_HELPER.read_bytes()).hexdigest() != NATIVE_SHA256:
        raise Error('native-bind.py 不存在或校验失败')
    spec = importlib.util.spec_from_file_location('vps_native_bind', NATIVE_HELPER)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def native_plan(unit, ports):
    module = native_module(); module.valid_unit(unit)
    module.instructions(ports, False); module.instructions(ports, True)
    if STATE.resolve()!=Path('/etc/vps-manager/listen-bind'):
        raise Error('原生服务需要使用标准状态目录，与启动钩子的配置位置一致')
    if not Path('/sys/fs/cgroup/cgroup.controllers').is_file(): raise Error('需要 cgroup v2')
    if run(['systemctl', 'is-active', unit], check=False).stdout.strip() != 'active': raise Error('请先启动服务以核对端口归属')
    fragment=run(['systemctl','show','--value','-p','FragmentPath',unit]).stdout.strip()
    if not fragment or not Path(fragment).is_file() or '/transient/' in fragment:raise Error('需要有持久化 unit 文件的服务；临时 systemd-run 单元不自动修改')
    relative=run(['systemctl','show','--value','-p','ControlGroup',unit]).stdout.strip()
    configured=read_json(STATE/'native-units'/(unit+'.json'),{})
    managed_ports=configured.get('tcp_ports',[]) if configured.get('unit')==unit else []
    if relative:verify_native_ownership(Path('/sys/fs/cgroup')/relative.lstrip('/'),module,managed_ports)
    current = scan(); selected = []
    for port in ports:
        if port in current['ssh_ports']: raise Error('禁止修改 SSH')
        row = next((e for e in current['entries'] if e['key'] == f'tcp/{port}'), None)
        if not row or unit not in row.get('units', []) or row.get('containers'):
            raise Error(f'tcp/{port} 不属于指定的原生服务')
        if set(row.get('units', [])) != {unit}: raise Error('端口由多个服务共同监听，拒绝自动修改')
        selected.append({'port':port, 'addresses':row['addresses']})
    return {'adapter':'native', 'unit':unit, 'tcp_ports':ports, 'current':selected,
            'operation':'仅修改指定服务的通配 bind；显式私网、其他端口、出站连接保持',
            'ipv6':'双栈通配 socket 改为 ::ffff:127.0.0.1；不提供独立 ::1 入口',
            'restart':'重启该服务；不修改应用源码/依赖/启动命令', 'firewall_changes':False}


def snapshot_files(paths):
    out = []
    for raw in paths:
        p = Path(raw)
        if p.exists():
            st = p.stat(); out.append({'path':str(p), 'before':p.read_text(), 'mode':st.st_mode & 0o7777, 'uid':st.st_uid, 'gid':st.st_gid})
        else: out.append({'path':str(p), 'before':None, 'mode':0o600, 'uid':0, 'gid':0})
    return out


def put_file(row, text):
    path = Path(row['path']); write(path, text)
    os.chmod(path, row['mode']); os.chown(path, row['uid'], row['gid'])


def restore_files(directory, rows):
    for index, row in enumerate(rows):
        p = Path(row['path'])
        if row['before'] is not None: put_file(row, row['before'])
        elif p.exists(): os.replace(p, directory / f'removed-{index}-{p.name}')


def validate_runtime_ports(ports, before):
    current = scan()
    for port in ports:
        entry = next((e for e in current['entries'] if e['key']==f'tcp/{port}'), None)
        if not entry or any(a in ('*', '0.0.0.0', '::') for a in entry['addresses']): raise Error(f'{port} 仍通配监听或未启动')
        previous = next((e['addresses'] for e in before if e['port']==port), [])
        if any(not loopback(a) and a not in previous for a in entry['addresses']): raise Error('出现未预期的非回环监听')


def verify_native_ownership(cgroup,module,ports):
    if cgroup.exists() and (module.attached(cgroup,8) or module.attached(cgroup,9)):
        if not ports or not module.owned(cgroup,ports):raise Error('存在外部 bind 适配，保持服务运行并停止修改')


def stop_native(unit, ports):
    relative=run(['systemctl','show','--value','-p','ControlGroup',unit]).stdout.strip()
    cgroup=Path('/sys/fs/cgroup')/relative.lstrip('/') if relative else None
    if cgroup:verify_native_ownership(cgroup,native_module(),ports)
    run(['systemctl','stop',unit],timeout=120)
    if cgroup and ports:native_module().detach(cgroup,ports)


def native_apply(unit, ports, url):
    with locked():
        preview = native_plan(unit, ports)
        if not url: raise Error('原生服务试用必须指定本机健康检查 URL')
        healthy(url, [{'published':str(p)} for p in ports])
        module = native_module()
        # Preflight verifier permissions before changing any service files.
        for ipv6 in (False, True): os.close(module.load(ports, ipv6))
        drop = Path('/etc/systemd/system') / (unit+'.d') / '70-vps-listen-bind.conf'
        config = STATE / 'native-units' / (unit+'.json')
        rows = snapshot_files([drop, config])
        if rows[0]['before'] is not None and '# VPS_LISTEN_BIND_MANAGED' not in rows[0]['before']:
            raise Error('同名 drop-in 不属于本工具')
        tx = uuid.uuid4().hex; directory = STATE/'transactions'/tx
        meta = {'adapter':'native', 'unit':unit, 'host':socket.gethostname(), 'status':'prepared', 'files':rows, 'tcp_ports':ports, 'health_url':url,
                'intents_before':read_json(STATE/'intents.json',{}),'choices':{f'tcp/{p}':['local','gateway'] for p in ports},'before_addresses':preview['current']}
        save(directory/'transaction.json', meta)
        content = '# VPS_LISTEN_BIND_MANAGED\n[Service]\nExecStartPre=+/usr/bin/python3 -B '+str(NATIVE_HELPER)+' --attach-unit '+unit+'\n'
        try:
            previous_ports=json.loads(rows[1]['before'])['tcp_ports'] if rows[1]['before'] else []
            stop_native(unit,previous_ports)
            put_file(rows[1], json.dumps({'unit':unit, 'tcp_ports':ports}, indent=2)+'\n')
            put_file(rows[0], content)
            for row in rows: row['after_sha256'] = sha(Path(row['path']).read_text())
            run(['systemctl','daemon-reload']); run(['systemctl','start',unit], timeout=120)
            healthy(url, [{'published':str(p)} for p in ports]); validate_runtime_ports(ports, preview['current'])
            intents=read_json(STATE/'intents.json',{});intents.update(meta['choices']);save(STATE/'intents.json',intents)
            meta.update(status='applied'); save(directory/'transaction.json',meta)
            print(json.dumps({'transaction':tx, 'status':'applied', 'unit':unit}))
        except BaseException:
            stop_native(unit,ports)
            restore_files(directory, rows); run(['systemctl','daemon-reload'])
            run(['systemctl','start',unit],timeout=120)
            meta.update(status='failed_restored');save(directory/'transaction.json',meta);raise


def nginx_rewrite(text, keep, allowed_ports=(80,443)):
    pattern = re.compile(r'^(\s*listen\s+)(?:(\[::\]|0\.0\.0\.0|\*):)?(\d+)([^;]*;)([^\n]*)(\n?)$',re.M)
    changed = []
    def replace(m):
        port = int(m[3])
        if port not in allowed_ports: return m[0]
        host = '[::1]' if m[2]=='[::]' else '127.0.0.1'
        changed.append(port)
        newline = m[6] or '\n'
        result = f'{m[1]}{host}:{port}{m[4]}{m[5]}{newline}'
        if m[2]!='[::]':
            for ip in keep:
                address = '['+ip+']' if ':' in ip else ip
                result += f'{m[1]}{address}:{port}{m[4]}{newline}'
        return result
    return pattern.sub(replace,text), sorted(set(changed))


def nginx_candidates(keep):
    assigned = {a['local'] for i in json.loads(run(['ip','-j','address']).stdout) for a in i.get('addr_info',[])}
    keep = sorted(set(keep))
    for ip in keep:
        value = ipaddress.ip_address(ip)
        if ip not in assigned or value.is_global or value.is_link_local or value.is_unspecified or value.is_multicast:
            raise Error('保留地址必须是本机已分配的明确内网/回环地址')
    output = run(['nginx','-T']).stdout
    files = sorted(set(re.findall(r'^# configuration file ([^\n]+):$',output,re.M)))
    candidates = []
    for raw in files:
        path = Path(raw).resolve(); before = path.read_text()
        after, ports = nginx_rewrite(before,keep)
        if before != after: candidates.append({'path':str(path), 'before':before, 'after':after, 'ports':ports})
    if not candidates:
        # Re-edit our already narrowed configuration using its original template.
        history=sorted((STATE/'transactions').glob('*/transaction.json'),key=lambda p:p.stat().st_mtime,reverse=True)
        for record in history:
            meta=read_json(record)
            if meta.get('adapter')!='nginx' or meta['status']!='applied':continue
            rows=meta['files']
            if not all(Path(row['path']).is_file() and sha(Path(row['path']).read_text())==row.get('after_sha256') for row in rows):continue
            templates=meta.get('nginx_templates') or {row['path']:row['before'] for row in rows}
            for row in rows:
                path=Path(row['path']);before=path.read_text();template=templates[row['path']]
                after,ports=nginx_rewrite(template,keep)
                if before!=after:candidates.append({'path':str(path),'before':before,'after':after,'ports':ports,'template':template})
            return candidates
        raise Error('没有可修改的标准监听，也未找到与当前配置匹配的管理事务')
    return candidates


def nginx_plan(keep):
    return {'adapter':'nginx','files':[{'path':c['path'],'ports':c['ports'],'before_sha256':sha(c['before'])} for c in nginx_candidates(keep)],
            'listen':['127.0.0.1','::1']+keep, 'operation':'仅修改 listen，nginx -t 后短暂重启 Nginx；不改 server_name/proxy_pass/TLS', 'firewall_changes':False}


def nginx_apply(keep):
    with locked():
        changes = nginx_candidates(keep)
        if not changes:print(json.dumps({'status':'unchanged','adapter':'nginx'}));return
        rows = snapshot_files([c['path'] for c in changes])
        tx=uuid.uuid4().hex;directory=STATE/'transactions'/tx
        meta={'adapter':'nginx','host':socket.gethostname(),'status':'prepared','files':rows,
              'nginx_templates':{c['path']:c.get('template',c['before']) for c in changes},
              'intents_before':read_json(STATE/'intents.json',{}),'choices':{f'tcp/{p}':['gateway']+(['peers'] if keep else []) for p in (80,443)}}
        save(directory/'transaction.json',meta)
        try:
            for row,c in zip(rows,changes):
                if Path(row['path']).read_text()!=c['before']:raise Error('配置被并发修改')
                put_file(row,c['after']);row['after_sha256']=sha(c['after'])
            run(['nginx','-t']);run(['systemctl','restart','nginx'])
            time.sleep(2)
            for e in scan()['entries']:
                if e['protocol']=='tcp' and e['port'] in (80,443) and any(a in ('*','0.0.0.0','::') for a in e['addresses']):raise Error('Nginx 仍通配监听')
            intents=read_json(STATE/'intents.json',{});intents.update(meta['choices']);save(STATE/'intents.json',intents)
            meta.update(status='applied');save(directory/'transaction.json',meta)
            print(json.dumps({'transaction':tx,'status':'applied','adapter':'nginx'}))
        except BaseException:
            restore_files(directory,rows);run(['nginx','-t']);run(['systemctl','restart','nginx'])
            meta.update(status='failed_restored');save(directory/'transaction.json',meta);raise


def restore_native(directory, meta):
    for row in meta['files']:
        if not Path(row['path']).exists() or sha(Path(row['path']).read_text())!=row['after_sha256']:raise Error('配置发生后续变更，拒绝覆盖')
    if meta['adapter']=='native':
        stop_native(meta['unit'],meta['tcp_ports'])
        restore_files(directory,meta['files'])
        run(['systemctl','daemon-reload']);run(['systemctl','start',meta['unit']],timeout=120)
        if meta.get('health_url'):healthy(meta['health_url'],[{'published':str(p)} for p in meta['tcp_ports']])
        if meta.get('before_addresses'):
            current=scan()
            for before in meta['before_addresses']:
                row=next((e for e in current['entries'] if e['key']==f'tcp/{before["port"]}'),None)
                if not row or row['addresses']!=before['addresses']:raise Error('恢复后实际监听与事务前不一致，未标记恢复成功')
    else:
        restore_files(directory,meta['files']);run(['nginx','-t']);run(['systemctl','restart','nginx'])
    intents=read_json(STATE/'intents.json',{})
    for key,value in meta.get('choices',{}).items():
        if intents.get(key)==value:
            if key in meta.get('intents_before',{}):intents[key]=meta['intents_before'][key]
            else:intents.pop(key,None)
    save(STATE/'intents.json',intents)
    meta['status']='rolled_back';save(directory/'transaction.json',meta);print('已恢复原监听配置，未改防火墙')


def choices_for(container, intents):
    d = inspect(container)
    return {f'{target.split("/")[1]}/{v["HostPort"]}': intents for target, vs in (d['HostConfig'].get('PortBindings') or {}).items() for v in vs or []}


def menu():
    while True:
        print('\n真实监听回环管理\n1) 扫描/查询实际监听和事务\n2) 选择容器用途并预览/应用\n3) 按事务恢复原监听\n4) 原生 systemd 服务真实 bind 回环\n5) Nginx 80/443 回环（可保留内网地址）\n0) 返回')
        action = input('请选择: ').strip()
        if action in ('', '0'): return
        try:
            if action == '1': show()
            elif action == '2':
                container = input('容器名（先查询）: ').strip()
                print('用途可组合：local 仅本机 / gateway 本机域名网关 / peers 其他机器 / public 公网 / keep 保持。\n远端网关请选择 peers；peers/public 保持监听，来源限制由原防火墙负责。显式内网绑定始终保留。')
                intents = input('用途，逗号分隔: ').strip().split(',')
                choices = choices_for(container, [x.strip() for x in intents])
                print(json.dumps(plan(container, choices), ensure_ascii=False, indent=2))
                if input('会短暂中断该服务；输入 RECREATE 执行，其他输入仅预览: ') == 'RECREATE':
                    url = input('本机健康检查 URL（建议填写）: ').strip() or None
                    apply(container, choices, url)
            elif action == '3': rollback(input('事务编号: ').strip())
            elif action == '4':
                unit=input('服务完整名称（如 app.service）: ').strip()
                ports=[int(p.strip()) for p in input('要回环的 TCP 端口，逗号分隔: ').split(',')]
                print(json.dumps(native_plan(unit,ports),ensure_ascii=False,indent=2))
                if input('仅适用于本机/本机网关用途；会重启该服务。输入 RESTART 执行: ')=='RESTART':
                    native_apply(unit,ports,input('本机 HTTP 健康检查 URL（必填）: ').strip())
            elif action == '5':
                keep=[x.strip() for x in input('保留的本机内网 IP，逗号分隔（无则留空）: ').split(',') if x.strip()]
                print(json.dumps(nginx_plan(keep),ensure_ascii=False,indent=2))
                if input('会短暂重启 Nginx；输入 RESTART 执行: ')=='RESTART': nginx_apply(keep)
        except (Error, ValueError, OSError, subprocess.SubprocessError) as exc:
            print('未完成：' + str(exc))


def main():
    global STATE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=Path, default=STATE)
    sub = parser.add_subparsers(dest='command', required=True)
    for c in ('menu', 'scan', 'show'): sub.add_parser(c)
    for c in ('plan', 'apply'):
        p = sub.add_parser(c); p.add_argument('container'); p.add_argument('--choices', type=Path)
        p.add_argument('--intents', default='local'); p.add_argument('--confirm-recreate', action='store_true'); p.add_argument('--health-url')
    sub.add_parser('rollback').add_argument('transaction')
    for c in ('native-plan','native-apply'):
        p=sub.add_parser(c);p.add_argument('unit');p.add_argument('--ports',required=True)
        p.add_argument('--confirm-restart',action='store_true');p.add_argument('--health-url')
    for c in ('nginx-plan','nginx-apply'):
        p=sub.add_parser(c);p.add_argument('--keep-address',action='append',default=[]);p.add_argument('--confirm-reload',action='store_true')
    args = parser.parse_args(); STATE = args.state_dir.resolve()
    if os.geteuid() != 0: raise Error('需要 root')
    if args.command == 'scan': print(json.dumps(scan(), ensure_ascii=False, indent=2))
    elif args.command == 'show': show()
    elif args.command == 'menu': menu()
    elif args.command == 'rollback': rollback(args.transaction)
    elif args.command.startswith('native-'):
        ports=[int(p) for p in args.ports.split(',')]
        if args.command=='native-plan':print(json.dumps(native_plan(args.unit,ports),ensure_ascii=False,indent=2))
        elif not args.confirm_restart:raise Error('应用需要 --confirm-restart')
        else:native_apply(args.unit,ports,args.health_url)
    elif args.command.startswith('nginx-'):
        if args.command=='nginx-plan':print(json.dumps(nginx_plan(args.keep_address),ensure_ascii=False,indent=2))
        elif not args.confirm_reload:raise Error('应用需要 --confirm-reload')
        else:nginx_apply(args.keep_address)
    else:
        choices = read_json(args.choices) if args.choices else choices_for(args.container, args.intents.split(','))
        if args.command == 'plan': print(json.dumps(plan(args.container, choices), ensure_ascii=False, indent=2))
        elif not args.confirm_recreate: raise Error('请先预览；执行需 --confirm-recreate')
        else: apply(args.container, choices, args.health_url)


if __name__ == '__main__':
    try: main()
    except (Error, OSError, ValueError, subprocess.SubprocessError) as exc:
        print('监听管理：' + str(exc), file=sys.stderr); raise SystemExit(1)
