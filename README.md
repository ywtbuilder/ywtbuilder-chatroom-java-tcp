# ChatNova — 局域网多人聊天室

> 基于 Java TCP Socket 的局域网多人实时聊天系统，含 Swing GUI 界面与多线程并发处理。

![Java](https://img.shields.io/badge/Java-8+-orange?logo=openjdk)
![Swing](https://img.shields.io/badge/GUI-Swing-blue)
![Socket](https://img.shields.io/badge/Network-TCP%20Socket-green)

---

## Showcase

### 一句话价值

在桌面 GUI 场景下完整实现“服务端并发 + 客户端实时广播 + 线程安全 UI 更新”。

### 1分钟演示视频

- [demo.mp4](docs/showcase/lab_聊天室/demo.mp4)

### 3张关键截图

1. [shot-01.png（服务端监控）](docs/showcase/lab_聊天室/shot-01.png)
2. [shot-02.png（三客户端聊天）](docs/showcase/lab_聊天室/shot-02.png)
3. [shot-03.png（公告广播）](docs/showcase/lab_聊天室/shot-03.png)

### 一键运行命令

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/start-chatroom.ps1
```

### 核心技术决策

1. 每客户端独立线程，减少连接间互相影响。
2. 服务端统一广播路径，确保消息传播一致性。
3. Swing UI 更新固定在 EDT 线程执行。

### 性能/稳定性证据

- 证据页：[evidence.md](docs/showcase/lab_聊天室/evidence.md)
- 建议展示指标：广播到达率、并发连接稳定性、异常断连恢复时间。

### 面试可提问点

1. 为什么此项目选择多线程阻塞 IO 而非 NIO？
2. 如何避免慢连接拖慢全局广播？
3. 如何从课程项目演进到生产级 IM 架构？

---

## 功能特性

- **多客户端并发**：服务端同时监听三个端口（6666 / 6667 / 6668），每个客户端独占一条线程
- **消息广播**：任意客户端发言后，消息实时广播给所有在线用户
- **服务端公告**：服务端管理界面支持一键向全体用户推送公告
- **Swing GUI**：客户端与服务端均有图形界面，聊天记录实时滚动显示
- **线程安全更新**：接收线程通过 `SwingUtilities.invokeLater` 确保 UI 在 EDT 中安全刷新
- **用户名配置**：客户端启动时可设置自定义用户名

---

## 架构设计

```
┌─────────────────────────────────────┐
│            ServerDemo               │
│  Port 6666  Port 6667  Port 6668    │
│      │          │          │        │
│   Thread1    Thread2    Thread3     │  ← 每客户端一条广播线程
│      └──────────┼──────────┘        │
│           Broadcast                 │  ← 消息广播给全部连接
└──────────────────────────────────────┘
       ↑↓          ↑↓          ↑↓
  Client_1      Client_2    Client_3
  (GUI)         (GUI)       (GUI)
```

| 文件 | 职责 |
|------|------|
| `server/serverDemo.java` | 服务端主程序，含 Swing GUI 与公告推送 |
| `server/thread.java` | 每客户端专属线程，负责收/广播消息 |
| `server/sockets.java` | Socket 连接管理与工具封装 |
| `client/client_1.java` | 客户端 1（Swing GUI，用户名 + 消息收发）|
| `client/client_2.java` | 客户端 2 |
| `client/client_3.java` | 客户端 3 |

---

## 快速启动

**环境要求**：JDK 8+，同一局域网内运行（Windows 推荐 PowerShell 7 `pwsh`）

### 脚本模式（一键启动 / 停止）

```powershell
# 1. 一键启动（默认会编译到 out，并自动清理 6666/6667/6668 端口冲突）
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/start-chatroom.ps1

# 2. 一键停止（按 runtime-logs/chatroom-pids.json 停止由脚本拉起的进程）
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/stop-chatroom.ps1

# 3. 强制兜底停止（额外按端口结束 Java 监听进程）
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/stop-chatroom.ps1 -ForceByPort
```

常用参数：

```powershell
# 跳过编译，直接使用现有 out
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/start-chatroom.ps1 -NoCompile

# 自定义输出目录
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/start-chatroom.ps1 -OutDir ./out-custom

# 禁用端口冲突自动清理
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File ./scripts/start-chatroom.ps1 -KillConflicts:$false
```

### 手动模式（兜底）

```bash
# 1. 编译所有源文件
javac -d out src/server/*.java src/client/*.java

# 2. 启动服务端（先启动）
java -cp out server.serverDemo

# 3. 分别启动客户端（新窗口）
java -cp out client.client_1
java -cp out client.client_2
java -cp out client.client_3
```

### 常见问题

- 端口占用（6666/6667/6668）
  - 现象：服务端启动报端口绑定失败。
  - 处理：`start-chatroom.ps1` 默认会自动结束占用进程；若不希望自动结束，可用 `-KillConflicts:$false` 改为直接失败。
- 未安装 JDK / 命令不可用
  - 现象：提示 `java` 或 `javac` 未找到。
  - 处理：安装 JDK 并确认 `java -version`、`javac -version` 可执行。
- GUI 窗口未弹出
  - 现象：脚本执行成功但看不到 Swing 界面。
  - 处理：确保在本机桌面会话运行；远程无桌面环境（如纯 SSH）无法正常显示 Swing 窗口。

---

## 核心实现

**服务端广播**（`thread.java`）

```java
// 收到消息后广播给全部客户端
String msg = reader.readLine();
for (Socket s : ServerDemo.clientList) {
    PrintWriter pw = new PrintWriter(s.getOutputStream(), true);
    pw.println("[" + username + "]: " + msg);
}
```

**客户端异步接收**（`client_1.java`）

```java
// 独立线程接收，SwingUtilities 保证 UI 安全
new Thread(() -> {
    String line;
    while ((line = reader.readLine()) != null) {
        final String msg = line;
        SwingUtilities.invokeLater(() -> chatArea.append(msg + "\n"));
    }
}).start();
```

---

## 技术栈

| 技术 | 用途 |
|------|------|
| `java.net.Socket` / `ServerSocket` | TCP 连接建立与管理 |
| `java.io.BufferedReader` / `PrintWriter` | 文本帧读写 |
| `java.lang.Thread` | 每客户端专属接收/广播线程 |
| `javax.swing.*` | 聊天界面（JFrame / JTextArea / JButton）|
| `SwingUtilities.invokeLater` | UI 线程安全更新 |

---

## License

MIT © 2026

