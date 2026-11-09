# MoveBit

> **v0.0.1 —— 全新起点（2026-10-27）。** 重启后的 MoveBit 最初按所有者决定以 v0.0.1 发布：这是历史上的版本线重启记录，并非当前版本说明。最新已发布版本请以 Releases 为准。旧实验线 v0.5.0（含全屏强制休息）退役为历史——v0.0.1 中不存在任何全屏休息，也不提供从 v0.5 的迁移路径。

一款桌面健康提醒应用：喝水、起身、护眼三类提醒，由原创小角色**沐比（Mubi）**交付——每次休息它都会走到你的工作区中央，置顶等你回应；你不工作时它就在旁边自己玩耍。它从不抢键盘焦点、从不遮挡你的工作，除了沐比本体以外的屏幕全部鼠标穿透。一份 Racket 领域核心（唯一的提醒状态机）通过 [Rivet](https://github.com/turlamai/rivet) 的类型化 RPC 驱动 Windows、macOS、Linux 上的第一方原生宿主。

[![release](https://img.shields.io/github/v/release/turlamai/movebit)](https://github.com/turlamai/movebit/releases/latest) ![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Rivet-c15f3c) [![CI](https://github.com/turlamai/movebit/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/movebit/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **中文**

## 开始使用

当前预览版免费且采用 MIT 源码许可。未来计划提供 Free + Pro 商业版本，但目前尚未交付或启用付费激活、结账及订阅；详见[收费政策](PRICING.zh-CN.md)。 提供 macOS、Windows、Linux 桌面预览。空闲检测依赖桌面会话；不支持的 Wayland 会话会回退为经过时间计时。Linux 上沐比角色卡在 X11 会话停靠——Wayland 合成器不允许应用放置穿透卡片，提醒在该类会话改为应用内提醒卡投递。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 为什么做

很多提醒工具的问题不是"不会提醒"，而是提醒太容易被随手关掉。MoveBit 把下面几件事当成产品契约：

- **尽量统计活跃工作时长，而不是盲目累计墙上时间。** Windows、macOS、Linux/X11 都有会话级空闲检测；Wayland 会优先使用 GNOME/Mutter IdleMonitor 或 freedesktop ScreenSaver 会话总线接口。桌面环境没有提供可靠接口时，MoveBit 会明确退化为自然时间，而不是猜一个假的空闲时间。
- **让提醒既躲不开、又必须回应。** 到点时，原创小角色沐比走到工作区中央——在所有窗口之上——等你回应。**摸摸沐比 = 做到**（自我报告），气泡上的「稍后」标签延后一次，托盘里的做到 / 稍后 / 隐藏随时可用。会被别的窗口盖住、会被随手点击关掉的提醒，不配叫提醒。
- **对「点一下」的含义保持诚实。** 「做到了」是自我报告而非实测；沉默同样不会被记成完成——无人回应的邀请会一直留在屏幕上，新一轮提醒触发时会合并进同一份邀请（始终只有一只沐比，每种含义都保留），绝不替你悄悄结账。专注模式静默排队，结束后只送回一条有界汇总。
- **真的休息过，就不要马上再催。** 离开电脑达到阈值后回来，三个提醒周期都会从零开始，休息本身也不会被算进工作时长。
- **不只看今天，还要看到工作模式。** 主界面支持最近 7 天 / 30 天切换，并统计当前连续工作、今日/近 30 天最长连续工作、活跃日平均时长、最活跃的一天等指标。
- **每个桌面平台都同时提供原生安装器和便携压缩包。** Windows 有 MSI + 便携 ZIP，macOS 在 Apple silicon 和 Intel 上都有 DMG + 便携 ZIP，Linux 提供便携 tar.gz 与 zip，另有 deb、rpm 与 AppImage。

## 架构

MoveBit 以 [Rivet](https://github.com/turlamai/rivet) 重建：所有策略都在一份 Racket 领域核心里（`app/backend.rkt` + `racket/`），每个平台宿主只是一层薄薄的原生壳，负责渲染状态、转发用户操作，通过类型化 RPC（RVT1）与核心通信：

| 宿主 | 技术栈 | 目录 |
| --- | --- | --- |
| Windows | WinUI 3（C++/WinRT），内嵌 Racket CS | `windows/` |
| macOS | SwiftUI | `macos-host/` |
| Linux | GTK 4，内嵌 Racket CS | `linux/` |

Racket 运行时静态链接进宿主——不依赖外部解释器、没有 .NET、没有 Electron。配置与历史文件的路径和格式在各宿主间完全一致（Windows 为 `%APPDATA%\movebit`，其余平台为系统应用数据目录），安装可以直接原地升级。

## 功能

- ⏱️ **活跃工作监测**：Windows `GetLastInputInfo`、macOS CoreGraphics、Linux/X11 XScreenSaver，以及可用时的 Wayland 会话总线后端
- 🐹 **提醒角色沐比**：屏幕边缘的举杯 / 拉伸 / 闭眼手势，配明确的建议文字、读屏标签与 Reduce Motion 支持；尺寸 S/M/L、动效三档、停靠位置与标签显示皆可设置
- 💧 **三条独立周期**：喝水、久坐、护眼各有间隔；多条同时到期合并为一条提醒，含义全部保留
- ✅ **诚实的提醒生命周期**：due → pending/displayed → acknowledged（自报）| snoozed | expired；十分钟过期，下一条按正常周期到来
- 🎯 **专注模式**：演示静默排队，结束后合并为一条有界汇总；托盘的做到 / 稍后 / 隐藏随时可触达
- 📊 **7 / 30 天历史**：可切换的活跃柱状图，最多保留 370 天历史
- 🧠 **工作模式洞察**：当前连续工作、今日/近期最长连续、活跃日平均、最活跃日
- 🌓 **中文 / English**：应用内切换，或跟随系统 UI 语言
- 🔁 **开机自启**：Windows 注册表 / macOS LaunchAgent / Linux XDG autostart，由后端统一管理
- ⏸️ **一键暂停一小时**：精确计算暂停到期
- 🔒 **单实例**：重复启动唤起已有实例，不会创建重复的调度器
- 📦 **原生 + 便携分发**：Windows MSI、macOS DMG、便携 ZIP，Linux tar.gz/zip/deb/rpm/AppImage

## 安装

从 [Releases](https://github.com/turlamai/movebit/releases/latest) 下载：

| 平台 | 便携压缩包 | 安装器 |
| --- | --- | --- |
| macOS Apple silicon | `movebit-<version>-macos-arm64.zip` | `movebit-<version>-macos-arm64.dmg` |
| macOS Intel | `movebit-<version>-macos-x64.zip` | `movebit-<version>-macos-x64.dmg` |
| Windows x64 | `movebit-<version>-windows-x64.zip` | `movebit-<version>-windows-x64.msi` |
| Windows ARM64 | 经 Windows on ARM 的 x64 模拟运行 x64 构建 | — |
| Linux x64 | `movebit-<version>-linux-x64.tar.gz` · `.zip` | `movebit-<version>-linux-x64.deb` · `-x86_64.rpm` · `.AppImage` |
| Linux arm64 | `movebit-<version>-linux-arm64.tar.gz` · `.zip` | `movebit-<version>-linux-arm64.deb` · `-aarch64.rpm` |

资产遵循统一的小写命名 `movebit-<version>-<os>-<arch>.<ext>`（例如 `movebit-0.5.0-macos-arm64.dmg`）。每个资产都有对应的 `.sha256` 文件，每个发布还提供 `SHA256SUMS` 与 Ed25519 签名的 `update-manifest.json`。

平台说明：

- **Windows** —— 日常使用运行 MSI 安装；便携 ZIP 解压到任意目录即可运行。ARM64 Windows 请使用 x64 资产（经模拟运行），暂无原生 ARM64 构建。
- **macOS** —— 打开 DMG 把应用拖进"应用程序"；便携 ZIP 是不带磁盘镜像的同一应用。构建为 ad-hoc 签名、未经公证，Gatekeeper 首次启动可能需要右键 → 打开，或执行 `xattr -cr /Applications/MoveBit.app`。公证在具备付费 Apple 开发者账号后补上。
- **Linux** —— 安装 deb（`sudo apt install ./movebit-<version>-linux-<arch>.deb`）或 rpm，运行 AppImage，或解压 tar.gz 直接运行；唯一运行时依赖是 GTK 4 及其系统库，其余全部内置。deb 安装到 `/opt/movebit`，带 `movebit` 命令与桌面入口。

> 发布二进制暂无发布者代码签名，Windows SmartScreen 或 macOS Gatekeeper 首次启动可能提示警告。付费签名/公证是分发路线上的最后一项。

## 工作方式

三个独立周期在 30 秒的调度 tick 上推进：

- **久坐周期**只累计活跃工作时长。满 50 活跃分钟成为一条提醒——沐比起身邀请你拉伸。
- **喝水周期**独立运行——每 60 活跃分钟沐比举起小蓝杯。
- **护眼周期**独立运行——每 20 活跃分钟沐比闭上眼睛，建议你看向远处。

空闲达到离席阈值（默认 5 分钟）即冻结累计；回来后所有周期从零开始。系统睡眠这类超大的时钟跳变会被截断，避免唤醒后倾倒过期提醒。

每个到期 tick 合并为一条提醒，走过显式生命周期：`due → pending/displayed → acknowledged | snoozed`。「做到了」是自我报告（绝非实测）——在屏幕上就是摸摸沐比；「稍后」把合并的全部种类按 10 个活跃分钟延后；「隐藏」不作任何声明。邀请永不过期、不会自动撤退：它置顶于所有窗口等你回应，新一轮提醒会合并进未回应的邀请。专注模式静默排队，结束后只送回一条有界汇总。

每日统计每隔几分钟写入历史存储，跨天归档，最多保留 370 天。

## 配置

配置位于 Windows 的 `%APPDATA%\movebit\config.json`（macOS/Linux 为系统应用数据目录）。默认值就是产品本身：没有节奏要研究、没有分种类开关、也没有外观选项——均衡节奏（50/60/20）、一套角色形象加拖拽摆放（和托盘「挪一挪」）已经覆盖一切。设置窗口只剩四项，后端会钳制数值并通过 config-changed 事件向各宿主重新广播：

| 设置 | 默认 |
| --- | --- |
| 提示音（每次提醒一声轻响） | 开 |
| 免打扰时段 | 关，22:00–07:00 |
| 自动检查更新 | 开 |
| 语言 | auto（跟随系统）、zh / en |

「现在不想被打扰」在托盘里，不在设置里：专注模式整体延后、暂停一小时静默、稍后延后单条提醒。磁盘配置带 `SchemaVersion` 标记（v5）；旧的磁盘格式会迁移，保留你的语言、免打扰、提示音与沐比位置；没有已知标记的外来文件一律回落默认值。

## 从源码构建

前置：[Racket CS](https://racket-lang.org)（9.x）、以 link 方式安装的 [rivet](https://github.com/turlamai/rivet) CLI，以及对应宿主的工具链（Windows 需带 WinUI 的 Visual Studio，Linux 需 GTK 4 开发包，macOS 需 Xcode）。

```bash
git clone https://github.com/turlamai/rivet.git ../rivet
raco pkg install --auto --no-docs --link ../rivet/rivet ../rivet/rivet-cli

raco rivet doctor        # 工具链自检
raco test racket/        # 领域核心测试
raco rivet build         # 生成客户端、编译后端、构建本平台宿主
```

Linux 打包脚本（deb / rpm / AppImage）在 `packaging/linux/` 下，作用于 rivet stage 出的 `dist/` 产物。

## 发布流程

1. 更新单一来源的 `VERSION` 文件；`scripts/check-release-version.sh` 校验 `VERSION == rivet.rktd`，发布 tag 也必须一致（如 `0.3.1` ↔ `v0.3.1`）。
2. 在 `CHANGELOG.md` 里加上对应版本的章节——发布流水线的 validate 任务会检查它。
3. CI 全绿才可合入（Racket 测试 + Windows/macOS/Linux 宿主矩阵）。
4. 推送版本 tag。发布自动化会构建 macOS DMG + 便携 ZIP（arm64/x64）、Windows MSI + 便携 ZIP、Linux tar.gz + zip（双架构）及 deb、rpm、AppImage，生成逐资产 `.sha256`、`SHA256SUMS` 与签名的 `update-manifest.json`；全部必需包成功后才创建唯一的 GitHub Release，发布说明取自 CHANGELOG 对应章节。

## 路线图

- [x] Windows 托盘图标与快捷操作（打开 / 暂停 / 退出）
- [x] 三端应用内签名清单更新已随 [0.5.0](https://github.com/turlamai/movebit/releases/tag/v0.5.0) 发布：下载可取消、Windows MSI 经被动 msiexec 交接自更新、zip 换装带备份与回滚。
- [x] 取消、拒绝错误签名与回滚的测试级证据（`racket/tests/update-test.rkt`，CI 上运行）。
- [x] v0.0.1 已作为全新起点基线发布，签名更新 feed 已上线（每个发布附带 `update-manifest.json`）。
- [ ] 每种安装形态的实测 N→N+1 更新证据（更新器测试已证明机制本身；逐形态的真实更新记录仍未做）。
- [ ] Windows 代码签名与 macOS 签名/公证
- [ ] Windows/Linux 手势动效的打包桌面实测调优（#56 D4）
- **不做移动端（iOS / iPadOS / Android）与 watchOS.** MoveBit 解决的是桌面办公时的长时间久坐；手机和平板的使用姿态是站着、走动、躺着，久坐问题不成立。产品定位就是桌面跨平台：macOS、Windows、Linux。

## 许可

[MIT](LICENSE)
