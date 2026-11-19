# WSL 中文与剪贴板一键安装

WSL 中文的粘贴、复制、文件及截图，与windows 主机的互操作。

在目标主机的 Debian / Ubuntu WSLg 普通用户终端中执行。

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/NorthwindL/WSL/main/install.sh -o /tmp/wsl-ai-install.sh && bash /tmp/wsl-ai-install.sh
```

安装时按终端提示输入该 Linux 用户的 sudo 密码。新版安装会停止并禁用旧的 `xclip-bridge.service`；若旧版桥接曾在终端手动运行，请先在对应终端按 Ctrl+C 结束。

`install.sh` 是自包含脚本。默认安装中文环境，并启用 `wsl-clipboard-desktop.service`，向普通 WSLg X11 窗口提供 Windows 剪贴板文本、PNG 和磁盘文件。可用 `--native` 选择仅使用 WSLg 自带剪贴板。

### OpenCode 桌面版粘贴修复

默认安装完成后，退出挂起的 OpenCode，直接运行 `ai.opencode` 或从普通桌面入口打开。应用使用普通 WSLg 显示。此前由本脚本生成的独立窗口桌面覆盖会恢复为软件包的直接启动入口，恢复前会备份。

后台服务直接读取 Windows 剪贴板，并在普通 X11 显示提供本地数据。它过滤 RDP 客户端回传的剪贴板事件，避免把自己发布的数据再次导入。等待 Windows 辅助程序期间继续处理 X11 请求。默认模式需要 Qt5 和构建依赖。普通桌面数据提供程序按 WSL 发行版和显示号分别互斥，支持多个发行版同时运行。旧全量桥接应停止以避免竞争。

2026-11-19 在新建 Ubuntu 24.04.5 环境中直接启动 OpenCode 2.3.2，验证英文、中文、emoji 多行和 2.2 万字符文本粘贴，截图显示为可解码的图片附件。编辑器清空后保留的末尾空行仍可出现在读回文本中。样本未发送给模型。

独立窗口仍可显式选择 `--opencode-session`，启动方式为 `~/.local/bin/wsl-opencode`。旧参数 `--opencode-wayland` 为其兼容别名。

### 双向文件、图片和文字粘贴

运行 `bash install.sh --file-session`，然后用 `~/.local/bin/wsl-clipboard-app 程序名 [参数...]` 启动需要粘贴的 X11 应用。例如已安装 Mousepad 时可运行 `~/.local/bin/wsl-clipboard-app mousepad --disable-server`。需要前台运行的应用实例，支持单实例转发的程序请使用其独立实例选项。安装器会为此模式安装 Xephyr、Openbox、Qt5 开发包及编译器，现场构建与本机架构匹配的辅助程序。

Windows 复制文件或目录后，窗口中的文件管理器获得 `text/uri-list`，文本框可粘贴 Linux 副本的路径。副本保存在权限为 0700 的 `/tmp/chatgpt-clipboard.*` 目录，各次复制独立暂存。等待文件复制结束再粘贴，使用完可删除对应暂存目录。反向复制时，Windows 收到标准文件列表，接收程序通过 WSL 共享路径读取内容，读取期间需保持发行版运行和源文件可访问。此模式通过文件系统传输内容，剪贴板仅携带路径。文本和 PNG 图片通过独立窗口自己的剪贴板传递。

同一 Windows 登录会话同一时间可运行一个增强窗口。关闭前台应用即可结束本次桥接。如果其他发行版仍运行旧的全量桥接，需要在对应发行版检查其服务。

重复运行新版安装器时，会停止并禁用旧版 `xclip-bridge.service` 全量监听服务，避免其持续读取和重发布 Windows 剪贴板。可选的 `--with-files` 只监听 Linux X11 剪贴板中的 `text/uri-list` 并向 Windows 发布文件列表，不读取 Windows 剪贴板。

安装使用 `--no-install-recommends`，由 APT 解析必需依赖。默认仅更新 APT 软件索引并安装所需组件。中文字体和输入法默认安装，可用 `--without-chinese` 跳过；系统软件升级通过 `--upgrade` 显式执行。

基础依赖为 `xclip`、`dbus-user-session`、`systemd`、`systemd-sysv`、`coreutils`、`util-linux`、`libc-bin` 和 `diffutils`。普通桌面数据提供程序额外需要 `g++`、`pkg-config`、`qtbase5-dev` 和 `procps`。实际新增包以本机 APT 解析结果为准。

## 安装内容

| 内容 | 设置结果 |
|---|---|
| 中文字体和语言 | 默认安装 Noto CJK、文泉驿字体，生成 zh_CN.UTF-8 并设置系统默认 LANG |
| Fcitx5 | 默认安装中文输入法和 GTK3 / Qt5 模块，新用户配置默认拼音并配置用户级后台服务 |
| Windows 文本和图片 | 默认由普通桌面数据提供程序读取并发布到当前 X11 显示，过滤 RDP 回传 |
| WSLg → Windows 文件（可选） | 用 `--with-files` 监听 Linux 的 `text/uri-list`，发布 Windows 文件列表；不把 `/mnt` 或桥接临时副本回传 |
| 自动启动 | 默认启用 wsl-clipboard-desktop.service，中文输入法使用独立用户服务 |

脚本适用于 Debian / Ubuntu 的 WSLg X11 环境，DISPLAY 形如 `:0`。原生 X11 组件由发行版软件仓库按当前系统架构安装。

首次运行若 PID 1 尚非 systemd，脚本会合并 `/etc/wsl.conf` 的 systemd 与互操作设置，保留其他键，然后以状态码 2 结束。保存工作后使用 `wsl -t <发行版名>` 停止目标发行版，再用 `wsl -d <发行版名>` 启动并重新运行安装命令。该 Linux 安装脚本会修改 Linux 内的 wsl.conf。Windows 端的 WSL 版本升级和发行版重启由用户完成。

## 常用选项

```bash
# 查看计划
bash /tmp/wsl-ai-install.sh --dry-run

# 默认安装中文环境和普通桌面剪贴板数据提供程序
bash /tmp/wsl-ai-install.sh

# 可选：从 WSLg 复制 Linux 文件后粘贴到 Windows
bash /tmp/wsl-ai-install.sh --with-files

# 不安装中文环境
bash /tmp/wsl-ai-install.sh --without-chinese

# 显式执行系统软件升级
bash /tmp/wsl-ai-install.sh --upgrade

# 查看安装结果
bash /tmp/wsl-ai-install.sh --check
```

## 完成后的验证

安装中文环境后，重新进入同一 WSL 用户会话，让语言和输入法环境生效。完全退出并重新打开需要中文输入的应用。新建的输入法配置包含英文键盘和拼音，可以通过 Fcitx5 配置工具调整。已有输入法 profile 会保留。

在增强窗口内试用中文多行文本、Win+Shift+S 截图、资源管理器中的文件与目录。文件应能从粘贴目标实际打开，图片应保持为图片。再从窗口内的文件管理器复制文件到资源管理器，打开粘贴后的副本核对内容。`--with-files` 另提供普通 X11 窗口到 Windows 的单向文件增强。

普通桌面剪贴板服务默认随该 WSL 用户会话启动。选择 `--native` 时会停用它。`--with-files` 启用 Linux 到 Windows 文件增强服务。中文输入法用户服务独立管理。

## 服务管理

在目标 WSL 普通用户终端执行。

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

systemctl --user status xclip-linux-files-bridge.service --no-pager -l
journalctl --user -u xclip-linux-files-bridge.service -n 30 --no-pager

# 停止并关闭自动启动
systemctl --user disable --now wsl-clipboard-desktop.service xclip-linux-files-bridge.service wsl-fcitx5.service
```

遇到 `Unit not found`，先确认当前主机、WSL 名称、Linux 用户和安装时相同，再重新执行安装脚本。

`--with-files` 服务仅在 Linux 剪贴板提供真实文件 URI 时更新 Windows 文件列表。普通文本路径不会被转换成文件。

## 配置保护与重复运行

已有被修改文件备份到 `~/.local/state/wsl-ai-setup/backups/时间-进程号/`，备份按原绝对路径保存。安装进程通过锁串行执行。配置写入前检查当前内容，修改范围限于本方案管理的文件与配置段。重复运行会按所选模式停用旧桥接或启用可选文件服务。

为整合原始操作步骤，脚本会移除 `.bashrc` / `.profile` 中原样的 `fcitx5 --disable=wayland -d --replace` 启动行和 `eval $(dbus-launch --sh-syntax)` 行，改由用户服务管理输入法。其他自定义 shell 内容保留，修改前会备份。

Windows 虚拟文件对象（例如部分邮件客户端的附件）需要单独的 `IStream` 协议。当前支持磁盘上的文件和目录。

## 官方参考

- [WSL 的 systemd 设置](https://learn.microsoft.com/en-us/windows/wsl/systemd)
- [Fcitx5 配置](https://fcitx-im.org/wiki/Setup_Fcitx_5/en)
