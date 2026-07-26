# VPS Manager

`VPS Manager` 是一个面向 Debian/Ubuntu VPS 的中文交互式管理脚本，用于完成服务器初始化、SSH 加固、Xray 配置、Clash/Mihomo YAML 管理，以及 Komari Agent/WARP 私网接入。

当前版本：`0.7.2-test`

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
- 输出可直接放进 Clash/Mihomo YAML 的节点内容
- 查看、导入、重命名和重新分组 YAML 节点
- 提供独立的 Windows SSH 公钥和私钥生成脚本
- 在 Linux 主脚本中提供 SSH 公钥校验、写入和加固管理
- 安装或管理 Komari Agent
- 使用内置流程配置 Cloudflare WARP 私网
- 查看系统、BBR、Xray、Komari 和 WARP 状态

## 支持环境

- Debian 或 Ubuntu
- 使用 `systemd`
- 使用 root 运行，或者当前用户可以执行 `sudo`
- 服务器能够访问所需的软件源

暂不支持 CentOS、AlmaLinux、Rocky Linux、OpenWrt 等系统。

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

Windows 不需要执行 `chmod +x`。上面的 `-ExecutionPolicy Bypass` 只对这一次 PowerShell 进程生效，用于执行刚下载的脚本，不会永久修改系统执行策略。

默认生成位置：

```text
私钥：%USERPROFILE%\.ssh\vps-manager-ed25519
公钥：%USERPROFILE%\.ssh\vps-manager-ed25519.pub
```

也可以指定密钥文件名和备注：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\windows-ssh-key.ps1" `
  -KeyName "my-vps-ed25519" `
  -Comment "my-vps"
```

脚本只负责生成密钥文件并显示公钥内容，不连接 VPS、不写入 `authorized_keys`，也不修改 Windows 或服务器的 SSH 配置。已有同名密钥时会停止，不会覆盖。

> `vps-manager.sh` 仍然需要在 Debian/Ubuntu VPS 中运行，不能直接在原生 Windows PowerShell 中执行。

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

## 3. SSH 密钥与加固管理

子菜单：

```text
1) Linux/macOS 生成并读取公钥
2) 校验 SSH 公钥并显示指纹
3) 添加公钥到当前管理用户 authorized_keys
4) 配置 SSH 高位端口和仅密钥登录
5) 查看当前管理用户 authorized_keys
0) 返回
```

当前管理用户自动使用运行脚本的登录用户，不需要另外填写用户名。

“添加公钥”只校验并写入 `~/.ssh/authorized_keys`，会避免重复添加相同密钥；它不会修改 SSH 端口，也不会关闭密码登录。已有文件在变更前会保存到 `/var/backups/vps-manager/`。

脚本只会显示客户端生成密钥的命令、读取你粘贴的公钥，不会在 VPS 上生成、保存或显示客户端私钥。

### SSH 加固注意事项

完整加固流程会要求：

- 输入 `10000-65535` 范围内的新 SSH 端口
- 粘贴一整行 SSH 公钥
- 确认云厂商安全组已经放行新端口
- 关闭密码登录并仅允许密钥认证

脚本会校验 SSH 配置、重新加载服务，并要求使用第二个终端验证新端口。验证失败时会尝试恢复原配置。

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

默认值：

```text
Cloudflare Zero Trust Team: your-team-name
Komari 私网地址: http://komari.example.internal:8080
WARP MDM: /var/lib/cloudflare-warp/mdm.xml
service_mode: warp
```

Cloudflare Access Service Token 的读取顺序：

1. 环境变量 `CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET`
2. `/root/warp-token.env`
3. 交互式隐藏输入

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

如果缺少 `nf_tables` 内核支持，脚本会询问是否安装新内核，但不会自动重启服务器。

### 普通公网模式

如果 Komari 面板可以通过公网直接访问，可以选择普通公网模式，输入：

- Komari 面板地址
- Komari Client Token
- Agent 安装目录
- 流量统计重置日
- 是否禁用 Web SSH
- 是否启用 GPU 监控
- 是否记录公网 IPv4

安装 Agent 本体时仍会下载并校验 Komari 官方安装器，而不是使用本仓库旧的包装脚本。

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

不是。主脚本不再下载本仓库旧的 Komari/WARP 包装脚本，但安装 Komari Agent 本体仍会从 [Komari 官方仓库](https://github.com/komari-monitor/komari-agent)获取官方安装器。

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
