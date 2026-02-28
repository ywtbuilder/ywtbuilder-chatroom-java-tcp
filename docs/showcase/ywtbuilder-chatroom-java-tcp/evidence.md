# ywtbuilder-chatroom-java-tcp 展示证据页

## 一句话价值

基于 Java TCP Socket + Swing GUI 的多人聊天室，覆盖服务端并发、消息广播与客户端线程安全更新。

## 1 分钟演示视频

- 文件：`docs/showcase/ywtbuilder-chatroom-java-tcp/demo.mp4`
- 建议镜头：服务端启动 -> 三客户端连接 -> 消息广播 -> 服务端公告

## 3 张关键截图

1. `shot-01.png`：服务端 GUI 与在线连接
2. `shot-02.png`：三个客户端并发聊天
3. `shot-03.png`：公告广播结果

## 一键运行命令

```powershell
cd ywtbuilder-chatroom-java-tcp
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-chatroom.ps1
```

## 核心技术决策

1. 线程模型：每客户端一线程，隔离连接故障。
2. 广播机制：共享连接集合统一下发消息。
3. UI 安全：接收线程通过 `SwingUtilities.invokeLater` 更新界面。

## 性能/稳定性证据

| 指标 | 目标 | 当前结果 | 说明 |
|---|---:|---:|---|
| 并发连接数 | >= 3 | 待填充 | 三客户端稳定在线 |
| 广播到达率 | 100% | 待填充 | 连续发送 50 条 |
| 异常断连恢复 | 可恢复 | 待填充 | 单客户端断开后其余不受影响 |

## 面试可提问点

1. 为什么这里选择线程而不是线程池/NIO？
2. 广播时如何避免单客户端阻塞拖慢全局？
3. Swing 线程模型中的 EDT 为什么重要？
4. 聊天协议如何扩展为私聊/群聊？
5. 如果支持跨网络部署，要补哪些安全措施？



