// FakeFish SQLite 事件流水账本 E2E（server/ledger.lua，HTTP /api/events）：
//   1. 注册进场 → 账本出现该玩家的 enter 事件
//   2. type 过滤只返回对应类型；limit 被钳制（非数值默认 20、上限 100、下限 1）
//   3. detail 为内嵌 JSON 字符串
//   4. 等待金币雨（本地/CI 周期均为 12s）→ 出现 feast 事件
const WebSocket = require('ws');

const WS_URL = 'ws://127.0.0.1:8081/';
const HTTP = 'http://127.0.0.1:8080';

function log(msg) { console.log('[ledger] ' + msg); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getJson(path) {
    const res = await fetch(HTTP + path);
    if (res.status !== 200) throw new Error('GET ' + path + ' -> ' + res.status);
    return res.json();
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
            let hit = false;
            try { hit = pred(m); } catch (e) { return; }
            if (hit) { clearTimeout(timer); ws.removeListener('message', onMsg); resolve(m); }
        }
        ws.on('message', onMsg);
    });
}

async function run() {
    const stamp = Date.now() % 1000000;
    const username = 'l' + stamp + String(Math.floor(Math.random() * 100)).padStart(2, '0');

    // 1. 进场
    const ws = await openWs();
    const login = waitFrame(ws, (m) => m.type === 'login_ok' || m.type === 'register_fail', 8000);
    ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
    const lm = await login;
    if (lm.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(lm));
    log('registered ' + username + ', waiting for ledger enter event...');

    // 账本写入在进场同帧完成，轮询 HTTP
    let enterRow = null;
    for (let i = 0; i < 20; i++) {
        await sleep(500);
        const j = await getJson('/api/events?type=enter&limit=50');
        if (j.code === 0 && Array.isArray(j.list)) {
            enterRow = j.list.find((r) => r.name === username);
            if (enterRow) break;
        }
    }
    if (!enterRow) throw new Error('enter event for ' + username + ' not found in ledger');
    if (enterRow.type !== 'enter') throw new Error('bad event type: ' + JSON.stringify(enterRow));
    if (typeof enterRow.ts !== 'number' || typeof enterRow.id !== 'number') {
        throw new Error('event row missing id/ts: ' + JSON.stringify(enterRow));
    }
    if (enterRow.detail !== 'player' && enterRow.detail !== 'bot') {
        throw new Error('enter detail should be player|bot: ' + JSON.stringify(enterRow));
    }
    log('PASS: enter event recorded: id=' + enterRow.id + ' detail=' + enterRow.detail);

    // 2a. type 过滤：只含 enter
    const onlyEnter = await getJson('/api/events?type=enter&limit=100');
    if (!onlyEnter.list.every((r) => r.type === 'enter')) {
        throw new Error('type=enter returned other types: ' + JSON.stringify(onlyEnter.list.map((r) => r.type)));
    }
    log('PASS: type=enter filter returns enter-only (' + onlyEnter.count + ' rows)');

    // 2b. limit 钳制：超大值最多 100；非数值走默认
    const capped = await getJson('/api/events?limit=99999');
    if (capped.count > 100) throw new Error('limit not capped to 100: count=' + capped.count);
    const bad = await getJson('/api/events?limit=abc');
    if (bad.code !== 0 || bad.count > 20) throw new Error('limit=abc should default to 20: ' + JSON.stringify(bad));
    const tiny = await getJson('/api/events?limit=2');
    if (tiny.count > 2) throw new Error('limit=2 returned ' + tiny.count + ' rows');
    log('PASS: limit clamping works (99999 -> <=100, abc -> <=20, 2 -> <=2)');

    // 3. 等金币雨 feast 事件（周期 12s；服务器可能早已触发，先查一次再轮询 20s）
    let feastRow = null;
    for (let i = 0; i < 20; i++) {
        const j = await getJson('/api/events?type=feast&limit=5');
        if (j.code === 0 && j.list.length > 0) { feastRow = j.list[0]; break; }
        await sleep(1000);
    }
    if (!feastRow) throw new Error('no feast event within 20s');
    let detail = null;
    try { detail = JSON.parse(feastRow.detail); } catch (e) { /* null */ }
    if (!detail || typeof detail.x !== 'number' || typeof detail.count !== 'number') {
        throw new Error('feast detail not embedded JSON: ' + JSON.stringify(feastRow));
    }
    log('PASS: feast event recorded with embedded JSON detail: ' + feastRow.detail);

    ws.close();
    console.log('=== [Ledger SQLite E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Ledger SQLite E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
