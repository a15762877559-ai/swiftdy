"""Owned loopback fixture server. Never contacts Douyin or any external host."""
import argparse
import json
from pathlib import Path
import signal
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK=threading.Lock()
STATS={}
VALID=b''
CORRUPT=b''

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_): pass
    def do_GET(self):
        parts=self.path.split('/')
        if len(parts)!=3 or parts[1] not in ('list','media') or parts[2] not in {f'INT-{n:03}' for n in range(1,30)}:
            self.send_error(404);return
        stage,case=parts[1:]
        with LOCK:
            row=STATS.setdefault(case,{'list_requests':0,'media_requests':0,'credential_present':False,
                                      'media_credential_present':False,'media_range_present':False,'media_bytes_sent':0})
            row[stage+'_requests']+=1
            if stage=='list': row['credential_present']|='Cookie' in self.headers
            else:
                row['media_credential_present']|=any(k in self.headers for k in ('Cookie','Authorization','Proxy-Authorization'))
                row['media_range_present']|='Range' in self.headers
        if stage=='list':
            url=f'http://127.0.0.1:{self.server.server_port}/media/{case}'
            if case=='INT-008':url='https://unreviewed.invalid/media'
            if case=='INT-009':url=f'http://synthetic@127.0.0.1:{self.server.server_port}/media/{case}'
            video={'play_addr':{'url_list':[url],'width':64,'height':64},'duration':1000}
            item={'aweme_id':'100','desc':'synthetic integration sample','create_time':1,'author':{'nickname':'fixture'},'video':video}
            if case=='INT-004':item['images']=[{'url_list':[url]},{'url_list':[url]}]
            if case=='INT-005':item['images']=[{'url_list':[url],'video':video}]
            body=json.dumps({'status_code':0,'aweme_list':[] if case=='INT-007' else [item],'has_more':True,'max_cursor':123456}).encode()
            status=403 if case=='INT-023' else 429 if case=='INT-024' else 200
            self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers()
            try:self.wfile.write(body)
            except OSError:pass
            return
        payload=VALID;ctype='video/mp4';chunked=False;status=200
        if case=='INT-010':payload=b'<html>synthetic error</html>';ctype='text/html'
        if case=='INT-011':payload=b'{"error":"synthetic"}'
        if case=='INT-012':payload=b'\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2'+b'\0'*128
        if case=='INT-013':payload=VALID[:-64]
        if case=='INT-014':payload=CORRUPT
        if case=='INT-016':payload=b''
        if case=='INT-026':status=302;payload=b''
        size=len(payload)
        if case in ('INT-015','INT-019'):size=105906176 if case=='INT-015' else 8388608;chunked=case=='INT-015'
        self.send_response(status);self.send_header('Content-Type',ctype)
        if chunked:self.send_header('Transfer-Encoding','chunked')
        else:self.send_header('Content-Length',str(size))
        if status==302:self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/media/INT-029')
        self.end_headers()
        try:
            if case=='INT-018':time.sleep(3)
            if case in ('INT-015','INT-019'):
                prefix=b'\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2'
                offset=0
                while offset<size:
                    count=min(65536,size-offset);data=((prefix if offset==0 else b'')+b'\0'*count)[:count]
                    if chunked:self.wfile.write(f'{count:x}\r\n'.encode())
                    self.wfile.write(data)
                    if chunked:self.wfile.write(b'\r\n')
                    with LOCK:row['media_bytes_sent']+=count
                    offset+=count
                    if case=='INT-019':time.sleep(.05)
                if chunked:self.wfile.write(b'0\r\n\r\n')
            elif case=='INT-017':
                self.wfile.write(payload[:24])
                with LOCK:row['media_bytes_sent']+=24
                self.connection.shutdown(socket.SHUT_RDWR);self.connection.close()
            else:
                self.wfile.write(payload)
                with LOCK:row['media_bytes_sent']+=len(payload)
        except OSError:pass

def corrupt_mdat(data):
    changed=bytearray(data);offset=0;found=False
    while offset<len(data):
        length=int.from_bytes(data[offset:offset+4],'big');kind=data[offset+4:offset+8];header=8
        if length==1:length=int.from_bytes(data[offset+8:offset+16],'big');header=16
        elif length==0:length=len(data)-offset
        assert header<=length<=len(data)-offset
        if kind==b'mdat':changed[offset+header:offset+length]=b'\0'*(length-header);found=True
        offset+=length
    assert found
    return bytes(changed)

def main():
    global VALID,CORRUPT
    parser=argparse.ArgumentParser();parser.add_argument('--root',required=True);args=parser.parse_args()
    root=Path(args.root);VALID=(root/'fixtures/valid.mp4').read_bytes();assert 0<len(VALID)<1048576
    CORRUPT=corrupt_mdat(VALID)
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    def stop(*_):
        with LOCK:(root/'server-counters.json').write_text(json.dumps(STATS,indent=2)+'\n')
        raise SystemExit(0)
    signal.signal(signal.SIGTERM,stop)
    (root/'ready.json').write_text(json.dumps({'port':server.server_port}))
    server.serve_forever(poll_interval=.05)

if __name__=='__main__':main()
