"""Diagnose the shipped engine with original audio and a local peer-wire seed.

Requires a running x86_64 Android emulator; does not launch Windows TorrServer.
"""
import hashlib
import http.server
import json
import pathlib
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ADB = pathlib.Path.home() / 'AppData/Local/Android/sdk/platform-tools/adb.exe'
def adb(*args):
    return subprocess.check_output([str(ADB), *args], text=True).strip()
def encode(value):
    if isinstance(value, int): return b'i' + str(value).encode() + b'e'
    if isinstance(value, str): return encode(value.encode())
    if isinstance(value, bytes): return str(len(value)).encode() + b':' + value
    if isinstance(value, list): return b'l' + b''.join(map(encode, value)) + b'e'
    return b'd' + b''.join(encode(k) + encode(value[k]) for k in sorted(value)) + b'e'

audio = (ROOT / 'assets/demo/01 - First light.wav.bin').read_bytes()
piece_size = 16384
info = {'name': 'original.wav', 'length': len(audio), 'piece length': piece_size,
        'pieces': b''.join(hashlib.sha1(audio[n:n+piece_size]).digest() for n in range(0, len(audio), piece_size))}
info_hash = hashlib.sha1(encode(info)).digest()
stats = {'requests': 0, 'announces': 0, 'peers': 0}
connections = set()
def receive(sock, count):
    result = b''
    while len(result) < count:
        chunk = sock.recv(count-len(result))
        if not chunk: raise EOFError()
        result += chunk
    return result
def seed(peer_port):
    if peer_port in connections: return
    connections.add(peer_port)
    forwarded = None
    try:
        forwarded = int(adb('forward', 'tcp:0', f'tcp:{peer_port}'))
        with socket.create_connection(('127.0.0.1', forwarded), timeout=20) as sock:
            sock.sendall(b'\x13BitTorrent protocol' + b'\x00'*8 + info_hash + b'-MU0001-123456789012')
            handshake = receive(sock, 68)
            print('HANDSHAKE', handshake[:20], flush=True)
            stats['peers'] += 1
            count = (len(audio)+piece_size-1)//piece_size
            field = bytearray([255]*((count+7)//8))
            if count % 8: field[-1] = (255 << (8-count%8)) & 255
            def send(mid, body): sock.sendall(struct.pack('>I', len(body)+1)+bytes([mid])+body)
            send(5, field)
            send(1, b'')
            while True:
                length = struct.unpack('>I', receive(sock, 4))[0]
                body = receive(sock, length)
                if not body: continue
                if body[0] == 6:
                    index, begin, count = struct.unpack('>III', body[1:])
                    start = index*piece_size+begin
                    send(7, struct.pack('>II', index, begin)+audio[start:start+count])
                    stats['requests'] += 1
    except Exception as exc: print('SEED', type(exc).__name__, str(exc), flush=True)
    finally:
        connections.discard(peer_port)
        if forwarded: adb('forward', '--remove', f'tcp:{forwarded}')

class Tracker(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print('HTTP', self.path, flush=True)
        query = urllib.parse.urlparse(self.path)
        if query.path == '/album.torrent': body = metainfo
        elif query.path == '/announce':
            stats['announces'] += 1
            port = int(urllib.parse.parse_qs(query.query)['port'][0])
            threading.Thread(target=seed, args=(port,), daemon=True).start()
            body = encode({'interval': 5, 'complete': 1, 'incomplete': 0, 'peers': b''})
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_): pass

tracker = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Tracker)
metainfo = encode({'announce': f'http://127.0.0.1:{tracker.server_port}/announce', 'info': info})
adb('reverse', f'tcp:{tracker.server_port}', f'tcp:{tracker.server_port}')
threading.Thread(target=tracker.serve_forever, daemon=True).start()
out = ROOT / 'test-output'
out.mkdir(exist_ok=True)
adb('shell', 'mkdir', '-p', '/data/local/tmp/mumpa-probe/state')
adb('push', str(ROOT / 'android/app/src/main/jniLibs/x86_64/libtorrserver.so'), '/data/local/tmp/mumpa-probe/torrserver')
adb('shell', 'chmod', '755', '/data/local/tmp/mumpa-probe/torrserver')
log = open(out / 'android-engine-probe.log', 'w')
engine = subprocess.Popen([str(ADB), 'shell', '/data/local/tmp/mumpa-probe/torrserver', '-p', '18090', '-i', '127.0.0.1', '-d', '/data/local/tmp/mumpa-probe/state'], stdout=log, stderr=log)
port = int(adb('forward', 'tcp:0', 'tcp:18090'))
base = f'http://127.0.0.1:{port}'
try:
    for _ in range(100):
        try:
            print('VERSION', urllib.request.urlopen(base+'/echo', timeout=1).read(), flush=True)
            break
        except Exception: time.sleep(.1)
    def request(action):
        return json.load(urllib.request.urlopen(urllib.request.Request(base+'/torrents', json.dumps(action).encode(), {'Content-Type':'application/json'}), timeout=15))
    added = request({'action':'add', 'link':f'http://127.0.0.1:{tracker.server_port}/album.torrent', 'save_to_db':True})
    torrent_hash = added['hash']
    print('ADDED', torrent_hash, flush=True)
    for _ in range(20):
        current = request({'action':'get', 'hash':torrent_hash})
        if current.get('file_stats'): break
        time.sleep(.3)
    print('INFO', current, flush=True)
    stream = base+'/stream?'+urllib.parse.urlencode({'link':torrent_hash,'index':current['file_stats'][0]['id'],'play':''})
    ranged = urllib.request.Request(stream, headers={'Range':'bytes=100-199'})
    with urllib.request.urlopen(ranged, timeout=25) as response:
        received = response.read()
        assert received == audio[100:200], (response.status, len(received))
        print('PASS', response.status, stats, flush=True)
finally:
    print('STATS', stats, flush=True)
    adb('shell', 'pkill', '-f', '^/data/local/tmp/mumpa-probe/torrserver')
    engine.wait(timeout=15)
    log.close()
    adb('forward', '--remove', f'tcp:{port}')
    adb('reverse', '--remove', f'tcp:{tracker.server_port}')
    tracker.shutdown()
