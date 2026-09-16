# 排错手册

## 案例一：客户端一直「未就绪，请检查网络连接」

这是自建 RustDesk 最常见、也最误导人的故障。

### 症状

- 客户端主界面状态为「未就绪」，提示「请检查网络连接」
- 客户端日志（`%APPDATA%\RustDesk\log\rustdesk_rCURRENT.log`）每 4 秒重复：

```
INFO [src\rendezvous_mediator.rs:802] register_pk of <服务器IP>:21116 due to key not confirmed
```

- 服务端数据库（`db_v2.sqlite3`）里**没有任何 peer 记录**，说明从未成功注册

### 极具迷惑性的假信号

排查时下面这些都会让你误判为"网络没问题"：

| 检查 | 结果 | 为什么不可信 |
|---|---|---|
| 外部 TCP 端口扫描 21116 | OPEN | 注册不走 TCP |
| `rustdesk-utils doctor` | `TCP Port 21116: OK` | 该工具只测 TCP |
| 服务端日志 | 有 TCP 连接记录 | 连接建立了，但注册请求在 TCP 上被拒绝 |
| 客户端 NAT 测试 | `Tested nat type: ASYMMETRIC` | NAT 测试能通，不代表注册能通 |

### 定位方法

**第一步：看客户端日志有没有 `key not confirmed` 循环**

```powershell
$log = "$env:APPDATA\RustDesk\log\rustdesk_rCURRENT.log"
Select-String -Path $log -Pattern 'key not confirmed' | Measure-Object | Select-Object Count
```

次数持续增长 = 注册失败。注意要在客户端运行 20 秒以上再看，
并且要看**最新**的 CURRENT 日志（客户端每次启动会滚动日志）。

**第二步：区分"没到服务器"和"到了但被拒"**

```powershell
# 服务端数据库里有没有这个客户端的 ID
$db = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'
Select-String -Path "$db\db_v2.sqlite3*" -Pattern '<客户端ID>' -Encoding Latin1
```

- 有记录 → 注册成功过
- 无记录 → 从未成功注册

**第三步：确认 UDP 是否被拦**

用内网 IP 做对照实验（完全绕开安全组和公网 NAT）：

1. 把客户端配置里的服务器地址改成**内网 IP**（如 `192.168.1.10`）
2. 重启客户端，观察 `key not confirmed` 是否停止

| 内网 IP | 公网 IP | 结论 |
|---|---|---|
| 正常 | 失败 | **UDP 公网入站被拦**（安全组漏了 UDP 规则），或者云 NAT 不支持 UDP hairpin |
| 正常 | 正常 | 网络没问题，去查 Key 是否填错 |
| 失败 | 失败 | 服务端没跑，或 Key 配置错误 |

### 根因

`rustdesk-server` 的注册请求**只支持 UDP**：

```rust
// rendezvous_server.rs —— UDP 路径：正常处理
Some(rendezvous_message::Union::RegisterPk(rk)) => {
    if rk.uuid.is_empty() || rk.pk.is_empty() {
        return Ok(());          // 注意：空 uuid/pk 会静默丢弃，不返回任何响应
    }
    ...
    msg_out.set_register_pk_response(RegisterPkResponse {
        result: register_pk_response::Result::OK.into(),
        ...
    });
    socket.send(&msg_out, addr).await?
}

// rendezvous_server.rs —— TCP 路径：不支持
Some(rendezvous_message::Union::RegisterPk(_)) => {
    let res = register_pk_response::Result::NOT_SUPPORT;
    ...                                  // 返回 NOT_SUPPORT
}
...
false                                    // 函数返回 false，外层立即 break 断开连接
```

外层调用处：

```rust
while let Ok(Some(Ok(bytes))) = timeout(30_000, b.next()).await {
    if !self.handle_tcp(&bytes, &mut sink, addr, key, ws).await {
        break;                           // ← 连接在这里被断开
    }
}
```

所以客户端在 TCP 上发注册请求时：收到 `NOT_SUPPORT` → 连接被断 → 4 秒后重试 →
永远拿不到 `OK` → `key_confirmed` 永远是 `false` → 界面永远「未就绪」。

服务端行为在 `master` 分支上一致，不是某个版本的偶发 bug。

### 修复

在云安全组里放行 **UDP 21116 入站**（`0.0.0.0/0`）。详见 [ports.md](ports.md)。

### 验证是否修复

客户端确认密钥成功后，会把结果**持久化**写入 `RustDesk.toml`：

```powershell
Get-Content "$env:APPDATA\RustDesk\config\RustDesk.toml" | Select-String -Pattern 'keys_confirmed' -Context 0,5
```

修复前：

```toml
[keys_confirmed]
rs-ny = true                       # 只确认过官方公共服务器
```

修复后（新增了你自己服务器的条目）：

```toml
[keys_confirmed]
rs-ny = true
"<你的服务器IP>:21116" = true        # ← 出现了这一行就是成功了
```

这是最可靠的验证方式：它证明客户端**真实收到了** `RegisterPkResponse{OK}`。
同时服务端数据库里也会出现该客户端的 ID。

---

## 案例二：`Handshake failed: invalid public key from rendezvous server`

**原因**：客户端填的 Key 与服务端的公钥不匹配。

服务端公钥在**服务工作目录**下的 `id_ed25519.pub`，也可以在服务日志里看到：

```
INFO [src\rendezvous_server.rs:1243] Key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
```

**注意**：这个值要**原样整串复制**，包含结尾的 `=`。
少一个字符就会报上面这个错，而且错误信息不会提示"你填错了"。

---

## 案例三：客户端能注册但被拒绝

`RegisterPkResponse` 的其它返回值：

| 返回值 | 含义 | 处理 |
|---|---|---|
| `UUID_MISMATCH` | 该 ID 已被另一个设备占用 | 客户端会自动重新生成 ID 并重试；频繁出现说明 ID 冲突 |
| `ID_EXISTS` | ID 已存在且公钥不同 | 删除服务端数据库里对应记录，或让客户端换 ID |
| `TOO_FREQUENT` | 注册太频繁被限流 | 正常情况不会出现；出现说明客户端在疯狂重试 |
| `NOT_SUPPORT` | 该传输方式不支持注册 | 见案例一，说明走了 TCP |
| `NOT_DEPLOYED` | Pro 版专用：设备未在控制台登记 | 需要 `rustdesk --deploy --token <api_token>` |

客户端对 `TOO_FREQUENT` 等未显式处理的返回值会打日志：

```
ERROR unknown RegisterPkResponse
```

如果日志里出现这一行，说明服务端**回包了但返回值不是 OK**，
此时应重点查服务端（ID 冲突 / 限流），而不是查网络。

---

## 案例四：连接建立后很快断开

服务端 debug 日志里：

```
DEBUG [src\rendezvous_server.rs:1135] Tcp connection from [::ffff:x.x.x.x]:port, ws: false
DEBUG [src\rendezvous_server.rs:1191] Tcp connection from [::ffff:x.x.x.x]:port closed
```

两条日志间隔只有**零点几毫秒**，说明连接刚建立就被关掉了。可能原因：

1. 这是客户端的 NAT 测试 / HTTP 代理探测连接，**属正常现象**（开完就关）
2. 这条连接发的是 `RegisterPk`，被 `handle_tcp` 拒绝后 `return false` 断连（见案例一）

如果连接**保持打开**（只有 opened 没有 closed），说明传输通道是好的，
问题在应用层 —— 优先怀疑 Key 和注册通道。

---

## 排查用到的命令速查

```powershell
# 服务是否在跑
Get-Service rustdesk-hbbs, rustdesk-hbbr | Select-Object Name, Status, StartType

# 端口是否在监听
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 21115..21119 }
Get-NetUDPEndpoint -LocalPort 21116

# 服务端日志（安装脚本会把日志放在 <安装目录>\logs）
Get-Content .\logs\hbbs-svc.out.log -Tail 30
Get-Content .\logs\hbbs-svc.err.log -Tail 30

# 开启 debug 级别日志（在服务配置 xml 里加 <env name="RUST_LOG" value="debug"/> 后重启服务）
# 会打印每一个 TCP 连接，用于判断"连上了但没注册成功"

# 客户端 ID
& 'C:\Program Files\RustDesk\RustDesk.exe' --get-id

# 客户端日志
Get-Content "$env:APPDATA\RustDesk\log\rustdesk_rCURRENT.log" -Tail 50
```
