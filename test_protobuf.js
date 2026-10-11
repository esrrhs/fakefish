// FakeFish protobuf 世界快照 E2E（fakelua protobuf）：
//   GET /api/world.pbf 返回 WorldSnapshot(PlayerCell 重复字段) 二进制帧，
//   用 Node 手写 proto3 wire-format 解码器逐字段断言（不依赖 protobufjs）：
//     1. 注册一个玩家后，快照中能找到该玩家（id/cell/name/x/y/gold/r/bot）
//     2. online>=1，地图尺寸 2000x2000
//     3. Content-Type 为二进制帧
//   另测 /api/codec/selftest（serialize 往返 + base91 文本往返）。
const http = require('http');
const WebSocket = require('ws');

const WS_URL = 'ws://127.0.0.1:8081/';

function log(msg) { console.log('[protobuf] ' + msg); }

function httpGet(path, headers = {}) {
    return new Promise((resolve, reject) => {
        const req = http.request({
            host: '127.0.0.1', port: 8080, path, method: 'GET', headers
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                headers: res.headers,
                body: Buffer.concat(chunks)
            }));
        });
        req.on('error', reject);
        req.end();
    });
}

// ---- 极简 proto3 wire decoder ----
function readVarint(buf, pos) {
    let result = 0n;
    let shift = 0n;
    while (true) {
        const b = buf[pos++];
        result |= BigInt(b & 0x7f) << shift;
        if ((b & 0x80) === 0) break;
        shift += 7n;
    }
    return [result, pos];
}

// 只解需要的两层：WorldSnapshot{ repeated PlayerCell=1(LEN), int64 online=2 ... }
// PlayerCell{ int64 id=1, int32 cell=2, string name=3, double x=4, double y=5,
//             int64 gold=6, double r=7, bool bot=8, string fx=9 }
function decodePlayerCell(buf) {
    const p = {};
    let pos = 0;
    while (pos < buf.length) {
        let tag;
        [tag, pos] = readVarint(buf, pos);
        const field = Number(tag >> 3n);
        const wire = Number(tag & 7n);
        if (wire === 0) {
            let v;
            [v, pos] = readVarint(buf, pos);
            if (field === 1) p.id = v;
            else if (field === 2) p.cell = Number(v);
            else if (field === 6) p.gold = Number(v);
            else if (field === 8) p.bot = v !== 0n;
        } else if (wire === 2) {
            let len;
            [len, pos] = readVarint(buf, pos);
            const raw = buf.subarray(pos, pos + Number(len));
            pos += Number(len);
            if (field === 3) p.name = raw.toString('utf8');
            else if (field === 9) p.fx = raw.toString('utf8');
        } else if (wire === 1) {
            // 64-bit fixed → little-endian double
            const raw = buf.subarray(pos, pos + 8);
            pos += 8;
            const d = raw.readDoubleLE(0);
            if (field === 4) p.x = d;
            else if (field === 5) p.y = d;
            else if (field === 7) p.r = d;
        } else if (wire === 5) {
            pos += 4;
        } else {
            throw new Error('unexpected wire type ' + wire + ' at field ' + field);
        }
    }
    return p;
}

function decodeWorldSnapshot(buf) {
    const s = { players: [] };
    let pos = 0;
    while (pos < buf.length) {
        let tag;
        [tag, pos] = readVarint(buf, pos);
        const field = Number(tag >> 3n);
        const wire = Number(tag & 7n);
        if (wire === 0) {
            let v;
            [v, pos] = readVarint(buf, pos);
            if (field === 2) s.online = Number(v);
            else if (field === 3) s.bots = Number(v);
            else if (field === 4) s.ts = Number(v);
            else if (field === 5) s.map_width = Number(v);
            else if (field === 6) s.map_height = Number(v);
        } else if (wire === 2) {
            let len;
            [len, pos] = readVarint(buf, pos);
            const raw = buf.subarray(pos, pos + Number(len));
            pos += Number(len);
            if (field === 1) s.players.push(decodePlayerCell(raw));
        } else {
            throw new Error('unexpected wire type ' + wire + ' at field ' + field);
        }
    }
    // proto3：零值标量不上线，按语言默认值补齐
    if (s.online === undefined) s.online = 0;
    if (s.bots === undefined) s.bots = 0;
    for (const p of s.players) {
        if (p.bot === undefined) p.bot = false;
        if (p.cell === undefined) p.cell = 0;
        if (p.gold === undefined) p.gold = 0;
    }
    return s;
}

async function openWs() {
    const ws = new WebSocket(WS_URL);
    await new Promise((resolve, reject) => {
        ws.once('open', resolve);
        ws.once('error', reject);
    });
    return ws;
}

function waitFrame(ws, pred, timeoutMs) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            ws.removeListener('message', onMsg);
            reject(new Error('wait frame timeout'));
        }, timeoutMs);
        function onMsg(bbuf) {
            let m;
            try { m = JSON.parse(bbuf.toString()); } catch (e) { return; }
            try { if (pred(m)) { clearTimeout(timer); ws.removeListener('message', onMsg); resolve(m); } }
            catch (e) { return; }
        }
        ws.on('message', onMsg);
    });
}

async function run() {
    const ws = await openWs();
    const stamp = Date.now() % 1000000;
    const username = 'pbf' + stamp + String(Math.floor(Math.random() * 100)).padStart(2, '0');

    const login = waitFrame(ws, (m) => m.type === 'login_ok' || m.type === 'register_fail', 8000);
    ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
    const lm = await login;
    if (lm.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(lm));
    log('registered as ' + username);

    // 1. 二进制世界快照
    const res = await httpGet('/api/world.pbf');
    if (res.status !== 200) throw new Error('world.pbf status ' + res.status);
    const ct = res.headers['content-type'] || '';
    if (ct !== 'application/x-protobuf') {
        throw new Error('expected application/x-protobuf, got: ' + ct);
    }
    if (res.body.length < 2) throw new Error('world.pbf body too small: ' + res.body.length);

    const snap = decodeWorldSnapshot(res.body);
    log('decoded snapshot: players=' + snap.players.length + ' online=' + snap.online
        + ' bots=' + snap.bots + ' map=' + snap.map_width + 'x' + snap.map_height);

    if (!Array.isArray(snap.players) || snap.players.length < 1) {
        throw new Error('snapshot has no players');
    }
    if (typeof snap.online !== 'number' || snap.online < 1) {
        throw new Error('online expected >=1, got ' + snap.online);
    }
    if (snap.map_width !== 2000 || snap.map_height !== 2000) {
        throw new Error('map dims expected 2000x2000, got ' + snap.map_width + 'x' + snap.map_height);
    }
    if (typeof snap.ts !== 'number' || snap.ts <= 0) {
        throw new Error('ts expected positive epoch seconds');
    }

    const me = snap.players.find((p) => p.name === username);
    if (!me) throw new Error('our player not found in snapshot: ' + username);
    if (typeof me.id !== 'bigint' || me.id <= 0n) throw new Error('bad id: ' + me.id);
    if (me.cell !== 1) throw new Error('cell expected 1, got ' + me.cell);
    if (me.gold !== 100) throw new Error('gold expected 100, got ' + me.gold);
    if (typeof me.x !== 'number' || me.x < 0 || me.x > 2000) throw new Error('x out of range: ' + me.x);
    if (typeof me.y !== 'number' || me.y < 0 || me.y > 2000) throw new Error('y out of range: ' + me.y);
    if (typeof me.r !== 'number' || !(me.r > 0)) throw new Error('r expected >0, got ' + me.r);
    if (me.bot !== false) throw new Error('bot expected false for human player');
    log('PASS: PlayerCell 字段正确（id=' + me.id + ', gold=' + me.gold
        + ', x=' + me.x.toFixed(1) + ', y=' + me.y.toFixed(1) + ', r=' + me.r.toFixed(1) + '）');

    // 2. serialize / base91 自检端点
    const st = await httpGet('/api/codec/selftest');
    if (st.status !== 200) throw new Error('selftest status ' + st.status);
    const j = JSON.parse(st.body.toString('utf8'));
    if (j.code !== 0 || j.ok !== true) throw new Error('selftest not ok: ' + JSON.stringify(j));
    if (j.bin_equal !== true) throw new Error('serialize roundtrip mismatch: ' + JSON.stringify(j));
    if (j.text_equal !== true) throw new Error('base91 roundtrip mismatch: ' + JSON.stringify(j));
    if (typeof j.bin_len !== 'number' || j.bin_len <= 0) throw new Error('bad bin_len');
    log('PASS: codec selftest 通过（serialize + base91 往返一致，bin_len=' + j.bin_len + '）');

    ws.close();
    console.log('=== [Protobuf E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Protobuf E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
