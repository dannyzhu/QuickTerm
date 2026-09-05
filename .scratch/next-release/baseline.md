# QuickTerm 代码现状（讨论依据）

检查日期：2026-09-05。代码基线：`c5ef314`。仅静态阅读源码和已有测试，未运行应用或测试。

这些观察描述当前实现；不把历史注释中的“用户确认”延伸为下一版承诺。

## 工作区与布局

- `Sources/Windowing/RootView.swift:5` 的 WorkspaceModel 使用 layouts、floatings 和 activeIndex 管理编号工作区，默认五个；setWorkspaceCount 可调整数量。该模型没有项目名称或项目根目录字段。
- `Sources/StatusBar/StatusBarView.swift:53` 按编号展示工作区。
- `Sources/Windowing/WorkspaceLayout.swift:4` 支持 scrolling 与 dwindle；`Sources/Windowing/FloatingPane.swift:6` 单独记录浮动 pane 及几何位置。
- `Sources/Windowing/MainWindowController.swift:1105` 新终端继承来源 pane 的工作目录。这不等于建立了项目级工作区关系。

## 键位与焦点

- `Sources/Config/KeybindingMap.swift:55` 的默认表中，⌘L 切换布局，⌘T 切换浮动，⌘F 放大 pane；浏览器地址栏使用 ⌘⇧L，新标签使用 ⌘N。
- `Sources/Windowing/MainWindowController.swift:225` 在事件分发前执行命中的窗口管理动作。浏览器专属动作按焦点 pane 类型决定是否消费，当前该层没有地址栏或网页输入框的文本编辑豁免。
- `Sources/Config/KeybindingMap.swift:29` 支持配置覆盖与解绑，可作为后续兼容方案的实现基础，尚未决定要提供何种默认方案。

## 浏览器

- `Sources/Panes/BrowserPaneView.swift:155` 使用共享默认网站数据存储；同文件的 addTab、导航委托和 WKUIDelegate 实现多标签、导航及弹窗处理。
- `Sources/Panes/BrowserPaneView.swift:465` 可在系统浏览器打开当前 URL；同文件下载委托将文件保存到 Downloads。
- `Sources/Config/ConfigStore.swift:120` 定义首页、搜索、UA、Web Inspector 和标签条配置。
- 这些代码不足以证明所有第三方登录和网站都兼容；候选场景确定后才能选择需要验证的网站与流程。
- `Sources/GhosttyEmbed/Ghostty.App.swift:734` 的终端链接处理最终经 `NSWorkspace.shared.open` 打开系统应用；内嵌浏览器存在不等于终端链接默认进入它。
- `Sources/Panes/BrowserPaneView.swift:50` 对裸 `localhost:3000` 补 HTTPS，完整 `http://localhost:3000` 则保留协议；`Tests/BrowserPaneTests.swift:6` 明确测试该行为。
- `Sources/Panes/BrowserPaneView.swift:679` 的下载完成和失败回调为空，能保存下载与提供下载反馈是不同能力。

## 状态恢复

- `Sources/Windowing/MainWindowController.swift:401` 存档包含布局、浮动层和活动工作区；saveState 的生产调用位于 `Sources/App/AppDelegate.swift:79` 的正常退出回调。本次源码检索未发现定时或逐次变更保存的调用。
- `Sources/GhosttyEmbed/Surface View/SurfaceView_AppKit.swift:1796` 的终端存档包含目录、UUID 和标题。解码时新建 surface；该格式不保存终端进程或滚屏内容。
- `Sources/Panes/BrowserPaneView.swift:501` 保存标签 URL、标题与活动标签索引，恢复时重新创建并加载网页；该快照不记录网页表单、滚动位置或前进后退历史。
- `Sources/Windowing/MainWindowController.swift:419` 读取失败或版本不支持时返回失败，启动走新建流程。正常退出恢复与异常退出恢复需要分别讨论。

## 待讨论而非结论

核心用户、主要场景、键位取舍、项目与工作区关系、浏览器职责、恢复承诺及交付顺序都尚未确定。对应的问题保存在本事项的独立决策任务中。
