// FakeFish 内存事件 feed E2E（fakelua container.deque + event 订阅）：
//   1. 注册进场后 GET /api/feed 能看到自己的 enter 条目（预编码 JSON 字符串）
//   2. limit 钳制：1 / 0 / 2 / 非法值 / 超上限
//   3. 金币雨 feast 条目可见（x/y/count）
//   4. 触发热更 feed：hotfix_result ok，且 deque 内容不丢
//   5. 热更后再注册一名玩家，enter 仍入队同一 deque（事件订阅按名解析到新代码）
const http = require('http');
const WebSocket = require('ws');

const WS_URL = 'ws://127.0.0.1:8081/';

function log(msg) { console.log('[feed] ' + msg); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

async function getFeed(limit) {
    const res = await httpGet('/api/feed' + (limit === undefined ? '' : '?limit=' + limit));
    if (res.status !== 200) throw new Error('feed status ' + res.status);
    const j = JSON.parse(res.body.toString('utf8'));
    if (j.code !== 0 || !Array.isArray(j.list)) throw new Error('feed malformed: ' + JSON.stringify(j));
    return j;
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
        function onMsg(buf) {
            let m;
            try { m = JSON.parse(buf.toString()); } catch (e) { return; }
            try { if (pred(m)) { clearTimeout(timer); ws.removeListener('message', onMsg); resolve(m); } }
            catch (e) { return; }
        }
        ws.on('message', onMsg);
    });
}

async function register(ws, username) {
    const login = waitFrame(ws, (m) => m.type === 'login_ok' || m.type === 'register_fail', 8000);
    ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
    const lm = await login;
    if (lm.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(lm));
}

async function pollEntry(matchFn, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const f = await getFeed(100);
        const hit = f.list.find(matchFn);
        if (hit) return hit;
        await sleep(500);
    }
    throw new Error('entry not observed within ' + timeoutMs + 'ms');
}

async function run() {
    const stamp = Date.now() % 1000000;
    const username = 'feed' + stamp + String(Math.floor(Math.random() * 100)).padStart(2, '0');

    const ws = await openWs();
    await register(ws, username);
    log('registered as ' + username);

    // 1. 自己的 enter 条目
    const enter = await pollEntry((e) => e.type === 'enter' && e.name === username, 8000);
    if (typeof enter.player_id !== 'number' || enter.player_id <= 0) {
        throw new Error('enter.player_id bad: ' + JSON.stringify(enter));
    }
    if (enter.bot !== false) throw new Error('enter.bot expected false: ' + JSON.stringify(enter));
    if (typeof enter.ts !== 'number') throw new Error('enter.ts bad');
    log('PASS: enter 条目入队（player_id=' + enter.player_id + '）');

    // 2. limit 钳制
    const full = await getFeed(100);
    if (full.capacity !== 50) throw new Error('capacity expected 50, got ' + full.capacity);
    if (full.count !== full.list.length) throw new Error('count != list.length');
    if (full.count !== full.total) throw new Error('limit=100 should return everything, count=' + full.count);

    const l1 = await getFeed(1);
    if (l1.count !== 1 || l1.list.length !== 1) throw new Error('limit=1 expected single entry');
    const l0 = await getFeed(0);
    if (l0.count !== 1) throw new Error('limit=0 should clamp to 1');
    // 注意：这些请求之间世界仍在 20Hz 运行，feast（12s 周期）随时可能入队，
    // 因此只能对【单次响应自身】做钳制自洽断言，不能拿前一次的 total 当固定基线
    const lBad = await getFeed('abc');
    if (lBad.count !== Math.min(lBad.total, 20) || lBad.count > 20) {
        throw new Error('limit=abc expected default clamp 20, count=' + lBad.count + ' total=' + lBad.total);
    }
    const lHuge = await getFeed(99999);
    if (lHuge.count !== lHuge.total || lHuge.count > 100) {
        throw new Error('limit=99999 expected clamp 100 and return all, count=' + lHuge.count + ' total=' + lHuge.total);
    }
    log('PASS: limit 钳制正确（1/0→1/默认20/上限100，capacity=50，total=' + full.total + '）');

    // 3. feast 条目（服务器每 12s 一次金币雨；套件跑到这里通常已有多条）
    const feast = await pollEntry((e) => e.type === 'feast'
        && typeof e.x === 'number' && typeof e.y === 'number' && e.count === 30, 20000);
    log('PASS: feast 条目可见（x=' + feast.x + ', y=' + feast.y + '）');

    // 4. 热更 feed：NativeObject deque 必须不丢
    const beforeTotal = full.total;
    const beforeEnter = full.list.find((e) => e.type === 'enter' && e.name === username);
    if (!beforeEnter) throw new Error('our enter missing before hotfix');

    const hf = waitFrame(ws, (m) => m.type === 'hotfix_result', 15000);
    ws.send(JSON.stringify({ type: 'hotfix', token: 'test123', modules: ['feed'] }));
    const hr = await hf;
    if (!hr.results || hr.results.length !== 1 || hr.results[0].module !== 'feed'
        || hr.results[0].ok !== true) {
        throw new Error('feed hotfix failed: ' + JSON.stringify(hr));
    }
    log('hotfix feed ok=' + hr.results[0].ok);

    const after = await getFeed(100);
    if (after.total < beforeTotal) throw new Error('deque lost entries after hotfix');
    const afterEnter = after.list.find((e) => e.type === 'enter' && e.name === username
        && e.player_id === enter.player_id);
    if (!afterEnter) throw new Error('our enter entry missing after hotfix (NativeObject lost?)');
    log('PASS: 热更后 deque 内容保留（total ' + beforeTotal + ' -> ' + after.total + '）');

    // 5. 热更后事件仍写入同一 deque（新代码函数 + 恢复的对象）
    const ws2 = await openWs();
    const username2 = username + 'b';
    await register(ws2, username2);
    const enter2 = await pollEntry((e) => e.type === 'enter' && e.name === username2, 8000);
    if (enter2.bot !== false || enter2.player_id <= 0) {
        throw new Error('post-hotfix enter bad: ' + JSON.stringify(enter2));
    }
    log('PASS: 热更后新进场事件正常入队（' + username2 + ', player_id=' + enter2.player_id + '）');

    ws.close();
    ws2.close();
    console.log('=== [Feed E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Feed E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
