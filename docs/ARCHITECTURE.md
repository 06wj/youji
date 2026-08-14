# 架构说明

## 数据流

```text
平台登录
  ├─ PlayStation WebView → NPSSO → OAuth 刷新令牌
  └─ Nintendo 系统网页登录 → session token
                              ↓
                      SyncCoordinator
                       ↙           ↘
       PlayStationAPIClient       NintendoAPIClient
                       ↘           ↙
                       SyncedGame
                            ↓
                 SwiftData / GameRecord
                            ↓ 每次成功同步
                    PlaySnapshot 历史快照
                            ↓
             DashboardView / AIAnalysisView
                            ↓
            AIChatListView / AIConversation
                            ↓
                       AIChatView
                            ↓ 用户主动生成或发送
                 AIAnalysisClient → 文本模型接口
```

`SyncCoordinator` 是 UI 与游戏平台客户端之间的唯一协调层。只有用户点击对应平台的同步按钮时才会请求游戏平台。AI 分析和聊天是独立的显式操作，由对应视图把所需的最小字段交给 `AIAnalysisClient`。

## 本地存储

| 数据 | 存储位置 | 说明 |
| --- | --- | --- |
| 游戏记录、时长、最近游玩、奖杯 | SwiftData | `GameRecord`，按平台账号隔离当前累计值 |
| 每次同步的累计值 | SwiftData | `PlaySnapshot`，保存游戏、账号、平台、时间、累计分钟与已获奖杯 |
| Switch 每日游玩 | SwiftData | `DailyPlayActivity`，按账号、游戏与自然日唯一保存精确分钟数 |
| AI 会话、消息、游戏上下文快照 | SwiftData | `AIConversation`，用于会话列表、继续聊天和删除会话 |
| AI 人格历史 | SwiftData | `AIProfileResult`，按账号范围保存生成时间、筛选条件和结果文本 |
| 待玩与重温清单 | SwiftData | `SavedGamePlan`，保存手动计划或从 AI 回答沉淀的灵感 |
| PlayStation 刷新令牌 | Keychain | `AfterFirstUnlockThisDeviceOnly` |
| Nintendo session token | Keychain | `AfterFirstUnlockThisDeviceOnly` |
| AI API Key | Keychain | 用户在设置中填写，只在生成分析时读取 |
| AI 模型名称 | UserDefaults | 非敏感配置，默认 `deepseek-r1` |
| 平台昵称、同步时间、PS 奖杯汇总 | UserDefaults | 非敏感展示状态 |
| 游戏封面 | Application Support | URL 的 SHA-256 作为文件名，排除 iCloud 备份 |

首页的“低时长旧游戏”规则仅控制展示：游玩不足 60 分钟且超过 6 个月未玩的记录不会出现在首页或平台游戏库，但不会从 SwiftData 删除，AI 分析仍可读取完整数据。
用户可以在“已隐藏”筛选中找到这些记录，并对单款设置始终显示；也可以手动隐藏、收藏、标记游玩状态和添加只保存在本机的私人备注。

`GameRecord.applicationID` 使用 `<platform>:<accountID>:<titleID>`，例如 `ps:123:NPWR00001_00`。升级前没有账号字段的记录会在该平台首次成功同步时归入当前账号。断开账号只清除凭据和当前身份，不删除游戏或快照；连接其他账号后，界面只读取新账号的数据。

## 历史快照

每次平台同步完成后，会为该账号下的每款游戏写入一条 `PlaySnapshot`：

```swift
PlaySnapshot(
    gameID: String,
    accountID: String,
    platform: GamePlatform,
    date: Date,
    totalMinutes: Int,
    trophiesEarned: Int
)
```

快照保存平台返回的累计值，不替代 `GameRecord`。后续可以用相邻快照的差值计算最近 7 天、30 天或年度新增时长与奖杯数。
`PlayInsightCalculator` 已把这些差值用于“游玩洞察”。没有足够同步时间点时展示零变化并解释数据如何积累，不会用累计总量冒充区间增量。

## 每日游玩记录

Nintendo 返回最近 7 个自然日的逐日游戏分钟数。同步时会先合并同一天同一游戏的重复条目，再以 `<platform>:<accountID>:<titleID>:<yyyy-MM-dd>` 写入 `DailyPlayActivity`。重复同步只更新同一条记录，已经滚出 Nintendo 七日窗口的历史记录不会删除。升级后首次打开首页还会用现有 `weeklyMinutes` 和该记录最后同步时间回填已有七日数据。

PlayStation 当前接口没有逐日分钟明细，因此不会用快照区间增量伪造精确日期；游玩日历目前只展示 Switch 的精确记录。

## PlayStation 同步

1. 从 Sony 登录页读取 NPSSO。
2. 交换 OAuth access token 与 refresh token。
3. 从 access token 取得稳定账号 ID，分页读取所有游戏记录。
4. 游戏分页完成后立即写入 `GameRecord`，奖杯接口故障不会阻止游戏列表更新。
5. 比较 `lastPlayedAt` 与 `trophiesSyncedAt`，仅处理新增或最近玩过的游戏。
6. 奖杯保持逐款串行请求；每款成功后立即写入，单款失败保留旧值并在下次同步重试。认证失效则停止并要求重新连接。
7. 单独读取账号奖杯汇总；失败不会回滚已经写入的游戏和单款奖杯。
8. 写入本次 `PlaySnapshot`。

## Nintendo 同步

1. 使用 PKCE 创建 Nintendo Account 授权请求。
2. 通过 `ASWebAuthenticationSession` 接收自定义 Scheme 回调。
3. 交换长期 session token，再获取短期 access token。
4. 读取 Nintendo Store Play Activity。
5. 使用 Nintendo 用户 ID 隔离账号，以 `switch:<accountID>:<titleID>` 写入 SwiftData。
6. 增量写入最近七日的 `DailyPlayActivity`，保留此前日期。
7. 写入本次 `PlaySnapshot`。

## UI

- `DashboardView`：总览与平台视图、排序、同步入口，以及按日期分组的 Switch 游玩日历。
- `GameDetailView`：单款游戏时间线、奖杯/每日记录、收藏、隐藏、状态和私人备注。
- `AccountCenterView`：当前连接身份、分平台同步时间、同步变化回执和离线历史账号档案。
- `InsightsView` / `SavedPlansView`：7 天、30 天、年度快照变化，以及待玩与重温行动清单。
- `DataManagementView`：完整 JSON 备份、合并恢复、CSV、诊断摘要和本地数据删除。
- `ConnectPlayStationView` / `ConnectNintendoView`：平台授权。
- `AIAnalysisView`：本地筛选、AI 人格分析、依据预览和辅助复制。
- `AIChatListView`：展示持久化会话，支持新建、继续和确认删除。
- `AIChatView`：展示当前会话并即时保存消息，不展示内部游戏上下文。
- `AIPrompts`：集中维护共享的“游戏大脑”身份、游戏信息序列化、人格任务和聊天任务提示词。
- `SettingsView`：配置 AI API Key、模型名称和 HTTPS 接口，测试连接，管理同步提醒、数据和隐私入口。
- `AIAnalysisClient`：仅在用户点击生成、发送或测试连接时，调用用户配置的 OpenAI Chat Completions 兼容文本接口；默认是策量智算。
- `ProductDataService`：不接触 Keychain，负责版本化备份、合并恢复、CSV、无敏感字段诊断、快照洞察和本地提醒。
- `CachedCoverImage`：优先复用有内存上限的已解码缩略图，其次读取 `CoverImageStore` 的磁盘缓存，缺失时下载并持久化。

## AI 分析

1. AI 分析页先在本地按平台和最低时长筛选，顺序固定为时长降序。
2. 用户点击“生成游戏人格”后，从 Keychain 读取 API Key，从 UserDefaults 读取模型名称。
3. 只发送筛选结果的游戏平台、名称、累计时长和奖杯比例，不发送平台令牌、账号 ID、封面或完整 SwiftData 数据。
4. 请求使用 `POST https://api.celitech.com.cn/v1/chat/completions`，不启用流式输出。
5. 返回结果只展示在当前分析页，可单独复制；切换筛选会清除旧结果，避免把旧分析误认为新筛选结果。
6. 每次成功结果按当前账号范围写入 `AIProfileResult`，可以回看并生成只含分析文本的分享图片。
7. 系统提示由 `AIPrompts` 生成，共用“游戏大脑”身份并叠加人格分析规则；没有奖杯值的游戏不会生成奖杯字段。

## AI 聊天

1. 聊天独立于人格分析筛选。新建会话时，读取当前账号全部严格大于 60 分钟的游戏，转换为平台、名称、累计时长和已有奖杯比例，并冻结为该会话的游戏上下文快照。
2. 游戏信息由 `AIPrompts` 写入系统提示，不作为气泡展示；没有奖杯值的游戏直接省略奖杯字段，也不描述平台字段差异。
3. 用户每次发送时，请求会包含系统提示、此前的用户问题、AI 回答和本次问题，以支持基础多轮对话；用户消息和 AI 回答都会即时写入 `AIConversation`。
4. 会话记录带有由当前 PS/NS 连接身份直接组成的 `accountScopeKey`，不从已有游戏反推账号；历史档案使用显式的平台账号 token。列表只展示同一范围的会话，避免尚无游戏或切换账号时串历史。
5. 会话列表按最近更新时间排序，可继续、新建或滑动删除，不再提供容易误触的整段重置入口。
6. 收到第二次 AI 回答后，后台用最近对话额外请求一次 4～12 字的短标题；失败不影响聊天，并在后续回答后重试。
7. 回答支持复制、停止和失败重试；AI 回答可以保存为同账号范围的待玩灵感。
8. 聊天不触发游戏平台同步，也不发送平台凭据、账号 ID、封面、私人备注或完整备份。

## 备份与隐私清单

完整 JSON 备份采用版本化 `YouJiBackup`，包含游戏、自定义字段、同步快照、每日活动、AI 会话、人格历史和清单。恢复采用按唯一标识 upsert，备份中的同一记录更新本机值，备份外的本机记录不删除。Keychain 和 UserDefaults 中的平台凭据、AI API Key、当前身份与同步状态不进入备份。若某个平台没有当前身份但只有一个本地历史账号，首页会自动展示该档案；存在多个历史账号时仍需在账号中心明确选择，避免混合不同账号。“删除全部本地数据”同时清除 SwiftData、封面缓存、账号显示身份和同步状态，但按界面说明保留 Keychain 凭据，供用户再次主动同步或单独清除。

`PrivacyInfo.xcprivacy` 随 App target 打包：声明不跟踪，声明用户主动 AI 请求涉及的游戏内容和其他用户内容，并以 `CA92.1` 说明 `UserDefaults` 只读写 App 自身可访问的偏好状态。

## 接口变更

外部接口分别封装在：

- `Services/PlayStationAPIClient.swift`
- `Services/NintendoAPIClient.swift`

若平台接口发生变化，应优先修改对应客户端的请求头、数据结构和错误解析，避免把平台细节扩散到视图或 SwiftData 模型中。
