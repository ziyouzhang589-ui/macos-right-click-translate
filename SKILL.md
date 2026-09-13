---
name: macos-right-click-translate
description: 在 macOS 上安装、更新、排障或卸载「中英快译」——选中文字后右键即可就地弹出中英互译的菜单栏小工具，在 Claude、VS Code 等 Electron 应用里也能用，使用系统本机翻译、无需 API Key。当用户想要右键翻译、划词翻译、选中即翻译，或提到中英快译、右键没有翻译、睡眠后翻译失效时使用。Install, update, troubleshoot, or uninstall a macOS right-click Chinese⇄English translator.
---

# 中英快译（macOS 右键翻译）

本 skill 所在目录下有：

- `app/`：应用源码（Swift，无 Xcode 工程，`swiftc` 直接编译）
- `scripts/install.sh`：建签名证书 → 测试 → 编译 → 安装 → 交给 launchd 常驻。可重复运行，也用于更新
- `scripts/create-signing-cert.sh`：只建证书（`install.sh` 会自动调用）
- `scripts/uninstall.sh`：卸载

下文的 `<skill>` 指本 SKILL.md 所在目录。

## 安装

1. **先向用户说明要做的事并征得同意**：会在登录钥匙串里创建一张本地自签名证书、编译应用、安装到 `~/Applications`、写入 `~/Library/LaunchAgents/com.local.bilingual-translator.plist` 实现开机自启和常驻。
2. 确认环境：
   - `sw_vers -productVersion` 需 ≥ 15（依赖系统 Translation 框架）
   - `xcode-select -p` 能输出路径。没有的话运行 `xcode-select --install`，会弹系统对话框，**让用户自己点「安装」**，装完再继续
3. 运行 `<skill>/scripts/install.sh`（编译两个架构约 1～2 分钟，超时要给够）。
4. 首次安装时应用会弹出「开启辅助功能」引导。请用户：系统设置 → 隐私与安全性 → 辅助功能 → 打开「中英快译」。**打开即生效，无需重启应用。**
5. 验证：`tail ~/Library/Logs/BilingualTranslator.log` 出现 `监听已装上` 即成功。也可让用户点菜单栏书本图标，看到「右键翻译　已启用」。

## 用法（告诉用户）

- **选中文字 → 右键** → 译文浮层弹在鼠标旁。中文译英文，英文译简体中文
- 没选中文字时右键，应用自己的菜单照常出现
- 浮层上有「拷贝译文」「拷贝原文」「在窗口中打开」；`Esc`、点别处或 `×` 关闭
- 首次翻译时 macOS 可能要求下载中英语言包，点允许即可
- 应用只在菜单栏显示书本图标，不占程序坞

## 更新

改了 `app/` 里的代码后重新运行 `scripts/install.sh`。因为签名证书固定，**辅助功能授权不会失效**，不用让用户重新打开。

## 排障

先看两处：菜单栏图标里的状态行，以及日志 `~/Library/Logs/BilingualTranslator.log`（每次右键被接管还是放行、依据哪一层判断都有记录，不记录文字内容）。

| 现象 | 原因与处理 |
|---|---|
| 系统设置里开关亮着，右键却没翻译；日志没有「监听已装上」 | 应用签名变过，旧授权作废但开关还显示开启。运行 `tccutil reset Accessibility com.local.bilingual-translator`，重新打开应用，让用户重新授权。确认 `codesign -dvv ~/Applications/中英快译.app` 的 Authority 是 `BilingualTranslator Local Code Signing` 而不是 ad-hoc，否则每次重编都会掉 |
| 右键出来的是应用自己的菜单 | 看日志：`右键放行：无选中迹象` 说明判定为没选中文字（正常）；日志完全没有这次右键说明监听没装上，按上一行处理 |
| 访达里右键文件出现翻译 | 不应发生，访达在前台时只信任辅助功能读到的文字。检查是否为旧版本，重新运行 `install.sh` |
| 睡眠唤醒后不工作 | `launchctl print gui/$(id -u)/com.local.bilingual-translator` 查看状态。`KeepAlive` 必须是无条件的 `true`：系统睡眠时是以 exit code 0 正常结束应用的，`SuccessfulExit: false` 不会拉起 |
| 浮层闪一下就没 / 看不见 | 看日志「浮层显示」一行的尺寸和位置，尺寸为 0×0 或不在任何屏幕内即为布局问题 |

**测权限时不要直接执行 `.app/Contents/MacOS/BilingualTranslator`**：从终端启动的进程，辅助功能授权会按终端算，结果永远是「未授权」，测不准。用 `open` 或 `launchctl kickstart`。

## 卸载

先征得用户同意，再运行 `<skill>/scripts/uninstall.sh`。应用移入废纸篓（可恢复），launchd 任务、授权记录、日志一并清除。签名证书保留，脚本会打印删除命令，由用户决定是否删除。

## 设计要点（改代码前读）

详见 `app/README.md`。核心几条：

- **为什么不用系统「服务」菜单**：Electron 应用的右键菜单是网页自绘的，系统无法插入条目。所以用 `CGEvent.tapCreate` 自己监听右键
- **Chromium 系应用在鼠标抬起时才弹菜单**：必须把配对的 `rightMouseUp` 一起吞掉，按序列判断而不是按修饰键判断
- **Claude 里辅助功能常读不到选中文字**：退而看最近有没有划选或双击，再模拟 ⌘C 取词，取词后还原剪贴板；取到的是文件就放弃并补发右键
- **事件抽头回调放独立线程**：放主线程会因界面渲染超时被系统停用
