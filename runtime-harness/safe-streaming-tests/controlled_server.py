"""Loopback-only payload server. No upstream APIs or credentials. Logs counters, not headers/URLs."""
import argparse
import json
import signal
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LIMIT=104857600
LOCK=threading.Lock()
STATS={}
PREFIX=b'\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2'


class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_GET(self):
        case=self.path.removeprefix('/')
        if not case.startswith('ST-') or len(case)!=6:
            self.send_error(404);return
        with LOCK:
            row=STATS.setdefault(case,dict(requests=0,payload_bytes_written=0,cookie_seen=False,authorization_seen=False,range_seen=False,completed=False))
            row['requests']+=1
            row['cookie_seen']|='Cookie' in self.headers
            row['authorization_seen']|='Authorization' in self.headers or 'Proxy-Authorization' in self.headers
            row['range_seen']|='Range' in self.headers
        size=256*1024;status=200;ctype='video/mp4';chunked=False;drip=False
        if case=='ST-002': size=0
        if case=='ST-003': size=LIMIT+1
        if case=='ST-004': chunked=True
        if case=='ST-005': size=LIMIT-1
        if case=='ST-006': size=LIMIT
        if case=='ST-007': size=LIMIT+1024*1024;chunked=True
        if case in ('ST-009','ST-010'): status=302 if case=='ST-009' else 307;size=0
        if case=='ST-011': ctype='text/html';size=64
        if case=='ST-012': ctype='application/json';size=64
        if case=='ST-013': size=1024*1024
        if case=='ST-014': size=65536
        if case in ('ST-015','ST-016','ST-017'): size=8*1024*1024;drip=case!='ST-016'
        if case=='ST-021': status=206
        if case=='ST-022': status=206
        if case=='ST-023': status=403;size=0
        if case=='ST-024': size=64 # JSON disguised as video/mp4.
        if case=='ST-025': size=1048576;chunked=True
        if case=='ST-099': size=64 # Redirect target must never be reached.
        with LOCK: row['http_status']=status;row['payload_bytes_planned']=size
        try:
            self.send_response(status)
            self.send_header('Content-Type',ctype)
            if chunked: self.send_header('Transfer-Encoding','chunked')
            else: self.send_header('Content-Length',str(size))
            if status in (302,307): self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/ST-099')
            if case=='ST-021': self.send_header('Content-Range',f'bytes 0-{size-1}/{size}')
            if case=='ST-022': self.send_header('Content-Range',f'bytes 100-{size+99}/{size+100}')
            self.end_headers()
            if case in ('ST-009','ST-010','ST-023'): return
            if case=='ST-014': time.sleep(5)
            sent=0
            while sent<size:
                count=min(65536,size-sent)
                data=(PREFIX+b'\0'*count)[:count] if sent==0 else b'\0'*count
                if case in ('ST-011','ST-012','ST-024'): data=(b'{"error":"synthetic"}'+b' '*count)[:count]
                if chunked: self.wfile.write(f'{count:x}\r\n'.encode())
                self.wfile.write(data)
                if chunked: self.wfile.write(b'\r\n')
                self.wfile.flush();sent+=count
                with LOCK: row['payload_bytes_written']+=count
                # CFNetwork may defer response delivery until initial body bytes.
                # Advertise the oversize body, send one small piece, then await cancel.
                if case=='ST-003': return
                if case=='ST-013':
                    self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
                if drip: time.sleep(.04)
                if case=='ST-025': time.sleep(.002)
            if chunked: self.wfile.write(b'0\r\n\r\n');self.wfile.flush()
            with LOCK: row['completed']=True
        except (BrokenPipeError,ConnectionError,OSError):
            with LOCK: row['peer_closed']=True


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--directory',required=True)
    folder=Path(parser.parse_args().directory)
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    def finish(*_):
        with LOCK: (folder/'server-counters.json').write_text(json.dumps(STATS,indent=2)+'\n')
        raise SystemExit(0)
    signal.signal(signal.SIGTERM,finish)
    (folder/'server-ready.json').write_text(json.dumps({'port':server.server_port}))
    server.serve_forever(poll_interval=.05)


if __name__=='__main__':main()
