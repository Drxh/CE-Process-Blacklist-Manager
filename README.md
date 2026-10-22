# CE Process Blacklist Manager

为 Cheat Engine 的“进程列表”增加一个可视化、可批量管理的进程黑名单。

当前版本：**v1.3 基线**。

> CE 6.x 已确认可用；CE 7.x 单独维护，后续修复不会影响 CE 6.x。

## 目录与版本

```text
CE6.x/
└─ CEProcessBlacklist.lua  # 已确认可用的 CE 6.x 版本

CE7.x/
└─ CEProcessBlacklist.lua  # CE 7.x 独立修复基线
```

两个目录当前都从 v1.3 基线开始。后续仅在 `CE7.x` 中修复 Cheat Engine 7.x 的兼容问题；`CE6.x` 保持稳定，避免版本互相影响。

## 功能

- 在 Cheat Engine 的 `TProcessWindow` 左下角增加一个 **“黑名单...”** 按钮。
- 打开管理器后自动读取当前运行进程。
- 左侧显示“当前运行且未拉黑”的进程。
- 右侧显示“已经拉黑”的进程。
- 支持 `Ctrl / Shift` 多选和左右列表一键全选。
- 支持批量加入、批量移除。
- 支持手动输入进程名。
- 顶部提供模糊搜索：
  - 大小写不敏感；
  - 按包含关系搜索；
  - 多个空格分隔关键词时按 AND 匹配。
- 黑名单保存到：

```text
autorun\CEProcessBlacklist.txt
```

## Cheat Engine 原生 Process Blacklist 怎么用

Cheat Engine 6.7 起原生支持：

```text
commonProcessesList.txt
```

文件放在 **Cheat Engine 安装目录根目录**，例如：

```text
F:\Program Files\Cheat Engine 6.7\commonProcessesList.txt
```

格式是一行一个进程映像名：

```text
svchost.exe
msedge.exe
chrome.exe
ChatGPT.exe
```

支持 `#` 注释：

```text
svchost.exe       # Windows Service Host
chrome.exe        # Google Chrome
```

重新打开 CE 的“进程列表”窗口后即可重新读取，不需要重启整个 CE。

### 原生功能的限制

CE 原生 `commonProcessesList.txt` 主要针对 **Processes** 标签。

原因是 CE 的原生过滤代码把列表文本的前 9 个字符（`XXXXXXXX-`，即 PID + `-`）去掉后，与 `commonProcessesList.txt` 中的内容比较：

```text
Processes:
00001234-chrome.exe
         └─ chrome.exe，可以匹配

Applications / Windows:
00001234-某个网页标题 - Google Chrome
         └─ 这里是窗口标题，不是 chrome.exe
```

因此只写 `chrome.exe` 时，原生机制可以稳定过滤 `Processes`，但无法按 EXE 名可靠过滤 `Applications / Windows`。

## v1.3 的处理方式

v1.3 继续保留“单次刷新、单次过滤”，但修正了 v1.2 在 CE 6.7 上可能跳过 `Applications / Windows` 的两个兼容点。

### Processes

仍然使用 Cheat Engine 原生 `commonProcessesList.txt`。因此 `Processes` 由 CE 自己在 `RefreshList -> filterlist -> EndUpdate` 过程中完成过滤，不需要 Lua 持续删列表。

### Applications / Windows

这两个标签仍按列表行前面的 8 位十六进制 PID 解析，再做：

```text
XXXXXXXX-窗口标题
    ↓
   PID
    ↓
PID → EXE
    ↓
CEProcessBlacklist.txt
```

v1.3 不再要求“必须识别出当前 TabIndex 是 0/2”才执行过滤，而是 **只要 CE 的可见列表真的发生变化，就对当前可见列表执行一次过滤**。这样可以避开 CE 6.7 不同 Lazarus/控件暴露方式造成的标签状态兼容问题。

PID → EXE 映射在 CE 6.7 上优先使用官方兼容的：

```text
createStringlist()
getProcesslist(list)
```

其行格式为：

```text
XXXXXXXX-process.exe
```

因此 PID 明确按十六进制解析。较新 CE 才回退使用 `getProcesslist()` table。

### 单次监听，不持续枚举进程

插件有一个轻量状态计时器，但每次只读取：

- 当前进程选择窗口是否存在；
- 当前列表数量；
- 少量列表文本；
- 当前标签状态（若 CE 暴露）。

只有检测到列表确实变化时，才调用一次 `getProcesslist` 建 PID → EXE 映射并过滤。过滤完成后保存“过滤后的列表签名”，因此插件自己删除黑名单行不会导致下一轮重复过滤。

不会像早期测试版那样每 25ms / 250ms 持续枚举进程或持续修改列表。

### 修改黑名单后立即刷新

在管理器执行加入、移除或手动添加后：

1. 保存 `CEProcessBlacklist.txt`；
2. 同步 `commonProcessesList.txt`；
3. 当前已经打开的进程选择窗口刷新一次；
4. 对刷新后的当前可见列表立即执行一次 PID → EXE 过滤。

因此无需手动关闭进程选择窗口。

## 安装

1. 完全退出 Cheat Engine。
2. 打开 Cheat Engine 的 `autorun` 目录，例如：

```text
Cheat Engine 6.7\autorun\
```

3. 删除旧版：

```text
CEProcessBlacklist.lua
```

4. 按你的 Cheat Engine 大版本选择对应文件，并把它放入 `autorun`：

   - Cheat Engine 6.x：`CE6.x\CEProcessBlacklist.lua`
   - Cheat Engine 7.x：`CE7.x\CEProcessBlacklist.lua`

5. 如果已经存在：

```text
autorun\CEProcessBlacklist.txt
```

请保留，它包含之前保存的黑名单。
6. 启动 Cheat Engine。
7. 打开进程列表，左下角应出现 `黑名单...`。

## 使用

点击 **“黑名单...”**：

```text
模糊搜索：[____________________________]

当前运行且未拉黑                 已拉黑
┌──────────────────┐         ┌──────────────────┐
│ chrome.exe       │         │ svchost.exe      │
│ ChatGPT.exe      │  加入>> │ msedge.exe       │
│ Steam.exe        │  <<移除 │ ...              │
│ ...              │         │                  │
└──────────────────┘         └──────────────────┘
```

### 批量加入

- 在左侧按住 `Ctrl` 或 `Shift` 多选；
- 或点击“全选左侧”；
- 点击“加入 >>”。

### 批量移除

- 在右侧多选；
- 或点击“全选右侧”；
- 点击“<< 移除”。

### 模糊搜索

输入：

```text
chat
```

可以匹配：

```text
ChatGPT.exe
```

输入：

```text
clash service
```

只显示同时包含 `clash` 和 `service` 的名称。

## 数据文件

插件自己的黑名单：

```text
autorun\CEProcessBlacklist.txt
```

Cheat Engine 原生过滤文件：

```text
commonProcessesList.txt
```

插件只维护其中（仅写入 EXE 名）：

```text
# >>> CE Process Blacklist Manager BEGIN >>>
...
# <<< CE Process Blacklist Manager END <<<
```

区块之外的原有内容会保留。

首次接管现有 `commonProcessesList.txt` 时，会尝试创建：

```text
commonProcessesList.txt.cepb.bak
```

## 卸载

1. 完全退出 Cheat Engine。
2. 删除：

```text
autorun\CEProcessBlacklist.lua
```

3. 如果不再需要插件黑名单，再删除：

```text
autorun\CEProcessBlacklist.txt
```

4. `commonProcessesList.txt` 中由插件生成的 BEGIN/END 区块可以手动删除。

## 错误日志

异常会尽量记录到：

```text
autorun\CEProcessBlacklist_error.log
```

反馈问题时建议同时提供：

- Cheat Engine 版本；
- 32 位 / 64 位 CE；
- 错误日志；
- 进程列表截图；
- 复现步骤。

## 兼容性

当前维护范围：

- `CE6.x`：Cheat Engine 6.x；已确认可用。
- `CE7.x`：Cheat Engine 7.x；独立维护，等待针对 7.x 的兼容问题修复。

v1.0 的原则是：

- `Processes` 尽量完全交给 CE 原生过滤；
- `Applications / Windows` 只在 CE 自己刷新事件中同步补一次 PID→EXE 过滤；
- 不恢复高频列表轮询；
- 不改变 CE 原来的附加逻辑，列表行仍保持 `PID-文本` 格式。
