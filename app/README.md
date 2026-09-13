# 中英快译 · 实现说明

> 安装请看仓库根目录的 README 或运行 `scripts/install.sh`。本文记录实现细节与踩过的坑。

一个适用于 macOS 15 或更高版本的本机中英文翻译小工具。

## 使用

- **在任何应用里选中文字，右键 →「服务」→「中英快译」**，译文会就地弹在鼠标旁边，
  不跳转窗口、不需要复制粘贴。可在 系统设置 → 键盘 → 键盘快捷键 → 服务 → 文本
  里给它绑快捷键。
- **选中文字后右键**，在任何应用里就地弹出译文，包括 Claude、VS Code 这类
  自绘右键菜单的应用。没有选中文字时右键照常弹出应用自己的菜单。
  需要「辅助功能」权限。
- 浮层按 `Esc`、点击别处或右上角 `×` 关闭；需要编辑或换方向时点「在窗口中打开」。
- 启动后直接粘贴或输入文字，停止输入约半秒后自动翻译。
- 中文内容自动翻译为英文，英文内容自动翻译为简体中文。
- 按 `Control + Option + T` 抓取当前选中的文字并立即翻译；未选中文字时，
  该快捷键仍然只是显示或隐藏窗口。取词需要「辅助功能」权限。
- 按 `Command + Enter` 立即翻译，按 `Escape` 或 `Command + W` 隐藏窗口。
- 应用常驻菜单栏（书本图标），不占程序坞；主窗口从该图标打开。

首次翻译时，macOS 可能请求下载中英文语言包。翻译由系统的 Translation
框架在本机处理，不需要 API Key。

## 右键翻译（服务菜单）

`Info.plist` 中的 `NSServices` 向系统声明了一个接收纯文本的服务，
`TranslationServiceProvider` 接收选中的文字后交给 `QuickResultController`，
在鼠标位置弹出浮层显示译文。主窗口只在用户主动打开应用时出现。
构建后把应用放进 `/Applications` 或 `~/Applications`，系统才会收录该服务。
若菜单中没有出现，刷新服务缓存后重新打开应用：

```bash
/System/Library/CoreServices/pbs -flush
```

少数应用（部分 Electron、Java 程序）的右键菜单不提供「服务」子菜单，
这些地方请改用取词快捷键。

## 右键翻译（辅助功能）

Electron、Java 等应用的右键菜单由应用自身绘制，系统无法向其中插入条目，
`NSServices` 在这些应用里不会出现。`RightClickWatcher` 因此用
`CGEvent.tapCreate` 监听鼠标事件，仅在判定「当前有选中文字」时截获右键。

判定分两层：先由 `AccessibilitySelection` 通过辅助功能接口直接读取选中内容；
Chromium 系应用常常读不到，此时退而依据最近的鼠标动作——划选或双击留下
选中迹象，普通单击将其清除。两层都判定没有选中就原样放行。

访达（含桌面）里框选的是文件，这套猜测会把文件名当文字翻译并吞掉原生菜单，因此访达在前台时只信任辅助功能读取，读不到直接放行；模拟拷贝若拿到的是文件（如打开/存储对话框），同样放弃并交还右键。

判定失误时（以为有选中、实际没有）会补发一次带标记的右键交还给应用，
应用的菜单照常弹出。选中文字后应用自身的右键菜单会被接管，因此浮层上
提供了「拷贝原文」。

事件抽头运行在独立线程：系统对回调有严格的超时限制，超时会直接停用抽头，
而主线程随时可能忙于界面渲染或翻译。

授权后无需重启：应用会轮询权限状态，一旦获得授权立即装上监听。

## 常驻与自启

应用以 `.accessory` 策略运行，只在菜单栏显示图标，不占用程序坞与 Cmd+Tab。

常驻由 launchd 托管（`~/Library/LaunchAgents/com.local.bilingual-translator.plist`），
首次运行自动安装。这里有两个必须踩过才知道的点：

- **不能用 `SMAppService` 的登录项**。它只在登录时启动一次，睡眠唤醒不重新
  登录，进程被系统收掉后无人拉起，睡一觉功能就没了。
- **`KeepAlive` 不能用 `SuccessfulExit: false`**。系统在睡眠期间是以
  「正常退出」（exit code 0）的方式收掉应用的，只认异常退出会让它一去不回。
  因此这里用无条件 `KeepAlive`；用户从菜单主动退出时先 `bootout` 解除本次
  会话的托管，plist 保留，下次登录照常自启。

此外 `Info.plist` 声明 `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination`
为 false，并在启动时调用 `disableSuddenTermination()`，从源头减少被回收的概率；
唤醒后还会自检事件抽头是否被系统停用。

菜单栏菜单会显示右键翻译当前是否已启用，未授权时点击可直接前往授权。

## 排查

运行日志位于 `~/Library/Logs/BilingualTranslator.log`，记录每次右键是被
接管还是放行、依据哪一层判断、选中文字如何读取，以及浮层的实际位置与尺寸。

## 取词翻译（辅助功能）

`SelectionCapture` 在热键按下时向前台应用发送一次 ⌘C 取走选中的文字，
随后还原用户原有的剪贴板内容，译文同样以浮层就地显示。它不经过菜单，
因此在 Claude、VS Code、Slack 等自绘右键菜单的 Electron 应用中同样可用。

首次按 `⌃⌥T` 取词时会引导前往 系统设置 → 隐私与安全性 → 辅助功能 授权，
**勾选后需要退出并重新打开应用**。

`build.sh` 使用固定的自签名证书 `BilingualTranslator Local Code Signing`，
使指定要求（DR）绑定证书而非 cdhash，重新构建后系统已授予的辅助功能权限
不会失效。证书缺失时会回退到 ad-hoc 签名并打印警告——那种情况下每次
重新构建都需要重新授权，需在辅助功能列表中移除旧条目再重新勾选。

创建该证书（仅需一次）：

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=BilingualTranslator Local Code Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -out cert.p12 -passout pass:temp -name "BilingualTranslator Local Code Signing"
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P temp -A
```

## 构建

需要 Xcode Command Line Tools 和 macOS 15 或更新版本的 SDK。

```bash
chmod +x build.sh test.sh
./test.sh
./build.sh
open ".build/中英快译.app"
```

构建脚本优先使用已安装的 macOS 15.4 SDK，使所有支持的系统版本都使用传统的
低延迟本机翻译模型。`build.sh` 默认生成同时支持 Apple Silicon 与 Intel 的通用应用。
只构建当前架构时：

```bash
ARCHS="$(uname -m)" ./build.sh
```
