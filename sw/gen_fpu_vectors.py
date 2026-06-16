import struct, random
random.seed(1234)
def f2b(x):  # float32 -> 32-bit int
    return struct.unpack('<I', struct.pack('<f', x))[0]
def b2f(b):
    return struct.unpack('<f', struct.pack('<I', b & 0xffffffff))[0]
def rf():  # random normal-range float32, magnitude ~ [2^-40, 2^40], no subnormals/overflow
    e = random.uniform(-40, 40)
    s = random.choice([-1,1])
    return b2f(f2b(s * (10.0**(e/13.0)) * random.uniform(0.3,3.0)))

OPS = {'ADD':0,'SUB':1,'MUL':2,'DIV':3,'SQRT':4,'CVT_WS':8,'CVT_SW':10}
vecs = []
def emit(op, a_bits, b_bits, exp_bits):
    vecs.append((OPS[op], a_bits & 0xffffffff, b_bits & 0xffffffff, exp_bits & 0xffffffff))

for _ in range(60):
    a, b = rf(), rf()
    fa, fb = f2b(a), f2b(b)
    emit('ADD', fa, fb, f2b(b2f(fa)+b2f(fb)))
    emit('SUB', fa, fb, f2b(b2f(fa)-b2f(fb)))
    emit('MUL', fa, fb, f2b(b2f(fa)*b2f(fb)))
    if b != 0: emit('DIV', fa, fb, f2b(b2f(fa)/b2f(fb)))
for _ in range(40):
    a = abs(rf())
    fa = f2b(a)
    import math
    emit('SQRT', fa, 0, f2b(math.sqrt(b2f(fa))))
# int<->float (values that fit exactly-ish; conversion is RTZ for f->int)
for _ in range(30):
    iv = random.randint(-(1<<30), (1<<30))
    emit('CVT_SW', iv & 0xffffffff, 0, f2b(float(iv)))   # int->float (may round)
for _ in range(30):
    x = rf()
    fx = f2b(x)
    tv = int(b2f(fx))   # C truncation toward zero
    tv &= 0xffffffff
    emit('CVT_WS', fx, 0, tv)

with open('tb/fpu_vectors.hex','w') as fp:
    for op,a,b,e in vecs:
        fp.write("%08x %08x %08x %08x\n" % (op,a,b,e))
print("wrote", len(vecs), "vectors")

# ---- directed special values & exact ops (append a second file) ----
import math
OPS2 = {'ADD':0,'SUB':1,'MUL':2,'DIV':3,'SGNJ':5,'MINMAX':6,'CMP':7,'FCLASS':14,'FMV_X_W':12}
INF=0x7f800000; NINF=0xff800000; QNAN=0x7fc00000; PZ=0x00000000; NZ=0x80000000
def packfl(op,fmt3,a,b,e):
    vecs2.append((op | (fmt3<<8), a&0xffffffff, b&0xffffffff, e&0xffffffff))
vecs2=[]
# arithmetic specials (numpy/host gives correct inf/nan; we match canonical qNaN 0x7fc00000)
import struct
def fb(x): return struct.unpack('<I',struct.pack('<f',x))[0]
def bf(b): return struct.unpack('<f',struct.pack('<I',b&0xffffffff))[0]
# inf + (-inf) = qNaN
packfl(0,0,INF,NINF,QNAN)
packfl(0,0,INF,fb(1.0),INF)
packfl(2,0,INF,PZ,QNAN)         # inf*0 = NV qNaN
packfl(3,0,fb(1.0),PZ,INF)      # 1/0 = inf
packfl(3,0,fb(-1.0),PZ,NINF)    # -1/0 = -inf
packfl(0,0,PZ,NZ,PZ)            # +0 + -0 = +0 (RNE)
packfl(1,0,fb(3.5),fb(3.5),PZ)  # x-x = +0
# sign inject: fsgnj/fsgnjn/fsgnjx  (fmt3 0/1/2)
packfl(5,0,fb(2.0),fb(-1.0),fb(-2.0))   # fsgnj: take sign of b
packfl(5,1,fb(2.0),fb(-1.0),fb(2.0))    # fsgnjn: ~sign of b
packfl(5,2,fb(-2.0),fb(-1.0),fb(2.0))   # fsgnjx: xor signs
# min/max (fmt3 0=min,1=max)
packfl(6,0,fb(2.0),fb(-1.0),fb(-1.0))
packfl(6,1,fb(2.0),fb(-1.0),fb(2.0))
packfl(6,0,QNAN,fb(5.0),fb(5.0))        # min(NaN,5)=5
# compare: fmt3 0=le,1=lt,2=eq -> integer 0/1
packfl(7,2,fb(1.5),fb(1.5),1)           # feq equal
packfl(7,1,fb(1.0),fb(2.0),1)           # flt
packfl(7,0,fb(2.0),fb(2.0),1)           # fle equal
packfl(7,1,fb(2.0),fb(1.0),0)           # flt false
packfl(7,2,QNAN,fb(1.0),0)              # feq with NaN = 0
packfl(7,2,PZ,NZ,1)                     # +0 == -0
# fclass
packfl(14,0,NINF,0,0x001)
packfl(14,0,fb(-2.0),0,0x002)
packfl(14,0,NZ,0,0x008)
packfl(14,0,PZ,0,0x010)
packfl(14,0,fb(2.0),0,0x040)
packfl(14,0,INF,0,0x080)
packfl(14,0,QNAN,0,0x200)
# fmv.x.w raw bits
packfl(12,0,fb(-2.5),0,fb(-2.5))
with open('tb/fpu_vectors2.hex','w') as f:
    for op,a,b,e in vecs2: f.write("%08x %08x %08x %08x\n"%(op,a,b,e))
print("wrote", len(vecs2), "directed vectors")
