import json
import os
import random
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import messagebox, ttk

try:
    import paramiko
except ImportError:
    paramiko = None


APP_DIR = Path(os.environ.get("APPDATA", str(Path.home()))) / "XingKongTimedSender"
CONFIG_FILE = APP_DIR / "config.json"
COMMAND_NAME = "desktop_command.json"
RESULT_NAME = "desktop_result.json"


class SenderApp:
    def __init__(self, root):
        self.root = root
        self.root.title("星空电脑端定时说说")
        self.root.geometry("720x650")
        self.root.minsize(680, 600)
        self.stop_event = threading.Event()
        self.worker = None
        self.sending = False

        self.host = tk.StringVar(value="192.168.6.242")
        self.port = tk.StringVar(value="22")
        self.user = tk.StringVar(value="mobile")
        self.password = tk.StringVar()
        self.token = tk.StringVar()
        self.interval = tk.StringVar(value="10")
        self.status = tk.StringVar(value="已停止")

        self._build_ui()
        self._load_config()
        self.root.protocol("WM_DELETE_WINDOW", self._close)

    def _build_ui(self):
        outer = ttk.Frame(self.root, padding=14)
        outer.pack(fill="both", expand=True)

        conn = ttk.LabelFrame(outer, text="手机连接", padding=10)
        conn.pack(fill="x")
        fields = [
            ("手机 IP", self.host, 18, False),
            ("SSH 端口", self.port, 8, False),
            ("SSH 用户", self.user, 12, False),
            ("SSH 密码", self.password, 16, True),
        ]
        for col, (label, var, width, secret) in enumerate(fields):
            ttk.Label(conn, text=label).grid(row=0, column=col, padx=4, sticky="w")
            ttk.Entry(conn, textvariable=var, width=width, show="*" if secret else "").grid(
                row=1, column=col, padx=4, sticky="ew"
            )
        conn.columnconfigure(0, weight=1)

        token_row = ttk.Frame(outer, padding=(0, 10, 0, 4))
        token_row.pack(fill="x")
        ttk.Label(token_row, text="电脑连接码").pack(side="left")
        ttk.Entry(token_row, textvariable=self.token).pack(side="left", fill="x", expand=True, padx=8)
        ttk.Button(token_row, text="粘贴", command=self._paste_token).pack(side="left")

        note = "在手机 App 设置页点击“电脑连接码”复制，再粘贴到这里。登录凭据不会从 App 导出。"
        ttk.Label(outer, text=note, foreground="#555").pack(anchor="w", pady=(0, 8))

        content_box = ttk.LabelFrame(outer, text="说说内容（多条内容用 | 分隔，每次随机选择一条）", padding=8)
        content_box.pack(fill="both", expand=False)
        self.contents = tk.Text(content_box, height=8, wrap="word")
        self.contents.pack(fill="both", expand=True)

        schedule = ttk.Frame(outer, padding=(0, 10))
        schedule.pack(fill="x")
        ttk.Label(schedule, text="发送间隔（分钟）").pack(side="left")
        ttk.Entry(schedule, textvariable=self.interval, width=8).pack(side="left", padx=8)
        ttk.Label(schedule, textvariable=self.status, foreground="#087f23").pack(side="right")

        buttons = ttk.Frame(outer)
        buttons.pack(fill="x", pady=(0, 10))
        ttk.Button(buttons, text="测试连接", command=self.test_connection).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="立即发送一次", command=self.send_once).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="开始定时发送", command=self.start).pack(side="left", padx=(0, 8))
        ttk.Button(buttons, text="停止", command=self.stop).pack(side="left")
        ttk.Button(buttons, text="保存配置", command=self._save_config).pack(side="right")

        log_box = ttk.LabelFrame(outer, text="发送记录", padding=8)
        log_box.pack(fill="both", expand=True)
        self.log_text = tk.Text(log_box, height=14, wrap="word", state="disabled")
        scroll = ttk.Scrollbar(log_box, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=scroll.set)
        self.log_text.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

    def _paste_token(self):
        try:
            self.token.set(self.root.clipboard_get().strip())
        except tk.TclError:
            messagebox.showinfo("提示", "剪贴板中没有文本")

    def _load_config(self):
        try:
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception:
            return
        self.host.set(data.get("host", self.host.get()))
        self.port.set(str(data.get("port", self.port.get())))
        self.user.set(data.get("user", self.user.get()))
        self.token.set(data.get("token", ""))
        self.interval.set(str(data.get("interval", self.interval.get())))
        self.contents.delete("1.0", "end")
        self.contents.insert("1.0", data.get("contents", ""))

    def _save_config(self, quiet=False):
        APP_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "host": self.host.get().strip(),
            "port": self.port.get().strip(),
            "user": self.user.get().strip(),
            "token": self.token.get().strip(),
            "interval": self.interval.get().strip(),
            "contents": self.contents.get("1.0", "end").strip(),
        }
        CONFIG_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        if not quiet:
            messagebox.showinfo("已保存", "配置已保存，SSH 密码不会保存")

    def _ui(self, callback):
        self.root.after(0, callback)

    def _log(self, content, result):
        line = f"{datetime.now():%Y-%m-%d %H:%M:%S} | {content} | {result}\n"

        def append():
            self.log_text.configure(state="normal")
            self.log_text.insert("end", line)
            self.log_text.see("end")
            self.log_text.configure(state="disabled")

        self._ui(append)

    def _validate(self, require_content=True):
        if paramiko is None:
            raise RuntimeError("当前电脑缺少 paramiko，请先安装：pip install paramiko")
        host = self.host.get().strip()
        user = self.user.get().strip()
        password = self.password.get()
        token = self.token.get().strip()
        if not host or not user or not password:
            raise RuntimeError("请填写手机 IP、SSH 用户和 SSH 密码")
        if require_content and not token:
            raise RuntimeError("请从 App 设置页复制电脑连接码")
        contents = [x.strip() for x in self.contents.get("1.0", "end").split("|") if x.strip()]
        if require_content and not contents:
            raise RuntimeError("请至少填写一条说说内容")
        try:
            port = int(self.port.get().strip())
        except ValueError:
            raise RuntimeError("SSH 端口格式错误")
        return host, port, user, password, token, contents

    def _connect(self):
        host, port, user, password, _, _ = self._validate(False)
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(host, port=port, username=user, password=password, timeout=10)
        return client

    @staticmethod
    def _exec(client, command, timeout=30):
        _, stdout, stderr = client.exec_command(command, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace").strip()
        err = stderr.read().decode("utf-8", "replace").strip()
        return out, err

    def _bridge_dir(self, client):
        command = (
            "find /var/mobile/Containers/Data/Application "
            "-path '*/Library/Caches/ShuDongTweak/patch.log' -type f "
            "-exec ls -t {} + 2>/dev/null | head -1"
        )
        path, _ = self._exec(client, command)
        if not path:
            raise RuntimeError("未找到手机端桥接目录，请确认 1.0.9 插件已安装并启动过 App")
        return str(Path(path).parent).replace("\\", "/")

    def _send_command(self, content):
        _, _, _, _, token, _ = self._validate(True)
        request_id = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:10]}"
        command = {"id": request_id, "token": token, "content": content}
        client = self._connect()
        try:
            self._exec(client, "uiopen --bundleid co.whou.pick >/dev/null 2>&1 || true")
            time.sleep(3)
            bridge_dir = self._bridge_dir(client)
            remote_command = f"{bridge_dir}/{COMMAND_NAME}"
            remote_temp = remote_command + ".tmp"
            remote_result = f"{bridge_dir}/{RESULT_NAME}"
            sftp = client.open_sftp()
            try:
                with sftp.file(remote_temp, "wb") as handle:
                    handle.write(json.dumps(command, ensure_ascii=False).encode("utf-8"))
                    handle.flush()
                try:
                    sftp.remove(remote_command)
                except IOError:
                    pass
                sftp.rename(remote_temp, remote_command)

                deadline = time.time() + 40
                while time.time() < deadline and not self.stop_event.is_set():
                    time.sleep(1)
                    try:
                        with sftp.file(remote_result, "rb") as handle:
                            result = json.loads(handle.read().decode("utf-8", "replace"))
                    except (IOError, ValueError, json.JSONDecodeError):
                        continue
                    if result.get("id") == request_id:
                        return result
            finally:
                sftp.close()
            raise RuntimeError("等待手机返回发送结果超时，请保持 App 在前台")
        finally:
            client.close()

    def _perform_send(self, content):
        try:
            result = self._send_command(content)
            if result.get("success"):
                self._log(content, "成功")
            else:
                self._log(content, "失败：" + str(result.get("message") or "未知错误"))
        except Exception as exc:
            self._log(content, "失败：" + str(exc))

    def test_connection(self):
        def task():
            try:
                client = self._connect()
                try:
                    bridge_dir = self._bridge_dir(client)
                finally:
                    client.close()
                self._log("[连接测试]", "成功：" + bridge_dir)
            except Exception as exc:
                self._log("[连接测试]", "失败：" + str(exc))

        threading.Thread(target=task, daemon=True).start()

    def send_once(self):
        if self.sending:
            messagebox.showinfo("提示", "当前正在发送，请稍候")
            return
        try:
            *_, contents = self._validate(True)
        except Exception as exc:
            messagebox.showerror("配置错误", str(exc))
            return
        content = random.choice(contents)

        def task():
            self.sending = True
            try:
                self._perform_send(content)
            finally:
                self.sending = False

        threading.Thread(target=task, daemon=True).start()

    def start(self):
        if self.worker and self.worker.is_alive():
            messagebox.showinfo("提示", "定时发送已经在运行")
            return
        try:
            *_, contents = self._validate(True)
            minutes = float(self.interval.get().strip())
            if minutes <= 0:
                raise ValueError
        except ValueError:
            messagebox.showerror("配置错误", "发送间隔必须大于 0")
            return
        except Exception as exc:
            messagebox.showerror("配置错误", str(exc))
            return

        self._save_config(True)
        self.stop_event.clear()
        self.status.set("运行中")

        def loop():
            self._log("[任务]", f"已启动，每 {minutes:g} 分钟发送")
            while not self.stop_event.is_set():
                self._perform_send(random.choice(contents))
                if self.stop_event.wait(minutes * 60):
                    break
            self._ui(lambda: self.status.set("已停止"))

        self.worker = threading.Thread(target=loop, daemon=True)
        self.worker.start()

    def stop(self):
        self.stop_event.set()
        self.status.set("正在停止")
        self._log("[任务]", "已请求停止")

    def _close(self):
        self.stop_event.set()
        self.root.destroy()


if __name__ == "__main__":
    window = tk.Tk()
    SenderApp(window)
    window.mainloop()
