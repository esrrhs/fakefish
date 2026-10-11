// FakeFish Phase 19 运维后台 E2E：
//   1. GET /api/health 免鉴权探针：status/uptime/components
//   2. POST /api/admin/players：无 token 403、GET 405、list 字段
//   3. action=say 全服系统公告 -> WS 客户端收到 type=chat/system=true
//   4. action=save 立即落盘 200；空消息/缺字段 400
//   5. action=kick 按昵称下线 -> error 帧携带自定义原因 -> 连接关闭 -> list 消失；
//      不存在的玩家 404
//   6. GET /api/audit?format=csv 含表头与 admin.say/admin.kick 记录
//   7. backup action=schedule 动态开 2s 定时备份 -> status/list 出现 reason=scheduled
//      -> 收尾删除测试产物并关闭调度；非法 interval_s 400
const http = require('http');
const WebSocket = require('ws');

const TOKEN = 'test123'; // CI 在测试前写入 config.yaml（server.hotfix_token）
const WS_URL = 'ws://127.0.0.1:8081/';

function log(msg) { console.log('[ops] ' + msg); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function request(method, p, body) {
    return new Promise((resolve, reject) => {
        const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
        const headers = {};
        if (data) {
            headers['Content-Type'] = 'application/json';
            headers['Content-Length'] = data.length;
        }
        const req = http.request({
            host: '127.0.0.1', port: 8080, path: p, method, headers
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                const text = Buffer.concat(chunks).toString('utf8');
                let j = null;
                try { j = JSON.parse(text); } catch (e) { /* 保留 null（CSV 等） */ }
                resolve({ status: res.statusCode, headers: res.headers, body: text, json: j });
            });
        });
        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
}

const post = (p, body) => request('POST', p, body);
const get = (p) => request('GET', p);

async function openWs() {
    const ws = new WebSocket(WS_URL);
    await new Promise((resolve, reject) => {
        ws.once('open', resolve);
        ws.once('error', reject);
    });
    return ws;
}

async function register(ws, username) {
    const got = new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('register timeout')), 8000);
        ws.on('message', function onMsg(buf) {
            let m;
            try { m = JSON.parse(buf.toString()); } catch (e) { return; }
            if (m.type === 'login_ok' || m.type === 'register_fail') {
                clearTimeout(timer);
                ws.removeListener('message', onMsg);
                resolve(m);
            }
        });
    });
    ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
    const m = await got;
    if (m.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(m));
}

function nextFrame(ws, pred, timeoutMs) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            ws.removeListener('message', onMsg);
            reject(new Error('frame timeout'));
        }, timeoutMs);
        function onMsg(buf) {
            let m;
            try { m = JSON.parse(buf.toString()); } catch (e) { return; }
            if (pred(m)) { clearTimeout(timer); ws.removeListener('message', onMsg); resolve(m); }
        }
        ws.on('message', onMsg);
    });
}

async function playersList() {
    const r = await post('/api/admin/players', { token: TOKEN, action: 'list' });
    if (r.status !== 200 || !r.json || !Array.isArray(r.json.list)) {
        throw new Error('players list bad: ' + r.status + ' ' + r.body);
    }
    return r.json.list;
}

async function backupPost(action, extra) {
    return post('/api/admin/backup', Object.assign({ token: TOKEN, action }, extra || {}));
}

async function run() {
    const stamp = Date.now() % 1000000;
    const t0 = Math.floor(Date.now() / 1000) - 2;
    const nameA = 'OpsA_' + stamp;
    const nameB = 'OpsB_' + stamp;
    const notice = '系统公告-OPS-' + stamp + '-中文🎉';
    const kickReason = 'ops-kick-' + stamp;

    // ---- 1. 健康探针（免鉴权）----
    const h = await get('/api/health');
    if (h.status !== 200 || !h.json || h.json.code !== 0 || h.json.status !== 'ok') {
        throw new Error('health bad: ' + h.status + ' ' + h.body);
    }
    if (typeof h.json.uptime_s !== 'number' || typeof h.json.ts !== 'number') {
        throw new Error('health fields bad: ' + h.body);
    }
    const c = h.json.components;
    if (typeof c !== 'object' || typeof c.ledger !== 'boolean' || typeof c.audit !== 'boolean'
        || typeof c.backup !== 'boolean' || typeof c.redis !== 'boolean'
        || (c.db_mode !== 'memory' && c.db_mode !== 'mysql')) {
        throw new Error('health components bad: ' + JSON.stringify(c));
    }
    log('PASS: /api/health 免鉴权探针正常（db_mode=' + c.db_mode + '，uptime=' + h.json.uptime_s + 's）');

    // ---- 2. 鉴权/方法门禁 ----
    const noAuth = await post('/api/admin/players', { action: 'list' });
    if (noAuth.status !== 403) throw new Error('players no-token expected 403: ' + noAuth.status);
    const badGet = await get('/api/admin/players');
    if (badGet.status !== 405) throw new Error('players GET expected 405: ' + badGet.status);
    log('PASS: players 管理口无 token -> 403、GET -> 405');

    // ---- 两名玩家进场 ----
    const wsA = await openWs();
    await register(wsA, nameA);
    const wsB = await openWs();
    await register(wsB, nameB);
    log('PASS: 两名玩家注册进场（' + nameA + ' / ' + nameB + '）');

    // ---- 3. list 字段 ----
    let rows = await playersList();
    const a = rows.find((x) => x.name === nameA);
    const b = rows.find((x) => x.name === nameB);
    if (!a || !b) throw new Error('registered players missing: ' + JSON.stringify(rows.map((x) => x.name)));
    if (a.bot !== false || typeof a.connid !== 'number' || typeof a.gold !== 'number'
        || typeof a.id !== 'number' || typeof a.x !== 'number' || typeof a.y !== 'number') {
        throw new Error('player row fields bad: ' + JSON.stringify(a));
    }
    log('PASS: list 包含在线玩家且字段完整（' + nameA + ' gold=' + a.gold + ' connid=' + a.connid + '）');

    // ---- 4. 系统公告 ----
    const chatP = nextFrame(wsA, (m) => m.type === 'chat' && m.system === true
        && m.name === '[系统]' && m.content === notice, 6000);
    const say = await post('/api/admin/players', { token: TOKEN, action: 'say', message: notice });
    if (say.status !== 200 || !say.json || say.json.code !== 0 || say.json.delivered !== notice) {
        throw new Error('say failed: ' + say.status + ' ' + say.body);
    }
    const frame = await chatP;
    if (frame.content !== notice) throw new Error('chat frame mismatch: ' + JSON.stringify(frame));
    const sayEmpty = await post('/api/admin/players', { token: TOKEN, action: 'say', message: '   ' });
    if (sayEmpty.status !== 400) throw new Error('blank say expected 400: ' + sayEmpty.status);
    const sayNoMsg = await post('/api/admin/players', { token: TOKEN, action: 'say' });
    if (sayNoMsg.status !== 400) throw new Error('say without message expected 400: ' + sayNoMsg.status);
    log('PASS: say 全服系统公告 WS 实发（含 emoji/中文），空消息与缺字段 -> 400');

    // ---- 5. 立即落盘 ----
    const save = await post('/api/admin/players', { token: TOKEN, action: 'save' });
    if (save.status !== 200 || save.json.code !== 0) throw new Error('save failed: ' + save.body);
    log('PASS: save 立即落盘在线金币 200');

    // ---- 6. 管理员踢人（自定义原因 + 两阶段断开）----
    const errP = nextFrame(wsB, (m) => m.type === 'error' && m.reason === kickReason, 6000);
    const closedP = new Promise((resolve) => wsB.once('close', () => resolve()));
    const kick = await post('/api/admin/players', {
        token: TOKEN, action: 'kick', name: nameB, reason: kickReason
    });
    if (kick.status !== 200 || !kick.json || kick.json.kicked !== b.id || kick.json.name !== nameB) {
        throw new Error('kick failed: ' + kick.status + ' ' + kick.body);
    }
    const errFrame = await errP;
    if (errFrame.reason !== kickReason) throw new Error('kick reason mismatch');
    await Promise.race([
        closedP.then(() => true),
        sleep(6000).then(() => { throw new Error('kicked ws did not close'); })
    ]);
    // list 里最终应查不到 B（每秒清理一轮，多给几轮）
    let gone = false;
    for (let i = 0; i < 8; i++) {
        rows = await playersList();
        if (!rows.some((x) => x.name === nameB)) { gone = true; break; }
        await sleep(1000);
    }
    if (!gone) throw new Error('kicked player still listed');
    const kickMiss = await post('/api/admin/players', {
        token: TOKEN, action: 'kick', name: 'Nobody_' + stamp
    });
    if (kickMiss.status !== 404) throw new Error('kick missing player expected 404: ' + kickMiss.status);
    log('PASS: kick 按昵称下线：error 帧原因正确、连接关闭、list 消失；不存在玩家 -> 404');

    // ---- 7. 审计 CSV ----
    const csv = await get('/api/audit?token=' + TOKEN + '&limit=50&format=csv');
    if (csv.status !== 200 || !String(csv.headers['content-type']).includes('text/csv')) {
        throw new Error('audit csv bad: ' + csv.status + ' ' + String(csv.headers['content-type']));
    }
    const firstLine = csv.body.split(/\r?\n/)[0].replace(/"/g, '');
    if (firstLine !== 'id,ts,actor,action,target,detail') {
        throw new Error('audit csv header bad: ' + JSON.stringify(firstLine));
    }
    if (!csv.body.includes('admin.say') || !csv.body.includes('admin.kick')) {
        throw new Error('audit csv missing fresh ops records');
    }
    log('PASS: /api/audit?format=csv 表头正确且含本轮 admin.say/admin.kick');

    // ---- 8. 动态定时备份 ----
    const schBad1 = await backupPost('schedule', { interval_s: 999999 });
    if (schBad1.status !== 400) throw new Error('schedule 999999 expected 400: ' + schBad1.status);
    const schBad2 = await backupPost('schedule', { interval_s: 'abc' });
    if (schBad2.status !== 400) throw new Error('schedule abc expected 400: ' + schBad2.status);

    const sch = await backupPost('schedule', { interval_s: 2 });
    if (sch.status !== 200 || !sch.json || !sch.json.schedule || sch.json.schedule.enabled !== true
        || sch.json.schedule.interval_s !== 2) {
        throw new Error('schedule enable failed: ' + sch.status + ' ' + sch.body);
    }

    // 轮询 status 直到出现最近备份，再到 list 里确认 reason=scheduled 的信封
    let observed = null;
    for (let i = 0; i < 12; i++) {
        await sleep(1000);
        const st = await backupPost('status');
        if (st.json && st.json.schedule && typeof st.json.schedule.last_ts === 'number'
            && st.json.schedule.last_ts >= t0) {
            const ls = await backupPost('list');
            observed = ls.json.list.find((x) => x.name === st.json.schedule.last_name
                && x.reason === 'scheduled' && x.ts >= t0);
            if (observed) break;
        }
    }
    if (!observed) throw new Error('scheduled backup not observed within 12s');
    log('PASS: schedule 开 2s 周期后自动备份落盘：' + observed.name + '（reason=scheduled）');

    // 收尾：关闭调度并删除本轮定时备份产物
    const off = await backupPost('schedule', { interval_s: 0 });
    if (off.status !== 200 || off.json.schedule.enabled !== false) {
        throw new Error('schedule disable failed: ' + off.status + ' ' + off.body);
    }
    const dl = await backupPost('delete', { id: observed.name });
    if (dl.status !== 200 || dl.json.code !== 0) throw new Error('cleanup delete failed: ' + dl.body);
    log('PASS: schedule 关闭（interval_s=0）并清理定时备份产物；非法周期 -> 400');

    try { wsA.close(); } catch (e) { /* ignore */ }
    try { wsB.close(); } catch (e) { /* ignore */ }
    console.log('=== [Admin Ops E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Admin Ops E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
