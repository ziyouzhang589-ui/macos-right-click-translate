# 中英快译 · macOS 右键翻译

**选中文字，点右键，译文就弹在鼠标旁边。** 中文译英文，英文译简体中文。

> **English:** A macOS menu-bar utility that pops up a Chinese⇄English translation right next to the cursor when you right-click selected text. Works in Electron apps (Claude, VS Code, Slack) whose context menus can't be extended by the system. Uses Apple's on-device Translation framework — no API key, nothing leaves your Mac. Ships as a Claude Code skill.

- **任何应用都能用**，包括 Claude、VS Code、Slack 这类右键菜单由应用自绘、系统无法往里加条目的 Electron 应用
- **不影响原本的右键**：没选中文字时，应用自己的菜单照常出现；访达里右键文件也不受影响
- **本机翻译**：用 macOS 自带的 Translation 框架，不需要 API Key，文字不出本机
- **常驻不打扰**：只在菜单栏显示图标，开机自启，睡眠唤醒后自动恢复

## 环境要求

- macOS 15 或更新（Apple Silicon 与 Intel 均可）
- Xcode 命令行工具：`xcode-select --install`

## 安装

### 方式一：交给 Claude Code（推荐）

这个仓库本身就是一个 [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills)：

```bash
git clone https://github.com/ziyouzhang589-ui/macos-right-click-translate.git ~/.claude/skills/macos-right-click-translate
```

然后对 Claude 说「帮我装中英快译」。它会检查环境、编译、安装，并带你开启权限。以后遇到右键没翻译、睡醒后失效等问题，也可以直接问它，排障步骤都写在 [SKILL.md](SKILL.md) 里。

### 方式二：手动

```bash
git clone https://github.com/ziyouzhang589-ui/macos-right-click-translate.git
cd macos-right-click-translate
./scripts/install.sh
```

脚本会依次完成：创建本地签名证书 → 运行测试 → 编译 → 安装到 `~/Applications` → 设置开机自启。编译大约需要一到两分钟。

装好后应用会弹出引导。到 **系统设置 → 隐私与安全性 → 辅助功能**，打开「中英快译」，立即生效，不用重启应用。

以后更新代码，重新运行 `./scripts/install.sh` 即可，不需要重新授权。

## 使用

1. 在任意应用里**选中一段文字**
2. **点右键**，译文浮层出现在鼠标旁边
3. 浮层上可以「拷贝译文」「拷贝原文」，或「在窗口中打开」继续编辑、换翻译方向
4. 按 `Esc`、点别处或点右上角 `×` 关闭

第一次翻译时，macOS 可能提示下载中英文语言包，点允许即可。

其他入口：

- **`⌃⌥T`**（Control + Option + T）：翻译当前选中的文字；没选中时打开或隐藏主窗口
- **右键 → 服务 → 中英快译**：仅限使用系统原生菜单的应用
- **菜单栏书本图标**：打开主窗口手动输入翻译、查看右键翻译是否已启用、开关开机自启、退出

## 已知限制

- **选中文字后，应用自己的右键菜单会被翻译浮层取代。** 浮层上的「拷贝原文」可以代替最常用的拷贝。不选中文字时右键一切照旧
- **判断「是否选中了文字」有时靠推测。** Claude 等 Electron 应用通常读不到选中内容，程序会根据你最近是否划选或双击来判断，再模拟一次 ⌘C 取词（取完还原剪贴板）。偶尔误判时，会把右键还给应用，菜单稍慢一点出现
- 目前只支持中文和英文互译，需要 macOS 15 或更新版本

## 为什么要这些权限

- **辅助功能**：监听鼠标右键、读取当前选中的文字。没有它就做不到在任意应用里右键翻译
- **本地签名证书**：安装脚本会在你的登录钥匙串里创建一张自签名证书给应用签名。否则每次重新编译，macOS 都会把它当成新程序，已给的辅助功能授权会静默失效。证书只在本机使用
- **LaunchAgent**：写入 `~/Library/LaunchAgents/com.local.bilingual-translator.plist`，负责开机自启和进程意外退出后自动拉起

翻译完全在本机进行，应用本身不联网。日志在 `~/Library/Logs/BilingualTranslator.log`，只记录每次右键的处理路径和文字长度，**不记录文字内容**。

## 排障

遇到问题先看菜单栏书本图标里的状态行，再看日志：

```bash
tail -20 ~/Library/Logs/BilingualTranslator.log
```

**系统设置里开关是开的，右键却没有翻译**：日志里没有「监听已装上」，说明旧授权已作废但开关还亮着。运行下面两行，再到辅助功能里重新打开「中英快译」：

```bash
tccutil reset Accessibility com.local.bilingual-translator
open ~/Applications/中英快译.app
```

**右键出来的是应用自己的菜单**：日志里有「右键放行：无选中迹象」，说明程序没判断出你选了文字，重新选中一次再右键。

**睡眠唤醒后没反应**：运行 `launchctl print gui/$(id -u)/com.local.bilingual-translator | grep state`，不是 `running` 的话重新运行 `./scripts/install.sh`。

用 Claude Code 装的话，把现象直接告诉 Claude 也行，[SKILL.md](SKILL.md) 里有更完整的排障步骤。

## 卸载

```bash
./scripts/uninstall.sh
```

应用会移入废纸篓。签名证书保留，脚本会打印删除命令。

实现细节和踩过的坑见 [app/README.md](app/README.md)。

## 许可证

[MIT](LICENSE)
