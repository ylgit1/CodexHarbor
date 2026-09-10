# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Users

macOS 上使用 Codex 的个人开发者与多连接用户。他们需要在 ChatGPT 账户、托管密钥和自定义 API 之间可靠切换，并能确认 Codex 当前真正使用的连接。

## Product Purpose

Codex Harbor 是原生 macOS 连接管理器。它集中保存连接档案、检查可用性、执行安全切换，并在需要时重新载入 Codex，同时保持现有任务与配置数据安全。

## Positioning

Harbor 不只是编辑 `config.toml`：它以事务方式识别和切换 Codex 的真实连接状态，管理本地凭据，并针对不同 API 协议隔离不兼容的历史任务。

## Operating Context

- 用户在 Codex 运行期间查看连接状态、查询托管密钥用量并切换连接。
- 连接切换后可能需要重新载入 Codex。
- 账户登录通过 Codex 官方流程完成；托管密钥和自定义 API 使用 Harbor 的本地私有凭据存储。

## Capabilities and Constraints

- 三类连接：账户登录、托管密钥、自定义 API 密钥。
- 支持多账户、多密钥档案的添加、检查、切换和删除；当前连接不可直接删除。
- 托管密钥支持查询已用、剩余和生效日期。
- 自定义 API 显示真实地址与当前模型，但主界面不提供模型目录或模型更新操作。
- 外部 API 默认只用于新任务，历史任务保持原连接语义。
- 业务逻辑由现有 `AppModel` 和 `CodexHarborCore` 提供，界面重构不得改变配置事务语义。

## Brand Commitments

- 产品名称为 Codex Harbor。
- 保留现有蓝色 Harbor 应用图标。
- 界面使用简体中文，遵循原生 macOS 交互与可访问性约定。

## Evidence on Hand

- 应用图标：`Resources/AppIcon.icns`
- 已确认三种连接状态原型：位于 `/Users/mac/.codex/generated_images/01a05b94-a993-79f3-bb9d-c3b18cb7e35f/`
- 现有功能与测试：`Sources/`、`Tests/`

## Product Principles

- 页面显示必须以 Codex 的真实配置为准。
- 切换失败不得破坏原配置、凭据或任务。
- 左侧管理连接资产，右侧只呈现当前连接详情与模式专属操作。
- 重要状态一眼可辨，说明文字保持克制。
- 所有模式共享一致的日志、状态和反馈组件。
