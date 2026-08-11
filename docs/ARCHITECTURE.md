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
                            ↓
              DashboardView / ExportDataView
```

`SyncCoordinator` 是 UI 与平台客户端之间的唯一协调层。视图不会直接调用远程 API；只有用户点击对应平台的同步按钮时才会发起网络请求。

## 本地存储

| 数据 | 存储位置 | 说明 |
| --- | --- | --- |
| 游戏记录、时长、最近游玩、奖杯 | SwiftData | `GameRecord`，保留完整同步结果 |
| PlayStation 刷新令牌 | Keychain | `AfterFirstUnlockThisDeviceOnly` |
| Nintendo session token | Keychain | `AfterFirstUnlockThisDeviceOnly` |
| 平台昵称、同步时间、PS 奖杯汇总 | UserDefaults | 非敏感展示状态 |
| 游戏封面 | Application Support | URL 的 SHA-256 作为文件名，排除 iCloud 备份 |

首页的“低时长旧游戏”规则仅控制展示：游玩不足 60 分钟且超过 6 个月未玩的记录不会出现在首页或平台游戏库，但不会从 SwiftData 删除，分析导出仍可读取完整数据。

## PlayStation 同步

1. 从 Sony 登录页读取 NPSSO。
2. 交换 OAuth access token 与 refresh token。
3. 分页读取所有游戏记录。
4. 比较 `lastPlayedAt` 与 `trophiesSyncedAt`，仅刷新新增或最近玩过的游戏奖杯。
5. 以 `ps:<titleId>` 为唯一键写入 SwiftData。

## Nintendo 同步

1. 使用 PKCE 创建 Nintendo Account 授权请求。
2. 通过 `ASWebAuthenticationSession` 接收自定义 Scheme 回调。
3. 交换长期 session token，再获取短期 access token。
4. 读取 Nintendo Store Play Activity。
5. 以 `switch:<titleId>` 为唯一键写入 SwiftData。

## UI

- `DashboardView`：总览与平台视图、排序、同步入口。
- `ConnectPlayStationView` / `ConnectNintendoView`：平台授权。
- `ExportDataView`：纯本地筛选、预览和复制。
- `CachedCoverImage`：优先读取 `CoverImageStore` 的磁盘缓存，缺失时下载并持久化。

## 接口变更

外部接口分别封装在：

- `Services/PlayStationAPIClient.swift`
- `Services/NintendoAPIClient.swift`

若平台接口发生变化，应优先修改对应客户端的请求头、数据结构和错误解析，避免把平台细节扩散到视图或 SwiftData 模型中。
