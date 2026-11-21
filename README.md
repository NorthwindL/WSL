# WSLg 中文、截图与双向文件剪贴板

在 Debian / Ubuntu WSLg 普通用户终端执行：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/NorthwindL/WSL/main/install.sh -o /tmp/wsl-ai-install.sh
bash /tmp/wsl-ai-install.sh
```

安装时按提示输入 Linux 用户的 sudo 密码。默认启用双向文件桥接，文字和截图保留 WSLg 原生剪贴板。后台不再读取、重新发布普通文字和图片，避免触发回传并改变 Windows 原有格式。默认安装中文字体、中文语言环境、Fcitx5 中文输入法及配置工具（fcitx5-configtool），不安装独立桌面，不修改应用的显示后端。安装后退出并重新打开目标应用。

## 默认行为

| 内容 | 实现方式 |
|---|---|
| 中文环境与输入法 | 默认安装中文字体、zh_CN.UTF-8、Fcitx5、拼音和配置工具 |
| Windows → WSLg 中文文字、多行、emoji | 使用 WSLg 原生通道；默认桥接通过文件格式标志跳过文字，不调用 GetDataObject 读取文字 |
| WSLg → Windows 文字 | 使用 WSLg 原生通道，保留原生 xclip 的选择区和参数行为 |
| Windows 截图 | 使用 WSLg 原生图片通道；安装 wl-copy / wl-paste 便于操作 Wayland 剪贴板 |
| Windows → WSLg 文件 | Windows 桌面/资源管理器处于前台时不读取、不导入；切换到经确认的 WSLg 窗口后才读取 CF_HDROP 并发布文件 URI，不提供纯文本路径目标 |
| WSLg → Windows 文件 | 后台服务读取 X11 文件 URI，通过 WSL 共享路径发布 Windows FileDrop；不复制文件内容到控制台 |
| 文件副本 | 保存至 ~/.cache/wsl-clipboard/files/copy-*，目录权限 0700，文件补充当前用户读写权限 |
| 容量与空间 | 单次总量最多 512 MiB、最多 10000 个文件及目录；预检并在复制中检查大小和剩余空间，保留至少 64 MiB |
| 自动清理 | 每小时删除创建超过 24 小时的托管副本；下次文件复制前也执行清理 |
| 旧版迁移 | 停用旧全量桥接和单向文件服务，恢复 /usr/local/bin/xclip 为原生 /usr/bin/xclip 的转发入口；备份已有配置 |

文件复制拒绝符号链接（含目录内部链接）、设备与其他特殊文件。文件全部复制成功后才发布路径，失败则移除本次副本并保留现有应用剪贴板。同名文件放在不同子目录；中文、空格、emoji 和换行文件名通过 JSON 或 NUL 协议传递。文件桥接不转换普通文本路径。

文件桥接覆盖 **WSLg X11 应用**，粘贴目标须支持文件 URI，例如文件管理器或支持附件粘贴的编辑器。原生 Wayland 应用是否接受跨系统文件取决于其自身及 WSLg 支持，当前文件桥接不覆盖其 Wayland 选择区。文字和截图的原生能力同样取决于目标应用支持的剪贴板格式，安装工具本身不保证所有应用的兼容性。

Windows 虚拟文件对象（如部分邮件附件）未实现 IStream 协议，目前支持磁盘文件与目录。反向粘贴时需保持 WSL 发行版运行、源文件可访问。暂存副本会在 24 小时后清理，长期使用的文件应及时另存。

## 常用命令

```bash
# 预览安装计划（不修改系统）
bash /tmp/wsl-ai-install.sh --dry-run

# 默认：中文环境、Fcitx5 和双向文件桥接；文字和截图走 WSLg 原生通道
bash /tmp/wsl-ai-install.sh

# 跳过中文字体、语言和 Fcitx5 安装
bash /tmp/wsl-ai-install.sh --without-chinese

# 检查默认文件桥接
bash /tmp/wsl-ai-install.sh --check

# 故障排查时，显式关闭文件桥接，仅保留 WSLg 原生通道
bash /tmp/wsl-ai-install.sh --native

# 显式兼容模式：接管文字和图片（可能触发 WSLg 回传，Windows 粘贴异常时勿启用）
bash /tmp/wsl-ai-install.sh --desktop-bridge

# 需要独立窗口时，显式安装并启动（X11）
bash /tmp/wsl-ai-install.sh --file-session
~/.local/bin/wsl-clipboard-app 程序名 [参数...]

# 为已安装的 OpenCode 配置独立窗口
bash /tmp/wsl-ai-install.sh --opencode-session

# 显式执行系统软件升级
bash /tmp/wsl-ai-install.sh --upgrade
```

`--with-files` 等同默认双向文件模式。`--files-out` 保留单向 Linux → Windows 文件模式。`--opencode-wayland` 是旧版独立窗口参数的兼容别名。增强模式的图片读取沿用 PNG 优先、Bitmap 转 PNG 的逻辑；默认模式只桥接文件，双向文字和图片均使用 WSLg 原生通道。`--desktop-bridge` 属于显式兼容模式；默认服务不使用它。

`--file-session` 仅在显式选择时安装 Xephyr 和 Openbox，启动器要求前台应用实例。单实例程序应选择独立实例参数。默认模式直接打开普通 WSLg 应用。

## 安装依赖和重启

基础依赖为 xclip、wl-clipboard、python3、dbus-user-session、systemd、systemd-sysv、coreutils、util-linux、libc-bin 和 diffutils。默认双向文件桥接还需要 g++、pkg-config、qtbase5-dev 和 procps。安装器使用 `--no-install-recommends`，默认只更新 APT 索引并安装依赖。中文环境默认安装，可用 `--without-chinese` 跳过；系统升级须显式选择。

若 PID 1 不是 systemd，安装器会合并 /etc/wsl.conf 的 systemd 与互操作设置，保留其他键，以状态码 2 退出。保存工作后，在 Windows 终端运行 `wsl -t <发行版名>`，再运行 `wsl -d <发行版名>`，然后重新执行安装命令。systemd 用户总线必须可用。

已有被修改配置备份至 `~/.local/state/wsl-ai-setup/backups/时间-进程号/`。重复安装会按所选模式管理桥接服务。默认生成 zh_CN.UTF-8 并设置系统默认 LANG，配置 Fcitx5；已有输入法 profile 保留。安装完成后重新进入 WSL 用户会话，并重新打开应用；可运行 `fcitx5-configtool` 调整输入法。`--with-chinese` 保留为显式启用参数；`--without-chinese` 跳过中文安装，但不会卸载已有软件或删除其环境变量。

## 修复 Windows 应用之间的复制粘贴干扰

重新下载并运行默认安装命令。安装器会在替换程序之前停止本用户旧桥接服务，并终止可精确匹配的旧 Qt 桥接进程；不会批量结束 PowerShell 或 Windows 应用。其他 WSL 发行版或用户运行的旧桥接，需要在对应环境更新或停用。

本次移除默认模式的 Windows 文字主动导入，并取消文件选区的纯文本路径回退，避免原本的 Word / Excel / HTML 内容被降为纯文字或文件路径。普通文字和图片变动只检查剪贴板序号、文件格式标志，不调用 OLE GetDataObject。文件发布携带来源标记以跳过自身回传；文件写入失败后等待新的复制事件，不再循环重写 Windows 剪贴板。双向文件桥接、512 MiB 限制、权限修复、清理定时器、中文环境和 Fcitx5 均保留。

完成后退出并重新打开目标 WSLg 应用。先测试 Windows 记事本、浏览器、Word / Excel 之间的连续复制，确认文字、表格和格式正常，再测双向文件。如果 WSLg 已进入剪贴板占用异常状态，脚本更新不一定能解除已有占用：保存全部 WSL 工作后，在 Windows PowerShell 执行 `wsl --shutdown`，再打开 WSL。该命令会停止全部发行版，安装器不会替你执行。

安装器无法保证修复 WSLg / msrdc 自身的所有问题。CI 验证了模拟 Windows 协议下的 X11 剪贴板行为和 Windows 后端的格式保护逻辑，仍需在目标 Windows 主机核对实际效果。

## 远程桌面内复制 Windows 文件

从另一台电脑通过 RDP 登录此 Windows 主机，在主机桌面复制 Excel 等文件并粘贴副本时，默认桥接只检查剪贴板元数据，不读取或修改原始文件列表，也不创建 Linux 暂存副本。切换到 WSLg 应用后，才允许将该文件导入 Linux。无法确认前台窗口属于 WSLg 时，会继续等待，不按普通远程桌面客户端推断它是 WSLg。

导入的缓存文件及其符号链接均禁止反向发布；Windows 后端另行拒绝 POSIX 路径、当前缓存路径和旧暂存路径作为 Windows FileDrop。真正从 Linux 文件系统主动复制的文件仍可反向粘贴。

验收时先在远程 Windows 桌面选中文件，按 Ctrl+C、Ctrl+V，确认副本出现在原桌面且剪贴板没有变成 `/home/.../copy-...`。再从 Windows 复制文件，切换 WSLg 文件管理器，等导入完成后粘贴，核对内容；最后测试 Linux → Windows 文件粘贴。CI 用模拟前台窗口和 Windows 元数据验证这些边界，不代替真实 RDP 会话验收。

## 验证与排查

1. Windows 复制中文多行文字到 WSLg 应用，再反向复制核对。
2. 用 Win+Shift+S 截图，确认目标应用收到图片附件。
3. Windows 资源管理器复制中文文件、同名文件和目录，在 WSLg 文件管理器粘贴后打开核对。
4. 从 WSLg 文件管理器复制 Linux 文件到 Windows 资源管理器，粘贴并核对内容。
5. 测试超过 512 MiB、符号链接及磁盘空间不足的选区，确认拒绝且未发布不完整路径。

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
systemctl --user status wsl-clipboard-desktop.service --no-pager -l
journalctl --user -u wsl-clipboard-desktop.service -n 30 --no-pager
systemctl --user list-timers wsl-clipboard-cleanup.timer

# 立即清理过期副本
~/.local/lib/wsl-clipboard-session/stage-files --cleanup
```

遇到 Unit not found，确认当前主机、WSL 发行版和用户与安装时一致。服务需要 Windows PowerShell 与 WSL 互操作 socket。多个发行版使用各自的缓存和服务，Windows 剪贴板仍为共享资源。

## 开发验证

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

测试覆盖文件暂存边界、空间检查、权限、文件名、清理、安装计划和内嵌 Bash 语法。CI 另编译内嵌 Qt C++ 程序，通过真实 X11 选择区测试原生 HTML 保留、文件 URI 导入、反向文件发布、失败停止重试及新 Windows 复制优先，并在 Windows 运行模拟元数据的后端保护测试（不接触运行器实际剪贴板）。Linux CI 无法替代 Windows / WSLg 上的双向实际粘贴验收。
