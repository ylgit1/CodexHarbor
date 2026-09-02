# Codex Harbor

Codex Harbor 是一个原生 macOS Codex 配置管理器。它提供：

- 输入激活密钥后一键部署 Codex 服务配置
- 在 Harbor 服务与现有 ChatGPT 账户之间切换
- 统一管理三类连接：账户登录、托管密钥、自定义 API 密钥
- 多账户与多 API 密钥档案切换，自动识别当前 Codex 真实配置
- 切换模式后可在重新载入时安全迁移全部历史任务到当前连接
- 同步迁移任务 JSONL 与 SQLite 索引，迁移前自动创建可回滚备份
- 原子写入、配置验证、失败回滚
- 卸载时精确恢复部署前的 `config.toml` 内容与权限
- 使用仅当前 macOS 用户可读（`0600`）的 Harbor 私有凭据文件，避免反复弹出 Keychain 授权

## 下载与安装

在 [Releases](../../releases) 下载最新的 `Codex-Harbor-macOS-*.zip`，解压后将 `Codex Harbor.app` 拖入“应用程序”。

当前安装包使用 ad-hoc 签名，macOS 首次打开若提示来源未验证，请在 Finder 中按住 Control 点击应用并选择“打开”。正式的 Developer ID 公证版本将在后续发布中提供。

## 本地运行

```bash
swift run CodexHarbor
```

## 测试

```bash
swift test
```

测试只操作临时目录，不会访问或修改真实的 `~/.codex`。

## 构建 macOS 应用

```bash
./Scripts/build-app.sh
```

产物位于 `dist/Codex Harbor.app`。开发构建使用 ad-hoc 签名；正式分发时应替换为 Developer ID 签名和公证流程。
