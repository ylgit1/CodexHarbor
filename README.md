# Codex Harbor

<p align="center">
  <strong>原生 macOS AI 开发控制中心</strong><br>
  管理 Codex 连接，让 ChatGPT 安全接入本地项目，并把修改、测试、构建与打包串成可验证的 Coding Task。
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
  <img alt="MCP" src="https://img.shields.io/badge/MCP-2026--07--28-2563EB">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-22C55E">
</p>

---

Codex Harbor 是一个面向 macOS 开发者的原生桌面应用。它把原本分散的 **Codex 账户/API 切换、ChatGPT MCP 接入、本地项目权限、文件修改、命令执行、测试构建、诊断与使用统计** 统一到一个控制面中。

它不是简单编辑 `~/.codex/config.toml` 的配置工具：Codex Harbor 会读取真实运行状态，以事务方式切换连接，对敏感配置和历史任务做保护，并通过独立的 `HarborChatGPTAgent` 将经过授权的本地开发能力暴露给 ChatGPT。

> Codex Harbor 是独立开源项目，不是 OpenAI 或 Cloudflare 的官方产品。

## 核心能力

### Codex 连接管理

Codex Harbor 当前支持三类 Codex 连接：

| 类型 | 能力 |
| --- | --- |
| 账户登录 | 保存多个 Codex 登录档案、检测可用性、切换当前账户 |
| 托管密钥 | 管理多个托管连接、查询用量与有效期、检测连接状态 |
| 自定义 API | 保存多个 API Provider、模型与凭据，独立统计请求与 Token |

连接切换不是简单覆盖配置。当前实现包含：

- 读取并识别 Codex **真实生效配置**
- 多账户、多托管密钥、多自定义 API 档案
- 原子更新 `config.toml` / `auth.json`
- 配置校验与失败回滚
- 部署前备份与精确恢复
- 必要时迁移历史任务 JSONL 与 SQLite 索引
- 外部修改检测，避免用 Harbor 的旧状态覆盖真实配置
- 登录状态变化监听与自动同步

### ChatGPT 接入

ChatGPT 可以通过 Codex Harbor 调用本机项目能力，而无需让整个文件系统暴露给远端。

目前支持两种独立的接入方式：

| 接入方式 | 说明 |
| --- | --- |
| OpenAI 本地管道 | 使用 OpenAI tunnel-client 建立受控的 MCP 通道 |
| 公网 HTTPS | 使用固定 HTTPS 地址与 cloudflared 暴露 MCP 服务 |

两套配置互相独立，可以长期共存和切换。Codex Harbor 会负责：

- 本地 Agent 生命周期管理
- MCP Server 启停与健康检查
- 仅监听 `127.0.0.1` 的本地服务
- Allowed Roots 项目目录授权
- Tunnel / HTTPS 运行状态检测
- Runtime Key / Access Token 生命周期处理
- 本地管道代理策略：自动 / 系统代理 / 直连
- 自动检测 macOS HTTP/HTTPS/SOCKS 代理；代理不可达时可回退直连
- 本地 MCP 强制加入 localhost / 127.0.0.1 / ::1 绕过代理
- 代理与直连都失败时提示 VPN/TUN/路由类网络异常
- 工具目录版本与 ChatGPT 已发现目录的差异检测
- 连接异常后的恢复与重新连接
- 自动下载当前 Mac 架构对应的 tunnel-client / cloudflared
- 下载校验与受控安装，不要求预装 Node、npm 或 Homebrew

典型链路：

```mermaid
flowchart LR
    A[ChatGPT] --> B{接入方式}
    B -->|OpenAI 本地管道| C[Tunnel Client]
    B -->|公网 HTTPS| D[Cloudflared]
    C --> E[HarborChatGPTAgent]
    D --> E
    E --> F[MCP Server]
    F --> G[权限与 Allowed Roots]
    G --> H[Workspace / Git / Command / Coding Task]
```

### 本地 MCP 开发工具

当前版本内置 **30 个 MCP 工具**（实际数量以运行时 `tools/list` 为准），覆盖项目浏览、文件修改、Git、命令、工作流和 Coding Task。

| 类别 | 工具 |
| --- | --- |
| 工作区 | `open_workspace`, `read`, `tail_file`, `search`, `list_directory`, `workspace_tree` |
| 文件与 Git | `edit`, `patch_file`, `write`, `create_directory`, `move_path`, `trash_path`, `restore_path`, `list_trash`, `git_diff`, `git_status` |
| 命令 | `run_command`, `bash`, `start_command`, `command_status`, `command_output`, `cancel_command` |
| 工作流 | `start_workflow`, `workflow_status`, `workflow_output`, `cancel_workflow`, `run_workflow`, `repair_project` |
| 高阶任务 | `coding_task`, `list_tasks` |

MCP Catalog 会根据工具定义自动生成版本号。服务端 `/health` 会同时返回协议版本、Catalog 版本、工具数量、Host 和 Port，便于检查 ChatGPT 是否仍缓存旧工具目录。

**项目重构与恢复：**可信 Workspace 内可使用 `create_directory` 建目录、`move_path` 移动文件/目录、`trash_path` 将废弃路径移入独立的可恢复储存区，再凭 `trashId` 使用 `restore_path` 恢复。恢复不会覆盖原位置现有文件。操作拒绝 Workspace 根目录、Git 元数据、越界和符号链接路径；仍需在代码变更后运行测试并检查 Git Diff。直接 `rm -rf` 依然被拦截。

**长命令与日志：**命令最长允许 30 分钟，最多可写入 256 MiB 的 stdout/stderr 日志；大输出按偏移调用 `command_output` 分页读取，单次最多 256 KiB。大型项目日志可用 `tail_file` 查看最后 256 KiB，不需要读取整个日志文件。超过 256 MiB 仍可能终止命令，以避免无限磁盘写入。

**多聊天使用：**`list_tasks` 返回同一 Agent 中最近的命令、工作流和 Coding Task（支持按 Workspace 过滤）。不同 Workspace 可同时执行 Coding Task；同一个 Workspace 仍限制并发修改。任务发现依赖运行中的 Agent，正在运行的子进程**不能在 Agent 重启后自动恢复**；Coding Task 已增加轻量状态检查点，可以在 Agent 重启后查看历史任务和中断状态，但不会自动重放文件修改、Git 或 Shell 命令。中断任务需要先检查 Git Diff，再创建新任务继续。并发命令仍存在全局上限。

### Coding Task

`coding_task` 是 Codex Harbor 的高阶开发任务编排能力。一次任务围绕同一个 Task ID 持续执行：

```text
需求
  ↓
精准修改
  ↓
Git Diff
  ↓
测试
  ↓
构建
  ↓
打包
```

当测试或构建失败时：

```text
needsRepair
  ↓
读取结构化编译错误
  ↓
生成修复 Patch
  ↓
repair（保持同一个 Task ID）
  ↓
重新测试 / 构建 / 打包
```

支持的动作：

- `start`：创建任务并应用模型生成的精确修改
- `status`：查询当前阶段和每一步状态
- `output`：增量读取当前命令 stdout / stderr
- `repair`：在同一个 Task 上应用修复并自动重新验证
- `cancel`：停止当前命令并终止后续步骤

Harbor 负责**编排、权限、状态和验证**；代码理解与 Patch 仍由模型完成，不会让本地服务脱离上下文盲目重写源码。

项目工作流当前可自动识别：

- Swift Package
- Xcode Project
- Node.js
- Python
- Maven
- Gradle

对于无法识别验证/打包工作流的项目，Coding Task 不会先修改文件再返回“不支持”。

## 使用统计与运行状态

Codex Harbor 会聚合真实的 Codex 使用数据，而不是用 UI 操作次数代替请求量。

当前统计包括：

- 请求数
- Token
- 成功率
- 平均响应时间
- 按连接类型 / Profile 的趋势
- 今日、7 日、当月时间范围
- Relay 请求与 Token 使用
- Codex rollout Token 记录
- Codex thread/request 状态

Telemetry 使用增量游标和文件变化监听，避免持续全量扫描大型日志或 SQLite 数据库。

ChatGPT 接入侧当前记录的是 **MCP 工具调用审计、状态与诊断信息**。它不等同于整个 ChatGPT 账号的消息数、Token 使用量或订阅额度。

### 常驻运行与更新一致性

- Agent 的轻量进程巡检以 5 秒为间隔，审计活动每 15 秒最多检查一次；审计只读取最多 512 KiB 的日志尾部，不在轮询中重复解析整份日志。
- 健康检查中的远端深度检测仍由恢复状态动态调度：正常时约 5 分钟，连接恢复期间约 10 秒。没有新状态变化时，Agent 不重复写相同的 `runtime.json`。
- App 会同时核对 MCP `/health` 返回的工具目录版本和工具数量；旧 Agent 仅返回 HTTP 200 不再被判为健康。启动、恢复时由现有生命周期管理器完成版本失配处理。
- 首页 ChatGPT 接入状态区分“已连接”“恢复中”“工具待刷新”；配置启用不代表链路健康。更新 Agent 后，ChatGPT 端仍可能需要重新发现 MCP 工具。
- 上述措施旨在减少空闲时的无意义文件读取与写盘；CPU、内存改善程度需在实际空闲和断网场景下测量，不能仅凭代码改动推断具体百分比。

## 安全模型

Codex Harbor 对本地开发能力默认采用“限定范围 + 显式权限 + 可审计”的方式。

### 文件系统边界

- ChatGPT 只能打开位于 Allowed Roots 内的 Workspace
- 所有文件路径都经过标准化和越界检查
- 拒绝 `..`、符号链接逃逸等跨目录访问
- 大型生成目录在 Workspace Tree 中不会递归展开

### 修改和命令权限

修改、Shell 和 Git Push 分开控制：

- 文件修改：`allow / ask / deny`
- Shell：`allow / safeOnly / ask / deny`
- Git Push：`allow / ask / deny`

高风险命令会被额外分类。即使处于宽松模式，明确禁止的提权、递归强制删除、下载后直接执行等操作仍会被拦截。

### 可信项目开发（按目录授权）

为了减少连续开发中的重复授权，可以在「设置」开启可信项目开发，也可以在 ChatGPT 接入的「允许访问的目录」旁单独点击「信任」。新安装及旧配置均默认不启用该权限。

- 仅当 Workspace 属于受信任且仍处于 Allowed Roots 中的目录时，文件修改工具可免重复审批；移除目录将撤销信任。
- 已信任项目内的 Swift 测试/构建、Node/Python/Maven/Gradle 工作流、相对路径 Shell 脚本、Git Add/Commit 等可免重复审批；Coding Task 的修改和验证也适用。
- Git Push 仍由独立权限决定，默认需要确认；提权、破坏性命令和任意 Shell -c 不属于自动审批范围。
- 注意：可信项目脚本以当前 macOS 用户身份执行，Allowed Roots **不是**操作系统级 Shell 沙箱。不要信任来源不明的仓库、脚本或依赖。
- 同时运行命令与日志输出仍受资源限额约束。旧版「完全授权」作为单独的高风险选项保留，不建议日常开启。

### 本地凭据

Codex 与 ChatGPT Bridge 的敏感信息保存在 Harbor 自己的本地凭据库中：

- 原子写入
- 文件权限 `0600`
- 仅当前 macOS 用户可读
- MCP Access Token 使用安全随机数生成
- Runtime Key / API Key 不会在普通界面回显

独立 Agent 使用本地凭据文件而不是依赖应用进程的 Keychain 授权，避免 App 重签名或 Agent 独立启动时反复弹出系统授权框。

### 授权记忆与后台确认

- 记忆授权绑定工作区、工具、目标文件和具体操作参数；旧版全项目文件授权不会自动沿用。
- 记忆授权最多 24 小时；参数内容仅在持久化规则中保存哈希。记忆记录不再在设置页展示，亦不提供“撤销全部授权”入口。
- 独立的置顶 NSPanel 显示待审批命令，与主窗口是否打开无关，不需要系统通知权限；90 秒后自动失效。

### 真实 macOS 界面读取与操作（按需授权）

Codex Harbor 通过 macOS Accessibility 提供独立的 UI 测试工具，两种 ChatGPT 接入方式共用同一套 Agent 能力：

- `ui_apps` / `ui_open_app`：列出可交互应用名称与 Bundle ID；仅在本机单独授权后才可打开指定应用。
- `ui_windows` / `ui_inspect`：先指定已授权应用、窗口索引及**准确标题**，再读取控件树、可用性与选中状态。密码输入框及普通可编辑输入框的值不回传。
- `ui_perform`：对明确控件执行单步点击、写入或滚动，操作前校验 ID 和原标签；敏感操作、授权按钮及系统安全窗口不得自动点击。
- `ui_wait` / `ui_wait_window`：轮询真实控件或窗口出现，不依赖固定睡眠时间。
- `ui_test`：最多 8 步的结构化 UI 验收，每步必须设置 `expectContains`（实际界面文字）或 `expectWindowGone`（目标窗口关闭）；未提供可观察的成功条件时，整个测试在操作前拒绝执行。
- `ui_capture`：**独立授权后**使用 ScreenCaptureKit 获取指定窗口的一张 JPEG 帧，MCP 返回标准 image 内容，默认不截图、不录制也不保存；不提供常驻视频流。

不必提前配置应用列表。首次实际调用指定 App 的界面工具时，Codex Harbor 会弹出置顶本地授权窗口，显示从本机读取的应用名称、Bundle ID、此次申请的读取/操作/截图权限；用户明确允许后自动继续原调用，拒绝或超时则不执行。授权只针对该 App 及所需等级，后续升级权限会再次确认。后台 Agent 仍需在 macOS **系统设置 → 隐私与安全性 → 辅助功能** 获得系统权限；单帧截图由前台 Codex Harbor 主程序通过本机受限 Unix socket 执行，因此需要单独为 **Codex Harbor 主程序**开启**屏幕与系统音频录制**权限，不能由 MCP 代替用户授权。

应用授权与 Workspace Allowed Roots **完全独立**，MCP 只能申请权限，只有 Codex Harbor 本地弹窗中的用户点击才能新增授权；目标窗口变化后必须重新选择，系统授权弹窗不能通过该能力自动批准。关闭主界面时不采集任何画面，截图仅在明确调用 `ui_capture` 时执行。通用快捷键与屏幕坐标拖动暂未开放，避免绕过控件校验造成误操作；持续视频镜像和远程观看端也尚未实现。

### 日志与诊断

- stdout / stderr 和审计摘要会经过常见 Token / API Key 脱敏
- Relay 持久化请求元数据与 Usage，不保存完整请求/响应正文
- Diagnostic Bundle 默认排除 Runtime Key、API Key、Authorization Header 和 Allowed Root 绝对路径
- MCP 内部诊断调用不会伪装成 ChatGPT 的工具目录发现

## 架构

Codex Harbor 使用 SwiftUI 为主、AppKit 补充，核心业务与 UI 分层：

```mermaid
flowchart TB
    UI[CodexHarbor · SwiftUI/AppKit]

    UI --> CORE[CodexHarborCore]
    UI --> BRIDGE[ChatGPTBridgeCore]

    CORE --> CFG[Codex Configuration]
    CORE --> PROF[Profiles & Credentials]
    CORE --> TEL[Telemetry & Relay]
    CORE --> TASK[Task Migration]

    BRIDGE --> MCP[MCP Router]
    BRIDGE --> SEC[Permissions & Security]
    BRIDGE --> CMD[Command / Workflow]
    BRIDGE --> CT[Coding Task]
    BRIDGE --> TRANS[Secure Tunnel / HTTPS]

    AGENT[HarborChatGPTAgent] --> BRIDGE
```

主要 Target：

| Target | 职责 |
| --- | --- |
| `CodexHarbor` | macOS App、页面、ViewModel、交互 |
| `CodexHarborCore` | Codex 配置、连接档案、Telemetry、Relay、任务迁移 |
| `ChatGPTBridgeCore` | MCP、Workspace、权限、命令、诊断、Transport、Coding Task |
| `HarborChatGPTAgent` | 独立本地 Agent，承载 MCP Server 和接入链路 |

## 系统要求

### 运行

- macOS 14 或更高
- Codex CLI（使用 Codex 连接功能时）
- ChatGPT 侧具备可配置 MCP Server 的环境（使用 ChatGPT 接入时）
- 网络连接（首次下载 tunnel-client / cloudflared 或使用公网接入时）

Transport Installer 当前同时包含 Apple Silicon（arm64）与 Intel（x86_64）资源选择逻辑。

### 从源码开发

- Xcode / Swift 6 工具链
- Git
- macOS Command Line Tools

不要求 Node、npm 或 Homebrew 才能运行 ChatGPT 接入。

## 下载与安装

从 [Releases](../../releases) 下载最新的 macOS 压缩包，解压后将 `Codex Harbor.app` 放入“应用程序”。

构建脚本会优先沿用已安装 Agent 的签名证书，并自动识别有效的 **Apple Development / Developer ID Application** 证书或本机固定名称的自签名证书；`HarborChatGPTAgent` 使用 `com.codexharbor.agent` 代码签名标识。

**不付费、仅在自己的 Mac 上开发：** 打开「钥匙串访问」→ 菜单「钥匙串访问」→「证书助理」→「创建证书」，将名称设为 `Codex Harbor Local Code Signing`，身份类型选「自签名根证书」，证书类型选「代码签名」。保存到登录钥匙串并保留私钥；若系统不认可该证书的代码签名用途，需要在钥匙串里按需检查信任设置。创建后检查：

```bash
security find-identity -v -p codesigning
# 自动选择同名本地证书，也可显式指定：
CODEX_HARBOR_SIGN_IDENTITY="Codex Harbor Local Code Signing" ./Scripts/build-app.sh fast
```

另一种免费方法是登录 Xcode 的 Apple Account / Personal Team，创建适用于本机开发的 Apple Development 证书。它不等同于付费的 Developer ID 分发证书，也有个人团队开发限制。

本机没有有效证书时仍会明确警告并退回 **ad-hoc 签名**；这种签名的标识即使固定，也不能保证 macOS 的辅助功能和「屏幕与系统音频录制」授权在重新编译后保留。**真正解决更新后反复失去 TCC 授权，仍需要持续使用相同的有效证书和代码身份**。从旧的 ad-hoc 版本第一次迁移到证书签名版，仍可能需要手动授权一次。不要通过自动更改 TCC 数据库来绕过用户权限。

截图需用户另行在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」授权 Codex Harbor 主程序；后台 Agent 不直接调用截图框架，主程序只处理按需授权的单窗口截图，不通过 `screencapture` 绕过系统权限。如果 macOS 首次打开应用时提示来源未验证，可以在 Finder 中 Control 点击应用并选择“打开”。

正式 Developer ID 公证及自动更新发布流水线仍需独立配置。

## 快速开始

### 1. 配置 Codex 连接

打开 **Codex 连接**：

1. 添加账户登录、托管密钥或自定义 API
2. 检测连接状态
3. 选择目标连接并切换
4. 回到“概览”确认当前真实连接

Codex Harbor 会在切换时保护原配置，不需要手工编辑 `~/.codex/config.toml`。

### 2. 配置 ChatGPT 接入

打开 **ChatGPT 接入**：

1. 添加允许访问的项目目录
2. 选择“OpenAI 本地管道”或“公网 HTTPS”
3. 完成该方式所需配置
4. 启动并检测链路
5. 使用页面中的“去 ChatGPT 配置”完成 MCP Server 配置

页面会分别显示 Agent、MCP、Transport、远端入口和 ChatGPT 调用状态，便于定位故障发生在哪一层。

### 3. 使用本地开发能力

接入后，ChatGPT 可以在授权 Workspace 中执行类似流程：

```text
打开项目
→ 搜索/读取代码
→ 精准 Patch
→ 查看 Git Diff
→ 测试
→ 构建
→ 修复失败
→ 再验证
```

对于完整的“修改并测试/构建/打包”请求，优先使用 `coding_task` 维持一个连续 Task ID。

## 从源码构建

### 运行 Debug App

```bash
swift run CodexHarbor
```

### 编译

```bash
swift build
```

### 测试

```bash
swift test
```

测试使用临时目录和隔离配置，不应修改真实的 `~/.codex`。

### 持续集成与性能验收

GitHub Actions 的 macOS 工作流会运行测试、Release 打包、签名和 Info.plist 检查；Developer ID 签名与 Apple 公证仍需要另行配置凭据。

分别在前台静止、后台静止、连接切换等场景执行：

```bash
./Scripts/benchmark-idle.sh 30 2
```

输出位于 `dist/performance/`，包括 App、Agent、Tunnel CPU 平均值与峰值、RSS 峰值。短时采样不能代替 Instruments 或长期内存检查。

安装新版后，如需从独立终端安全重启 GUI（有等待审批的请求则拒绝重启）：

```bash
./Scripts/restart-installed-app.sh
```

安装脚本默认不强制退出正在使用的 App。构建号按 Git 提交数量生成，并在 Info.plist 写入提交哈希；精确打在 `vX.Y.Z` 标签上时才更新公开版本号。

### 构建 Release App

快速 Release 编译并安装：

```bash
./Scripts/build-app.sh fast
```

完整优化编译：

```bash
./Scripts/build-app.sh full
```

仅生成 Release App，不替换 `/Applications`，适用于 Coding Task 或 CI 风格验证：

```bash
./Scripts/build-app.sh fast --no-install
```

复用已有 Release 二进制，只重新打包：

```bash
./Scripts/build-app.sh package-only
```

产物：

```text
dist/Codex Harbor.app
```

默认安装脚本包含：

1. 防止重复构建的进程锁
2. Release 编译
3. Staging App 组装
4. ad-hoc codesign
5. Info.plist / 签名静态校验
6. 安全替换 `/Applications/Codex Harbor.app`
7. 暂存上一版本
8. Agent 重载
9. `/health` 与 MCP Catalog 校验
10. 失败时自动恢复上一版本

安装后的验证状态写入：

```text
/tmp/codexharbor-install-verify.status
/tmp/codexharbor-install-verify.log
```

## MCP 兼容性

当前 MCP Server：

- Server Name：`Codex Harbor Local`
- Server Version：`0.3.0`
- 现代协议：`2026-07-28`
- 保留旧协议兼容握手
- Tool Catalog 版本根据工具定义自动计算

健康端点示例：

```bash
curl http://127.0.0.1:19473/health
```

响应包含：

```json
{
  "status": "ok",
  "protocolVersion": "2026-07-28",
  "toolCatalogVersion": "3.0-23-...",
  "toolCount": 23,
  "host": "127.0.0.1",
  "port": 19473
}
```

如果 Harbor 已更新工具，而当前 ChatGPT 会话仍显示旧 Catalog，重新连接 MCP 或新建会话即可触发新的 `tools/list`。

## 数据目录

Codex 原生数据仍位于：

```text
~/.codex/
```

Codex Harbor 自己的连接、Telemetry、Profile、事务与 Relay 数据位于：

```text
~/Library/Application Support/Codex Harbor/
```

ChatGPT Bridge 的独立配置、权限、运行状态、凭据与审计数据位于：

```text
~/Library/Application Support/CodexHarbor/ChatGPTBridge/
```

> 不建议手工编辑这些运行态文件。连接与权限设置应通过 Codex Harbor UI 完成。

## 项目结构

```text
CodexHarbor/
├── Resources/
│   ├── AppIcon.icns
│   └── Info.plist
├── Scripts/
│   ├── build-app.sh
│   ├── verify-installed-app.sh
│   └── reload-and-verify-installed-app.sh
├── Sources/
│   ├── CodexHarbor/               # macOS App / SwiftUI / AppKit
│   ├── CodexHarborCore/           # Codex 配置、连接、Telemetry、Relay
│   ├── ChatGPTBridgeCore/         # MCP、权限、Workspace、Workflow、Coding Task
│   └── HarborChatGPTAgent/        # 独立 MCP Agent
├── Tests/
│   ├── CodexHarborCoreTests/
│   └── ChatGPTBridgeCoreTests/
├── Package.swift
├── DESIGN.md
├── PRODUCT.md
└── README.md
```

## 测试覆盖

测试重点覆盖：

- Codex 配置事务、切换与恢复
- 多 Profile 凭据和连接状态
- 历史任务迁移与回滚
- Relay Protocol 与 Usage
- Auth / Relay 文件变化监听
- Workspace 路径安全
- Patch / Unified Diff
- Git 状态与 Diff
- 命令超时、取消和输出流
- Workflow Session
- Coding Task 完整生命周期与 Repair
- MCP Discovery / tools/list / tool call
- Local MCP / Tunnel / HTTPS 健康检查
- Runtime Key 与 Transport 生命周期
- Diagnostic Bundle 脱敏
- 安装后 Agent / Catalog 一致性

提交改动前建议至少运行：

```bash
swift test
git diff --check
```

## 当前边界

为了避免把未实现能力写进 README，当前版本有以下明确边界：

- 仅支持 macOS
- 默认构建仍是 ad-hoc 签名，尚未提供 Developer ID 公证发布流水线
- “使用统计”目前主要统计 Codex 请求、Token、延迟和成功率
- ChatGPT 接入能记录 MCP 调用审计和诊断，但不能代表整个 ChatGPT 账号的消息数、Token 或订阅额度
- OpenAI 本地管道需要相应 Tunnel 配置；公网 HTTPS 需要相应 Cloudflare/域名配置
- ChatGPT 会话可能缓存旧 MCP Tool Catalog，工具变化后可能需要重新连接或新建会话
- Coding Task 只在存在可识别的验证/打包工作流时自动进入闭环，不会在无法验证的项目里先修改再宣告成功

## 开发原则

对 Codex Harbor 的修改应尽量保持这些约束：

- **真实状态优先**：UI 不用缓存状态覆盖 Codex 实际配置
- **失败可恢复**：配置切换、安装和迁移都必须保留回滚路径
- **权限最小化**：ChatGPT 只访问明确授权的 Workspace
- **精准修改**：优先 Patch，不使用无必要的整文件重写
- **验证闭环**：修改后运行针对性测试，再执行完整验证
- **统计口径稳定**：UI 重构不得改变现有请求/Token/趋势统计定义
- **秘密不进日志**：任何 Token、Key、Authorization 信息必须脱敏

## Contributing

欢迎通过 Issue 或 Pull Request 改进项目。

建议流程：

1. Fork / 创建独立分支
2. 保持改动范围清晰
3. 为行为变化补充测试
4. 运行 `swift test`
5. 运行 `git diff --check`
6. 不要在提交中包含真实 Token、Runtime Key、账号凭据或本地绝对路径

## License

Codex Harbor 使用 [MIT License](LICENSE)。

---

如果你正在调试连接问题，优先查看应用中的 **ChatGPT 接入 → 检测**；如果是 MCP 工具数量或版本不一致，先比较运行时 `/health` 的 `toolCatalogVersion` 与 ChatGPT 当前会话发现的 Catalog。
