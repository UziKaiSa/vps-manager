# VPS Manager

面向 Debian/Ubuntu VPS 的交互式初始化与配置脚本。目前包含：

- 安装基础工具，可选开启 BBR
- SSH 密钥登录加固与高位端口配置
- Xray 安装、首次配置、预览和增量更新
- 输出可粘贴到 Clash/Mihomo YAML 的节点内容
- YAML 节点导入、重命名、分组和校验
- SSH 客户端密钥命令助手
- 安装及管理 Komari Agent
- 内置 Cloudflare WARP 私网接入流程

## 使用

```bash
curl -fLO https://raw.githubusercontent.com/UziKaiSa/vps-manager/main/vps-manager.sh
chmod +x vps-manager.sh
sudo ./vps-manager.sh
```

预览模式不会修改系统：

```bash
bash vps-manager.sh --demo
```

当前仅支持使用 systemd 的 Debian/Ubuntu。

## 主菜单

```text
1) 初始化环境
2) Xray 管理
3) SSH 客户端密钥助手
4) YAML 管理
5) 安装/管理 Komari Agent
6) 状态检查
0) 退出
```

## Komari 与 WARP

原 `install-komari-warp-agent.sh` 的流程已经并入 `vps-manager.sh`。在“安装/管理 Komari Agent”中可以：

1. 配置或修复 WARP 私网，并继续安装/重装 Agent
2. 安装/重装普通公网 Agent
3. 查看 Agent 与 WARP 状态
4. 重连 WARP

主脚本不会再下载并执行本仓库里的 Komari/WARP 包装脚本。安装 Agent 时仍会获取并校验 [Komari 官方安装器](https://github.com/komari-monitor/komari-agent)。

Cloudflare Access Service Token 的读取顺序：

1. `CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET` 环境变量
2. `/root/warp-token.env`
3. 交互式安全输入

不要把任何 Token、密码或私钥提交到 Git。

当前默认 WARP 参数：

```text
Team: uzikaisa
Komari 私网地址: http://komari.example.internal:8080
service_mode: warp
MDM: /var/lib/cloudflare-warp/mdm.xml
```

如果机器缺少 `nf_tables`，脚本会提示是否安装新内核，但不会自动重启。

## Komari 看板主题

仓库继续保留 `apply-kaisa-komari-theme.py`：

```bash
python3 apply-kaisa-komari-theme.py --db ./data/komari.db
```

主题脚本默认先备份数据库。可通过 `--backup-dir` 指定备份目录，或在明确不需要备份时使用 `--no-backup`。

## 安全边界

- Xray 和 YAML 更新会先生成候选内容并要求确认。
- YAML 管理只重写 `proxies` 与 `proxy-groups`。
- SSH 加固会保留回滚路径，并要求使用第二个终端验证。
- WARP MDM 中的 Service Token 不会在预览或状态输出中显示。
- 系统配置写入前会尽量创建备份。
