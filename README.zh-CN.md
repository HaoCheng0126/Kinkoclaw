<div align="center">
  <h1>KinkoClaw</h1>
  <p>
    <a href="README.md">English</a>
  </p>
</div>

---

> *KinkoClaw 是 OpenClaw Gateway 的 macOS 桌面外壳。*

<div align="center">
  <p>
    <img alt="License" src="https://img.shields.io/badge/License-MIT-111111?style=flat-square" />
    <img alt="macOS" src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat-square" />
    <img alt="Swift" src="https://img.shields.io/badge/Swift-6-111111?style=flat-square" />
    <img alt="Live2D" src="https://img.shields.io/badge/Live2D-Enabled-111111?style=flat-square" />
    <img alt="Gateway" src="https://img.shields.io/badge/OpenClaw-Gateway-111111?style=flat-square" />
  </p>
</div>

<p align="center">
  KinkoClaw 把一个已经存在的 OpenClaw Gateway，变成适合日常使用的 macOS 形态：
  顶部菜单栏入口、桌面悬浮宠物，以及带 Live2D 角色的主舞台聊天界面。
</p>

<p align="center">
  适合已经在本地或远端运行 OpenClaw 的用户，用一个更像桌面应用的外壳替代浏览器优先的交互方式。
</p>

<p align="center">
  <a href="#产品预览">产品预览</a>
  ·
  <a href="#核心能力">核心能力</a>
  ·
  <a href="#quick-start">Quick Start</a>
  ·
  <a href="#从源码运行">从源码运行</a>
</p>

## 产品预览

### 桌面宠物

![Desktop Pet](assets/readme/desktop-pet.png)

### 主舞台

![Main Stage](assets/readme/main-stage.png)

### 模型选择

![Model Picker](assets/readme/model-picker.png)

## 核心能力

- 菜单栏常驻，不打扰 Dock 的正常使用
- 桌面悬浮宠物，点击即可打开主舞台
- 左侧角色、右侧对话的 Live2D 主舞台
- 支持本地、SSH 隧道、直连 `wss://` 三种网关连接方式
- 支持内置和导入 Live2D 模型切换
- 支持缩放、水平偏移、垂直偏移等角色构图调节
- 本地人设记忆卡会在发送前影响回复风格
- 主舞台支持浅色和深色两种外观模式

## 产品定位

KinkoClaw 是一个明确收敛在 macOS 上的薄客户端。

- 不负责托管模型后端
- 不替代你已有的 OpenClaw Gateway 部署
- 只负责桌面交互、角色展示和聊天体验

如果你已经在本地或远端运行 OpenClaw Gateway，而你想要一个更像“桌面应用”的入口，KinkoClaw 就是这个外壳。

## Quick Start

1. 先确保你已经有一个可用的 OpenClaw Gateway。
2. 启动 KinkoClaw。
3. 打开主舞台或设置抽屉。
4. 选择一种连接方式：
   - 本地 `ws://127.0.0.1`
   - SSH 隧道
   - 直连 `wss://`
5. 选择角色模型，然后通过 `main` 会话开始聊天。

## 从源码运行

### 环境要求

- macOS 15+
- Xcode
- Node.js
- pnpm

### 日常开发启动

```bash
./scripts/run-kinkoclaw-debug.sh
```

这是当前唯一的本地开发启动方式。它会重建舞台前端、重建 Swift target、关闭旧实例，并直接拉起可见的调试二进制。

## 打包

需要生成最终可分发的 `.app` 时：

```bash
./scripts/package-kinkoclaw-app.sh
```

## 仓库结构

- `apps/macos/Sources/KinkoClaw` — 原生 macOS 外壳
- `apps/macos/stage-live2d` — Live2D 舞台前端运行时
- `apps/macos/Tests/KinkoClawTests` — 客户端测试
- `scripts/run-kinkoclaw-debug.sh` — 可见调试二进制启动脚本
- `scripts/package-kinkoclaw-app.sh` — 最终 macOS 应用打包脚本
- `assets/readme/` — README 截图资源

## License

MIT
