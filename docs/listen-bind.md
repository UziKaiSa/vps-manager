# 真实监听管理（已验证实现）

入口：VPS 管理脚本 → 防火墙管理 → **8) 真实监听回环**。也可运行 `vps-listen-bind show`、`vps-listen-bind menu`。

本功能修改服务实际监听配置，不添加 nftables/iptables 规则，不安装额外防火墙服务。扫描不会自动修改业务。原防火墙继续独立工作。

## 查询、用途与修改

查询列出协议、端口、进程/容器、实际监听地址、期望用途和事务状态。全网监听如实显示“存在非回环监听”；私网绑定也不会冒充“已回环”。

用途可以组合：

- `local`：仅本机。
- `gateway`：经过本机反向代理或 Tunnel 的域名访问；后端可以回环。
- `peers`：其他机器需要连接；保持当前监听，原防火墙负责限制来源。
- `public`：公网客户端需要直连；保持当前监听，不会修改原防火墙放行规则，也不会自动将已有回环扩大为全网监听。
- `keep`：保持当前映射。

只有 local/gateway 组合会将通配绑定改成 127.0.0.1。显式的私网/特定地址绑定保持，避免切断远端网关和内部通道。SSH 端口拒绝自动回环。域名仅解析到服务器 IP 并不属于“本机网关”；这种场景需要 peers/public。

可通过 `--choices /root/choices.json` 按 `tcp/端口`、`udp/端口` 分别选择用途；未选择的映射保持原样。交互菜单可对一个容器的端口统一选择用途，再预览。

```sh
vps-listen-bind plan CONTAINER --intents local,gateway
vps-listen-bind apply CONTAINER --intents local,gateway --confirm-recreate --health-url http://127.0.0.1:PORT/
vps-listen-bind rollback TRANSACTION_ID
```

应用前预览具体映射、配置文件、当前镜像和重建范围。只有输入 RECREATE 或明确指定 `--confirm-recreate` 才执行。只重建选中服务，不拉取、不构建镜像，不重启依赖。

## 持久化与恢复

直接修改原 Compose 文件中所选服务的 ports 块，其余文本保持。不会依赖遗漏后即失效的额外 override。若 Compose 文件与当前容器指纹不同、镜像标签发生漂移、存在不支持的 YAML 继承或多文件组合，停止并报告。

执行时验证最终 Compose 模型除端口外完全相同，重建后验证镜像、环境、命令、用户、挂载和其余 HostConfig 不变。可以指定本机 HTTP 健康检查，失败则恢复原文件，并在已重建时按旧配置恢复服务。

原文件及结果保存在 `/etc/vps-manager/listen-bind/transactions/事务编号`，root-only。这是管理功能所需的恢复数据，不属于待清理的临时备份。恢复时检查文件哈希和当前容器，检测到后续修改则拒绝覆盖。

## 当前适配范围

已支持：单一普通 Compose 文件、bridge 网络、已存在且与运行镜像相同的镜像标签。可以保留原 build 声明，但执行永远带 `--no-build --pull never`。另外已验证下述 Nginx 和原生 systemd 服务适配。

普通 docker run、多文件 Compose、host 网络、YAML 继承暂不自动改写。不能据 已有适配结果声称支持所有第三方部署方式。

## 原生 systemd 服务（子菜单 4）

```sh
vps-listen-bind native-plan happyclaw.service --ports 3000
vps-listen-bind native-apply happyclaw.service --ports 3000 --confirm-restart --health-url http://127.0.0.1:3000/api/health
```

对缺少监听配置项的服务，使用其独立 cgroup 的 bind4/bind6 适配。程序在创建指定 TCP 端口的通配 socket 时，内核将其地址改成实际回环地址；并非监听公网后拦截数据包。所有 bind 调用均允许，不增加包过滤器，不修改 nft/iptables，也不向应用注入代码。

只改明确选择的 TCP 端口；显式私网绑定、其他端口和常规未绑定这些源端口的出站请求不变。IPv6 双栈通配 socket 改为 IPv4-mapped loopback `::ffff:127.0.0.1`，因此保留 127.0.0.1 调用；不额外提供 ::1 服务入口。HappyClaw 的既有反向代理使用 127.0.0.1，已实测正常。IPv6-only 应用需另行适配，失败时恢复配置，不能当作通用双栈方案。

需要 systemd 持久化 unit、cgroup v2、支持 bind hook 的 Linux 内核及 root 权限。修改前核对端口归属、SSH 保护、已有 bind 程序所有权和 BPF verifier。对 Linux 6.1 等旧 verifier 的可识别上下文写入限制，使用语义相同的寄存器存储指令；不会放宽权限检查或端口范围。内核不支持则拒绝，不改用另一套防火墙。

安装到该服务自己的 `70-vps-listen-bind.conf`，仅增加 ExecStartPre，不改原 unit 的 ExecStart、用户、环境或应用文件。开机/重启由该步骤自动附加适配；加载失败会阻止服务以通配监听启动。相同程序重复启动可复用；外部程序不会被覆盖。恢复时先停服务、只卸载指令标签匹配的本工具程序，再恢复文件并启动，实测查询实际监听后才标记成功。没有全局驻留代理、独立防火墙服务或 pinned BPF 文件。

## Nginx 配置（子菜单 5）

```sh
vps-listen-bind nginx-plan --keep-address <private-IP>
vps-listen-bind nginx-apply --keep-address <private-IP> --confirm-reload
```

仅收窄标准 80/443 通配 listen，改为 127.0.0.1、::1 和明确保留的已分配内网地址；server_name、proxy_pass、证书和其他配置保持。先执行 nginx -t，再短暂重启以释放旧通配监听。CLI 的 `--confirm-reload` 是显式操作确认参数，实际采用 restart；交互菜单明确提示重启。平滑 reload 曾在 隔离测试中无法完成地址切换，已通过恢复测试，不再把 reload 返回成功当作收窄成功。

通过已应用事务保存的原始模板，可查询和修改保留内网地址；配置发生外部变更时拒绝覆盖。重复应用相同地址为 no-op，不重启。明确保留的私网地址不会自动移除。

未来项目更新若替换 Compose 文件，仍可能恢复旧映射；请用查询复核实际地址。工具不会宣称永久覆盖所有软件。

部署只作用于当前机器，不自动向其他节点推广，也不升级业务版本。
