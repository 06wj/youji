# 游迹隐私政策 / YouJi Privacy Policy

生效日期 / Effective date: 2026-08-13

## 简体中文

游迹（YouJi）是一款本地优先的个人游戏活动资料库。本政策说明游迹如何处理数据。

### 本机数据

游戏记录、游玩时长、奖杯、同步快照、Switch 每日活动、封面缓存、私人备注、收藏、游玩状态、AI 会话、游戏人格和待玩清单默认保存在用户设备上。游迹不包含广告、跨应用跟踪或自建分析服务。

平台会话令牌和用户填写的 AI API Key 保存在 iOS Keychain；它们不会进入游戏数据库、完整备份、CSV 或诊断摘要。非敏感偏好和同步状态保存在 App 自身的 UserDefaults。

### 游戏平台请求

只有用户主动连接或同步时，游迹才会请求 PlayStation 或 Nintendo 服务。请求会携带完成身份验证所必需的平台凭据。游迹不会要求或保存平台账号密码。平台如何处理请求受其各自隐私政策和条款约束。

### AI 请求

只有用户主动生成分析、发送聊天消息或测试连接时，游迹才会请求用户在设置中选择的 OpenAI Chat Completions 兼容服务。默认接口由策量智算提供，用户可以改为其他 HTTPS 兼容接口。

人格分析发送当前筛选游戏的名称、平台、累计时长和已有奖杯比例。聊天发送创建会话时冻结的同类游戏信息以及当前对话内容。游迹不会向模型服务发送游戏平台凭据、平台账号 ID、封面、私人备注或完整本地备份。模型服务对请求数据的保留和处理遵循该服务商自己的政策，用户应只配置自己信任的服务。

### 导出、删除与通知

用户可以导出完整 JSON 备份或 CSV，合并恢复 JSON 备份，删除单个历史账号档案，或清除游戏数据库、封面缓存、账号显示身份与同步状态。删除全部本地数据时会保留 Keychain 中的平台凭据和 AI API Key；用户可以再单独断开游戏平台并清除 AI API Key。断开平台默认保留本地游戏历史。

每周同步提醒默认关闭。只有用户主动开启并允许系统通知后，游迹才会安排本地通知；通知不会触发后台同步。

### 联系与变更

如需反馈隐私问题，请通过 [GitHub Issues](https://github.com/06wj/youji-ios/issues) 联系。若数据处理方式发生实质变化，本政策和应用内说明会随版本更新。

## English

YouJi is a local-first personal game activity library. This policy explains how YouJi handles data.

### On-device data

Game records, play time, trophies, synchronization snapshots, Switch daily activity, cached covers, private notes, favorites, play status, AI conversations, generated profiles, and play plans are stored on the user's device by default. YouJi contains no advertising, cross-app tracking, or first-party analytics service.

Platform session tokens and the user's AI API key are stored in the iOS Keychain. They are never included in the game database, complete backup, CSV export, or diagnostic summary. Non-sensitive preferences and synchronization state are stored in app-only UserDefaults.

### Platform requests

YouJi contacts PlayStation or Nintendo services only when the user explicitly connects or synchronizes. Requests include platform credentials required for authentication. YouJi does not request or store platform account passwords. Each platform processes requests under its own privacy policy and terms.

### AI requests

YouJi contacts the OpenAI Chat Completions-compatible service selected in Settings only when the user explicitly generates an analysis, sends a chat message, or tests the connection. The default endpoint is provided by Celitech; users may configure another compatible HTTPS endpoint.

Profile requests include the selected games' titles, platforms, cumulative play time, and available trophy ratios. Chat requests include the same categories of game information frozen when the conversation was created, plus the current conversation. YouJi does not send platform credentials, platform account IDs, covers, private notes, or a complete local backup to the model service. Request retention and processing are governed by the selected provider's policy, so users should configure only a provider they trust.

### Export, deletion, and notifications

Users can export a complete JSON backup or CSV, merge-restore a JSON backup, remove one historical account archive, or clear the game database, cover cache, displayed account identity, and synchronization state. Clearing all local data preserves platform credentials and the AI API key in Keychain; users can disconnect each platform and clear the AI API key separately. Disconnecting a platform preserves local game history by default.

The weekly synchronization reminder is off by default. YouJi schedules a local notification only after the user enables it and grants notification permission. A notification never starts background synchronization.

### Contact and changes

For privacy questions, contact the project through [GitHub Issues](https://github.com/06wj/youji-ios/issues). If data handling changes materially, this policy and the in-app disclosure will be updated with the relevant release.
