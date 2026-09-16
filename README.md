# RustDesk 自建服务器 —— Windows Server 部署与客户端分发

在 **Windows Server** 上部署 RustDesk 自建服务器（hbbs + hbbr），无需 Docker / WSL，
并生成一套可以直接发给别人的**预配置客户端**。

本仓库记录的是实测通过的完整流程，附带一个**很多人会踩、但官方文档没写清楚的坑**（见下）。

---

## ⚠️ 先看这个：最关键的一个坑

> **hbbs 只接受 UDP 上的客户端注册请求。安全组只放行 TCP 是没用的。**

这是实测 + 对照源码确认的结论：

| 传输方式 | 服务端函数 | RegisterPk 的处理 |
|---|---|---|
| **UDP** 21116 | `handle_udp()` | 正常处理，返回 `OK` ✅ |
| **TCP** 21116 | `handle_tcp()` | 返回 `NOT_SUPPORT`，且函数结尾 `return false` 会**立刻断开连接** ❌ |

**症状**：客户端一直显示

```
未就绪，请检查网络连接
```

客户端日志里每 4 秒重复一次，永不停止：

```
INFO [src\rendezvous_mediator.rs:802] register_pk of <你的服务器IP>:21116 due to key not confirmed
```

**注意这里的迷惑性**：TCP 端口用外部工具测是**通的**，`rustdesk-utils doctor` 也会显示
`TCP Port 21116 (hbbs): OK`，于是很容易误判为"网络没问题"。但注册走的是 UDP。

**结论：`21116/UDP` 必须放行，只开 TCP 一定失败。**

---

## 需要开放的端口

| 端口 | 协议 | 用途 | 是否必须 |
|---|---|---|---|
| 21114 | TCP | Pro 版网页控制台 / API | 开源版不需要 |
| 21115 | TCP | NAT 类型测试 | 建议开 |
| **21116** | **TCP** | ID 注册 / 心跳 | **必须** |
| **21116** | **UDP** | **ID 注册（关键！）** | **必须，最容易漏** |
| **21117** | TCP | 中继转发（Relay） | **必须** |
| 21118 | TCP | 网页客户端 WebSocket | 可选 |
| 21119 | TCP | 网页客户端 WebSocket | 可选 |

### 云安全组配置示例

需要添加 **2 条**入站规则（别只加 TCP 那条）：

```
规则 1:  协议 TCP   端口 21115-21117   来源 0.0.0.0/0
规则 2:  协议 UDP   端口 21116         来源 0.0.0.0/0     ← 漏了这条就用不了
```

腾讯云 / 阿里云 / AWS / 华为云 都需要在**控制台的安全组（防火墙）**里放行；
机器自带的 Windows 防火墙是另一层，别混淆。

> 为什么 UDP 容易漏：控制台添加规则时"协议"默认常是 TCP，
> 而 "TCP 21115-21117" 这种写法看起来已经覆盖了 21116，实际只覆盖 TCP。

---

## 快速开始

### 0. 环境要求

- Windows Server 2016+ / Windows 10+（64 位）
- 一台**有公网 IP** 的机器（客户端要能访问到）
- 管理员权限的 PowerShell
- 不需要 Docker、不需要 WSL、不需要编译环境

### 1. 下载并安装服务端

```powershell
# 以管理员身份运行 PowerShell
cd server
.\install-service.ps1 -RelayServer <你的公网IP或域名>
```

这个脚本会：

1. 下载官方 `rustdesk-server` Windows 版并解压
2. 下载 WinSW（把控制台程序包装成 Windows 服务的工具）
3. 生成 hbbs / hbbr 的服务配置
4. 注册并启动两个 Windows 服务（自动启动 + 崩溃自动重启）
5. 打印**公钥**（客户端要填的 Key）

完成后会输出类似：

```
服务已启动：
  rustdesk-hbbs   Running
  rustdesk-hbbr   Running

客户端需要填写：
  ID 服务器   : <你的公网IP>
  中继服务器  : <你的公网IP>
  Key(公钥)   : xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
```

### 2. 在云控制台放行端口

按上面「需要开放的端口」添加 **TCP 和 UDP 两条**规则。

### 3. 生成客户端包

```powershell
cd ..\client
.\make-package.ps1 -Server <你的公网IP> -Key <上一步的公钥>
```

产出 `RustDesk客户端/` 目录和一个同名 zip，可以直接发给别人。
对方解压后双击 `1-一键配置并启动.bat` 即可，**不需要手动填任何服务器地址**。

---

## 目录结构

```
.
├─ README.md                      本文件
├─ docs/
│  ├─ ports.md                    端口清单 + 各云厂商安全组说明
│  ├─ troubleshooting.md          排错手册（含"未就绪"完整定位过程）
│  └─ windows-service.md          为什么用 WinSW / 服务化细节
├─ server/
│  ├─ install-service.ps1         一键下载 + 服务化安装
│  ├─ uninstall-service.ps1       卸载服务
│  ├─ hbbs-svc.xml.template       hbbs 服务配置模板
│  └─ hbbr-svc.xml.template       hbbr 服务配置模板
├─ client/
│  ├─ set-server.ps1              客户端配置工具（弹窗 / 静默两种模式）
│  ├─ make-package.ps1            生成可分发客户端包
│  ├─ 1-一键配置并启动.bat
│  ├─ 2-修改服务器设置.bat
│  ├─ 服务器设置.ini.template      预设值（用记事本就能改）
│  └─ 使用说明.txt                 给最终用户看的说明
└─ tools/
   └─ verify-ports.ps1            从外网检测端口是否真的通
```

---

## 实测环境

本流程在以下环境验证通过（2026-09）：

| 项目 | 版本 / 配置 |
|---|---|
| 操作系统 | Windows Server 2022 Datacenter (Build 20348) |
| 机器 | 腾讯云 CVM，4 vCPU / 8 GB，公网 IP |
| 服务端 | rustdesk-server 1.1.16（`rustdesk-server-windows-x86_64-unsigned.zip`） |
| 客户端 | RustDesk 1.4.9（`rustdesk-1.4.9-x86_64.exe`） |
| 服务包装 | WinSW v2.12.0 |
| 服务内存占用 | hbbs ≈ 21 MB，hbbr ≈ 7 MB（非常轻量） |

---

## 两个额外提醒

1. **服务端二进制未做代码签名**，杀毒软件可能报毒，建议把安装目录加入白名单。
2. **`id_ed25519` 私钥和 `db_v2.sqlite3` 数据库**要一起备份：
   - 私钥丢了，所有已配置的客户端都要重新填 Key
   - 数据库里存着所有连过的客户端 ID，属于隐私数据，别外传

---

## 关于本仓库

- 本仓库**不包含**任何二进制文件，只提供脚本和文档，安装时从官方源自动下载。
- RustDesk 及其服务端版权归 [rustdesk](https://github.com/rustdesk/rustdesk) 所有，遵循其各自的开源协议。
- 本仓库提供的脚本以 MIT 协议开源，见 `LICENSE`。

## 参考

- rustdesk-server: https://github.com/rustdesk/rustdesk-server
- rustdesk 客户端: https://github.com/rustdesk/rustdesk
- 官方文档: https://rustdesk.com/docs/en/self-host/
