# 在 Windows 上把 hbbs / hbbr 做成系统服务

## 为什么不能直接用 `sc create`

`hbbs.exe` / `hbbr.exe` 是**控制台程序**，不是 Windows 服务程序。
用 `sc.exe create` 直接注册会失败：

```
错误 1053: 服务没有及时响应启动或控制请求。
```

因为服务控制管理器（SCM）启动进程后，会等待它在 30 秒内通过
`SERVICE_RUNNING` 上报状态，而控制台程序根本不会做这件事，于是被判定为启动失败。

## 解决方案：WinSW

[WinSW](https://github.com/winsw/winsw)（Windows Service Wrapper）是一个极小的
服务包装器：它自己实现服务控制协议，然后把真正的程序作为子进程拉起，
并转发日志、处理重启和停止。

本仓库的安装脚本会自动下载 WinSW，并按下面的方式布置：

```
<安装目录>\
├─ hbbs.exe                 官方二进制
├─ hbbr.exe                 官方二进制
├─ rustdesk-utils.exe       官方工具（doctor / genkeypair）
├─ id_ed25519               私钥（首次启动自动生成）
├─ id_ed25519.pub           公钥 ← 客户端要填的 Key
├─ logs\                    服务日志
└─ service\
   ├─ hbbs-svc.exe          WinSW 副本
   ├─ hbbs-svc.xml          hbbs 服务配置
   ├─ hbbr-svc.exe          WinSW 副本
   └─ hbbr-svc.xml          hbbr 服务配置
```

> WinSW 通过**自身文件名**找同名 xml 配置（`hbbs-svc.exe` → `hbbs-svc.xml`），
> 所以每个服务各需要一份 WinSW 副本。

## 服务配置说明

`hbbs-svc.xml` 关键项：

```xml
<executable>...\hbbs.exe</executable>
<arguments>-r <中继地址> -k _</arguments>
<workingdirectory>...</workingdirectory>     <!-- 密钥文件生成在这里 -->
<logpath>...\logs</logpath>
<log mode="roll-by-size">
  <sizeThreshold>10240</sizeThreshold>       <!-- 单文件 10MB 后滚动 -->
  <keepFiles>8</keepFiles>
</log>
<onfailure action="restart" delay="10 sec"/> <!-- 崩溃自动重启 -->
<startmode>Automatic</startmode>             <!-- 开机自启 -->
```

`hbbr-svc.xml` 的区别是不需要 `-r`：

```xml
<arguments>-k _</arguments>
```

### 参数含义

| 参数 | 说明 |
|---|---|
| `-r <地址>` | **告诉客户端中继服务器是谁**。填公网 IP 或域名，端口默认 21117。hbbs 会把客户端的中继地址指向这里 |
| `-k _` | 使用工作目录下 `id_ed25519` 里的密钥。<br>`_` 是特殊值，表示"用文件里的密钥"，不是字面上的下划线。<br>启用后，客户端**必须**填对应的公钥才能注册 |
| `-p <端口>` | 修改监听端口，一般不需要 |

> `-r` 忘填的后果：客户端能注册上线，但**建立连接时找不到中继**，
> 打洞失败就彻底连不上。单机部署时 `-r` 填本机公网 IP。

### 密钥说明

首次启动 hbbs 时会在工作目录生成密钥对：

```
INFO [src\common.rs:147] Private/public key written to id_ed25519/id_ed25519.pub
INFO [src\rendezvous_server.rs:1243] Key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
```

- `id_ed25519` —— **私钥，绝对不要外传、不要提交到 git**
- `id_ed25519.pub` —— 公钥，就是客户端"Key"字段要填的内容
- hbbr 会读取同一个 `id_ed25519`，所以两个服务必须用同一个工作目录

`.gitignore` 里已经排除了这两个文件。

## 服务管理

```powershell
Get-Service rustdesk-hbbs, rustdesk-hbbr        # 查看状态
Restart-Service rustdesk-hbbs                   # 重启
Stop-Service rustdesk-hbbr                      # 停止

# 用 WinSW 直接操作（等价）
.\service\hbbs-svc.exe restart
.\service\hbbs-svc.exe status
```

查看服务恢复策略是否生效：

```powershell
sc.exe qfailure rustdesk-hbbs
# 应显示: FAILURE_ACTIONS : RESTART -- Delay = 10000 milliseconds.
```

## 开启详细日志

排查连接问题时，在 xml 的 `</service>` 前加一行，然后重启服务：

```xml
<env name="RUST_LOG" value="debug"/>
```

会额外打印每一个 TCP 连接：

```
DEBUG [src\rendezvous_server.rs:1135] Tcp connection from [::ffff:x.x.x.x]:port, ws: false
DEBUG [src\rendezvous_server.rs:1191] Tcp connection from [::ffff:x.x.x.x]:port closed
```

排查完记得去掉，否则日志增长很快。

## 卸载

```powershell
.\server\uninstall-service.ps1
```

或手工：

```powershell
.\service\hbbs-svc.exe uninstall
.\service\hbbr-svc.exe uninstall
```

> 卸载前先备份 `id_ed25519` 和 `db_v2.sqlite3`，
> 否则重装后所有客户端都要重新填 Key。

## 服务账户与数据位置

服务默认以 `LocalSystem` 启动，因此 hbbs 的数据库写在服务账户的配置目录里：

```
C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\db_v2.sqlite3
```

这个文件记录了所有注册过的客户端 ID。备份服务器时**必须把它一起带上**，
但注意它属于隐私数据，不要公开分享。
