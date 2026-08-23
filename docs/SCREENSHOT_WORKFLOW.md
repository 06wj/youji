# 真机截图工作流

这套流程用于在不依赖 iPhone 镜像、不修改真实数据的前提下，把 Debug 版本直接打开到指定页面，再由 Xcode 保存真机原始 PNG。截图入口只在 `DEBUG` 构建中存在，不进入 Release 行为。

## 准备

1. 用数据线或无线调试连接一台已信任、已开启开发者模式的 iPhone。
2. 保持 iPhone 解锁。
3. 在 Xcode 的 Devices and Simulators 中复制设备 Identifier，并设置：

```bash
export YOUJI_SCREENSHOT_DEVICE='<真机 UDID>'
```

## 拍摄一张

例如打开 PlayStation 页面：

```bash
scripts/capture-device-screenshot.zsh playstation
```

脚本会依次完成当前 Debug 版本的真机构建、安装和页面直达。页面稳定后：

1. 打开 Xcode → Window → Devices and Simulators。
2. 选择同一台 iPhone。
3. 点击 Take Screenshot。
4. 把 Xcode 生成的 PNG 保存为脚本提示的路径。

不得缩放、裁切或转成 JPEG。iPhone 17 Pro Max 的当前原图尺寸为 `1320 × 2868`，其他机型应保留各自的原始尺寸和宽高比。

## 页面与文件

| 页面参数 | PRD 文件 |
| --- | --- |
| `overview` | `docs/screenshots/prd/overview.png` |
| `playstation` | `docs/screenshots/prd/playstation.png` |
| `switch` | `docs/screenshots/prd/switch.png` |
| `play-calendar` | `docs/screenshots/prd/play-calendar.png` |
| `game-detail-switch` | `docs/screenshots/prd/game-detail-switch.png` |
| `game-detail-playstation` | `docs/screenshots/prd/game-detail-playstation.png` |
| `game-detail-playstation-trophies` | `docs/screenshots/prd/game-detail-playstation-trophies.png` |
| `account-sync` | `docs/screenshots/prd/account-sync.png` |
| `insights` | `docs/screenshots/prd/insights.png` |
| `plans` | `docs/screenshots/prd/plans.png` |
| `ai-analysis` | `docs/screenshots/prd/ai-analysis.png` |
| `ai-profile-history` | `docs/screenshots/prd/ai-profile-history.png` |
| `ai-chat-list` | `docs/screenshots/prd/ai-chat-list.png` |
| `ai-chat` | `docs/screenshots/prd/ai-chat.png` |
| `data-management` | `docs/screenshots/prd/data-management.png` |
| `privacy` | `docs/screenshots/prd/privacy.png` |

README 使用同一轮原图：`overview`、`playstation`、`switch`、`ai-analysis` 和 `ai-chat` 分别复制到 `docs/screenshots/` 下对应的 PNG 文件。

## 发布前检查

- 所有 PRD 和 README 图片都是 Xcode 真机截图生成的 PNG。
- 同一批图片使用同一台设备和同一显示模式。
- 不纳入登录授权页、API Key、完整账号 ID、安全诊断或系统通知。
- 用 `sips -g pixelWidth -g pixelHeight <图片>` 检查未发生缩放。
- 更新 PRD 的截图日期和页面说明。
