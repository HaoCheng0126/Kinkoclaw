# KinkoClaw

[English](README.md) | 简体中文

KinkoClaw 是一个连接现有 OpenClaw Gateway 的 macOS 桌面宠物客户端。
它把你已经部署在本地或服务器上的 OpenClaw，变成一个菜单栏助手、桌面悬浮宠物和 AIRI 风格的 Live2D 对话舞台。

## 它能做什么

- 菜单栏常驻，不进入 Dock
- 桌面悬浮宠物，点击打开主舞台
- AIRI 风格主舞台，左侧角色、右侧对话
- 连接已有 OpenClaw Gateway，支持：
  - 本地 `ws://127.0.0.1`
  - SSH 隧道
  - 直连 `wss://`
- 固定绑定 Gateway 的 `main` 会话
- 导入和切换 Live2D 模型包
- 调整角色缩放、水平偏移、垂直偏移
- 本地保存“人设记忆卡”，在发送前影响回复风格

## 产品定位

KinkoClaw 是一个薄客户端，不负责安装、托管或管理 OpenClaw。
OpenClaw 在别处运行，KinkoClaw 负责提供桌面端的交互外壳。

## 当前体验

- 仅支持 `macOS`
- 菜单栏入口 + 桌面宠物
- 使用 `WKWebView` 承载 AIRI 风格 Live2D 舞台
- 主舞台和桌宠都走 Live2D 渲染链
- 保留一个轻量文本聊天面板作为调试/兜底入口

## 主要功能

### 连接能力

- 连接本地 Gateway
- 通过 SSH 隧道连接远端 Gateway
- 直接连接远端 `wss://` Gateway
- 连接配置保存在本地客户端

### 角色舞台

- 大尺寸 Live2D 角色舞台
- 字幕气泡和聊天历史
- 舞台内设置抽屉
- 角色切换和导入模型
- 舞台构图调节

### 桌面宠物

- 桌面悬浮显示
- 单击打开主舞台
- 支持拖动
- 重启后恢复位置

### 人设记忆卡

- 角色身份
- 说话风格
- 与用户关系
- 长期记忆
- 约束条件

这张记忆卡只在本地客户端生效，会在发送消息前注入隐藏上下文，不会回写到 Gateway。

## 仓库结构

- `apps/macos/Sources/KinkoClaw`：原生 macOS 客户端外壳
- `apps/macos/stage-live2d`：AIRI 风格舞台前端运行时
- `apps/macos/Tests/KinkoClawTests`：macOS 客户端测试
- `scripts/package-kinkoclaw-app.sh`：`.app` 打包脚本

## 从源码运行

### 环境要求

- macOS 15+
- Xcode
- Node.js
- pnpm

### 构建舞台前端

```bash
cd apps/macos/stage-live2d
pnpm install
pnpm build
```

### 构建 macOS 客户端

```bash
cd apps/macos
swift build --product KinkoClaw
```

### 启动应用

```bash
cd apps/macos
./.build/arm64-apple-macosx/arm64-apple-macosx/debug/KinkoClaw
```

## 打包

生成独立 `.app`：

```bash
./scripts/package-kinkoclaw-app.sh
```

## 说明

- KinkoClaw 依赖一个已经存在的 OpenClaw Gateway，但这个仓库当前专注的是客户端体验。
- 现阶段的核心工作都集中在 macOS 客户端和 Live2D 舞台运行时。

## License

MIT
