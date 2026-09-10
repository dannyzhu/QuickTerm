# 人工启动检查（每次构建必做）

单元测试跑不到这条路：测试宿主里 `restoreSession()` 整段跳过，而且 TCC（隐私授权）在
进程内没法模拟。**从终端直接跑二进制也验不了**——那条路的 TCC 责任进程是已获授权的终端，
永远是通的。必须用 LaunchServices 拉起来（`open` / Dock / Finder）。

## 背景：为什么会挂

macOS 把 `~/Desktop`、`~/Documents`、`~/Downloads` 划成受保护目录。授权记在 TCC 里，
按**代码签名身份**绑定；本项目是 ad-hoc 签名（`CODE_SIGN_IDENTITY: "-"`），身份就是 cdhash，
所以**每重新构建一次就换一个身份**，已有的授权立刻不适用。

这时候如果进程是被 LaunchServices 拉起来的，tccd 既不弹窗也不拒绝：`open(2)` 就那样
永远挂着（0% CPU）。复原会话时 libghostty 在 `ghostty_surface_new` 里同步打开存档里的 cwd，
于是整个 app 卡死在 `applicationDidFinishLaunching`，一个窗口都出不来。

代码里的防线是 `Sources/Windowing/WorkingDirectoryGate.swift`：受保护根目录先用一条独立线程
带超时地试着 `open`，探不通就退回引擎默认目录，pane 照常起。治本的做法是换成稳定的签名身份
（Developer ID，或至少一张长期留在登录钥匙串里的自签证书），那样授权跨构建就能留下来。

## 步骤

1. 构建 Debug（`xcodebuild -scheme QuickTerm -configuration Debug build`），记下产物路径。
2. 准备一份存档副本，里面的终端 `pwd` **必须**有几个在 `~/Documents` / `~/Desktop` /
   `~/Downloads` 底下，并且至少有两个窗口和一个带标签的浏览器 pane：

   ```
   cp ~/Library/Application\ Support/QuickTerm/state.json /tmp/qt-check.json
   ```

3. 用 LaunchServices 启动（**不要**直接跑二进制），把存档与 socket 指到别处，
   免得抢用户那份会话：

   ```
   mkdir -m 700 -p /private/tmp/qt-check     # socket 的目录必须是自己的、0700、且不是符号链接
   open -n /path/to/QuickTerm.app \
     --env QUICKTERM_STATE_FILE=/tmp/qt-check.json \
     --env QUICKTERM_CONTROL_SOCKET=/private/tmp/qt-check/c.sock
   ```

   （`--env QUICKTERM_CONTROL_SOCKET=/tmp/...` 会失败：`/tmp` 是指向 `/private/tmp` 的符号链接，
   `ControlSocket.prepareDirectory` 会拒绝，控制面就不监听了。）

4. **要求：5 秒内窗口出现，且每个屏幕的 pane 都在。** 没出现就是又挂了——
   `sample QuickTerm 3` 看主线程，栈底若是 `__openat` 就是本文说的这个坑。
5. 再验五条：
   - 没有存档时（`QUICKTERM_STATE_FILE` 指到一个不存在的路径）→ 一个新窗口 + 一个终端；
   - `open -n QuickTerm.app --args --open-browser https://example.com` → 起来后多一个浏览器 pane；
   - `quickterm --socket /private/tmp/qt-check/c.sock state --json` 能返回完整的世界
     （屏幕数 / pane 数与存档一致，浏览器 pane 也在）；
   - **在复原出来的 pane 里手打** `echo $QUICKTERM_SOCKET`，要打印
     `/private/tmp/qt-check/c.sock`。空 = 控制 socket 绑晚了：环境变量是 spawn 那一刻烤进
     pane 的，之后再开服也补不回来，那样 pane 里的 agent 会去驱动用户那台真正的 QuickTerm。
     （只能手打：pane 的 shell 是 setuid 的 `login` 拉起来的，`ps -E` 看不到它的环境。）
   - **启动 2 秒后**（防抖存档已落盘）看 `/tmp/qt-check.json`：原来在 `~/Documents` 下的
     那些 `pwd` 必须还在，没被改写成家目录。二进制没授权时 shell 其实是起在家目录的
     （`lsof -a -p <shell pid> -d cwd` 可证），但存档里必须留着用户自己的目录，
     见 `SurfaceView.deniedWorkingDirectory`。同一个目录下还应多出一份
     `state.previous.json`（本进程第一次写盘前留的保命副本）。
6. 收尾：关掉这个实例（`kill` 掉那个 pid），删掉 `/tmp/qt-check.json` 与 `/private/tmp/qt-check`。

## 自动化那一半

`Tests/WorkingDirectoryGateTests.swift` 用「永不应答的探针」把 TCC 挂住的环境搬进用例，
覆盖真实的 `restoreSession(from:)`（两块屏幕、5 个工作区、多个 `~/Documents` 下的终端、
一个多标签浏览器 pane），断言每个 pane 都建得出来且整段及时返回。
它抓得住「代码把 cwd 直接怼给引擎」的回归，抓不住启动机制本身——那一半靠上面的人工检查。
