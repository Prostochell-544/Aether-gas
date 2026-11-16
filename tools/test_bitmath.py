"""Port of the pure bit math from sh_spatial.lua — verifies formulas, not the Lua runtime.
LuaJIT bit.* is int32; all keys < 2^30 so Python ints behave identically here."""
import math
import random


def i32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


band = lambda *a: i32(__import__("functools").reduce(lambda p, q: p & q, a))
bor = lambda *a: i32(__import__("functools").reduce(lambda p, q: p | q, a))
bnot = lambda a: i32(~a)
lshift = lambda a, n: i32(a << n)
rshift = lambda a, n: i32((a & 0xFFFFFFFF) >> n)

GRID_MASK, GRID_BIAS, Y_STRIDE, Z_STRIDE = 1023, 512, 1024, 1 << 20
MAX_KEY = Z_STRIDE * 1024 - 1


def pack(gx, gy, gz):
    return bor(gx, lshift(gy, 10), lshift(gz, 20))


def unpack(k):
    return band(k, GRID_MASK), band(rshift(k, 10), GRID_MASK), band(rshift(k, 20), GRID_MASK)


def chunk_key_of(k):
    return bor(band(rshift(k, 3), 127), lshift(band(rshift(k, 13), 127), 7), lshift(band(rshift(k, 23), 127), 14))


def chunk_of(k):
    return chunk_key_of(k), bor(band(k, 7), lshift(band(rshift(k, 10), 7), 3), lshift(band(rshift(k, 20), 7), 6))


def chunk_voxel_key(ck, li):
    gx = bor(lshift(band(ck, 127), 3), band(li, 7))
    gy = bor(lshift(band(rshift(ck, 7), 127), 3), band(rshift(li, 3), 7))
    gz = bor(lshift(band(rshift(ck, 14), 127), 3), band(rshift(li, 6), 7))
    return bor(gx, lshift(gy, 10), lshift(gz, 20))


def voxel_center(k, s):
    gx, gy, gz = unpack(k)
    return (gx - GRID_BIAS + 0.5) * s, (gy - GRID_BIAS + 0.5) * s, (gz - GRID_BIAS + 0.5) * s


def chunk_origin(ck, s):
    s8 = s * 8
    return (band(ck, 127) - 64) * s8, (band(rshift(ck, 7), 127) - 64) * s8, (band(rshift(ck, 14), 127) - 64) * s8


def world_to_voxel(x, y, z, s):
    inv = 1 / s
    gx, gy, gz = math.floor(x * inv) + GRID_BIAS, math.floor(y * inv) + GRID_BIAS, math.floor(z * inv) + GRID_BIAS
    if min(gx, gy, gz) < 0 or max(gx, gy, gz) > GRID_MASK:
        return None
    return pack(gx, gy, gz)


FACE_KNOWN_X, FACE_WORLD_X, FACE_DYN_X = 0x1, 0x8, 0x40
CELL_KNOWN, SOLID_WORLD, SOLID_DYNAMIC, FACE_SKY_X = 0x200, 0x400, 0x800, 0x1000
FACE_KNOWN_ALL, FACE_WORLD_ALL, FACE_DYN_ALL, FACE_SKY_ALL = 0x7, 0x38, 0x1C0, 0x7000
FACE_BLOCK_X, SOLID_ANY, FULL_WORLD = 0x48, 0xC00, 0x63F
POP3 = [0, 1, 1, 2, 1, 2, 2, 3]


def cleared(f):
    wf = band(f, FACE_WORLD_ALL)
    keep = bor(wf, rshift(wf, 3), band(f, FACE_SKY_ALL))
    if band(f, SOLID_WORLD):
        keep = bor(keep, CELL_KNOWN, SOLID_WORLD)
    return keep


def pending_cost(f):
    if f is None or band(f, CELL_KNOWN) == 0:
        return 4
    if band(f, SOLID_ANY):
        return 0
    return POP3[band(bnot(f), FACE_KNOWN_ALL)]


def test_constants():
    assert FULL_WORLD == CELL_KNOWN | SOLID_WORLD | FACE_KNOWN_ALL | FACE_WORLD_ALL
    assert FACE_BLOCK_X == FACE_WORLD_X | FACE_DYN_X
    for a in range(3):
        assert lshift(FACE_BLOCK_X, a) == lshift(FACE_WORLD_X, a) | lshift(FACE_DYN_X, a)
        assert lshift(FACE_KNOWN_X, a) << 3 == lshift(FACE_WORLD_X, a)  # rshift(world,3) -> known
        assert lshift(FACE_KNOWN_X, a) << 6 == lshift(FACE_DYN_X, a)    # lshift(unknown,6) -> dyn
    all_bits = [FACE_KNOWN_ALL, FACE_WORLD_ALL, FACE_DYN_ALL, CELL_KNOWN, SOLID_WORLD, SOLID_DYNAMIC, FACE_SKY_ALL]
    acc = 0
    for b in all_bits:
        assert acc & b == 0, "overlapping flag groups"
        acc |= b
    print("constants OK")


def test_keys():
    rnd = random.Random(1)
    for _ in range(200000):
        gx, gy, gz = rnd.randrange(1024), rnd.randrange(1024), rnd.randrange(1024)
        k = pack(gx, gy, gz)
        assert 0 <= k <= MAX_KEY
        assert unpack(k) == (gx, gy, gz)
        ck, li = chunk_of(k)
        assert 0 <= ck < 1 << 21 and 0 <= li < 512
        assert chunk_voxel_key(ck, li) == k
        assert ck == (gx >> 3) | ((gy >> 3) << 7) | ((gz >> 3) << 14)
        # neighbour arithmetic == repacking
        if gx < 1023: assert k + 1 == pack(gx + 1, gy, gz)
        if gy > 0: assert k - Y_STRIDE == pack(gx, gy - 1, gz)
        if gz < 1023: assert k + Z_STRIDE == pack(gx, gy, gz + 1)
    for s in (32, 40, 64, 128):
        for _ in range(20000):
            k = pack(rnd.randrange(1024), rnd.randrange(1024), rnd.randrange(1024))
            cx, cy, cz = voxel_center(k, s)
            assert world_to_voxel(cx, cy, cz, s) == k
            ck, li = chunk_of(k)
            ox, oy, oz = chunk_origin(ck, s)
            lx, ly, lz = li & 7, (li >> 3) & 7, (li >> 6) & 7
            assert abs(ox + (lx + 0.5) * s - cx) < 1e-9 and abs(oy + (ly + 0.5) * s - cy) < 1e-9 and abs(oz + (lz + 0.5) * s - cz) < 1e-9
        # Full Source coordinate range must fit at min voxel size
        assert world_to_voxel(-16384, -16384, -16384, 32) is not None
        assert world_to_voxel(16383.9, 16383.9, 16383.9, 32) is not None
    # wraparound across row end lands on a border cell (solid)
    k = pack(1023, 5, 5)
    assert unpack(k + 1) == (0, 6, 5)  # border gx=0 -> FULL_WORLD, so no leak
    print("keys/chunks OK")


def test_flags():
    # world-blocked +Y with sky, dyn +X, open +Z, cell open
    f = CELL_KNOWN | FACE_KNOWN_ALL | lshift(FACE_WORLD_X, 1) | lshift(FACE_SKY_X, 1) | FACE_DYN_X
    c = cleared(f)
    assert c == lshift(FACE_KNOWN_X, 1) | lshift(FACE_WORLD_X, 1) | lshift(FACE_SKY_X, 1), hex(c)
    assert pending_cost(c) == 4  # cell unknown again -> worst case
    # solid world cell stays fully known
    assert cleared(FULL_WORLD) == FULL_WORLD and pending_cost(FULL_WORLD) == 0
    # solid dynamic cell -> everything forgotten
    fd = CELL_KNOWN | SOLID_DYNAMIC | FACE_KNOWN_ALL | FACE_DYN_ALL
    assert cleared(fd) == 0
    # cost counts unknown faces only
    assert pending_cost(CELL_KNOWN | FACE_KNOWN_X) == 2
    assert pending_cost(CELL_KNOWN | FACE_KNOWN_ALL) == 0
    # solid-dynamic shortcut: unknown faces -> known + dyn
    f = CELL_KNOWN | SOLID_DYNAMIC | FACE_KNOWN_X | FACE_WORLD_X
    unknown = band(bnot(f), FACE_KNOWN_ALL)
    f2 = bor(f, unknown, lshift(unknown, 6))
    assert band(f2, FACE_KNOWN_ALL) == FACE_KNOWN_ALL
    assert band(f2, FACE_DYN_ALL) == lshift(FACE_DYN_X, 1) | lshift(FACE_DYN_X, 2)
    assert band(f2, FACE_WORLD_ALL) == FACE_WORLD_X
    print("flags OK")


class Queue:
    """Literal port of the Lua ring buffer (1-based buf emulated with dict)."""

    def __init__(self, cap):
        c = 16
        while c < cap:
            c *= 2
        self.buf = {i: 0 for i in range(1, c + 1)}
        self.set, self.cap, self.head, self.count = set(), c, 0, 0

    def grow(self):
        old, oc = self.buf, self.cap
        nc = oc * 2
        buf = {}
        for i in range(self.count):
            buf[i + 1] = old[band(self.head + i, oc - 1) + 1]
        for i in range(self.count + 1, nc + 1):
            buf[i] = 0
        self.buf, self.cap, self.head = buf, nc, 0

    def push(self, k):
        if k in self.set:
            return False
        if self.count >= self.cap:
            self.grow()
        self.buf[band(self.head + self.count, self.cap - 1) + 1] = k
        self.count += 1
        self.set.add(k)
        return True

    def pop(self):
        if self.count == 0:
            return None
        k = self.buf[self.head + 1]
        self.head = band(self.head + 1, self.cap - 1)
        self.count -= 1
        self.set.discard(k)
        return k


def test_queue():
    from collections import deque
    rnd = random.Random(7)
    q, ref = Queue(16), deque()
    for step in range(200000):
        if rnd.random() < 0.55:
            k = rnd.randrange(500)
            pushed = q.push(k)
            assert pushed == (k not in ref)
            if pushed:
                ref.append(k)
        else:
            got = q.pop()
            exp = ref.popleft() if ref else None
            assert got == exp, (step, got, exp)
        assert q.count == len(ref) and q.set == set(ref)
    assert q.cap & (q.cap - 1) == 0
    print(f"ring queue OK (cap grew to {q.cap})")


test_constants()
test_keys()
test_flags()
test_queue()
