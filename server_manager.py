#!/usr/bin/env python3
"""
╔═══════════════════════════════════════════════════════════════════╗
║              Linux 远程服务器管理工具 v1.0                       ║
║              Remote Server Manager                               ║
╚═══════════════════════════════════════════════════════════════════╝

依赖安装:  pip install paramiko rich

用法:      python server_manager.py
"""

import sys
import os


def _pause_before_exit():
    """双击运行时防止窗口闪退，等待用户按键"""
    try:
        input("\n按回车键退出...")
    except (KeyboardInterrupt, EOFError):
        pass


def _check_and_install(name, pip_name=None):
    """检查依赖是否安装，未安装则尝试自动安装"""
    pip_name = pip_name or name
    try:
        __import__(name)
    except ImportError:
        print(f"[*] 缺少依赖: {name}，正在自动安装 {pip_name} ...")
        os.system(f"{sys.executable} -m pip install {pip_name} -q")
        try:
            __import__(name)
            print(f"[✔] {pip_name} 安装成功")
        except ImportError:
            print(f"[✘] {pip_name} 安装失败，请手动执行: pip install {pip_name}")
            _pause_before_exit()
            sys.exit(1)


# ── 检查并安装依赖 ──
_check_and_install("paramiko")
_check_and_install("rich")

import paramiko
import time
import socket
import select

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.prompt import Prompt, IntPrompt
from rich import box

# ═══════════════════════════════════════════════════════════════════
#  全局配置
# ═══════════════════════════════════════════════════════════════════

console = Console()
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DIAG_SCRIPT = os.path.join(SCRIPT_DIR, "server_diag.sh")
REMOTE_DIAG_PATH = "/tmp/_server_diag_tmp.sh"


# ═══════════════════════════════════════════════════════════════════
#  SSH 连接管理器
# ═══════════════════════════════════════════════════════════════════

class SSHManager:
    """封装 paramiko 的 SSH 连接与操作"""

    def __init__(self):
        self.client = None
        self.host = ""
        self.port = 22
        self.username = ""

    # ────────────── 连接 ──────────────

    def connect(self, host, port, username, password=None, key_file=None):
        """建立 SSH 连接，支持密码和密钥两种认证方式"""
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.host = host
        self.port = port
        self.username = username

        connect_kwargs = {
            "hostname": host,
            "port": port,
            "username": username,
            "timeout": 15,
            "allow_agent": False,
            "look_for_keys": False,
        }

        # 选择认证方式
        if key_file:
            key_path = os.path.expanduser(key_file)
            if not os.path.isfile(key_path):
                self.client = None
                raise FileNotFoundError(f"密钥文件不存在: {key_path}")
            connect_kwargs["key_filename"] = key_path
        elif password:
            connect_kwargs["password"] = password
        else:
            self.client = None
            raise ValueError("未提供密码或密钥文件")

        try:
            self.client.connect(**connect_kwargs)
        except paramiko.AuthenticationException:
            self.client = None
            raise
        except (paramiko.SSHException, socket.timeout, socket.error, OSError) as e:
            self.client = None
            raise ConnectionError(str(e))

    # ────────────── 状态 ──────────────

    def is_connected(self):
        if self.client is None:
            return False
        transport = self.client.get_transport()
        return transport is not None and transport.is_active()

    def disconnect(self):
        if self.client:
            try:
                self.client.close()
            except Exception:
                pass
            self.client = None

    # ────────────── 执行命令 ──────────────

    def exec_command(self, command, timeout=120):
        """远程执行命令，返回 (exit_code, stdout_str, stderr_str)"""
        if not self.is_connected():
            raise ConnectionError("SSH 未连接")
        _, stdout, stderr = self.client.exec_command(command, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        return exit_code, out, err

    # ────────────── SFTP 上传 ──────────────

    def upload_text(self, remote_path, content):
        """将文本内容上传为远程文件"""
        if not self.is_connected():
            raise ConnectionError("SSH 未连接")
        sftp = self.client.open_sftp()
        try:
            with sftp.file(remote_path, "w") as f:
                f.write(content)
        finally:
            sftp.close()


# ═══════════════════════════════════════════════════════════════════
#  系统基本信息采集与展示
# ═══════════════════════════════════════════════════════════════════

def fetch_sysinfo(ssh):
    """通过远程命令采集系统基本信息"""
    commands = {
        "hostname":     "hostname 2>/dev/null",
        "kernel":       "uname -r",
        "os":           "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 | tr -d '\"'",
        "arch":         "uname -m",
        "cpu_model":    "grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs",
        "cpu_cores":    "grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0",
        "uptime":       "uptime -p 2>/dev/null || uptime",
        "load":         "cat /proc/loadavg 2>/dev/null",
        "mem_total_kb": "grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}'",
        "mem_avail_kb": "grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}'",
        "swap_total_kb":"grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}'",
        "swap_free_kb": "grep SwapFree /proc/meminfo 2>/dev/null | awk '{print $2}'",
        "disk":         "df -hP 2>/dev/null",
        "net_listen":   "ss -tlnp 2>/dev/null | tail -n +2 | wc -l",
        "net_conn":     "ss -ant 2>/dev/null | awk 'NR>1{s[$1]++}END{for(k in s)print k,s[k]}'",
        "proc_count":   "ps aux 2>/dev/null | wc -l",
        "proc_zombie":  "ps aux 2>/dev/null | awk '$8~/Z/{c++}END{print c+0}'",
        "oom_count":    "dmesg 2>/dev/null | grep -ci 'oom-killer' || true",
        "time":         "date '+%Y-%m-%d %H:%M:%S'",
    }
    info = {}
    for key, cmd in commands.items():
        try:
            _, out, _ = ssh.exec_command(cmd, timeout=10)
            info[key] = out.strip()
        except Exception:
            info[key] = ""
    return info


def show_sysinfo(info):
    """将采集到的信息以 Rich 表格展示"""
    table = Table(
        box=box.ROUNDED,
        show_header=True,
        header_style="bold cyan",
        border_style="cyan",
        title="📊 服务器基本信息",
        title_style="bold",
    )
    table.add_column("项目", style="bold", width=16, no_wrap=True)
    table.add_column("详情")

    def val(v, default="N/A"):
        return v if v else default

    def fmt_bytes(kb_str):
        try:
            kb = int(kb_str)
            if kb > 1048576:
                return f"{kb / 1048576:.1f} GB"
            return f"{kb / 1024:.0f} MB"
        except (ValueError, TypeError):
            return "N/A"

    # ── 基础信息 ──
    table.add_row("🖥  主机名", val(info.get("hostname")))
    os_name = val(info.get("os"))
    table.add_row("📦 系统版本", os_name if os_name != "N/A" else "[dim]无法识别[/dim]")
    table.add_row("🔧 内核版本", val(info.get("kernel")))
    table.add_row("🏗  架构", val(info.get("arch")))
    table.add_row("🕐 当前时间", val(info.get("time")))

    # ── 运行时间 ──
    uptime_str = val(info.get("uptime"))
    table.add_row("⏱  运行时间", uptime_str)

    # ── CPU ──
    cores = info.get("cpu_cores", "0")
    cpu_model = val(info.get("cpu_model"))
    table.add_row("⚡ CPU", f"{cpu_model}  [bold]({cores} 核)[/bold]")

    # Load Average
    load_parts = info.get("load", "").split()
    load_str = "N/A"
    if len(load_parts) >= 3:
        load_str = f"[bold]{load_parts[0]}[/bold] / {load_parts[1]} / {load_parts[2]}  (1/5/15 min)"
        try:
            if float(load_parts[0]) > int(cores):
                load_str += "  [red]⚠ 过载[/red]"
        except (ValueError, TypeError):
            pass
    table.add_row("📈 负载", load_str)

    # ── 内存 ──
    mem_total_kb = info.get("mem_total_kb", "")
    mem_avail_kb = info.get("mem_avail_kb", "")
    try:
        mt = int(mem_total_kb)
        ma = int(mem_avail_kb)
        pct = (1 - ma / mt) * 100 if mt > 0 else 0
        status = "🟢" if pct < 80 else ("🟡" if pct < 90 else "🔴")
        table.add_row(
            "💾 内存",
            f"总计 {fmt_bytes(mem_total_kb)} | 可用 {fmt_bytes(mem_avail_kb)} | "
            f"使用 [bold]{pct:.1f}%[/bold]  {status}",
        )
    except (ValueError, TypeError):
        table.add_row("💾 内存", "N/A")

    # ── Swap ──
    swap_total_kb = info.get("swap_total_kb", "0")
    swap_free_kb = info.get("swap_free_kb", "0")
    try:
        st = int(swap_total_kb)
        sf = int(swap_free_kb)
        if st > 0:
            su = st - sf
            sp = su / st * 100
            table.add_row(
                "🔄 Swap",
                f"总计 {fmt_bytes(swap_total_kb)} | 已用 {fmt_bytes(str(su))} | "
                f"使用 [bold]{sp:.1f}%[/bold]",
            )
        else:
            table.add_row("🔄 Swap", "[dim]未配置[/dim]")
    except (ValueError, TypeError):
        table.add_row("🔄 Swap", "N/A")

    # ── 磁盘 ──
    disk_out = info.get("disk", "")
    if disk_out:
        lines = disk_out.split("\n")
        if len(lines) > 1:
            disk_rows = []
            for line in lines[1:]:
                parts = line.split()
                if len(parts) >= 6 and not parts[0].startswith("tmpfs") and not parts[0].startswith("devtmpfs"):
                    disk_rows.append(f"{parts[5]}  →  {parts[4]}  (已用 {parts[2]} / 共 {parts[1]})")
            table.add_row("💿 磁盘", "\n".join(disk_rows) if disk_rows else "[dim]无数据[/dim]")

    # ── 网络 ──
    listen_count = info.get("net_listen", "0")
    table.add_row("🌐 监听端口", f"[bold]{listen_count}[/bold] 个")

    conn_out = info.get("net_conn", "")
    if conn_out:
        conn_parts = []
        for line in conn_out.strip().split("\n"):
            p = line.strip().split()
            if len(p) == 2:
                conn_parts.append(f"{p[0]}: {p[1]}")
        if conn_parts:
            table.add_row("🔗 TCP连接", "  |  ".join(conn_parts))

    # ── 进程 ──
    proc_count = info.get("proc_count", "0")
    zombie = info.get("proc_zombie", "0")
    zombie_display = f"[red]{zombie} 个 ⚠[/red]" if zombie != "0" else f"[green]{zombie} 个[/green]"
    table.add_row("📋 进程", f"总计 [bold]{proc_count}[/bold]  |  僵尸进程 {zombie_display}")

    # ── OOM ──
    oom = info.get("oom_count", "")
    if oom and oom != "0" and oom != "":
        try:
            if int(oom) > 0:
                table.add_row("🚨 OOM", f"[red]检测到 {oom} 次 OOM Killer[/red]")
            else:
                table.add_row("🚨 OOM", "[green]无记录[/green]")
        except ValueError:
            pass

    console.print()
    console.print(table)
    console.print()


# ═══════════════════════════════════════════════════════════════════
#  完整诊断脚本执行
# ═══════════════════════════════════════════════════════════════════

def run_diag_script(ssh):
    """上传 server_diag.sh 到远程服务器并执行"""
    console.print()

    # 1. 读取本地诊断脚本
    if not os.path.isfile(DIAG_SCRIPT):
        console.print(Panel(
            f"[red]未找到诊断脚本:[/red]\n  {DIAG_SCRIPT}\n\n"
            f"请确保 [bold]server_diag.sh[/bold] 与本程序在同一目录下。",
            title="❌ 错误",
            border_style="red",
        ))
        return

    with open(DIAG_SCRIPT, "r", encoding="utf-8") as f:
        script_content = f.read()

    # 2. 上传到远程 /tmp
    console.print("[cyan]⬆  正在上传诊断脚本到远程服务器...[/cyan]")
    try:
        ssh.upload_text(REMOTE_DIAG_PATH, script_content)
    except Exception as e:
        console.print(f"[red]✘ 上传失败:[/red] {e}")
        console.print("[dim]提示: 服务器可能禁用了 SFTP，可手动上传 server_diag.sh 后执行[/dim]")
        return
    console.print("[green]✔ 上传完成[/green]")

    # 3. 执行诊断
    console.print("[cyan]▶  正在执行诊断 (约 5-15 秒，含 CPU 采样)...[/cyan]")
    console.print()
    try:
        _, stdout_ch, stderr_ch = ssh.client.exec_command(
            f"bash {REMOTE_DIAG_PATH} 2>&1", timeout=120
        )
        raw_output = stdout_ch.read()
        sys.stdout.buffer.write(raw_output)
        sys.stdout.buffer.write(b"\n")
        sys.stdout.flush()
    except Exception as e:
        console.print(f"[red]✘ 诊断执行失败:[/red] {e}")

    # 4. 清理临时文件
    try:
        ssh.exec_command(f"rm -f {REMOTE_DIAG_PATH}")
    except Exception:
        pass


# ═══════════════════════════════════════════════════════════════════
#  交互式 Shell
# ═══════════════════════════════════════════════════════════════════

def interactive_shell(ssh):
    """提供交互式远程命令行"""
    console.print()
    console.print(Panel(
        "[bold]交互式远程 Shell[/bold]\n\n"
        "直接输入命令在远程服务器上执行\n"
        "输入 [bold cyan]exit[/bold cyan]、[bold cyan]quit[/bold cyan] "
        "或按 [bold cyan]Ctrl+C[/bold cyan] 返回主菜单",
        title="🖥  Shell",
        border_style="cyan",
    ))

    # 获取远程提示符信息
    _, hostname_out, _ = ssh.exec_command("hostname")
    prompt_label = hostname_out.strip() or ssh.host

    while True:
        try:
            cmd = Prompt.ask(f"\n[bold green]{ssh.username}@{prompt_label}[/bold green]")
        except (EOFError, KeyboardInterrupt):
            console.print("\n[dim]返回主菜单...[/dim]")
            break

        cmd = cmd.strip()
        if not cmd:
            continue
        if cmd.lower() in ("exit", "quit", "q"):
            console.print("[dim]返回主菜单...[/dim]")
            break

        try:
            _, stdout_ch, stderr_ch = ssh.client.exec_command(cmd, timeout=120)
            out = stdout_ch.read()
            err = stderr_ch.read()
            exit_code = stdout_ch.channel.recv_exit_status()

            if out:
                sys.stdout.buffer.write(out)
                if not out.endswith(b"\n"):
                    sys.stdout.buffer.write(b"\n")
                sys.stdout.flush()
            if err:
                sys.stderr.buffer.write(err)
                if not err.endswith(b"\n"):
                    sys.stderr.buffer.write(b"\n")
                sys.stderr.flush()

            if exit_code != 0:
                console.print(f"[dim]\\[exit code: {exit_code}][/dim]")

        except Exception as e:
            console.print(f"[red]执行失败:[/red] {e}")


# ═══════════════════════════════════════════════════════════════════
#  菜单渲染
# ═══════════════════════════════════════════════════════════════════

def print_banner():
    console.print()
    console.print(Panel(
        "[bold]Linux 远程服务器管理工具[/bold]  v1.0\n"
        "[dim]SSH 连接 → 系统信息 → 负载诊断[/dim]",
        border_style="bright_blue",
        box=box.DOUBLE,
    ))


def print_menu(connected, host="", port=0, username=""):
    console.print()
    if connected:
        console.print(
            f"  [green]● 已连接[/green]  "
            f"[bold]{username}@{host}:{port}[/bold]"
        )
    else:
        console.print("  [red]● 未连接[/red]")

    console.print(
        Panel(
            "  [bold cyan]\\[1][/bold cyan]  🔌  连接服务器\n"
            "  [bold cyan]\\[2][/bold cyan]  📊  查看系统基本信息  (快速采集)\n"
            "  [bold cyan]\\[3][/bold cyan]  🔍  运行完整负载诊断  (server_diag.sh)\n"
            "  [bold cyan]\\[4][/bold cyan]  🖥   交互式远程 Shell\n"
            "  [bold cyan]\\[5][/bold cyan]  ❌  断开连接\n"
            "  [bold cyan]\\[0][/bold cyan]  🚪  退出程序",
            title="📋 操作菜单",
            border_style="bright_blue",
        )
    )


# ═══════════════════════════════════════════════════════════════════
#  连接流程
# ═══════════════════════════════════════════════════════════════════

def do_connect(ssh):
    """引导用户输入连接信息并建立 SSH 连接"""
    if ssh.is_connected():
        console.print("[yellow]⚠ 当前已有连接，请先断开[/yellow]")
        return

    console.print()
    console.print(Panel(
        "请输入远程服务器连接信息",
        title="🔌 新建连接",
        border_style="cyan",
    ))

    host = Prompt.ask("  [bold]主机地址[/bold]  (IP 或域名)")
    port = IntPrompt.ask("  [bold]端口[/bold]", default=22)
    username = Prompt.ask("  [bold]用户名[/bold]", default="root")

    console.print()
    console.print("  认证方式:  [bold cyan]\\[1][/bold cyan] 密码    [bold cyan]\\[2][/bold cyan] 密钥文件")
    auth_type = IntPrompt.ask("  请选择", default=1)

    password = None
    key_file = None

    if auth_type == 2:
        key_file = Prompt.ask("  密钥文件路径", default="~/.ssh/id_rsa")
    else:
        console.print("  [yellow](密码将以明文显示，请注意周围环境)[/yellow]")
        password = input("  密码: ")

    console.print()
    with console.status("[bold cyan]正在连接...[/bold cyan]"):
        try:
            ssh.connect(host, port, username, password=password, key_file=key_file)
        except paramiko.AuthenticationException:
            console.print("[red]✘ 认证失败 — 用户名/密码错误或密钥不匹配[/red]")
            return
        except FileNotFoundError as e:
            console.print(f"[red]✘ {e}[/red]")
            return
        except ConnectionError as e:
            console.print(f"[red]✘ 连接失败 — {e}[/red]")
            return
        except Exception as e:
            console.print(f"[red]✘ 未知错误 — {e}[/red]")
            return

    console.print(
        f"[green]✔ 连接成功！[/green]  "
        f"[bold]{username}@{host}:{port}[/bold]"
    )


# ═══════════════════════════════════════════════════════════════════
#  主程序入口
# ═══════════════════════════════════════════════════════════════════

def main():
    ssh = SSHManager()
    print_banner()

    while True:
        try:
            # 检测连接是否断开
            if ssh.client and not ssh.is_connected():
                console.print("\n[yellow]⚠ 连接已断开[/yellow]")
                ssh.client = None

            print_menu(ssh.is_connected(), ssh.host, ssh.port, ssh.username)
            choice = IntPrompt.ask("\n  请选择操作", default=0)

            if choice == 1:
                do_connect(ssh)

            elif choice == 2:
                if not ssh.is_connected():
                    console.print("[yellow]⚠ 请先连接服务器 (选项 1)[/yellow]")
                    continue
                with console.status("[bold cyan]正在采集系统信息...[/bold cyan]"):
                    info = fetch_sysinfo(ssh)
                show_sysinfo(info)

            elif choice == 3:
                if not ssh.is_connected():
                    console.print("[yellow]⚠ 请先连接服务器 (选项 1)[/yellow]")
                    continue
                run_diag_script(ssh)

            elif choice == 4:
                if not ssh.is_connected():
                    console.print("[yellow]⚠ 请先连接服务器 (选项 1)[/yellow]")
                    continue
                interactive_shell(ssh)

            elif choice == 5:
                if ssh.is_connected():
                    ssh.disconnect()
                    console.print("[green]✔ 已断开连接[/green]")
                else:
                    console.print("[yellow]⚠ 当前未连接[/yellow]")

            elif choice == 0:
                if ssh.is_connected():
                    ssh.disconnect()
                console.print("\n  [bold blue]👋 再见！[/bold blue]\n")
                break

            else:
                console.print("[yellow]⚠ 无效选项，请重新选择[/yellow]")

        except KeyboardInterrupt:
            console.print("\n\n  [bold blue]👋 再见！[/bold blue]\n")
            ssh.disconnect()
            break
        except EOFError:
            console.print("\n\n  [bold blue]👋 再见！[/bold blue]\n")
            ssh.disconnect()
            break


def _pause_before_exit():
    """双击运行时防止窗口闪退，等待用户按键"""
    try:
        input("\n按回车键退出...")
    except (KeyboardInterrupt, EOFError):
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"\n程序出错: {e}")
        import traceback
        traceback.print_exc()
    finally:
        _pause_before_exit()
