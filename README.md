# Komari WARP Agent 部署脚本

这个仓库用于把无桌面的 Linux 探针机器接入 Cloudflare Zero Trust WARP，让 Komari Agent 通过私网域名上报，而不是访问公网 Cloudflare 域名。

## 当前网络设计

- Komari 服务端私网路由：`192.0.2.10/32`
- Komari 私网 DNS：`komari.example.internal -> 192.0.2.10`
- 远端探针使用的 Komari 地址：`http://komari.example.internal:8080`
- Komari 母机本机地址：`http://127.0.0.1:8080`
- Cloudflare Zero Trust 团队名：`uzikaisa`
- WARP 设备配置文件：`komari-agent-warp`
- Split Tunnel 模式：只 include `192.0.2.10/32`
- 本地域回退：`example.internal -> 192.0.2.10`
- 默认 Agent 安装目录：`目标普通用户 HOME/scripts/komari-agent`

## Cloudflare 前置配置

1. 通过 Cloudflare Tunnel 发布私网路由：

   ```bash
   cloudflared tunnel route ip add 192.0.2.10/32 example-tunnel
   ```

2. 创建 Cloudflare Access Service Token，用于无桌面服务器接入 WARP。

3. 在 Device enrollment 权限里允许这个 Service Token：

   ```text
   Action: Service Auth
   Include: Service Token = <komari WARP token>
   ```

4. 确认匹配的设备配置文件使用 Include 模式，并且只包含：

   ```text
   192.0.2.10/32
   ```

5. 确认 Local Domain Fallback / 本地域回退包含：

   ```text
   example.internal -> 192.0.2.10
   ```

## 一键使用命令

优先使用下面这段，复制到目标 Linux 机器上直接执行：

```bash
wget -O install-komari-warp-agent.sh https://raw.githubusercontent.com/UziKaiSa/komari-warp-scripts/main/install-komari-warp-agent.sh
chmod +x install-komari-warp-agent.sh
sudo ./install-komari-warp-agent.sh
```

如果当前已经是 `root`，并且系统没有 `sudo`，最后一行改成：

```bash
./install-komari-warp-agent.sh
```

脚本会先配置 WARP，验证私网访问，然后询问是否继续安装 Komari Agent。

如果因为私有仓库权限导致 raw 链接无法下载，可以改用 GitHub SSH 克隆：

```bash
git clone git@github.com:UziKaiSa/komari-warp-scripts.git
cd komari-warp-scripts
sudo ./install-komari-warp-agent.sh
```

## 凭证输入方式

脚本会按以下顺序读取 Cloudflare Service Token：

1. 当前环境变量：

   ```bash
   CF_ACCESS_CLIENT_ID
   CF_ACCESS_CLIENT_SECRET
   ```

2. 如果存在，则读取：

   ```text
   /root/warp-token.env
   ```

3. 如果前两者都没有，就在运行时交互输入：

   ```text
   请输入 Cloudflare Access Client ID:
   请输入 Cloudflare Access Client Secret（输入时不会显示）:
   ```

不要把任何密钥提交到 Git。

## 交互式安装流程

运行：

```bash
sudo ./install-komari-warp-agent.sh
```

WARP 私网验证完成后，脚本会询问：

```text
WARP 私网接入配置已完成。
请选择下一步：
  1) 继续安装/重装 Komari Agent
  2) 跳过 Komari Agent 安装
请输入选项 [2]:
```

选择 `1` 后，脚本会继续询问 Komari Client Token：

```text
请输入 Komari Client Token（输入时不会显示）:
```

后续默认值一般直接回车即可：

```text
Komari 连接地址 [http://komari.example.internal:8080]:
Komari Agent 安装目录 [目标普通用户 HOME/scripts/komari-agent]:
流量统计重置日 [11]:
是否禁用 Web SSH（直接回车默认：是） [Y/n]:
是否启用 GPU 监控（直接回车默认：是） [Y/n]:
是否自动探测公网 IPv4 并写入 --custom-ipv4（直接回车默认：是） [Y/n]:
```

默认安装目录会动态计算：

- 如果通过普通用户执行 `sudo ./install-komari-warp-agent.sh`，默认目录是：`该用户 HOME/scripts/komari-agent`
- 如果已经是 root 直接执行 `./install-komari-warp-agent.sh`，脚本会优先查找 `/home` 下的普通用户，并使用：`普通用户 HOME/scripts/komari-agent`
- 只有在机器上找不到普通用户时，才会兜底使用：`/root/scripts/komari-agent`

安装目录支持输入 `~/xxx`，脚本会自动展开成当前用户的绝对路径，例如 root 用户下会变成 `/root/xxx`。systemd 不支持 `~` 路径，所以不要把未展开的 `~/xxx` 直接写进服务文件。

脚本会自动探测机器的公网 IPv4，并写入 `--custom-ipv4`，这样 Komari 后台展示的 IP 和国家会按真实公网出口计算，而不是 WARP/内网 IP。

WARP 模式下不要再加：

```bash
--get-ip-addr-from-nic
```

否则 Komari 后台可能展示内网 IP，国家也会不准确。

## 非交互安装

如果要在非交互环境里同时配置 WARP 并安装 Komari Agent，可以提前导出变量：

```bash
export CF_ACCESS_CLIENT_ID='xxx.access'
export CF_ACCESS_CLIENT_SECRET='xxx'
export KOMARI_AGENT_TOKEN='komari-client-token'
sudo -E ./install-komari-warp-agent.sh --install-agent
```

如需覆盖默认安装目录，可以传环境变量：

```bash
export KOMARI_AGENT_INSTALL_DIR="$HOME/scripts/komari-agent"
sudo -E ./install-komari-warp-agent.sh --install-agent
```

如果只想配置 WARP，不想出现 Komari Agent 安装询问：

```bash
sudo ./install-komari-warp-agent.sh --skip-agent
```

## Komari 看板主题脚本

仓库里还包含一个可选脚本：

```text
apply-kaisa-komari-theme.py
```

这个脚本用于向 Komari SQLite 数据库写入 `configs.custom_head` 和 `configs.custom_body`，实现当前 KaiSa 看板样式：

- 静态背景图和暗色遮罩
- 主页面透明化
- 搜索框轻暗底
- 节点卡片 hover 的主题色渐变黑和毛玻璃效果
- 查看延迟浮层的主题色毛玻璃效果

脚本不会硬编码 Komari 数据库路径。运行时需要通过参数或环境变量传入 DB 路径：

```bash
python3 apply-kaisa-komari-theme.py --db ./data/komari.db
```

也可以使用环境变量：

```bash
export KOMARI_DB_PATH=./data/komari.db
python3 apply-kaisa-komari-theme.py
```

如果需要自定义备份目录：

```bash
python3 apply-kaisa-komari-theme.py \
  --db ./data/komari.db \
  --backup-dir ./data/theme-backups
```

默认会先备份数据库到：

```text
<db_dir>/theme-backups/<db_name>.before-kaisa-theme-<timestamp>
```

如果明确不需要备份，可以加：

```bash
python3 apply-kaisa-komari-theme.py --db ./data/komari.db --no-backup
```

如果要替换背景图：

```bash
KAISA_BG_IMAGE_URL='https://example.com/background.jpg' \
python3 apply-kaisa-komari-theme.py --db ./data/komari.db
```

## 内核兼容处理

如果机器内核缺少 `nf_tables` 支持，WARP 可能无法启动防火墙。可以只升级内核包：

```bash
sudo ./install-komari-warp-agent.sh --upgrade-kernel
sudo reboot
sudo ./install-komari-warp-agent.sh
```

如果你确认机器可以自动重启，也可以：

```bash
sudo ./install-komari-warp-agent.sh --upgrade-kernel --reboot-if-needed
```

## 验证命令

```bash
warp-cli --accept-tos status
dig komari.example.internal
curl -i http://komari.example.internal:8080
```

期望结果：

```text
Status update: Connected
Network: healthy
192.0.2.10
HTTP/1.1 200 OK
```

## 未来迁移母机时要做的事情

这里的“母机”指运行 Komari 服务端、Cloudflare Tunnel、私有 DNS 的机器。当前母机私网 IP 是 `192.0.2.10`，私网域名是 `komari.example.internal`。

迁移目标是：Agent 仍然使用同一个 endpoint，不需要逐台修改。

```text
http://komari.example.internal:8080
```

### 1. 在新母机上准备 Komari 服务端

先把 Komari 服务端迁移到新机器，并确认新机器本机能访问：

```bash
curl -i http://127.0.0.1:8080
```

期望能返回 Komari 页面或 `HTTP/1.1 200 OK`。如果 Komari 不是监听 `8080`，需要先统一服务端监听端口，或者同步修改后续所有验证命令。

### 2. 确认新母机私网 IP

在新母机上确认 Cloudflare Tunnel 能访问到的私网 IP，例如：

```bash
ip -4 addr
```

假设新母机私网 IP 是：

```text
NEW_PRIVATE_IP=172.31.x.x
```

后续命令里的 `NEW_PRIVATE_IP` 都替换成真实值。

### 3. 在新母机上部署私有 DNS

新母机需要继续解析：

```text
komari.example.internal -> NEW_PRIVATE_IP
```

如果继续使用 `dnsmasq`，可以参考：

```bash
sudo apt-get update
sudo apt-get install -y dnsmasq dnsutils

sudo tee /etc/dnsmasq.d/komari-internal.conf >/dev/null <<EOF
# Private DNS for Komari agents over Cloudflare WARP.
listen-address=NEW_PRIVATE_IP
bind-interfaces
address=/komari.example.internal/NEW_PRIVATE_IP
local=/example.internal/
domain-needed
bogus-priv
EOF

sudo dnsmasq --test
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq
```

验证：

```bash
dig +short @NEW_PRIVATE_IP komari.example.internal A
```

期望返回：

```text
NEW_PRIVATE_IP
```

### 4. 调整 Cloudflare Tunnel 私网路由

在 Cloudflare Zero Trust 的 CIDR Routes 里，把旧路由切换到新母机：

```text
旧：192.0.2.10/32 -> 旧 Tunnel
新：NEW_PRIVATE_IP/32 -> 新 Tunnel
```

如果新母机沿用同一个 Tunnel 名称，可以添加新 route 后再删除旧 route。命令示例：

```bash
cloudflared tunnel route ip add NEW_PRIVATE_IP/32 example-tunnel
```

确认新路由生效后，再删除旧的：

```bash
cloudflared tunnel route ip delete 192.0.2.10/32 example-tunnel
```

如果你是在 Cloudflare 控制台操作，就在：

```text
Zero Trust -> 网络 -> 路由 -> CIDR 路由
```

确认最终只有新母机的 `/32` 路由指向正确 Tunnel。

### 5. 调整 WARP 设备配置文件的 Split Tunnel

进入：

```text
Zero Trust -> 团队和资源 -> 设备 -> 设备配置文件 -> komari-agent-warp
```

确认拆分隧道仍是 Include 模式，并把旧 IP 替换为：

```text
NEW_PRIVATE_IP/32
```

如果仍保留旧的 `192.0.2.10/32`，Agent 可能继续把流量送到旧母机。

### 6. 调整 Local Domain Fallback

仍在 `komari-agent-warp` 设备配置文件里，找到：

```text
Local Domain Fallback / 本地域回退
```

把：

```text
example.internal -> 192.0.2.10
```

改成：

```text
example.internal -> NEW_PRIVATE_IP
```

这里不要改 Agent endpoint，Agent 仍然用：

```text
http://komari.example.internal:8080
```

### 7. 在一台已接入 WARP 的探针机器上验证

以 `hk` 这类探针机器为例，重连 WARP：

```bash
warp-cli --accept-tos disconnect
warp-cli --accept-tos connect
```

验证 DNS：

```bash
dig komari.example.internal
getent hosts komari.example.internal
```

期望解析到：

```text
NEW_PRIVATE_IP
```

验证 HTTP：

```bash
curl -i http://komari.example.internal:8080
```

期望返回 Komari 页面或 `HTTP/1.1 200 OK`。

### 8. 验证已有 Agent 是否自动恢复

因为 Agent endpoint 没变，正常情况下不需要逐台修改 Agent。只需要在探针机器上看服务状态：

```bash
systemctl status komari-agent --no-pager -l
journalctl -u komari-agent -n 80 --no-pager
```

期望看到类似：

```text
Basic info uploaded successfully
WebSocket connected using v2 protocol
```

### 9. 迁移完成后清理旧母机

确认所有探针都恢复后，再清理旧母机：

```text
1. 删除旧 Cloudflare Tunnel route：192.0.2.10/32
2. 停止旧母机上的 dnsmasq
3. 停止旧母机上的 Komari 服务
4. 下线旧服务器
```

不要在新链路验证完成前删除旧 route，否则 Agent 会短暂全部断连。

### 10. 回滚方式

如果新母机验证失败，回滚只需要反向恢复三处：

```text
1. CIDR Route 恢复：192.0.2.10/32 -> 旧 Tunnel
2. Split Tunnel include 恢复：192.0.2.10/32
3. Local Domain Fallback 恢复：example.internal -> 192.0.2.10
```

Agent 仍然使用 `http://komari.example.internal:8080`，所以回滚也不需要逐台修改 Agent。

## 资源占用说明

在测试用的小规格 `hk` Debian 机器上：

- 总内存约 `335MiB`
- `warp-svc` 连接后 RSS 约 `100MiB`
- 连接后 Swap 使用量为 `0B`

这个占用可以接受，但 WARP 对小机器不算轻。新机器接入后建议观察内存和 Swap。
