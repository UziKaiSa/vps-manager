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

脚本会先配置 WARP，验证私网访问，然后询问是否继续安装 Komari Agent。

如果因为私有仓库权限导致 raw 链接无法下载，可以改用 GitHub SSH 克隆：

```bash
git clone git@github.com:UziKaiSa/komari-warp-scripts.git
cd komari-warp-scripts
sudo ./install-komari-warp-agent.sh
```

如果你已经在机器上放好了脚本，也可以直接运行：

```bash
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
Komari Agent 安装目录 [/home/ubuntu/repos/komari/komari-agent]:
流量统计重置日 [11]:
是否禁用 Web SSH [Y/n]:
是否启用 GPU 监控 [Y/n]:
是否自动探测公网 IPv4 并写入 --custom-ipv4 [Y/n]:
```

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

如果只想配置 WARP，不想出现 Komari Agent 安装询问：

```bash
sudo ./install-komari-warp-agent.sh --skip-agent
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

## 资源占用说明

在测试用的小规格 `hk` Debian 机器上：

- 总内存约 `335MiB`
- `warp-svc` 连接后 RSS 约 `100MiB`
- 连接后 Swap 使用量为 `0B`

这个占用可以接受，但 WARP 对小机器不算轻。新机器接入后建议观察内存和 Swap。
