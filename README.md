# Linux 远程服务器管理工具

一站式 SSH 连接 + 系统信息采集 + 负载诊断的命令行工具。

## 环境要求

| 项目 | 要求 |
|------|------|
| Python | **3.8** 及以上 |
| 操作系统 | Windows / macOS / Linux |
| 网络 | 能 SSH 到目标服务器 |

## 安装依赖

```bash
pip install paramiko rich
```

| 依赖包 | 用途 | 安装时自动带上的子依赖 |
|--------|------|----------------------|
| `paramiko` | SSH 连接与远程命令执行 | bcrypt, cryptography, pynacl, invoke, cffi, pycparser |
| `rich` | 终端美化输出（表格、面板、颜色） | markdown-it-py, mdurl, pygments |

> 首次双击运行时，程序会自动检测并安装缺失的依赖，无需手动操作。

## 文件说明

```
├── server_manager.py    # 主程序（双击运行）
├── server_diag.sh       # 服务器负载诊断脚本（由主程序自动上传执行）
└── README.md            # 本文件
```

## 使用方法

### Windows — 双击运行

直接双击 `server_manager.py`，首次运行会自动安装依赖。

### 命令行运行

```bash
python server_manager.py
```

## 功能菜单

| 选项 | 功能 | 说明 |
|------|------|------|
| 1 | 🔌 连接服务器 | 输入主机、端口、用户名，支持密码/密钥认证 |
| 2 | 📊 系统基本信息 | 快速采集 CPU、内存、磁盘、网络、进程等 |
| 3 | 🔍 完整负载诊断 | 自动上传 `server_diag.sh` 并执行 6 大维度检测 |
| 4 | 🖥 交互式 Shell | 在远程服务器上自由执行命令 |
| 5 | ❌ 断开连接 | 断开当前 SSH 连接 |
| 0 | 🚪 退出程序 | 断开连接并退出 |

## 诊断脚本检测维度

`server_diag.sh` 会检测以下 6 个维度并给出汇总报告：

| 维度 | 检测项 |
|------|--------|
| CPU 负载 | Load Average、CPU 使用率（us/sy/wa/id）、Top 5 进程 |
| 内存 | 总量/可用/Swap、Top 5 进程 |
| 磁盘 IO | iostat 采样、IO 饱和检测、IO 活跃进程 |
| 网络 | TCP 连接状态统计、监听端口、网卡流量 |
| 磁盘空间 | 分区使用率、Inode 使用率、Top 10 目录 |
| 进程与系统 | 僵尸进程、文件描述符、OOM Killer、内核日志、登录记录 |

每个维度自动判定状态：
- 🟢 正常
- 🟡 警告（需关注）
- 🔴 异常（需立即处理）

## 常见问题

**Q: 双击后窗口闪退？**
A: 已修复，程序退出前会暂停等待按键。如果仍闪退，用命令行运行查看报错信息。

**Q: 密码输入时看不到字符？**
A: 已改为明文显示，输入的字符会直接可见。

**Q: 连接失败？**
A: 检查：
1. 服务器 IP 和端口是否正确
2. 用户名和密码/密钥是否正确
3. 服务器是否开放了 SSH 端口（默认 22）
4. 防火墙是否放行

**Q: 诊断脚本报 "iostat 不可用"？**
A: 在远程服务器上安装 sysstat：
```bash
# CentOS/RHEL
yum install -y sysstat

# Ubuntu/Debian
apt install -y sysstat
```

## 快速开始

```bash
# 1. 安装依赖（或双击运行时自动安装）
pip install paramiko rich

# 2. 运行
python server_manager.py

# 3. 按提示操作
#    选 1 → 输入服务器信息 → 选 2 或 3 查看诊断结果
```
