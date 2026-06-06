#!/usr/bin/env python3
"""
gdbstub.py - a GDB Remote Serial Protocol (RSP) server for the hardware
debug module (rtl/debug_module.v). It lets a real riscv64-unknown-elf-gdb
halt/step/inspect the core:

    (host)  gdb  <--TCP :3333-->  gdbstub.py  <--transport-->  debug_module (DMI)

gdbstub.py speaks RSP to gdb and translates each request into DMI register
accesses. The transport is pluggable:
  * SerialDMI  - talk to an on-board debug-UART bridge (real hardware).
  * MockDMI    - an in-process model of the DM + a toy core, used by the
                 built-in self-test (`python3 gdbstub.py --selftest`) so the
                 RSP logic is verifiable without gdb or hardware.

DMI register map (matches rtl/debug_module.v):
  0x00 CONTROL(W) bit0 halt / bit1 resume / bit2 step
  0x04 STATUS(R)  bit0 halted
  0x08 REGSEL(W)  0x0C REGDATA(RW)  0x10 DPC(RW)
  0x14 MEMADDR(W) 0x18 MEMDATA(RW)
  0x1C BPSEL(W)   0x20 BPSET(W)     0x24 BPCLR(W)
"""
import socket, sys

CONTROL, STATUS, REGSEL, REGDATA, DPC, MEMADDR, MEMDATA, BPSEL, BPSET, BPCLR = \
    0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24
NBP = 4

# ----------------------------------------------------------------------
# Transports: must provide w32(addr, val) and r32(addr) -> int
# ----------------------------------------------------------------------
class SerialDMI:
    """Real hardware: a tiny framed protocol to an on-board debug-UART bridge.
       'W' addr(4 LE) data(4 LE)  ->  (no reply)
       'R' addr(4 LE)             ->  data(4 LE)
       (The bridge RTL turns these into DMI accesses.)"""
    def __init__(self, port, baud=115200):
        import serial                       # pip install pyserial
        self.s = serial.Serial(port, baud, timeout=2)
    def w32(self, a, v):
        self.s.write(b'W' + a.to_bytes(4,'little') + (v & 0xffffffff).to_bytes(4,'little'))
    def r32(self, a):
        self.s.write(b'R' + a.to_bytes(4,'little'))
        return int.from_bytes(self.s.read(4), 'little')

class MockDMI:
    """In-process model of debug_module.v + a toy core, for the self-test."""
    def __init__(self):
        self.regs = [0]*32; self.pc = 0x100; self.mem = {}
        self.halted = True; self.regsel = 0; self.memaddr = 0
        self.bpsel = 0; self.bp = [None]*NBP
        self.regs[15] = 42                  # something to read back
    def _run(self, step):
        # toy "execution": advance pc, stop at a breakpoint or after one step
        for _ in range(100000):
            self.pc = (self.pc + 4) & 0xffffffff
            if self.pc in [b for b in self.bp if b is not None]:
                self.halted = True; return
            if step:
                self.halted = True; return
        self.halted = True
    def w32(self, a, v):
        v &= 0xffffffff
        if a == CONTROL:
            if v & 1: self.halted = True
            if v & 2: self.halted = False; self._run(step=False)
            if v & 4: self.halted = False; self._run(step=True)
        elif a == REGSEL:  self.regsel = v & 31
        elif a == REGDATA: self.regs[self.regsel] = v
        elif a == DPC:     self.pc = v          # NOTE: DPC==REGDATA addr clash avoided below
        elif a == MEMADDR: self.memaddr = v
        elif a == MEMDATA: self.mem[self.memaddr & ~3] = v
        elif a == BPSEL:   self.bpsel = v % NBP
        elif a == BPSET:   self.bp[self.bpsel] = v
        elif a == BPCLR:   self.bp[self.bpsel] = None
    def r32(self, a):
        if a == STATUS:  return 1 if self.halted else 0
        if a == REGDATA: return self.regs[self.regsel]
        if a == DPC:     return self.pc
        if a == MEMDATA: return self.mem.get(self.memaddr & ~3, 0)
        return 0

# ----------------------------------------------------------------------
# RSP server
# ----------------------------------------------------------------------
class GdbStub:
    def __init__(self, dmi):
        self.dmi = dmi
        self.bp_slots = {}                  # addr -> bp index

    # ---- core operations via DMI ----
    def halt(self):   self.dmi.w32(CONTROL, 1)
    def cont(self):   self.dmi.w32(CONTROL, 2)
    def step(self):   self.dmi.w32(CONTROL, 4)
    def is_halted(self): return self.dmi.r32(STATUS) & 1
    def rd_reg(self, i):
        if i == 32: return self.dmi.r32(DPC)
        self.dmi.w32(REGSEL, i); return self.dmi.r32(REGDATA)
    def wr_reg(self, i, v):
        if i == 32: self.dmi.w32(DPC, v); return
        self.dmi.w32(REGSEL, i); self.dmi.w32(REGDATA, v)
    def rd_word(self, a):
        self.dmi.w32(MEMADDR, a & ~3); return self.dmi.r32(MEMDATA)
    def wr_word(self, a, v):
        self.dmi.w32(MEMADDR, a & ~3); self.dmi.w32(MEMDATA, v)
    def rd_mem(self, addr, length):
        out = bytearray()
        for off in range(length):
            a = addr + off
            out.append((self.rd_word(a) >> (8*(a & 3))) & 0xff)
        return bytes(out)
    def wr_mem(self, addr, data):
        for off, b in enumerate(data):
            a = addr + off; w = self.rd_word(a)
            sh = 8*(a & 3); w = (w & ~(0xff << sh)) | (b << sh); self.wr_word(a, w)
    def set_bp(self, addr):
        idx = len(self.bp_slots) % NBP
        self.bp_slots[addr] = idx
        self.dmi.w32(BPSEL, idx); self.dmi.w32(BPSET, addr)
    def clr_bp(self, addr):
        if addr in self.bp_slots:
            self.dmi.w32(BPSEL, self.bp_slots[addr]); self.dmi.w32(BPCLR, 0)
            del self.bp_slots[addr]

    # ---- RSP packet handling ----
    @staticmethod
    def _hexreg(v): return ''.join('%02x' % ((v >> (8*i)) & 0xff) for i in range(4))  # LE

    def handle(self, pkt):
        """Map one RSP packet body to a response body (str)."""
        c = pkt[0] if pkt else ''
        if pkt.startswith('qSupported'): return 'PacketSize=1000;hwbreak+'
        if pkt == 'qAttached':           return '1'
        if pkt in ('qC', 'qfThreadInfo', 'qsThreadInfo', 'qTStatus'):
            return '' if pkt != 'qfThreadInfo' else 'm0'
        if c == '?':  self.halt();        return 'S05'
        if c == 'g':                                  # read all regs
            return ''.join(self._hexreg(self.rd_reg(i)) for i in range(33))
        if c == 'G':
            data = pkt[1:]
            for i in range(33):
                v = int.from_bytes(bytes.fromhex(data[i*8:i*8+8]), 'little')
                self.wr_reg(i, v)
            return 'OK'
        if c == 'p':
            return self._hexreg(self.rd_reg(int(pkt[1:], 16)))
        if c == 'P':
            r, v = pkt[1:].split('='); self.wr_reg(int(r,16),
                int.from_bytes(bytes.fromhex(v),'little')); return 'OK'
        if c == 'm':
            a, l = pkt[1:].split(','); return self.rd_mem(int(a,16), int(l,16)).hex()
        if c == 'M':
            head, data = pkt[1:].split(':'); a, l = head.split(',')
            self.wr_mem(int(a,16), bytes.fromhex(data)); return 'OK'
        if c == 'c':  self.cont();  return 'S05'
        if c == 's':  self.step();  return 'S05'
        if c in ('Z', 'z'):
            typ, addr, _ = pkt[1:].split(',')
            if typ in ('0','1'):
                (self.set_bp if c=='Z' else self.clr_bp)(int(addr,16)); return 'OK'
            return ''
        return ''                                     # unsupported -> empty

# ----------------------------------------------------------------------
def _checksum(s): return sum(s.encode()) & 0xff
def _frame(body): return '$%s#%02x' % (body, _checksum(body))

def serve(stub, host='localhost', port=3333):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port)); srv.listen(1)
    print('gdbstub: listening on %s:%d  (target remote :%d)' % (host, port, port))
    conn, _ = srv.accept(); buf = ''
    while True:
        data = conn.recv(4096)
        if not data: break
        buf += data.decode('latin1')
        while '#' in buf and buf.index('#') + 2 < len(buf):
            if buf[0] == '\x03':                       # gdb ctrl-C
                stub.halt(); conn.sendall(b'+' + _frame('S05').encode()); buf = buf[1:]; continue
            i = buf.index('$'); j = buf.index('#', i)
            body = buf[i+1:j]; buf = buf[j+3:]
            conn.sendall(b'+')
            conn.sendall(_frame(stub.handle(body)).encode())

# ----------------------------------------------------------------------
def selftest():
    """Exercise the RSP handlers against the mock DM."""
    dmi = MockDMI(); s = GdbStub(dmi); ok = True
    def chk(name, got, want):
        nonlocal ok
        print('  %-22s %s' % (name, 'OK' if got == want else 'FAIL got=%r want=%r' % (got, want)))
        ok = ok and got == want
    chk('qSupported', 'hwbreak+' in s.handle('qSupported'), True)
    chk('? halts -> S05', s.handle('?'), 'S05')
    chk('halted', s.is_halted(), True)
    chk('read x15 (p f)', s.handle('pf'), GdbStub._hexreg(42))
    s.handle('P6=efbeadde')                       # write x6 = 0xDEADBEEF (LE hex)
    chk('write/read x6', s.handle('p6'), GdbStub._hexreg(0xDEADBEEF))
    s.handle('M300,4:78563412')                   # mem[0x300] = 0x12345678
    chk('write/read mem', s.handle('m300,4'), '78563412')
    g = s.handle('g'); chk('g len (33 regs)', len(g), 33*8)
    pc0 = s.rd_reg(32); s.handle('s'); pc1 = s.rd_reg(32)
    chk('single-step advances pc', pc1 != pc0, True)
    s.handle('Z1,200,4'); s.handle('c')           # bp at 0x200, continue -> should stop there
    chk('breakpoint stop pc', s.rd_reg(32), 0x200)
    print('SELFTEST:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1

if __name__ == '__main__':
    if '--selftest' in sys.argv:
        sys.exit(selftest())
    # real use: pick a transport, e.g. SerialDMI('/dev/ttyUSB1'), then serve.
    port = sys.argv[1] if len(sys.argv) > 1 else None
    if not port:
        print('usage: gdbstub.py <serial-port>   |   gdbstub.py --selftest'); sys.exit(2)
    serve(GdbStub(SerialDMI(port)))
