<p align="center">
  <img src="YouJi/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="112" alt="游迹 App 图标">
</p>

<h1 align="center">游迹 · PlayLog</h1>

<p align="center">
  把 PlayStation 与 Nintendo Switch 的游戏生涯，收进同一个本地游戏库。
</p>

游迹是一款为主机玩家设计的 iPhone App。它集中展示 PS4 / PS5 与 Nintendo Switch 的游戏时长、最近游玩、奖杯和近 7 天活动，让分散在不同平台的记录变成一份清晰、长期可回看的个人游戏档案。

## App 截图

<p align="center">
  <img src="docs/screenshots/overview.jpg" width="23%" alt="游迹总览">
  <img src="docs/screenshots/playstation.jpg" width="23%" alt="PlayStation 游戏与奖杯">
  <img src="docs/screenshots/switch.jpg" width="23%" alt="Switch 近 7 天游玩">
  <img src="docs/screenshots/export.jpg" width="23%" alt="筛选并导出给 AI 分析">
</p>

## 你可以用游迹做什么

### 一个游戏库看完两台主机

- 分别连接 PlayStation 与 Nintendo Account，需要时单独同步。
- 在“总览 / PlayStation / Switch”之间快速切换。
- 合并统计总游戏时间、游戏数量与最近游玩。
- 优先显示平台提供的官方中文名称。
- 封面首次加载后保存在本机，再次打开无需重复下载。

### 查看 PlayStation 奖杯

- 查看奖杯等级、升级进度和白金 / 金 / 银 / 铜数量。
- 每款游戏直接显示奖杯数量、完成率和白金标记。
- 可按“白金优先、完成率其次”的奖杯规则排序。
- 奖杯使用增量更新，没有新游玩记录时不会重复请求。

### 回顾 Switch 近 7 天活动

- 查看最近 7 天每天的游玩时长。
- 显示本周活跃天数与本周最常玩的游戏。
- 游戏列表保留总时长与最近游玩时间，不显示无意义的进度条。

### 整理真正重要的游戏

- 默认按游玩时长排序，也可切换到最近游玩。
- 首页自动隐藏“游玩不足 1 小时且超过半年未玩”的记录，减少试玩和误启动带来的干扰。
- 隐藏只影响首页展示，不删除任何本地记录。

### 导出给 AI 分析

- 按 PlayStation、Switch 或全部平台筛选。
- 筛选大于 1 / 2 / 10 / 50 小时的游戏。
- 带封面预览游戏名称、时长和奖杯完成率。
- 一键复制文本，可交给任意 AI 做偏好、类型与时间投入分析。
- 导出始终读取完整本地数据，不受首页隐藏规则影响。

## 使用方式

1. 点击首页右上角蓝色 **PS** 或红色 **NS** 按钮。
2. 在平台官方页面完成账号授权。
3. 再次点击对应按钮即可单独同步该平台。
4. 切换总览或平台页面，查看游戏、奖杯与近期活动。
5. 点击“分析导出”，筛选并复制需要的数据。

PlayStation 当前只提供每款游戏的累计时长和最近游玩时间，不提供逐日时长；Switch 页面因此拥有独立的近 7 天统计。

## 数据与隐私

- 不读取或保存 PlayStation / Nintendo 账号密码。
- PlayStation 刷新令牌与 Nintendo 长期会话令牌只保存在这台 iPhone 的 Keychain。
- 游戏记录、筛选、排序和分析导出均在本地完成。
- 只有用户主动点击 PS / NS 同步按钮时才会访问平台服务。
- 仓库不包含任何个人账号、令牌或本地游戏数据。

---

## 开发与运行

### 环境

- iOS 17+
- Xcode 26（推荐）
- Swift 6

### 运行项目

1. 克隆仓库并打开 `YouJi.xcodeproj`。
2. 在 Xcode 的 **Signing & Capabilities** 中选择自己的开发团队。
3. 安装到真机时，将 Bundle Identifier 改为自己账号下的唯一值。
4. 选择 `YouJi` Scheme 后运行。

```bash
xcodebuild \
  -project YouJi.xcodeproj \
  -scheme YouJi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

模拟器适合浏览界面；实际同步需要在真机上完成平台账号授权。

### 实现

- SwiftUI：界面与交互
- SwiftData：本地游戏记录
- Swift Charts：Switch 近 7 天活动
- AuthenticationServices / WebKit：平台网页登录
- Keychain Services：会话令牌
- CryptoKit：封面缓存文件名

游戏封面保存在 `Application Support/YouJi/Covers`，平台令牌使用 `AfterFirstUnlockThisDeviceOnly` 级别写入 Keychain。

### 项目结构

```text
YouJi/
├── Assets.xcassets/       # App 图标与品牌资源
├── Design/                # 颜色与通用视图样式
├── Models/                # SwiftData 游戏模型
├── Services/              # 平台同步、Keychain 与封面缓存
├── Views/                 # 首页、登录和分析导出
└── YouJiApp.swift         # App 入口

docs/
├── ARCHITECTURE.md        # 数据流、存储与同步设计
└── screenshots/           # README 截图（JPG，已移除 EXIF）
```

详细的数据流和平台同步逻辑见 [架构说明](docs/ARCHITECTURE.md)。

使用 AI 协助开发前，请先阅读 [AI 贡献指南](AGENTS.md)，其中记录了产品不可变约束、数据安全边界与验证方式。

### 接口说明

PlayStation 与 Nintendo 的游戏记录接口都不是面向第三方开发者的稳定公开 API。平台升级后，请优先检查：

- `YouJi/Services/PlayStationAPIClient.swift`
- `YouJi/Services/NintendoAPIClient.swift`

## 免责声明

本项目为个人学习与自用项目，与 Sony Interactive Entertainment 或 Nintendo 无关联。PlayStation、PS4、PS5、Nintendo Switch 及相关商标归各自权利人所有。

## 许可证

本项目使用 [MIT License](LICENSE)。
