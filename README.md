# VPS Manager

`VPS Manager` 是一个面向 Debian/Ubuntu VPS 的中文交互式管理脚本，并为小硬盘 Alpine/OpenRC NAT VPS 提供受限模式，用于完成服务器初始化、Xray 配置，以及 Komari Agent/WARP 私网接入。

当前版本：`0.9.5-test`

> 目前是测试版。首次在正式服务器上使用前，建议先运行预览模式，并保留一个已经登录的 SSH 终端。

## 功能

- 安装常用基础工具：`curl`、`wget`、`vim`、`unzip`、`python3` 等
- 可选开启 BBR
- 管理 SSH 公钥，并可独立配置高位端口和仅密钥登录
- 安装或升级 Xray
- 首次生成 VLESS Reality 配置
- 增量更新已有 Xray 配置
- 添加 SOCKS5、HTTP、HTTPS 或 Shadowsocks 出口
- 检查部分 SOCKS5 域名解析/连接问题并应用 IPv4 兜底
- SOCKS5 两种检测均失败时，默认停止；用户可明确确认风险后强制写入，并在状态中标记为未验证
- 输出可直接放进 Clash/Mihomo YAML 的节点内容
- 查看、导入、重命名和重新分组 YAML 节点
- 提供独立的 Windows SSH 公钥和私钥生成脚本
- 在 Linux 主脚本中提供 SSH 公钥校验、写入和加固管理
- 安装或管理 Komari Agent
- 使用内置流程配置 Cloudflare WARP 私网
- 查看系统、BBR、Xray、Komari 和 WARP 状态

## 支持环境

- Debian 或 Ubuntu，并使用 `systemd`：支持完整功能
- Alpine Linux `x86_64`，并使用 OpenRC：只支持 BBR 检查、Xray、Komari+WARP、状态检查和脚本更新/删除
- 使用 root 运行，或者当前用户可以执行 `sudo`
- 服务器能够访问所需的软件源

暂不支持 CentOS、AlmaLinux、Rocky Linux、OpenWrt 等系统。Alpine 模式不会显示 SSH 加固和 YAML 管理等无关选项。

### Alpine 受限模式说明

Alpine 使用宿主机内核。脚本只有在 `tcp_available_congestion_control` 确实包含 `bbr` 时才会写入并启用 BBR；如果 NAT/容器宿主机没有加载 `tcp_bbr`，脚本只会说明限制，不会写入一个看似成功但实际无效的配置。

Xray 使用 XTLS 官方发布的 Linux amd64 静态压缩包，并由 OpenRC 管理。生成或更新配置后仍会先校验候选 JSON，再替换文件并重启 Xray。

[Cloudflare 官方支持列表](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/download/)目前没有 Alpine。为了让小硬盘 Alpine 机器仍可使用 Zero Trust Team、MDM 和 Service Token，脚本会安装并锁定 Cloudflare WARP `2026.1.150.0`，将官方 Debian 程序及其经过 SHA-256 校验的 glibc 依赖隔离在 `/opt/cloudflare-warp`。它不会替换 Alpine 的 musl，但属于兼容方案而不是 Cloudflare 官方支持的 Alpine 安装方式。

Alpine 安装流程还会部署一个每 5 分钟执行的资源保护器：`warp-svc.log` 超过 8 MiB 时保留末尾 2 MiB 并压缩归档，`warp-svc` 的 RSS 超过 160 MiB 时自动重启服务。日志轮转不影响隧道；内存保护触发时会有一次短暂的 WARP 重连。

对于 `x86_64` 且根分区可用空间不足 300 MiB 的极小 Alpine 容器，脚本提供实验性极限小磁盘模式。该模式要求根分区至少剩余 105 MiB、`/run` 或 `/dev/shm` 至少剩余 60 MiB：官方安装包只暂存在 tmpfs，客户端包只提取 `warp-svc` 和 `warp-cli`，glibc 运行时按递归 ELF 依赖白名单裁剪，并把 `warp-cli` 压缩保存、使用时解压到 `/run`。资源保护器会直接读取已安装的 `PROFILE`，把日志限制为 512 KiB并保留末尾128 KiB，`warp-svc` RSS达到96MiB时重启；重复安装或更新保护器不会退回普通阈值。安装前仍会再次检查依赖安装后的根分区空间；不足时会清理候选文件并停止，不会强行写满磁盘。此模式只完成了 `amd64` 依赖审计，不对 `arm64` 开放。

Debian/Ubuntu 安装流程会部署同一内存阈值的 systemd timer，每 5 分钟检查一次 `warp-svc` RSS，超过 160 MiB 时自动重启服务。官方客户端自己的文件日志已按固定数量轮转，因此不会再叠加一套文件日志轮转。

## 快速开始

### 方法一：使用 curl

```bash
curl -fLO https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/vps-manager.sh
chmod +x vps-manager.sh
sudo ./vps-manager.sh
```

### 方法二：使用 wget

```bash
wget https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/vps-manager.sh
chmod +x vps-manager.sh
sudo ./vps-manager.sh
```

### 方法三：克隆仓库

```bash
git clone https://github.com/UziKaiSa/vps-manager.git
cd vps-manager
sudo ./vps-manager.sh
```

如果当前已经是 root，可以直接运行：

```bash
./vps-manager.sh
```

## Windows 使用方法：仅生成 SSH 公钥和私钥

Windows 用户可以单独下载密钥生成脚本：

```powershell
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/windows-ssh-key.ps1" `
  -OutFile ".\windows-ssh-key.ps1"
```

运行脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\windows-ssh-key.ps1"
```

运行后只需输入密钥文件名后缀。例如输入 `GB`，会生成 `id_ed25519_GB` 和 `id_ed25519_GB.pub`；直接回车使用默认后缀 `vps-manager`。

Windows 不需要执行 `chmod +x`。上面的 `-ExecutionPolicy Bypass` 只对这一次 PowerShell 进程生效，用于执行刚下载的脚本，不会永久修改系统执行策略。

默认生成位置：

```text
私钥：%USERPROFILE%\.ssh\id_ed25519_vps-manager
公钥：%USERPROFILE%\.ssh\id_ed25519_vps-manager.pub
```

也可以直接指定密钥文件名后缀和备注：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\windows-ssh-key.ps1" `
  -KeyNameSuffix "my-vps" `
  -Comment "my-vps"
```

脚本默认只生成密钥文件并显示公钥内容，不连接 VPS、不写入 `authorized_keys`，也不修改服务器配置；只有在你确认配置快捷名称后，才会更新本机 Windows 的 SSH config。已有同名密钥时会停止，不会覆盖。

密钥生成后，脚本会询问是否配置 SSH 快捷名称。选择后需要填写快捷名称、服务器 IP/域名、SSH 用户和端口，配置会写入 `%USERPROFILE%\.ssh\config`；以后可以直接执行 `ssh 快捷名称`。已有同名 `Host` 时会明确提示，并询问是否换一个名称，绝不会覆盖原配置。

> `vps-manager.sh` 需要在受支持的 Debian/Ubuntu 或 Alpine VPS 中运行，不能直接在原生 Windows PowerShell 中执行。

## 建议先使用预览模式

预览模式不需要 root，也不会修改系统：

```bash
bash vps-manager.sh --demo
```

预览模式适合：

- 查看完整菜单和交互流程
- 预览 Xray JSON
- 确认需要填写哪些字段
- 检查节点名称和客户端 YAML 输出
- 在应用正式配置前进行人工审核

其他参数：

```bash
bash vps-manager.sh --version
bash vps-manager.sh --help
```

## 主菜单

启动脚本后会看到：

```text
1) 初始化环境：基础工具和可选 BBR
2) Xray 管理：安装、首次配置或更新现有配置
3) SSH 密钥与加固管理
4) YAML 管理：查看、导入节点、更新名称和分组
5) 安装/管理 Komari Agent
6) 状态检查
7) 从 GitHub 更新当前脚本
8) 删除当前 .sh 脚本
0) 退出
```

## 1. 初始化环境
在 Debian 11 Bullseye 上，初始化会先备份 APT 源文件，修正旧的 `bullseye/updates` 安全源，并禁用普通 Debian 镜像中已经下线的 `bullseye-backports`。其他系统和自定义镜像不会被改写。

如果 `apt-get update` 报告 Packages/MergeList/package cache 损坏，脚本会先检查内核日志：没有存储错误时自动清理可重新下载的 APT 索引并重试一次；如果发现 EXT4、I/O 或块设备错误，则立即停止并要求先离线检查文件系统，不会用删除缓存掩盖底层故障。


初始化会先安装：

```text
ca-certificates curl wget vim unzip python3 python3-yaml
openssl iproute2 openssh-client
```

基础工具安装完成后，脚本只会询问是否开启 BBR；可以选择跳过。

SSH 公钥写入和 SSH 加固已经移到一级菜单的“SSH 密钥与加固管理”，初始化不会再修改 SSH 端口或登录方式。

## 2. Xray 管理

子菜单：

```text
1) 安装或升级 Xray（不改配置）
2) 首次生成并应用完整配置
3) 更新现有受管配置
4) 显示连接参数与 AWS YAML
5) 查看 Xray 状态并校验配置
0) 返回
```

### 首次配置

首次配置会询问节点名称、客户端连接地址、Reality 端口、`dest`、`serverNames`、出口代理和可选入站协议。

常用说明：

- 节点名称只用于 YAML 展示和识别
- 客户端连接地址填写 VPS 公网 IP 或已经解析到该 VPS 的域名
- Reality target 填写裸域名或裸 IP 时会自动补全 `:443`；已经填写合法端口则保持不变
- Reality `serverNames` 支持多个域名，用英文逗号分隔
- 默认开启 Reality 防偷：未鉴权 fallback 先进入仅监听 `127.0.0.1` 的 TLS SNI 检查入站，仅 `full:` 精确命中 `serverNames` 时才访问原 target；可在 Reality 更新菜单中关闭或重新开启
- 防偷辅助端口稳定保存在状态中，默认从 `39000-59999` 选择且避开其他受管入站；更新器兼容 Xray 的 `target` 和旧版 `dest`
- UUID、Reality 密钥和 Short ID 会自动生成
- 配置写入前会显示完整 JSON 供审核

Xray 主配置文件：

```text
/usr/local/etc/xray/config.json
```

脚本状态与输出文件：

```text
/etc/vps-manager/state.json
/etc/vps-manager/last-install.txt
/etc/vps-manager/proxies.yaml
```

### 出口代理链接格式

支持以下协议：

```text
socks5://
http://
https://
ss://
```

SOCKS5、HTTP 和 HTTPS 推荐使用标准 URL：

```text
协议://用户名:密码@IP或域名:端口
```

示例：

```text
socks5://user:pass@1.2.3.4:1080
https://user:pass@proxy.example.com:443
```

同时兼容旧格式：

```text
协议:IP或域名:端口@用户名:密码
```

Shadowsocks 使用标准 `ss://` 链接，例如：

```text
ss://BASE64(加密方式:密码)@IP或域名:端口
```

代理链接和密码使用隐藏输入，不会直接显示在终端上。

### 更新已有配置

“更新现有受管配置”可以分别修改：

- 节点名称和客户端连接地址
- Reality 端口、`dest` 和 `serverNames`
- Reality 密钥和 Short ID
- ISP 出口代理
- SOCKS5 入站
- Shadowsocks 入站
- UUID

脚本会先读取现有配置并生成候选文件。只有选择“应用配置”并确认后，才会写入正式配置和重启 Xray。

如果 `config.json` 在脚本外被修改，脚本不会再直接拒绝更新，而会提供三个选择：恢复最近一份 `config/state` 指纹匹配的完整备份；保留当前 live config，经过 Xray 语法、受管结构、client/route/outbound 和 Reality 公钥校验后作为新的更新基线；或者取消且不修改文件。接管当前配置前会先创建统一备份，真正刷新 `state.json`、连接信息和 YAML 仍需在更新菜单中预览并确认应用。外部新增且无法从旧 state 找到名称的出口会暂用其 Xray tag 作为名称，可在应用前修改。

## 3. SSH 密钥与加固管理

子菜单：

```text
1) 本机 Linux 生成密钥并可配置快捷名称
2) 校验 SSH 公钥并显示指纹
3) 配置 SSH 高位端口和仅密钥登录
4) 添加公钥到当前管理用户 authorized_keys
5) 查看当前管理用户 authorized_keys
0) 返回
```

“本机 Linux 生成密钥”会直接操作当前管理用户的 `~/.ssh`。例如输入后缀 `GB`，会实际生成 `~/.ssh/id_ed25519_GB` 和 `~/.ssh/id_ed25519_GB.pub`；直接回车使用默认后缀 `vps-manager`。可以选择是否为私钥设置密码。

密钥生成后还可以配置本机 SSH 快捷名称。填写快捷名称、服务器地址、用户和端口后，脚本会写入当前管理用户的 `~/.ssh/config`；以后可以直接执行 `ssh 快捷名称`。如果同名 `Host` 已存在，脚本会明确提示并询问是否换一个名称；选择否则取消写入，原配置不会变化。

当前管理用户自动使用运行脚本的登录用户，不需要另外填写用户名。

“添加公钥”只校验并写入 `~/.ssh/authorized_keys`，会避免重复添加相同密钥；它不会修改 SSH 端口，也不会关闭密码登录。已有文件在变更前会保存到 `/var/backups/vps-manager/`。

菜单 3 和菜单 4 完成后都会检查 SSH 的重启持久性：写入 `/etc/tmpfiles.d/vps-manager-sshd.conf`，确保每次启动都创建临时目录 `/run/sshd`；随后执行 `sshd -t`，确认 `ssh.service`/`sshd.service` 已启用且正在运行，并显示生效监听端口。由 `ssh.socket` 切换到高位端口服务模式时，脚本会同时启用对应 service，避免当前会话正常但重启后 SSH 断链。

脚本只会显示客户端生成密钥的命令、读取你粘贴的公钥，不会在 VPS 上生成、保存或显示客户端私钥。

### SSH 加固注意事项

完整加固流程会要求：

- 输入 `10000-65535` 范围内的新 SSH 端口
- 粘贴一整行 SSH 公钥；如果当前 `authorized_keys` 已有有效公钥，可以直接回车沿用
- 确认云厂商安全组已经放行新端口
- 关闭密码登录并仅允许密钥认证

脚本会校验 SSH 配置、重新加载服务，并等待最多约 10 秒确认新端口开始监听，然后要求使用第二个终端验证。验证失败时会尝试恢复原配置。

脚本会扫描 `/etc/ssh/sshd_config` 和 `/etc/ssh/sshd_config.d/*.conf` 中已有的显式 `Port`（包括云厂商预置的高位端口），先备份并停用旧指令，再仅写入用户选择的新端口。任何校验或登录验证失败时，所有被修改的端口来源文件都会一并恢复。

请务必：

- 不要关闭当前 SSH 会话
- 提前在云厂商安全组或防火墙中开放新端口
- 只粘贴 `.pub` 公钥，不要粘贴私钥
- 第二个终端确认能够登录后，再关闭旧会话和 22 端口规则

## 4. YAML 管理

YAML 管理用于维护 Clash/Mihomo 配置中的 `proxies` 和 `proxy-groups`：

```text
1) 选择/切换 YAML 文件
2) 查看节点与分组摘要
3) 使用 vim 只读查看完整 YAML
4) 导入或更新 Xray 输出节点
5) 重命名节点并同步分组引用
6) 更新节点分组
7) 校验 YAML
```

脚本会自动检查：

```text
/var/www/share/config/*.yaml
/var/www/share/config/*.yml
```

也可以手动输入其他 YAML 文件的绝对路径。

导入节点时，可以选择：

- 使用本机最近一次 Xray 输出
- 直接粘贴节点 YAML
- 指定另一个节点文件

写入前会显示 diff，并要求再次确认。YAML 管理只重写：

```yaml
proxies:
proxy-groups:
```

不会主动修改 DNS、规则、订阅提供器或其他顶层配置。

## 5. 安装/管理 Komari Agent

子菜单：

```text
1) 配置/修复 WARP 私网，并可继续安装 Agent
2) 安装/重装普通公网 Komari Agent
3) 查看 Agent/WARP 状态
4) 重连 WARP
0) 返回
```

### WARP 私网模式

原仓库中的 `install-komari-warp-agent.sh` 已经并入主脚本。此选项会直接调用内置函数，不再下载并执行本仓库的包装脚本。

以下值不在公开脚本中提供默认值，运行时必须输入：

```text
Cloudflare Zero Trust Team
Komari 私网地址
WARP MDM: /var/lib/cloudflare-warp/mdm.xml
service_mode: warp
```

Reality target 和 `serverNames` 同样没有内置默认域名，首次配置时必须输入。

Cloudflare Access Service Token 的读取顺序：

1. 环境变量 `CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET`
2. `/root/warp-token.env`
3. 交互式隐藏输入

首次安装官方 Cloudflare WARP 客户端前，脚本会检查根分区容量。由于当前官方包强制依赖 WebKit/GTK 等大型组件，脚本要求：

```text
根分区总容量：至少 3 GiB
根分区可用空间：至少 1.5 GiB
建议根分区：4 GiB 或更大
```

Debian 11、Debian 12、Ubuntu 22.04、Ubuntu 24.04 和 Ubuntu 26.04 amd64 默认安装 Cloudflare 官方 `2026.1.150.0` 轻量稳定版；Ubuntu 22.04 使用 Jammy 包，Ubuntu 26.04 使用向后兼容的 Noble 包。如果已经安装其他版本，脚本会在确认后降级。该版本是新版 Linux GUI 引入前的官方版本，下载约 53 MiB、安装后约 152 MiB，仍支持 `mdm.xml`、Zero Trust Team 和 Service Token。安装前至少需要 400 MiB 可用空间。其他未经验证的系统会明确停止，不再回退安装仓库最新版。

脚本会校验官方安装包的 SHA-256；降级前备份现有 `mdm.xml`，安装时使用 `--allow-downgrades`，完成后执行 `apt-mark hold cloudflare-warp`，防止系统升级时重新拉入带 WebKit/GTK 的大型新版。锁定期间不会获得新版功能和安全修复；如需恢复新版，应手动解除锁定并升级：

如果 Ubuntu/Debian 的 `unattended-upgrade`、`apt-daily` 或其他合法软件包事务正在持有 APT/dpkg 锁，脚本会保留锁和系统更新进程，最多等待 10 分钟并定期显示持有者。等待超时或 APT 更新失败时，本次 WARP 安装会立即停止，不会继续下载后再次撞锁，也不会建议删除锁文件。

```bash
apt-mark unhold cloudflare-warp
apt update
apt install cloudflare-warp
```

`/root/warp-token.env` 示例：

```bash
CF_ACCESS_CLIENT_ID='你的 Client ID'
CF_ACCESS_CLIENT_SECRET='你的 Client Secret'
```

建议设置权限：

```bash
sudo chmod 600 /root/warp-token.env
```

脚本会安装 Cloudflare 官方 WARP 客户端、写入 MDM、连接 WARP、检查 Komari 私网地址，然后询问是否继续安装 Agent。

脚本以 `nft list ruleset` 的实际结果判断 nftables 能力，不会因为 LXC 容器内无法执行 `modprobe` 而误判。容器共享宿主机内核：如果 nftables 不可用，脚本会提示联系服务商开放 nftables/NET_ADMIN 和 `/dev/net/tun`，不会在容器内反复安装无效的 `linux-image`。只有非容器系统在加载 `nf_tables` 后仍不可用时，才会询问是否安装新内核，并且不会自动重启服务器。

### 普通公网模式

如果 Komari 面板可以通过公网直接访问，可以选择普通公网模式，输入：

- Komari 面板地址
- Komari Client Token
- Agent 安装目录
- 流量统计重置日
- 是否禁用 Web SSH
- 是否启用 GPU 监控
- 是否记录公网 IPv4

安装 Agent 时会先检测环境变量 `KOMARI_LOCAL_AGENT` 指向的文件，或者目标用户家目录下与当前架构匹配的 `komari-agent-linux-amd64` / `komari-agent-linux-arm64`，也支持带版本号的文件名（例如 `komari-agent-linux-amd64-v1.2.60`，存在多个版本时选择版本号最高的文件）。检测到非空的普通文件后，脚本会显示路径并默认询问是否优先使用；确认后会计算 SHA-256、执行 `--help` 校验、安装到 Agent 目录，并跳过 GitHub Release 下载。

仓库的 `assets/` 目录同时保存经过 SHA-256 固定校验的 amd64 兜底 Agent。若 Komari 官方安装器或其 GitHub Release 下载链路失败，且目标机上没有手动上传的 Agent，脚本会询问是否从 VPS Manager 仓库下载固定版本；确认后只有哈希完全匹配才会执行。

本地安装路径会生成权限为 `700` 的启动包装器保存 Agent 参数，避免 Client Token 出现在 systemd/OpenRC service 文件中。私网 Endpoint 会让 `komari-agent` 显式依赖 `warp-svc`，保证重启时先建立私网；如果 WARP没有正确安装，Agent服务也不会伪装成成功启动。已有 Agent、启动包装器和服务文件会先保存到 `/var/backups/vps-manager/`。

如果脚本检测到服务器只有 IPv6 默认路由、没有 IPv4 默认路由，并且尚未找到本地 Agent，它会停止自动下载并直接显示对应架构的 GitHub Releases 下载链接、上传路径和需要重新选择的菜单项。脚本不会自动修改 DNS，也不会接入第三方 NAT64 或下载代理。

纯 IPv6 机器可以先在其他能够访问 GitHub Releases 的电脑下载官方二进制，再通过可信的文件传输工具上传。例如 amd64 root 用户默认放置在：

```text
/root/komari-agent-linux-amd64
```

上传完成后重新执行相同的 Komari 安装菜单项；脚本检测到本地文件后会进行校验并优先使用。非 IPv6-only 环境找不到本地文件，或者用户明确拒绝使用已检测到的文件时，脚本仍会下载并校验 Komari 官方安装器，保持原有安装路径。

## 6. 状态检查

状态检查会显示：

- 系统、主机名和内核版本
- BBR 状态
- Xray 配置校验和服务状态
- 当前连接参数保存位置
- Komari Agent 状态
- WARP 服务状态

## 更新和删除脚本

一级菜单的“从 GitHub 更新当前脚本”会：

1. 从本仓库 `main` 分支下载最新版到临时文件
2. 校验 Bash 语法和脚本身份
3. 校验通过后原子覆盖当前运行的 `.sh` 文件

更新成功后，当前旧进程会立即退出，并自动启动刚覆盖的新脚本，不需要手动重新运行。也可以手动更新：

```bash
curl -fL https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/vps-manager.sh -o vps-manager.sh
chmod +x vps-manager.sh
./vps-manager.sh --version
```

“删除当前 .sh 脚本”会显示绝对路径并要求二次确认。它只删除当前运行的脚本文件，不会删除 Xray、SSH、YAML、Komari 配置或 `/var/backups/vps-manager/` 中的备份。删除成功后程序会退出。

更新或删除脚本本身都不会主动修改现有 Xray、SSH、YAML 或 Komari 配置。

## 配置与备份位置

主要路径：

```text
/usr/local/etc/xray/config.json       Xray 配置
/etc/vps-manager/state.json           脚本管理状态
/etc/vps-manager/last-install.txt     最近连接参数
/etc/vps-manager/proxies.yaml         最近生成的节点 YAML
/etc/ssh/sshd_config.d/00-vps-manager-hardening.conf
/var/lib/cloudflare-warp/mdm.xml      WARP MDM 配置
/var/backups/vps-manager/             自动备份目录
```

涉及正式配置的操作会尽量先创建备份。仍建议在大规模部署前自行保存云厂商快照。

## Komari 看板主题脚本

仓库继续保留：

```text
apply-kaisa-komari-theme.py
```

使用方法：

```bash
python3 apply-kaisa-komari-theme.py --db ./data/komari.db
```

指定备份目录：

```bash
python3 apply-kaisa-komari-theme.py \
  --db ./data/komari.db \
  --backup-dir ./data/theme-backups
```

只有在明确不需要数据库备份时才使用：

```bash
python3 apply-kaisa-komari-theme.py --db ./data/komari.db --no-backup
```

## 常见问题

### 为什么预览模式不能查看现有系统配置？

预览模式的目标是安全演示，不读取或修改需要 root 权限的正式配置。需要检查现有服务时，请使用 root 启动正常模式，然后选择对应的状态或查看选项。

### 为什么配置 SSH 后暂时保留原来的会话？

修改端口或认证方式后，现有 SSH 会话通常不会立即断开。保留它是为了在新连接验证失败时进行恢复。

### 为什么 YAML 管理不修改 DNS 和规则？

节点、分组、DNS 和路由规则属于不同配置层。此功能只管理节点与分组，避免导入节点时意外破坏已经验证过的 DNS 和规则。

### Komari 选项是否完全不再访问 GitHub？

不一定。检测到并确认使用本地 Agent 时，不会访问 GitHub Release；IPv6-only 环境缺少本地 Agent 时只显示手动下载和上传提示，不会继续自动下载。其他环境找不到本地文件或用户拒绝使用时，仍会从 [Komari 官方仓库](https://github.com/komari-monitor/komari-agent)获取官方安装器。

## 安全提醒

- 不要把密码、Token、私钥或完整代理链接提交到 Git
- 不要在未开放新端口前关闭 SSH 22 端口
- 不要在新 SSH 连接验证成功前退出旧会话
- Xray 和 YAML 写入前认真检查预览内容
- 建议先在测试机运行，再批量部署到正式 VPS

## 文件说明

```text
vps-manager.sh                 VPS 初始化与管理主脚本
windows-ssh-key.ps1            Windows SSH 公钥和私钥生成脚本
apply-kaisa-komari-theme.py    可选的 Komari 看板主题脚本
README.md                      中文使用说明
```
