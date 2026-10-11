#!/usr/bin/env python3
"""Exercise the actual POSIX serial transport against a fragmented independent PTY logger."""
import base64
import binascii
import errno
import json
import os
import pty
import select
import struct
import subprocess
import sys
import threading
import time

binary = sys.argv[1] if len(sys.argv) > 1 else '.build/debug/tr7'

def run(command, *arguments, fault=None):
    master, slave = pty.openpty()
    path = os.ttyname(slave)
    pages = [bytearray([0xA5] * 256), bytearray([0xB6] * 256)]
    pages[0][192:200] = bytes([1, 1, 0xA5, 0xA5, 88, 2, 0, 0])
    pages[1][:124] = bytes(124)
    pages[1][:13] = b'192.168.0.150'
    pages[1][124:128] = struct.pack('<HH', 7, 8888)
    original = [bytes(page) for page in pages]
    clock = bytes([26, 10, 11, 12, 0, 0])
    seen, errors = [], []
    done = threading.Event()
    def emulate():
        nonlocal clock
        buffer = b''
        try:
            while not done.is_set():
                if not select.select([master], [], [], .1)[0]:
                    continue
                buffer += os.read(master, 4096)
                while len(buffer) >= 7:
                    size = struct.unpack('<H', buffer[3:5])[0]
                    if len(buffer) < size + 7:
                        break
                    frame, buffer = buffer[:size+7], buffer[size+7:]
                    assert frame[0] == 1
                    assert struct.unpack('>H', frame[-2:])[0] == binascii.crc_hqx(frame[:-2], 0)
                    cmd, param, payload = frame[1], frame[2], frame[5:-2]
                    seen.append((cmd, param, payload))
                    if fault == 'timeout':
                        continue
                    data, status = b'', 6
                    if cmd == 0x6D:
                        assert not payload
                        data = bytes(pages[param])
                    elif cmd == 0x6F:
                        if param == 0:
                            clock = payload
                        data = clock
                    elif cmd == 0x56:
                        data = b'Patio\0' + bytes(68)
                    elif cmd == 0x6C:
                        assert param == 0x1B
                        offset = struct.unpack('<H', payload[:2])[0]
                        assert offset in (0x100, 0xC0)
                        page, start = divmod(offset, 256)
                        assert len(payload) == (130 if page == 1 else 66)
                        if fault != 'ignore-write':
                            pages[page][start:start+len(payload)-2] = payload[2:]
                    elif cmd == 0x50:
                        assert param in (0, 0x1B) and not payload
                    else:
                        raise AssertionError(f'Unexpected command {cmd:x}')
                    if fault == 'rejected':
                        status = 0x15
                    response = bytes([1, cmd if fault != 'wrong-command' else 0xFF, status]) + struct.pack('<H', len(data)) + data
                    checksum = binascii.crc_hqx(response, 0)
                    response += struct.pack('>H', checksum ^ (1 if fault == 'crc' else 0))
                    # Deliberately split header, payload, and CRC at arbitrary boundaries.
                    for i in range(0, len(response), 3):
                        os.write(master, response[i:i+3])
                        time.sleep(.0002)
        except OSError as exc:
            if not done.is_set() and exc.errno != errno.EIO:
                errors.append(exc)
        except Exception as exc:
            errors.append(exc)
    worker = threading.Thread(target=emulate, daemon=True)
    worker.start()
    try:
        result = subprocess.run([binary, command, path, *arguments], capture_output=True, text=True, timeout=20)
    finally:
        done.set(); worker.join(1); os.close(master); os.close(slave)
    assert not errors, errors
    return result, seen, pages, original

result, seen, pages, original = run('read')
assert result.returncode == 0, result.stderr
settings = json.loads(result.stdout)
assert settings['address'] == '192.168.0.150' and settings['port'] == 8888
assert settings['name'] == 'Patio' and settings['intervalSeconds'] == 600
assert base64.b64decode(settings['page0']) == original[0]
assert not any(cmd == 0x6C for cmd, _, _ in seen)

result, seen, pages, original = run('destination', '192.168.0.56', '8000')
assert result.returncode == 0, result.stderr
assert pages[1][:12] == b'192.168.0.56' and struct.unpack('<H', pages[1][126:128])[0] == 8000
assert pages[1][124:126] == original[1][124:126] and pages[1][128:] == original[1][128:]
assert pages[0] == original[0]
assert seen[-1][:2] == (0x50, 0)

result, seen, pages, original = run('interval', '1200')
assert result.returncode == 0, result.stderr
assert pages[0][196:200] == struct.pack('<I', 1200)
assert pages[0][:196] == original[0][:196] and pages[0][200:] == original[0][200:]
assert pages[1] == original[1]

result, seen, pages, original = run('clock', '2026-10-11T20:30:00')
assert result.returncode == 0, result.stderr
assert json.loads(result.stdout)['clock']['hour'] == 20
assert (0x6F, 0, bytes([26, 10, 11, 20, 30, 0])) in seen

for fault, expected in [('crc', 'checksum'), ('wrong-command', 'different command'), ('rejected', 'rejected'), ('timeout', 'timeout')]:
    result, seen, pages, original = run('read', fault=fault)
    assert result.returncode != 0 and expected in result.stderr.lower(), (fault, result.stderr)
    assert pages == original

result, seen, pages, original = run('destination', 'new.example', '80', fault='ignore-write')
assert result.returncode != 0 and 'verification failed' in result.stderr.lower(), result.stderr
assert seen[-1][:2] == (0x50, 0)
print('PASS: 9 PTY scenarios: fragmented reads, destination/interval/clock writes, CRC, command mismatch, rejection, timeout, and failed write verification')
