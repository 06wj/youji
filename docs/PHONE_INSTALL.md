# 用 GitHub 编译，在 iPhone 上安装与续签

GitHub Actions 负责把源代码编译为 `YouJi-unsigned.ipa`。AltStore / SideStore 用你的 Apple 账号在手机上完成签名和安装。这样在首次配置后，日常更新和续签可以不打开 Mac。

仅下载 IPA 不能直接安装。免费 Apple 账号的安装描述文件仍只有 7 天有效期，云端编译不会延长有效期；没有更新代码时，只需续签已安装的版本，无须每周重新编译。

## 首次准备

1. 先在游迹的“数据管理”导出完整 JSON 备份，保留现有 App。
2. 按 [AltStore Classic 安装指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) 用 Mac 完成首次安装，并使用当前给游迹签名的 Apple 账号。
3. 在 AltStore 设置中选择 **Set up Remote AltServer**，按提示配对并安装 LocalDevVPN。见 [远程续签指南](https://faq.altstore.io/altstore-classic/remote-altservers)。
4. 后续在手机上连接 Wi-Fi 并开启 LocalDevVPN，即可安装、更新、续签。配对失效或续签工具自身过期时，可能仍需电脑重新配置。

也可使用 [SideStore](https://docs.sidestore.io/docs/installation/prerequisites)。按其当前文档检查 iOS 版本兼容性；它同样需要首次电脑安装，后续通过 Wi-Fi 和 LocalDevVPN 工作。

## 从 GitHub 获取新版本

工作流文件需先提交到仓库的默认分支 `main`，GitHub 才会显示手动运行入口。

1. 用 iPhone 的 Safari 登录 GitHub，打开仓库 **Actions → Build iPhone IPA**。
2. 点击 **Run workflow**，选择分支并运行。
3. 测试与编译成功后，打开本次运行，在摘要链接或 **Artifacts** 中下载 `YouJi-unsigned.ipa` 到“文件”。下载需要仓库读取权限。
4. 在 AltStore 的 **My Apps** 页面用 **+** 导入这个 IPA，完成签名和安装。
5. 更新时保留同一 Apple 账号与 App 标识，不要先删除旧 App；若工具更改标识而生成独立 App，可用第一步的 JSON 备份恢复游戏档案。平台登录和 AI Key 不包含在备份中。

工作流只手动运行，使用 GitHub 的标准 macOS runner 和 Xcode 26.2，先跑单元测试，再生成 Release 真机安装包。IPA 保留 14 天，过期后可重新运行工作流。它不需要 Apple 密码、证书、描述文件或仓库 Secrets，也不会接触手机数据。公开仓库可免费使用标准 runner；私有仓库按 GitHub Actions 的额度和计费规则执行。

## 日常续签

开启 AltStore 的后台刷新，并定期检查剩余天数；必要时在 **My Apps → Refresh All** 手动续签。远程模式需要 Wi-Fi 和 LocalDevVPN，后台刷新并不保证每次成功。更新游迹代码才需要重新从 GitHub 下载 IPA。

## 本地复现构建

在安装 Xcode 的 Mac 上执行：

```bash
bash scripts/build-unsigned-ipa.sh
```

产物为 `build/unsigned-ipa/YouJi-unsigned.ipa`，临时构建目录自动清理。该文件仍须经安装工具签名，不能直接安装到 iPhone。

参考：[Apple 免费账号限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[GitHub 下载构建产物](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)、[GitHub runner 规则](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。
