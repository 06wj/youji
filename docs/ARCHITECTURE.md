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
| 游戏记录、时长、最近游玩、奖杯 | SwiftData | `GameRecord`，按平台账号隔离当前累计值；平台数据更新时间与用户编辑时间分开记录 |
| 每次同步的累计值 | SwiftData | `PlaySnapshot`，保存游戏、账号、平台、时间、累计分钟与已获奖杯 |
| Switch 每日游玩 | SwiftData | `DailyPlayActivity`，用不随时区变化的 `yyyy-MM-dd` 日期键，按账号、游戏与自然日唯一保存精确分钟数 |
| AI 会话、消息、游戏上下文快照 | SwiftData | `AIConversation`，保存消息、冻结游戏上下文及独立未发送草稿，用于会话列表、继续聊天和删除会话 |
| AI 人格历史 | SwiftData | `AIProfileResult`，按账号范围保存生成时间、筛选条件、允许输入字段的指纹和结果文本 |
| 待玩与重温清单 | SwiftData | `SavedGamePlan`，保存完整标题/说明、可选完整游戏 ID 和来源会话 ID；旧记录的关联为空 |
| PlayStation 刷新令牌 | Keychain | `AfterFirstUnlockThisDeviceOnly` |
| Nintendo session token | Keychain | `AfterFirstUnlockThisDeviceOnly` |
| AI API Key | Keychain | 用户在设置中填写，只在生成分析时读取 |
| AI 模型名称 | UserDefaults | 非敏感配置，默认 `deepseek-r1` |
| 平台昵称、同步时间、PS 奖杯汇总 | UserDefaults | 非敏感展示状态 |
| 游戏封面 | Application Support | URL 的 SHA-256 作为文件名，排除 iCloud 备份 |

首页的“低时长旧游戏”规则仅控制展示：游玩不足 60 分钟且超过 6 个月未玩的记录不会出现在首页或平台游戏库，但不会从 SwiftData 删除，AI 分析仍可读取完整数据。
用户可以在“已隐藏”筛选中找到这些记录，并对单款设置始终显示；也可以手动隐藏、收藏、标记游玩状态和添加只保存在本机的私人备注。

`GameRecord.applicationID` 使用 `<platform>:<accountID>:<titleID>`，例如 `ps:123:NPWR00001_00`。升级前没有账号字段的记录会在该平台首次成功同步时归入当前账号；迁移同时重写快照和每日活动的游戏引用，并先合并收藏、备注、状态等本地字段，避免删除重复记录时丢失用户数据。断开账号只清除凭据和当前身份，不删除游戏或快照；连接其他账号后，界面只读取新账号的数据。

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
`PlayInsightCalculator` 已把这些差值用于“游玩洞察”，同时输出按游戏拆分的时长与奖杯贡献供周期详情使用。`PlayTimelineBuilder` 会将相邻快照的正向差值按游戏和自然日合并，再整理为按日期排序的游玩变化记录；Switch 已有精确每日活动时优先使用 `DailyPlayActivity`，避免和快照增量重复计算。单游戏累计图同一天只保留最后一次快照。没有足够同步时间点时展示零变化并解释数据如何积累，不会用累计总量冒充区间增量。年度月度分布按同步快照落点计算；跨月未同步的累计变化会归入下一次同步所在月份，并在界面明确说明。

## 每日游玩记录

Nintendo 返回最近 7 个自然日的逐日游戏分钟数。同步时会先合并同一天同一游戏的重复条目，再以平台响应中的自然日键 `<platform>:<accountID>:<titleID>:<yyyy-MM-dd>` 写入 `DailyPlayActivity`。日期键独立于设备时区，显示时才转换成本地日期。重复同步只更新同一条记录，已经滚出 Nintendo 七日窗口的历史记录不会删除。`NintendoAPIClient.normalize` 将映射时的自然日保存为 `SyncedGame.weeklyEndingDayKey`，协调层连同七元素数组写入 `GameRecord`。显示窗口始终是当前设备近七个自然日：精确 `DailyPlayActivity` 优先，数组只能根据合法的稳定窗口日期补充；未知日期标为缺少记录，不等同于零。旧版本没有稳定日期的数组不再从 `updatedAt` 猜测或回填日期，已持久化的每日记录继续保留。

PlayStation 当前接口没有逐日分钟明细，因此不会用快照区间增量伪造精确日期；游玩日历目前只展示 Switch 的精确记录。

## PlayStation 同步

1. 从 Sony 登录页读取 NPSSO。
2. 交换 OAuth access token 与 refresh token，但先不替换本机旧凭据。
3. 从 access token 取得稳定账号 ID并分页读取所有游戏记录；确认新会话可用后才保存 refresh token 和当前身份。
4. 游戏分页完成后立即写入 `GameRecord`，奖杯接口故障不会阻止游戏列表更新。
5. 比较 `lastPlayedAt` 与 `trophiesSyncedAt`，仅处理新增或最近玩过的游戏。
6. 奖杯保持逐款串行请求；每款成功后立即写入，单款失败保留旧值并在下次同步重试。认证失效则停止并要求重新连接。
7. 单独读取账号奖杯汇总；失败不会回滚已经写入的游戏和单款奖杯。
8. 写入本次 `PlaySnapshot`。

## Nintendo 同步

1. 使用 PKCE 创建 Nintendo Account 授权请求。
2. 通过 `ASWebAuthenticationSession` 接收自定义 Scheme 回调。
3. 交换长期 session token，再获取短期 access token，但先不替换本机旧凭据。
4. 读取 Nintendo Store Play Activity；确认新会话可用后才保存 session token 和当前身份。
5. 使用 Nintendo 用户 ID 隔离账号，以 `switch:<accountID>:<titleID>` 写入 SwiftData。
6. 增量写入最近七日的 `DailyPlayActivity`，保留此前日期。
7. 写入本次 `PlaySnapshot`。

## UI

- `DashboardView`：首次连接欢迎页与已有档案首页；紧凑总览、最近游玩、更新时间、洞察/AI/待玩入口、本地周回顾及完整游戏库。原排序和筛选不变。错误按平台给出直接重连/重试，空态按账号/同步/隐藏状态给出下一步。Switch 日历只读取所选 Switch 账号。
- `GameDetailView`：封面下提供收藏、游玩状态、加入或查看待玩计划；时间线、奖杯/每日记录和备注位于下方。修改通过隔离写入提交，失败保留原界面记录。
- `AccountCenterView`：当前连接身份、分平台同步时间、阶段进度、变化回执和离线历史账号档案；提供连接、重连和重试操作，所有请求仍经 `SyncCoordinator`。
- `InsightsView` / `SavedPlansView`：跨游戏总时间线、7 天、30 天和年度变化；同步覆盖与计算方法统一收进 info，不在主卡片展示快照/增量术语。总时间线可按最新或最早优先查看全部记录，洞察周期支持下钻到月度、游戏/奖杯贡献和单款档案；行动清单区分待行动/已完成并防止整行误触。
- `DataManagementView`：完整 JSON 备份、合并恢复、CSV、诊断摘要和本地数据删除。
- `ConnectPlayStationView` / `ConnectNintendoView`：平台授权。
- `AIAnalysisView`：恢复最近人格及原平台/时长筛选，仅显示当前条件的结果；比较允许输入字段的指纹提示主动更新。人格追问和情境按钮只准备草稿，不发请求。
- `AIChatListView`：展示持久化会话，支持新建、继续和确认删除。
- `AIChatView`：展示快照日期和款数，保存消息及未发送草稿；末条用户消息未获回复时可显式继续生成。新记录与冻结内容不同时，可另建会话，旧快照不变；新视图按 ID 从 UI 上下文取对象，避免跨上下文模型。
- `AIPrompts`：集中维护共享的“游戏大脑”身份、游戏信息序列化、人格任务和聊天任务提示词。
- `SettingsView`：从首页进入时优先展示产品与数据，从 AI 页面进入时优先展示模型配置；支持保存/测试 AI 服务，并管理同步提醒、数据和隐私入口。
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
4. 会话记录带有与首页当前展示档案一致的 `accountScopeKey`：优先使用已连接身份，未连接且只有一个本地历史账号时使用该历史身份，显式打开历史档案时使用对应平台账号 token。旧版无范围会话仅在本机账号归属唯一时自动迁移；存在多个候选账号时不猜测归属。列表只展示同一范围的会话，避免尚无游戏或切换账号时串历史。
5. 会话列表按最近更新时间排序，可继续、新建或滑动删除，不再提供容易误触的整段重置入口。
6. 收到第二次 AI 回答后，后台用最近对话额外请求一次 4～12 字的短标题；失败不影响聊天，并在后续回答后重试。
7. 回答支持复制、停止和失败重试；AI 回答可以保存为同账号范围的待玩灵感。
8. 聊天不触发游戏平台同步，也不发送平台凭据、账号 ID、封面、私人备注或完整备份。

## 备份与隐私清单

完整 JSON 备份采用版本化 `YouJiBackup` v2（继续支持读取 v1），包含游戏、自定义字段、同步快照、每日活动、AI 会话、人格历史和清单。恢复采用按唯一标识 upsert：平台累计数据与收藏、备注、隐藏、状态等用户字段分别比较更新时间；不会用旧备份覆盖本机较新的编辑，也不会因新设备先同步平台数据而漏掉备份中的私人字段。备份外的本机记录不删除，整次保存失败会回滚。Keychain 和 UserDefaults 中的平台凭据、AI API Key、当前身份与同步状态不进入备份。平台同步时间与回执按账号保存；旧版全局值只迁移给升级时的当前账号。若某个平台没有当前身份但只有一个本地历史账号，首页会自动展示该档案；存在多个历史账号时仍需在账号中心明确选择，避免混合不同账号。“删除全部本地档案”同时清除 SwiftData、封面缓存、账号显示身份和同步状态，但按界面说明保留 Keychain 凭据，供用户再次主动同步或单独清除。

`PrivacyInfo.xcprivacy` 随 App target 打包：声明不跟踪，声明用户主动 AI 请求涉及的游戏内容和其他用户内容，并以 `CA92.1` 说明 `UserDefaults` 只读写 App 自身可访问的偏好状态。

## 接口变更

外部接口分别封装在：

- `Services/PlayStationAPIClient.swift`
- `Services/NintendoAPIClient.swift`

若平台接口发生变化，应优先修改对应客户端的请求头、数据结构和错误解析，避免把平台细节扩散到视图或 SwiftData 模型中。

## 数据安全边界

- `LocalPersistence.transaction` 先提交其他页面已有编辑，再用关闭自动保存的独立 `ModelContext` 完成写入。失败时丢弃该上下文，成功后刷新受影响的界面模型。旧系统不会自动刷新已注册的跨上下文模型，因此只在写入成功后，将已落盘字段映射回界面对象并幂等保存；失败操作不会修改界面对象。这样避免 SwiftData 保存失败后，待删除或待插入对象继续留在 UI 上下文。PS 游戏列表、每款奖杯及最终快照仍分阶段持久化。
- `LocalDataRevision` 是主线程上的请求有效性标记。显式切换授权、断开、删除档案或恢复会更新标记；同步及 AI 请求在网络返回后、写入前再次检查，过期的结果和错误都不能修改新状态。重复同步入口也由协调层拦截。
- PS 时长解析支持日、时、分、秒及小数单位；奖杯计数支持整数、整数值浮点数和数字字符串。未知、缺失、负数、溢出数值及不匹配的游戏奖杯映射不会成为成功更新，也不会推进奖杯缓存时间。Nintendo 数值会在归一化和持久化前检查。
- `AIConversation` 区分空对话与无法解码的内容。旧消息缺少 ID/时间时使用稳定兼容值；真正无法读取时保留原始数据、禁止发送和自动清空。v2 备份通过可选原始字节字段保存这些内容；恢复优先使用可读内容，能用旧备份修复损坏部分，同时保留较新的可读消息。
- 恢复在修改数据库前校验格式版本、唯一标识、账号/平台/游戏一致性、日期键和数值范围；尚未收录对应游戏但账号身份一致的历史记录仍保留。旧备份缺少后续新增的集合或用户字段时使用兼容默认值。日期导出保留毫秒，读取同时支持旧版整秒日期。旧记录的用户编辑时间在合并和平台刷新之前冻结，避免把旧备注误认为新编辑。
- AI 人格请求冻结游戏列表及平台、最低时长、账号范围；筛选改变或离开页面会取消请求，结果返回时还会检查请求标识及本地档案有效性。

## 数据库启动失败

`LocalDatabaseState` 继续打开原有默认 SwiftData 存储，不新增持久化模型字段。打开失败时显示恢复页面，绝不通过删除数据库或换成空的内存库掩盖故障。原始档案导出包含数据库、存在的 WAL/SHM 和外部存储目录，使用 `.youjirecovery` 文件包；该包是原始数据副本，不是可直接合并的 JSON 备份。

用户选择 JSON 备份后，恢复先写入新的 `YouJi-Recovered-<UUID>/default.store`，完整提交后才把该目录名原子写入同目录的 `youji-active-store.json` 并切换界面；失败不切换档案；为避免旧版系统仍持有 SQLite 文件句柄，失败尝试的独立目录也暂时保留。原始数据库始终保留。已选中的恢复文件缺失时会停留在恢复界面，不会悄悄新建空库。

回归测试包含真实旧版 SQLite 模型升级、只读存储保存失败、原始损坏文件保全、旧备份兼容、重复恢复、原始对话字节往返，以及延迟网络响应与删除/恢复交错。

## 视觉层与开发预览

`Design/Theme.swift` 统一深色表面、平台色、按钮、白金标记与装饰插画。游戏库仅将封面墙 / 列表偏好存入 UserDefaults；辅助功能字号自动使用列表，不影响游戏筛选和排序。插画随 Asset Catalog 打包，不触发远程生成。封面列表沿用 512 像素解码，详情使用 1024 像素；内存缓存按尺寸区分，原始磁盘文件与下载去重仍共用同一 URL 键。

Debug 模拟器可通过 `--youji-design-preview` 使用独立内存容器查看虚构游玩数据；可搭配 `--youji-screenshot-route`。不向正式数据库插入预览数据，真机与发行构建不可启用。详见 [美术规范](DESIGN.md)。

## 2026-10-19 产品流程

`SyncCoordinator.syncProgress` 仅描述活动请求，包含平台、阶段、已完成/总项数以及列表是否已保存；`issue(for:)` 按平台保留可重连、可重试、部分成功的问题。PS 仍先保存全库，再串行补奖杯，每项立即落盘，缓存成功时间规则不变。用户关闭连接页先浏览不会取消已明确发起的导入。UI/诊断只使用受控错误文案，不展示平台原始响应。

`LibraryExperience.swift` 的日期窗口和本地周回顾不联网。周回顾只用当前账号的精确 Switch 每日活动与 PS 快照变化，首条累计快照不作为一周游玩量；PS 变化归入后一次同步日，并明确说明可能包含更早游玩。没有记录不代表没有玩。

计划关联完整 `applicationID`，不会按同名游戏混合平台或账号。开始一条关联计划在同一事务中把游戏标为“正在玩”、计划标为完成，不改平台时长和最后游玩日期。关联已移除时文字仍可读。旧空账号范围会话迁移时，同步迁移来自该会话且范围为空的计划。

完整备份仍使用 v2：新增字段可选读取，旧 SQLite 使用默认空值迁移。`AIConversation.draft` 与发送消息分开，按 `updatedAt` 合并；旧备份缺草稿字段不清除设备上的草稿，新备份明确空值表示清空。计划关联在恢复前校验账号范围；稳定窗口日期只接受合法 yyyy-MM-dd。新建或从最新记录分支的聊天仍快照全部当前账号 >60 分钟游戏，AI 只接收平台、标题、分钟和奖杯比例及用户显式发送的对话。
