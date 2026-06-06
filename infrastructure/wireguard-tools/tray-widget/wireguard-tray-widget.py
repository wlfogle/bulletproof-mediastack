#!/usr/bin/env python3
"""
WireGuard System Tray Widget for Pop!_OS
Manages native WireGuard (PiVPN) tunnel — no Docker dependency.
Provides toggle, status, peer list, and API masking proxy controls.
"""

import subprocess
import sys
import time

import requests
from PyQt5.QtCore import QThread, pyqtSignal, Qt
from PyQt5.QtGui import QColor, QFont, QIcon, QPainter, QPixmap
from PyQt5.QtWidgets import (
    QAction,
    QApplication,
    QDialog,
    QHBoxLayout,
    QLabel,
    QMenu,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSystemTrayIcon,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

import os

# ── Config ────────────────────────────────────────────────────────────────────
WG_INTERFACE = "wg0"
PIVPN_HOST = "192.168.12.244"
API_PROXY_PORT = "8080"
TOOLS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ── Helpers ───────────────────────────────────────────────────────────────────
def run_cmd(cmd, timeout=10):
    """Run a shell command and return (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except Exception as e:
        return -1, "", str(e)


def parse_wg_show(output):
    """Parse `sudo wg show` output into structured data."""
    result = {
        "interface": None,
        "public_key": None,
        "listening_port": None,
        "peers": [],
    }
    current_peer = None
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("interface:"):
            result["interface"] = line.split(":", 1)[1].strip()
        elif line.startswith("public key:"):
            if current_peer is None:
                result["public_key"] = line.split(":", 1)[1].strip()
            else:
                current_peer["public_key"] = line.split(":", 1)[1].strip()
        elif line.startswith("listening port:"):
            result["listening_port"] = line.split(":", 1)[1].strip()
        elif line.startswith("peer:"):
            current_peer = {
                "public_key": line.split(":", 1)[1].strip(),
                "endpoint": None,
                "allowed_ips": None,
                "latest_handshake": None,
                "transfer_rx": None,
                "transfer_tx": None,
                "keepalive": None,
            }
            result["peers"].append(current_peer)
        elif current_peer is not None:
            if line.startswith("endpoint:"):
                current_peer["endpoint"] = line.split(":", 1)[1].strip()
            elif line.startswith("allowed ips:"):
                current_peer["allowed_ips"] = line.split(":", 1)[1].strip()
            elif line.startswith("latest handshake:"):
                current_peer["latest_handshake"] = line.split(":", 1)[1].strip()
            elif line.startswith("transfer:"):
                parts = line.split(":", 1)[1].strip()
                if "received" in parts and "sent" in parts:
                    chunks = parts.split(",")
                    current_peer["transfer_rx"] = chunks[0].replace("received", "").strip()
                    current_peer["transfer_tx"] = (
                        chunks[1].replace("sent", "").strip() if len(chunks) > 1 else "0"
                    )
            elif line.startswith("persistent keepalive:"):
                current_peer["keepalive"] = line.split(":", 1)[1].strip()
    return result


# ── Status Checker Thread ─────────────────────────────────────────────────────
class StatusChecker(QThread):
    statusUpdated = pyqtSignal(dict)

    def __init__(self):
        super().__init__()
        self.running = True

    def run(self):
        while self.running:
            status = self._check()
            self.statusUpdated.emit(status)
            time.sleep(8)

    def stop(self):
        self.running = False
        self.quit()
        self.wait()

    def _check(self):
        status = {
            "tunnel_up": False,
            "wg_data": None,
            "api_proxy": False,
            "external_ip": "Unknown",
            "peer_count": 0,
        }

        rc, out, _ = run_cmd(f"sudo wg show {WG_INTERFACE}")
        if rc == 0 and out:
            status["tunnel_up"] = True
            status["wg_data"] = parse_wg_show(out)
            status["peer_count"] = len(status["wg_data"]["peers"])

        try:
            r = requests.get(f"http://127.0.0.1:{API_PROXY_PORT}/health", timeout=2)
            status["api_proxy"] = r.status_code == 200
        except Exception:
            pass

        try:
            r = requests.get("http://ifconfig.me", timeout=5)
            if r.status_code == 200:
                status["external_ip"] = r.text.strip()
        except Exception:
            pass

        return status


# ── Control Panel ─────────────────────────────────────────────────────────────
class ControlPanel(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("WireGuard Control Panel — PiVPN")
        self.setFixedSize(620, 560)
        self._build_ui()

    def _build_ui(self):
        layout = QVBoxLayout()

        header = QLabel("WireGuard VPN Manager")
        header.setFont(QFont("Arial", 16, QFont.Bold))
        header.setAlignment(Qt.AlignCenter)
        layout.addWidget(header)

        self.vpn_status = QLabel("VPN: Checking...")
        self.ip_status = QLabel("External IP: Checking...")
        self.proxy_status = QLabel("API Proxy: Checking...")
        self.peers_label = QLabel("Peers: Checking...")
        for lbl in (self.vpn_status, self.ip_status, self.proxy_status, self.peers_label):
            lbl.setFont(QFont("Monospace", 10))
            layout.addWidget(lbl)

        self.peer_detail = QTextEdit()
        self.peer_detail.setReadOnly(True)
        self.peer_detail.setMaximumHeight(120)
        self.peer_detail.setFont(QFont("Monospace", 9))
        layout.addWidget(self.peer_detail)

        row1 = QHBoxLayout()
        self.toggle_btn = QPushButton("Toggle VPN")
        self.toggle_btn.clicked.connect(self.toggle_vpn)
        self.toggle_btn.setStyleSheet(
            "background-color: #2196F3; color: white; font-weight: bold; padding: 6px;"
        )
        self.reconnect_btn = QPushButton("Reconnect")
        self.reconnect_btn.clicked.connect(self.reconnect_vpn)
        self.reconnect_btn.setStyleSheet(
            "background-color: #FF9800; color: white; font-weight: bold; padding: 6px;"
        )
        row1.addWidget(self.toggle_btn)
        row1.addWidget(self.reconnect_btn)
        layout.addLayout(row1)

        row2 = QHBoxLayout()
        self.start_proxy_btn = QPushButton("Start API Proxy")
        self.start_proxy_btn.clicked.connect(self.start_api_proxy)
        self.start_proxy_btn.setStyleSheet(
            "background-color: #4CAF50; color: white; font-weight: bold; padding: 6px;"
        )
        self.stop_proxy_btn = QPushButton("Stop API Proxy")
        self.stop_proxy_btn.clicked.connect(self.stop_api_proxy)
        self.stop_proxy_btn.setStyleSheet(
            "background-color: #F44336; color: white; font-weight: bold; padding: 6px;"
        )
        row2.addWidget(self.start_proxy_btn)
        row2.addWidget(self.stop_proxy_btn)
        layout.addLayout(row2)

        row3 = QHBoxLayout()
        self.test_btn = QPushButton("Test Connectivity")
        self.test_btn.clicked.connect(self.test_connectivity)
        self.test_btn.setStyleSheet(
            "background-color: #9C27B0; color: white; font-weight: bold; padding: 6px;"
        )
        self.pivpn_btn = QPushButton("PiVPN Status (SSH)")
        self.pivpn_btn.clicked.connect(self.pivpn_status)
        self.pivpn_btn.setStyleSheet(
            "background-color: #607D8B; color: white; font-weight: bold; padding: 6px;"
        )
        row3.addWidget(self.test_btn)
        row3.addWidget(self.pivpn_btn)
        layout.addLayout(row3)

        self.progress = QProgressBar()
        self.progress.setVisible(False)
        layout.addWidget(self.progress)

        layout.addWidget(QLabel("Log:"))
        self.log_output = QTextEdit()
        self.log_output.setMaximumHeight(100)
        self.log_output.setFont(QFont("Monospace", 8))
        self.log_output.setReadOnly(True)
        layout.addWidget(self.log_output)

        self.setLayout(layout)

    def update_status(self, status):
        if status["tunnel_up"]:
            wg = status["wg_data"]
            n = status["peer_count"]
            self.vpn_status.setText(f"VPN: Connected ({WG_INTERFACE}, {n} peer(s))")
            self.vpn_status.setStyleSheet("color: green; font-weight: bold;")
            self.toggle_btn.setText("Disconnect VPN")
            self.toggle_btn.setStyleSheet(
                "background-color: #F44336; color: white; font-weight: bold; padding: 6px;"
            )
            lines = []
            for p in (wg["peers"] if wg else []):
                ep = p.get("endpoint") or "?"
                hs = p.get("latest_handshake") or "never"
                rx = p.get("transfer_rx") or "0"
                tx = p.get("transfer_tx") or "0"
                lines.append(f"  {ep}  handshake: {hs}  rx: {rx}  tx: {tx}")
            self.peer_detail.setPlainText("\n".join(lines) if lines else "No peers")
            self.peers_label.setText(f"Peers: {n}")
        else:
            self.vpn_status.setText("VPN: Disconnected")
            self.vpn_status.setStyleSheet("color: red; font-weight: bold;")
            self.toggle_btn.setText("Connect VPN")
            self.toggle_btn.setStyleSheet(
                "background-color: #4CAF50; color: white; font-weight: bold; padding: 6px;"
            )
            self.peer_detail.setPlainText("")
            self.peers_label.setText("Peers: —")

        self.ip_status.setText(f"External IP: {status['external_ip']}")

        if status["api_proxy"]:
            self.proxy_status.setText(f"API Proxy: Active (:{API_PROXY_PORT})")
            self.proxy_status.setStyleSheet("color: green; font-weight: bold;")
        else:
            self.proxy_status.setText("API Proxy: Inactive")
            self.proxy_status.setStyleSheet("color: red; font-weight: bold;")

    def _log(self, msg):
        ts = time.strftime("%H:%M:%S")
        self.log_output.append(f"[{ts}] {msg}")
        self.log_output.ensureCursorVisible()

    def _run(self, cmd, ok_msg, fail_msg):
        self.progress.setVisible(True)
        self.progress.setRange(0, 0)
        rc, out, err = run_cmd(cmd, timeout=30)
        if rc == 0:
            self._log(f"OK: {ok_msg}")
            if out:
                self._log(out[:300])
        else:
            self._log(f"FAIL: {fail_msg}")
            if err:
                self._log(err[:300])
        self.progress.setVisible(False)

    def toggle_vpn(self):
        rc, _, _ = run_cmd(f"sudo wg show {WG_INTERFACE}")
        if rc == 0:
            self._log("Disconnecting VPN...")
            self._run(f"sudo wg-quick down {WG_INTERFACE}", "VPN disconnected", "Failed to disconnect")
        else:
            self._log("Connecting VPN...")
            self._run(f"sudo wg-quick up {WG_INTERFACE}", "VPN connected", "Failed to connect")

    def reconnect_vpn(self):
        self._log("Reconnecting VPN...")
        self._run(
            f"sudo wg-quick down {WG_INTERFACE} 2>/dev/null; sudo wg-quick up {WG_INTERFACE}",
            "VPN reconnected",
            "Reconnect failed",
        )

    def start_api_proxy(self):
        proxy_script = os.path.join(TOOLS_DIR, "api-masking", "api-mask-proxy.py")
        if not os.path.isfile(proxy_script):
            self._log(f"FAIL: proxy script not found at {proxy_script}")
            return
        self._log("Starting API proxy...")
        log_file = os.path.join(TOOLS_DIR, "api-proxy.log")
        self._run(
            f'nohup python3 "{proxy_script}" > "{log_file}" 2>&1 &',
            "API proxy started",
            "Failed to start API proxy",
        )

    def stop_api_proxy(self):
        self._log("Stopping API proxy...")
        self._run('pkill -f "api-mask-proxy.py"', "API proxy stopped", "Stop failed")

    def test_connectivity(self):
        self._log("Testing connectivity...")
        targets = [
            ("PiVPN server (10.92.29.1)", "ping -c 1 -W 3 10.92.29.1"),
            ("Bahamut LAN (192.168.12.244)", "ping -c 1 -W 3 192.168.12.244"),
            ("Internet (1.1.1.1)", "ping -c 1 -W 3 1.1.1.1"),
            ("DNS (google.com)", "ping -c 1 -W 3 google.com"),
        ]
        for label, cmd in targets:
            rc, _, _ = run_cmd(cmd, timeout=5)
            tag = "OK" if rc == 0 else "FAIL"
            self._log(f"  {tag}: {label}")

    def pivpn_status(self):
        self._log("Querying PiVPN on Bahamut...")
        rc, out, err = run_cmd(
            f"ssh -o ConnectTimeout=5 -o BatchMode=yes root@{PIVPN_HOST} 'pivpn -l 2>&1'",
            timeout=15,
        )
        if rc == 0 and out:
            self._log(out[:500])
        else:
            self._log(f"FAIL: {err[:200]}")


# ── Tray Icon ─────────────────────────────────────────────────────────────────
class WireGuardTrayWidget(QWidget):
    def __init__(self):
        super().__init__()

        if not QSystemTrayIcon.isSystemTrayAvailable():
            QMessageBox.critical(
                None, "System Tray", "System tray is not available on this system."
            )
            sys.exit(1)

        self.control_panel = None
        self.current_status = {}

        self.tray_icon = QSystemTrayIcon(self)
        self._set_icon_color(QColor(33, 150, 243))

        self.act_panel = QAction("Control Panel", self)
        self.act_panel.triggered.connect(self.show_panel)

        self.act_toggle = QAction("Connect VPN", self)
        self.act_toggle.triggered.connect(self.quick_toggle)

        self.act_reconnect = QAction("Reconnect", self)
        self.act_reconnect.triggered.connect(self.quick_reconnect)

        self.act_status = QAction("Status", self)
        self.act_status.triggered.connect(self.show_status)

        self.act_quit = QAction("Quit", self)
        self.act_quit.triggered.connect(self.quit_app)

        menu = QMenu()
        menu.addAction(self.act_panel)
        menu.addSeparator()
        menu.addAction(self.act_toggle)
        menu.addAction(self.act_reconnect)
        menu.addSeparator()
        menu.addAction(self.act_status)
        menu.addSeparator()
        menu.addAction(self.act_quit)
        self.tray_icon.setContextMenu(menu)
        self.tray_icon.activated.connect(self._on_activated)

        self.checker = StatusChecker()
        self.checker.statusUpdated.connect(self._on_status)
        self.checker.start()

        self.tray_icon.show()
        self.tray_icon.setToolTip("WireGuard Manager — Initializing...")

    def _on_activated(self, reason):
        if reason in (QSystemTrayIcon.DoubleClick, QSystemTrayIcon.Trigger):
            self.show_panel()

    def show_panel(self):
        if self.control_panel is None:
            self.control_panel = ControlPanel()
            self.checker.statusUpdated.connect(self.control_panel.update_status)
        self.control_panel.show()
        self.control_panel.raise_()
        self.control_panel.activateWindow()

    def quick_toggle(self):
        rc, _, _ = run_cmd(f"sudo wg show {WG_INTERFACE}")
        if rc == 0:
            run_cmd(f"sudo wg-quick down {WG_INTERFACE}")
            self.tray_icon.showMessage(
                "WireGuard", "VPN disconnected", QSystemTrayIcon.Information, 3000
            )
        else:
            run_cmd(f"sudo wg-quick up {WG_INTERFACE}")
            self.tray_icon.showMessage(
                "WireGuard", "VPN connected", QSystemTrayIcon.Information, 3000
            )

    def quick_reconnect(self):
        run_cmd(f"sudo wg-quick down {WG_INTERFACE} 2>/dev/null; sudo wg-quick up {WG_INTERFACE}")
        self.tray_icon.showMessage(
            "WireGuard", "VPN reconnected", QSystemTrayIcon.Information, 3000
        )

    def show_status(self):
        s = self.current_status
        vpn = "Connected" if s.get("tunnel_up") else "Disconnected"
        ip_addr = s.get("external_ip", "Unknown")
        peers = s.get("peer_count", 0)
        proxy = "Active" if s.get("api_proxy") else "Inactive"
        msg = f"VPN: {vpn}\nPeers: {peers}\nProxy: {proxy}\nIP: {ip_addr}"
        self.tray_icon.showMessage("WireGuard Status", msg, QSystemTrayIcon.Information, 5000)

    def _on_status(self, status):
        self.current_status = status
        up = status.get("tunnel_up", False)
        ip_addr = status.get("external_ip", "Unknown")
        peers = status.get("peer_count", 0)

        if up:
            self._set_icon_color(QColor(76, 175, 80))
            self.act_toggle.setText("Disconnect VPN")
            self.tray_icon.setToolTip(f"WireGuard: Connected | {peers} peers | IP: {ip_addr}")
        else:
            self._set_icon_color(QColor(244, 67, 54))
            self.act_toggle.setText("Connect VPN")
            self.tray_icon.setToolTip(f"WireGuard: Disconnected | IP: {ip_addr}")

    def _set_icon_color(self, color):
        pixmap = QPixmap(22, 22)
        pixmap.fill(QColor(0, 0, 0, 0))
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setBrush(color)
        painter.setPen(QColor(255, 255, 255))
        painter.drawRoundedRect(2, 2, 18, 18, 4, 4)
        painter.setPen(QColor(255, 255, 255))
        painter.setFont(QFont("Arial", 11, QFont.Bold))
        painter.drawText(5, 16, "W")
        painter.end()
        self.tray_icon.setIcon(QIcon(pixmap))

    def quit_app(self):
        self.checker.stop()
        if self.control_panel:
            self.control_panel.close()
        QApplication.quit()


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("WireGuard Manager")
    app.setApplicationVersion("2.0")
    app.setOrganizationName("bulletproof-mediastack")

    widget = WireGuardTrayWidget()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
