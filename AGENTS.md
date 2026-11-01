# AGENTS.md

## Product experience direction (owner request 2026-10-31; proposal until reviewed)

The owner requests a product-led experience and commercial viability reboot: [master #86](https://github.com/turlamai/movebit/issues/86), [bilingual detailed design](docs/PRODUCT-EXPERIENCE-2026.md) / [中文版](docs/PRODUCT-EXPERIENCE-2026.zh-CN.md). Delivery issues: #87 reminder UX, #88 truthful metrics, #89 expressive Mubi, #90 onboarding/UI, #94 opt-in guided microbreaks, #91 paid value, #92 real product acceptance. Existing #51/#54/#56 remain authoritative for safety, original art and the no-interruption rule, **but earlier prohibitions on all voluntary pet interactions or subtle ambient personality are proposed to be relaxed** within the strict limits in #89. This does NOT authorize feeding, punishment, attention loops, full-screen blocking, spying or unverified claims. Do not claim design hypotheses are completed implementation.

**Critical commercial decision conflict:** main's historical "free-only / no Permit" language is superseded as a planned product direction by owner decision tracked in #81 and open PR #82. #82 owns PRICING.md and PRICING.zh-CN.md; avoid overlapping edits until it is reviewed/merged. Free + Pro is a plan, **not permission to enable payment gates, collect money, demand accounts or claim paid features ship**. Permit-in-core/Commerce-server work remains gated by #81's engineering and release evidence, and existing MIT source rights stay intact.

When implementing a bounded slice, check the current main/PR heads first; coordinate with active agents, avoid reverting their changes, use the shared Racket scheduler and three native hosts, record real packaged acceptance and upgrade/migration of already released 0.0.1 user data.

## Highest-priority product direction — MoveBit v1 reboot (owner approval 2026-10-26)

**This repository's v0.x releases were experiments with no real users.** The owner has explicitly authorized a breaking clean-slate **first real v1**. Source of truth: [#55](https://github.com/turlamai/movebit/issues/55) (execution/old-feature retirement), [#51](https://github.com/turlamai/movebit/issues/51) (product charter), [#54](https://github.com/turlamai/movebit/issues/54) (focus and input safety). Earlier lines in old releases, docs, tests and agent notes that require preserving experimental full-screen/strict-mode UX, backward-compatible config/history, v0.x migration, or side-by-side legacy reminder paths **are superseded**. Do not rebuild legacy compatibility without a newly discovered concrete user need.

**What we are building:** a hydration / stand-up / eye-rest desktop reminder app, with an original small expressive character as the default, **non-blocking delivery mechanism**, not as an independent pet/companionship product. No forced full-screen/multi-monitor cover or delayed skip in v1. Explicit reminders must be clear and actionable (Done / Later / Hide / Focus), no focus theft or broad invisible hit-catching window. No feeding/mood/play loops, paid gating, accounts or AI chat.

**Allowed:** remove experimental features, replace onboarding/settings/UI and API/config schemas, delete/rewrite obsolete legacy tests, start the new release at a distinct version (owner decision 2026-10-27: the reboot ships as v0.0.1, a fresh version baseline) without supporting v0.x upgrade migration. **Keep:** sound engineering and safety: Racket as canonical scheduler, one Rivet contract for all native hosts, accessibility, local privacy, packaging/update signature integrity, real CI/native acceptance and reproducible tests. Never reuse/delete historical published Git tags or mark an unshipped redesign released.

**Execution order:** remove strong-break architecture and legacy UX with cross-host changes; wire semantic due/pending/ack/snooze cues through the backend, implement character-style native reminders and safe notification fallback on each host, simplify fresh-install settings/onboarding, then test and release. Each PR owns one bounded feature slice and includes CI + actual host verification. Screenshot or a green domain unit suite alone is not sufficient.


## Authorization decision before implementation

Decision `2026-10-auth-1`: No commercial Permit credentials, Commerce checkout or licensing account. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

指引给 AI agent（及开发者）：如何理解、构建、运行、改动 MoveBit。

## 这是什么

MoveBit 以 Rivet（github.com/turlamai/rivet）构建：一份 Racket 领域核心，
通过 Rivet 类型化 RPC（RVT1 协议）驱动各平台第一方原生 UI 薄壳。
Avalonia/.NET 旧栈已彻底移除，仓库从 rivet 时代（0.1.0 起）起算。

| 平台宿主 | 技术栈 | 目录 | 状态 |
|---|---|---|---|
| macOS | SwiftUI 宿主 + 生成客户端 | `macos-host/` | 可用 |
| Windows | C++/WinRT 宿主 + 生成客户端 | `windows/` | 可用 |
| Linux | GTK4 宿主 + 生成客户端 | `linux/` | 可用 |
| agent CLI | — | — | 不适用 |

## 快速命令

```bash
# 前置：Racket CS 9.x，rivet 以 link 方式安装
# cd ../rivet && raco pkg install --auto --no-docs --name rivet --link file://$PWD

raco rivet doctor --json   # 工具链自检
raco rivet schema check rivet-schema.json --json # RPC 兼容性门禁
raco rivet build           # 生成三端客户端 + 编译后端 bundle + 宿主构建
raco rivet dev             # 开发循环
raco test racket/          # 领域核心测试
raco test racket/tests/backend-server-test.rkt # 真实 RVT1 wire test
raco rivet acceptance --json # 当前平台的打包产品验收
```

## 完成定义

- GUI 功能必须通过 `raco rivet acceptance --json`：领域契约、真实 RVT1、
  原生宿主、可分发包以及打包后的原生 UI 操作缺一不可。
- 默认验收使用隔离配置启动打包应用，确认真实后端工作状态以及**喝水 / 久坐活动 / 护眼健康提醒动作**能被原生可访问性树与用户操作覆盖；只构建成功、只截图或只打开空窗口不算完成。旧版仅验证 `Active today` 的验收不再足够。
- 跨平台交互要同步 macOS、Windows、Linux，或明确记录真实平台边界。
- 不得用 `continue-on-error`、空测试、跳过 UI 或强杀进程作为成功证据。

## 契约（不要破坏）

- **v1 数据契约可全新定义**：没有真实用户，无需兼容旧版 `config.json`、`history.json`、旧字段或迁移旧路径。新格式必须有确定的 fresh-install 默认值、schema 版本、读写容错、隐私与测试；同一 v1 版本在 macOS / Linux / Windows 之间保持一致。保留本地数据优先。
- **i18n 单源**：`shared/i18n/{zh,en}.json`，平台副本必须逐字节一致；zh 为默认
- **RPC 面**：`app/backend.rkt` 的 define-rpc 是宿主唯一数据通道；改签名 = 各端宿主 + 生成客户端同步改
- **宿主只做渲染与交互**：业务一律走 RPC；定时器/调度/HTTP/存储都在 Racket 后端
- **Rivet 改动走上游**：缺能力先提 issue/PR 到 turinglambdaai/rivet

## 项目结构

```
├── rivet.rktd          Rivet 应用清单
├── app/backend.rkt     Rivet 后端入口（装配领域层）
├── racket/             Racket 领域核心 + tests/
├── shared/i18n/        zh.json / en.json 单源
├── macos-host/         SwiftUI 宿主
├── windows/            WinUI3 宿主
└── linux/              GTK4 宿主
```

## 组合定位（Portfolio placement）

- 当前决策（2026-10-v2）：免费社区工具。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turlamai/turlamai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前**产品实施优先入口**：[v1 重启与旧功能退役 #55](https://github.com/turlamai/movebit/issues/55)。健康提醒产品目标见 [#51](https://github.com/turlamai/movebit/issues/51)，原生交互安全见 [#54](https://github.com/turlamai/movebit/issues/54)。旧版全屏强制休息已决定从 v1 移除；#48 属于旧版交付收尾历史，不阻塞新产品的代码重构。仍须通过新版本真实打包验收，保持 MIT 免费。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.
