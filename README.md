# WSLg 按粘贴请求传输文字、文件与图片

在 Debian / Ubuntu WSLg 普通用户终端更新或安装：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/NorthwindL/WSL/main/install.sh -o /tmp/wsl-ai-install.sh
bash /tmp/wsl-ai-install.sh
```

默认安装中文字体、zh_CN.UTF-8、Fcitx5、fcitx5-configtool 和文字、文件、图片双向桥接。文字已加入同一个后台脚本，无需 `--text-fallback`，不以 WSLg 原生文字同步成功作为前提。不安装独立桌面，不强制应用切换显示后端，不修改 Windows RDP 剪贴板策略或 WSLg 全局配置。

## 触发规则

| 操作 | 脚本行为 |
|---|---|
| Windows 复制文字、文件或截图 | 只检查剪贴板序号和格式标志；不读取正文、文件列表或图片，不创建缓存，不改写 Windows 剪贴板 |
| Windows 桌面复制文件并粘贴副本 | 保留 Windows 原始 FileDrop 列表；直接操作主机和远程桌面使用相同规则 |
| 切换、激活或重启 Linux 应用 | 不触发 Windows 内容读取 |
| Linux 应用查询 TARGETS | 只报告类型，不读取 Windows 内容 |
| Linux Ctrl+V 或右键粘贴，请求文字数据 | 此时读取 Windows UnicodeText，转换为 UTF-8，返回给应用 |
| Linux 应用请求文件 URI | 此时读取 Windows 文件列表，复制到 Linux 缓存后返回 URI |
| Linux 应用请求 image/png | 此时读取 Windows 图片，必要时将 Bitmap 转 PNG，返回图片数据 |
| 重复粘贴同一次复制 | 检查剪贴板版本后复用已读取的数据 |
| Linux 复制文字 | 将 UnicodeText 和来源标记写入 Windows 剪贴板 |
| Linux 复制本地文件 | 向 Windows 发布标准 FileDrop 文件列表；缓存文件及其符号链接不回传 |
| Linux 复制 PNG/BMP | 向 Windows 发布 PNG、DIB 和来源标记 |

后台每 250 毫秒检查元数据。Windows 内容读取仅发生在 `PULL`；格式探测、窗口切换及普通轮询不调用内容读取函数。文字和图片仅保存在内存中，文件才生成磁盘缓存。

**触发依据是应用的数据请求，无法从 X11 协议判断请求是否由用户点击产生。** Ctrl+V 和右键粘贴共用数据请求处理；应用或剪贴板管理器主动预取实际数据，也会触发。仅查询格式不会触发。没有全局按键或鼠标监听器。

本桥接覆盖 WSLg **X11 应用**，包括使用 XWayland 的应用。原生 Wayland 应用的数据请求不在本桥接范围内。终端通常使用 Ctrl+Shift+V；Windows Terminal 自身的粘贴由终端处理。文件接收应用须支持文件 URI。Windows 虚拟附件（IStream）未实现，目前支持磁盘文件和目录。

## 文字与格式

文字支持中文、多行、emoji、空文字和较长内容，单次 UTF-8 正文上限 8 MiB。Windows → Linux 将换行转换为 LF；Linux → Windows 发布带终止符的 UTF-16 UnicodeText，换行转换为 CRLF。Linux 提供 `UTF8_STRING`、`text/plain;charset=utf-8`、`text/plain` 和 `TEXT`，大选区使用 X11 INCR。

文字按纯文本传输，不同步 Word/Excel/HTML 的富文本格式。Windows 原剪贴板只在 Linux 主动复制时才被脚本写入；Windows → Linux 的读取不改写 Windows 内容。Linux 混合文字/图片优先导出文字，文件 URI 优先于文字；原 Linux 应用自己的格式仍保留。只有 HTML、没有普通文字的来源不会被当作普通文字导出。

每次传输检查 Windows 剪贴板版本，丢弃过期数据；反向写入也检查版本，避免覆盖较新的 Windows 复制。来源标记和原生 WSLg 回声检测避免重复导入，文字另有同内容回声抑制。脚本不会从 WSLg 原生回声请求自身的延迟文字，以免形成互相等待。系统原生同步仍可能同时运行；真实主机上的并发、RDP 行为需要验收，自动测试不能保证这些场景。

## 文件、图片与缓存

文件仅提供 `text/uri-list` 和 `x-special/gnome-copied-files`，不会把文件路径作为正文发布。图片仅提供 `image/png`；Linux PNG/BMP 导出同时生成 Windows PNG 和 DIB。图片上限 64 MiB，不写入文件缓存。

文件缓存位于 `~/.cache/wsl-clipboard/files/copy-*`，目录权限 0700，副本补充当前用户读写权限。单次最多 512 MiB、10000 个文件及目录；保留至少 64 MiB 可用空间。拒绝符号链接及特殊文件，失败清理本次副本。每小时清理创建超过 24 小时的缓存，下次传输前也清理。长期使用的文件请另存。

反向文件复制仅接受 Windows 绝对路径或 WSL UNC 共享路径，拒绝 POSIX 路径、缓存路径和旧暂存路径。Windows 后端在当前用户可访问的 Windows 会话中运行，不结束其他 PowerShell 或远程桌面进程。

## 启动、关闭与排查

在 WSL 中使用同一个服务管理文字、文件、图片：

```bash
# 启动、停止、重启
systemctl --user start wsl-clipboard-desktop.service
systemctl --user stop wsl-clipboard-desktop.service
systemctl --user restart wsl-clipboard-desktop.service

# 自动启动 / 关闭自动启动并立即停止
systemctl --user enable --now wsl-clipboard-desktop.service
systemctl --user disable --now wsl-clipboard-desktop.service

# 状态与日志
systemctl --user status wsl-clipboard-desktop.service --no-pager -l
journalctl --user -u wsl-clipboard-desktop.service -n 30 --no-pager
```

若提示用户总线不可用，先设置：

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
```

重启脚本后，在 Windows 重新复制文字，再到 Linux 粘贴。停止脚本只停止其桥接，不关闭系统原生同步，不关闭 WSL 或应用。

## 安装选项与旧版本清理

```bash
bash /tmp/wsl-ai-install.sh --dry-run
bash /tmp/wsl-ai-install.sh --check
bash /tmp/wsl-ai-install.sh --without-chinese
bash /tmp/wsl-ai-install.sh --upgrade
```

`--with-files` 保留为兼容参数，现在启用文字、文件、图片完整桥接；`--with-chinese` 也是默认行为。`--native` 停用全部脚本桥接，交还系统原生行为。旧的主动导入、单向轮询、焦点检测和独立桌面模式已移除。

默认安装编译器、QtCore 和 X11 开发库，安装时编译，运行时不编译。系统升级须显式选择。首次启用 systemd 后若提示重启，保存工作后重启目标发行版，再执行同一安装命令。

更新前停止本用户旧桥接服务及精确匹配的旧桥接进程，恢复本脚本生成的旧独立应用入口为直接启动。配置备份至 `~/.local/state/wsl-ai-setup/backups/时间-进程号/`。不卸载共用依赖，不删除用户已有文件。其他用户或发行版需分别更新或停用旧桥接。

## 验证

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

CI 在 Linux 编译 QtCore/X11 程序，使用真实 X11 选择区和模拟 Windows 后端，验证无预取、按需文字/文件/图片读取、重复粘贴、中文多行 emoji、空文字、INCR 长文字、版本切换和双向复制。Windows CI 验证 UnicodeText 格式、换行、元数据不读取正文、来源标记、过期写入保护及图片转换。

真实主机需另外验证：Windows 桌面 Excel 文件副本正常；先文件/截图后文字；关闭并重开 ChatGPT 后文字粘贴；分别在本机和 RDP 会话进行双向文字、文件、图片测试。CI 没有真实 WSLg/RDP 主机，不能代替这些验收。
