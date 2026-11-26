# 本地文字助手 · Local Text Assistant for macOS

macOS 菜单栏助手。开启辅助功能权限后，在其他应用中选中文字，浮动面板会显示以下操作：

- **英文润色**：把选区译成自然英文，或润色已有英文。
- **译为中文**：把选区译成简体中文。
- **智能清理**：清理多余空格、断行和标点，核对字词与数字是否保留。
- **加入 To Do**：识别独立待办并逐项选择。同一申请的步骤和要求归到一条任务的备注。
- **朗读**：使用 macOS 系统语音朗读中文和英文。也可以从菜单栏停止。

前三项使用本机 Ollama。结果可以编辑、复制，或在应用支持时替换原选区。选区读取和替换取决于前台应用的辅助功能支持。可从菜单栏暂停浮动面板。

## 截图翻译和识别

- **⌘⇧Z** 框选截图并翻译成简体中文。译文在可编辑窗口中显示，点「复制」才写入剪贴板。
- **⌘⇧Q** 框选并识别截图中的文字和公式，公式用 LaTeX 表示，识别后自动复制。
- 两项均可从菜单栏打开。全局快捷键依赖辅助功能权限，启用时会接管对应快捷键。

## 从源码构建

需要 macOS 26 或更新版本、支持 macOS 26 的 Xcode 命令行工具与系统 Python 3。翻译、清理、截图识别和任务提取还需要安装 [Ollama](https://ollama.com/download/mac)，并先下载模型。

```sh
ollama pull qwen3.5:4b
sh build.sh
open "build/Local Text Assistant.app"
```

从菜单栏选择「启用选区功能」并按系统提示开启辅助功能权限。使用截图功能时另需屏幕录制权限。权限变更后可能需要重新打开应用。

## 可选 · 连接 Microsoft To Do

安装 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos)，然后在仓库目录运行：

```sh
pwsh -NoProfile -Command 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
pwsh -NoProfile -File ./graph_todo.ps1 -Operation connect
```

按提示在 Microsoft 官方登录页面完成设备登录。默认使用个人 Microsoft 账号。工作或学校账号可用 `-Tenant organizations` 重试，能否授权取决于组织策略。应用使用委托权限 `Tasks.ReadWrite`，写入登录账号的默认 Tasks 列表。登录过期时可重新运行连接命令。

任务先在本机提取。识别到多项时，勾选要加入的任务。单条任务、带备注或待核对的任务可在确认窗口修改标题、截止日期和备注。同一申请的原文可作为备注保留，具体的截止时间和时区也会留在备注里。

确认后，所选任务的标题、截止日期及备注会发给 Microsoft Graph。授权缓存、账号与列表绑定以及用于防重复提交的记录均保存在本机。

## 数据处理

模型请求使用本机回环地址。截图在处理过程中写入临时目录，识别结束后删除。模型可能误识别公式符号或日期，请在使用前核对预览。
