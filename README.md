# WSLg 按粘贴请求传输文件与图片

在 Debian / Ubuntu WSLg 普通用户终端执行：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/NorthwindL/WSL/main/install.sh -o /tmp/wsl-ai-install.sh
bash /tmp/wsl-ai-install.sh
```

默认安装中文字体、zh_CN.UTF-8、Fcitx5 中文输入法、fcitx5-configtool 和双向文件/图片桥接。Windows UnicodeText 纯文本由桥接写入 Linux Wayland 剪贴板；截图保留 WSLg 原生通道，文件和图片仍按数据请求处理。不安装独立桌面、不强制应用切换显示后端。

## 文件传输何时执行

| 操作 | 桥接行为 |
|---|---|
| 在 Windows 复制文件 | 只检查剪贴板序号和文件格式标志；不读取文件列表、不复制文件、不创建缓存、不改写 Windows 剪贴板 |
| 在 Windows 桌面 Ctrl+C、Ctrl+V 创建副本 | 保持 Windows 自己的原始文件列表；直接操作主机和通过远程桌面操作使用相同规则 |
| 切换或激活 Linux 窗口 | 不触发文件传输，已删除前台窗口判断逻辑 |
| Linux 应用检查可用剪贴板格式 | 只返回文件格式信息，不读取 Windows 文件列表、不生成缓存 |
| Linux 应用请求文件 URI 数据 | 此时才读取 Windows 文件列表并复制到 Linux 缓存，完成后返回可用的文件 URI |
| Linux 应用请求 image/png 数据 | 此时才读取 Windows 图片，必要时将 Bitmap 转 PNG，向目标应用返回图片数据 |
| 重复粘贴同一次 Windows 复制 | 复用已生成的缓存副本，不重复复制 |
| 在 Linux 主动复制本地文件 | 向 Windows 发布标准 FileDrop 文件列表；缓存文件及其符号链接不反向发布 |
| 在 Linux 复制 PNG/BMP 图片 | 将图片同步为 Windows PNG 与 DIB 格式，保持为图片 |
| 在 Linux 复制文字、HTML 或混合文字/图片内容 | 文字优先使用原生通道，不主动重发布文字或覆盖其富文本格式 |

桥接持续运行一个轻量的元数据监听进程，以便 Linux 应用知道剪贴板是否有文件；文件路径读取、图片解码和内容传输均在应用请求相应数据时才执行。采用原生 X11 选择区协议，根据数据类型精确提供 `text/uri-list`、`x-special/gnome-copied-files` 或 `image/png`，不提供文件路径的纯文本回退，也不借助 Qt 自动转换格式。

Ctrl+V、右键“粘贴”等操作只要目标应用请求上述文件数据，即可触发。**协议只能识别应用的数据请求，不能识别请求背后是否一定发生了用户点击**：若某个应用或剪贴板管理器主动预取文件数据，也会触发传输。单纯查询 TARGETS 不会触发。目标应用必须支持文件粘贴，不能把任意文本框都当成文件接收器。

文件桥接覆盖 WSLg **X11 应用**。原生 Wayland 应用的文件/图片数据请求不在本桥接范围内。Windows 虚拟附件（IStream）未实现，目前支持磁盘文件和目录。Windows PowerShell 必须位于当前用户可访问的 Windows 会话中；真实 RDP 会话兼容性仍需在目标主机验收。

## 文字交接与图片处理

Windows 剪贴板包含 UnicodeText 时，桥接读取该纯文本并通过 `wl-copy --type text/plain;charset=utf-8` 写入 Linux Wayland 剪贴板，适用于中文、多行和 Unicode 字符。若 Windows 剪贴板同时包含 HTML、RTF 或图片，当前实现仍以 UnicodeText 为准，Linux 收到纯文本，其他富文本/图片格式不随这次文本传输保留。Windows 仅含图片时仍由原生 WSLg 通道处理。Linux 复制文字、HTML 或混合内容时不读取或重发布正文，保持原有原生通道行为。

图片按需读取为 PNG，Windows Bitmap 截图在请求时转换成 PNG。Linux 复制 PNG 或 BMP 时，Windows 同时收到 PNG、DIB 和来源标记，不把图片变成路径或文字。图片负载上限 64 MiB，图片数据不写入文件缓存。文件、图片、文字之间切换前核对剪贴板版本，避免向正在请求的应用返回已经失效的数据。

## 文件缓存与保护

缓存位于 `~/.cache/wsl-clipboard/files/copy-*`，目录权限 0700，文件补充当前用户读写权限。单次最多 512 MiB、10000 个文件及目录；复制前和复制中检查剩余空间，保留至少 64 MiB。拒绝符号链接及特殊文件，失败清理本次副本。每小时清理创建超过 24 小时的缓存；下次传输前也清理。长期使用的文件请另存。

Windows 后端的 `POLL` 只报告数据类型，不读取正文、文件列表或图片；收到对应的 `PULL` 后才读取文本、文件列表或图片。文本有 8 MiB 上限，文件列表有 4 MiB 上限，图片有 64 MiB 上限。传输期间 Windows 剪贴板发生变化时，不向 Linux 发布过期文本或文件/图片数据。反向文件复制仅接受 Windows 绝对路径或 WSL UNC 共享路径，禁止 POSIX 路径、缓存路径及旧暂存路径；写入前核对 Windows 剪贴板版本，避免覆盖较新的复制内容。

## 常用选项

```bash
bash /tmp/wsl-ai-install.sh --dry-run
bash /tmp/wsl-ai-install.sh --check
bash /tmp/wsl-ai-install.sh --without-chinese
bash /tmp/wsl-ai-install.sh --upgrade
```

`--with-files` 和 `--with-chinese` 为默认行为的显式写法。`--native` 用于排障时停用文件桥接。旧的主动导入、单向轮询和独立桌面模式已经移除，相关旧参数会提示改用默认模式。

默认安装编译器、QtCore 开发库和 X11 开发库，在安装时编译桥接；运行时不再编译。安装器仅安装所需软件，系统升级须显式选择。首次启用 systemd 后若提示重启，请保存工作，在 Windows 终端停止并重新启动目标发行版，再执行同一安装命令。

## 更新与清理旧实现

重新下载并执行默认安装命令，无需卸载 WSL。更新前会停止本用户旧桥接服务及可精确匹配的旧桥接进程。移除旧的主动导入、文字/图片重发布、焦点检测、单向桥接和 Xephyr/Openbox 启动逻辑；原有由本脚本生成的独立应用入口恢复为直接启动，旧入口脚本改为直接转发，不再启动嵌套桌面。

已有配置备份至 `~/.local/state/wsl-ai-setup/backups/时间-进程号/`。不卸载其他程序可能共用的旧依赖，不删除用户已有文件。其他 WSL 发行版和用户的旧桥接，需要在对应环境更新或停用。

更新后重新复制原文件，再进行本机和远程桌面测试，不沿用旧剪贴板内容。若 WSLg 已存在占用异常，保存全部 WSL 工作后，可在 Windows PowerShell 执行 `wsl --shutdown` 再重新打开 WSL；该操作会停止全部发行版，安装器不会代为执行。

## 验证与排查

文字测试应特别覆盖：复制中文、多行、emoji 和长文字，确认 Linux Wayland 剪贴板收到对应 UTF-8 纯文本；确认 Windows 富文本混合格式按 UnicodeText 降为纯文本；先复制截图再复制文本，确认新文本接管。还需验证 Windows 截图 → Linux 图片附件，以及 Linux PNG/BMP → Windows 图片粘贴。

1. 在 Windows 桌面复制 Excel 文件并粘贴副本，确认 Windows 原始操作正常。
2. Windows 复制文件后，检查缓存没有新增；切换 Linux 窗口后仍不应新增。
3. 在支持文件 URI 的 Linux 应用粘贴，确认此时才生成副本且内容正确。
4. 在 Linux 复制本地文件到 Windows，确认成功；缓存路径不回传。
5. 分别在本机和 RDP 会话重复以上步骤，并检查文字、截图和 Word/Excel 格式未受干扰。

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
systemctl --user status wsl-clipboard-desktop.service --no-pager -l
journalctl --user -u wsl-clipboard-desktop.service -n 30 --no-pager
systemctl --user list-timers wsl-clipboard-cleanup.timer
```

## 开发验证

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

CI 编译 QtCore/X11 程序，用真实 X11 数据请求和模拟 Windows 后端验证无预取、首次粘贴触发、重复粘贴复用、GNOME 文件格式、大选区 INCR、Windows 纯文本写入 Wayland、双向图片、反向文件复制、文件/图片到文字的所有权交接和 Linux 混合格式原生保留。在 Windows 验证元数据轮询不读取文本/文件/图片、只有数据请求可取正文、UnicodeText UTF-8 编码、Bitmap→PNG 转换，以及 PNG/BMP 反向同步为正确的 PNG/DIB 格式。CI 不替代真实 Windows/RDP 的端到端验收。
