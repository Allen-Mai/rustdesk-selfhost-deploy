# 端口清单与安全组配置

## 完整端口表

| 端口 | 协议 | 谁在监听 | 用途 | 是否必须 |
|---|---|---|---|---|
| 21114 | TCP | hbbs (Pro) | Pro 版网页控制台 / API | 开源版不需要 |
| 21115 | TCP | hbbs | NAT 类型测试 | 建议放行 |
| **21116** | **TCP** | hbbs | ID 注册 / 心跳（TCP 通道） | **必须** |
| **21116** | **UDP** | hbbs | **ID 注册（实际注册走的通道）** | **必须，最常见漏项** |
| **21117** | TCP | hbbr | 中继转发（P2P 打洞失败时用） | **必须** |
| 21118 | TCP | hbbs | 网页客户端 WebSocket | 可选 |
| 21119 | TCP | hbbr | 网页客户端 WebSocket | 可选 |

如果只用开源版、不需要网页客户端，**最少需要**：

```
TCP 21115-21117
UDP 21116
```

## 为什么 UDP 21116 不能省

客户端的注册（`RegisterPk`）走 UDP。服务端两种传输路径的代码行为不同：

```
handle_udp()  ->  RegisterPk: 正常处理，返回 OK
handle_tcp()  ->  RegisterPk: 返回 NOT_SUPPORT，然后 return false 直接断开连接
```

只放行 TCP 时：
- 端口扫描 / telnet / `doctor` 都显示"通"
- 客户端却永远处于「未就绪」，日志每 4 秒刷一次
  `register_pk ... due to key not confirmed`

详见 [troubleshooting.md](troubleshooting.md)。

## 各云平台安全组配置

### 腾讯云（CVM）

控制台 → 云服务器 → 实例 → 安全组 → 入站规则 → 添加规则

需要加**两条**：

| 类型 | 来源 | 协议端口 | 策略 |
|---|---|---|---|
| 自定义 | 0.0.0.0/0 | **TCP:21115-21117** | 允许 |
| 自定义 | 0.0.0.0/0 | **UDP:21116** | 允许 |

### 阿里云（ECS）

控制台 → 实例 → 安全组 → 配置规则 → 入方向 → 手动添加，
同样需要 TCP 和 UDP 各一条。

### AWS（EC2）

安全组 → 入站规则 → 编辑入站规则：

| 类型 | 协议 | 端口范围 | 源 |
|---|---|---|---|
| 自定义 TCP | TCP | 21115-21117 | 0.0.0.0/0 |
| 自定义 UDP | UDP | 21116 | 0.0.0.0/0 |

### 华为云 / 其它

同理，找到「安全组 / 防火墙 / 网络 ACL」，TCP 与 UDP 分别放行。

## 机器自带防火墙

Windows 防火墙是**另一层**，和云安全组互不替代。本仓库的安装脚本会自动添加放行规则：

```powershell
New-NetFirewallRule -DisplayName 'RustDesk Server (TCP 21115-21119)' `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 21115-21119
New-NetFirewallRule -DisplayName 'RustDesk Server (UDP 21116)' `
  -Direction Inbound -Action Allow -Protocol UDP -LocalPort 21116
```

检查当前状态：

```powershell
Get-NetFirewallProfile | Select-Object Name, Enabled      # 防火墙是否开启
Get-NetFirewallRule -DisplayName 'RustDesk Server*'       # 规则是否存在
```

## 如何验证端口真的通了

### 本机监听检查

```powershell
Get-NetTCPConnection -State Listen |
  Where-Object { $_.LocalPort -in 21115,21116,21117,21118,21119 } |
  Select-Object LocalAddress, LocalPort

Get-NetUDPEndpoint -LocalPort 21116 | Select-Object LocalAddress, LocalPort
```

> 注意：本机监听正常 **不代表**外网能连上，安全组仍然可能拦着。

### 服务端自带诊断

```powershell
.\rustdesk-utils.exe doctor <你的公网IP>
```

输出示例：

```
TCP Port 21114 (API): ERROR                 <- 开源版正常，Pro 才有
TCP Port 21115 (hbbs extra port for nat test): OK in 3 ms
TCP Port 21116 (hbbs): OK in 3 ms
TCP Port 21117 (hbbr tcp): OK in 3 ms
TCP Port 21118 (hbbs websocket): OK in 3 ms
TCP Port 21119 (hbbr websocket): OK in 3 ms
```

⚠️ 这个工具**只测 TCP**。它全绿也不代表能用，UDP 必须单独确认。

### 从外网检测（推荐）

用 `tools/verify-ports.ps1`，它通过 check-host.net 的多国节点从外部真实探测：

```powershell
.\tools\verify-ports.ps1 -Server <你的公网IP>
```

建议同时用一个「已知能通」的端口（如 3389）做对照测试：
如果对照端口通、目标端口不通，才能确定是安全组的问题，而不是检测节点被墙。

> **UDP 无法用这类工具检测。** 在线端口检测服务基本都是 TCP。
> 判断 UDP 是否放行的唯一可靠方法：让一个外网客户端实际注册一次，
> 看它是否从「未就绪」变成「就绪」（见 troubleshooting.md 的验证方法）。
