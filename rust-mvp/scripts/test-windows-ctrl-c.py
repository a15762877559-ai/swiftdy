"""Offline Windows console Ctrl+C smoke test; no real credentials or external endpoints."""
import argparse
import ctypes
import http.server
import json
import os
import pathlib
import re
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    if os.name != "nt":
        raise RuntimeError("WINDOWS_REQUIRED")
    exe = str(pathlib.Path(args.exe).resolve())
    help_result = subprocess.run([exe, "acceptance", "--help"], capture_output=True, check=True)
    if b"--fixture-url" not in help_result.stdout:
        raise RuntimeError("OFFLINE_TEST_BINARY_REQUIRED")
    counts = {"list": 0, "media": 0}
    forbidden_headers = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path.startswith("/list?"):
                counts["list"] += 1
                body = json.dumps({"status_code": 0, "max_cursor": 0, "has_more": False,
                    "aweme_list": [{"aweme_id": "980000000000000001", "aweme_type": 0,
                        "create_time": 1, "desc": "synthetic only", "video": {"duration": 1000,
                        "play_addr": {"url_list": [f"http://127.0.0.1:{self.server.server_port}/slow"]}}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/slow":
                counts["media"] += 1
                for key in ("Cookie", "Authorization", "Referer", "Range"):
                    if self.headers.get(key):
                        forbidden_headers.append(key)
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.end_headers()
                try:
                    for _ in range(300):
                        self.wfile.write(bytes(1024))
                        self.wfile.flush()
                        time.sleep(0.03)
                except (ConnectionError, OSError):
                    pass
            else:
                self.send_error(404)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    process = None
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    attached = False
    try:
        with tempfile.TemporaryDirectory(prefix="doustudio-ctrl-c-") as directory:
            evidence = pathlib.Path(directory) / "result.json"
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = subprocess.SW_HIDE
            process = subprocess.Popen([exe, "acceptance", "--fixture-url",
                f"http://127.0.0.1:{server.server_port}/list", "--output", directory,
                "--evidence", str(evidence)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=startup)
            started = threading.Event()
            output = bytearray()
            overflow = threading.Event()

            def drain_stdout():
                while block := process.stdout.read(4096):
                    if len(output) + len(block) > 1024 * 1024:
                        overflow.set()
                    else:
                        output.extend(block)

            def drain_stderr():
                while line := process.stderr.readline(16384):
                    match = re.search(rb'"received_bytes":\s*(\d+)', line)
                    if match and int(match.group(1)) >= 1024:
                        started.set()

            readers = [threading.Thread(target=drain_stdout), threading.Thread(target=drain_stderr)]
            for reader in readers:
                reader.start()
            process.stdin.write(b"AUTHORIZE LIST\n1\nDOWNLOAD 1\n")
            process.stdin.close()
            if not started.wait(20):
                raise RuntimeError("NO_SYNTHETIC_DOWNLOAD_PROGRESS")
            kernel.FreeConsole()
            if not kernel.AttachConsole(process.pid):
                raise RuntimeError("ATTACH_CONSOLE_FAILED")
            attached = True
            if not kernel.SetConsoleCtrlHandler(None, True):
                raise RuntimeError("HELPER_SIGNAL_GUARD_FAILED")
            if not kernel.GenerateConsoleCtrlEvent(0, 0):
                raise RuntimeError("CTRL_C_EVENT_FAILED")
            exit_code = process.wait(timeout=20)
            for reader in readers:
                reader.join(timeout=5)
            if overflow.is_set():
                raise RuntimeError("DIAGNOSTICS_OVERFLOW")
            result = json.loads(evidence.read_text(encoding="utf-8"))
            remaining_parts = list(pathlib.Path(directory).glob("*.part"))
            assert exit_code == 130, exit_code
            assert result["stop_reason"] == "CANCELLED"
            assert result["temporary_file_cleanup"] == "PASS"
            assert not result["final_file_committed"]
            assert not remaining_parts
            assert not (pathlib.Path(directory) / "accepted-video.mp4").exists()
            assert counts == {"list": 1, "media": 1}, counts
            assert not forbidden_headers
            proof = {"test": "Windows GenerateConsoleCtrlEvent CTRL_C_EVENT",
                "result": "PASS", "exit_code": exit_code, "requests": counts,
                "temporary_file_cleanup": "PASS", "final_file_committed": False,
                "application_accepted_bytes": result["application_accepted_bytes"],
                "media_credentials_observed": False, "real_worklist_requests": 0,
                "real_media_requests": 0}
            pathlib.Path(args.evidence).write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(proof))
    finally:
        if attached:
            kernel.FreeConsole()
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
