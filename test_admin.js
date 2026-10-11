// FakeFish 管理接口 E2E（fakelua process.run 白名单 + io.open 原子写公告）：
//   1. POST /api/admin/run：非法方法/非法 JSON/坏 token/未知命令全拒绝；白名单 ping 成功
//   2. POST /api/admin/motd：中文公告写入、GET 回读、文件落盘、WS login_ok 下发
//   3. 超长（201 汉字 > max_len 200）/ CR / 非字符串全部 400 且不覆盖原公告
//   4. 收尾清空公告，避免污染后续套件
const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

const WS_URL = 'ws://127.0.0.1:8081/';
const TOKEN = 'test123'; // CI 在测试前写入 config.yaml（server.hotfix_token）
const MOTD_FILE = path.join(__dirname, 'data', 'motd.txt');

function log(msg) { console.log('[admin] ' + msg); }

function request(method, p, bodyObj, rawBody, headers = {}) {
    return new Promise((resolve, reject) => {
        const body = rawBody !== undefined ? rawBody
            : (bodyObj === undefined ? '' : JSON.stringify(bodyObj));
        const req = http.request({
            host: '127.0.0.1', port: 8080, path: p, method,
            headers: Object.assign({
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(body)
            }, headers)
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
        req.end(body);
    });
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

async function run() {
    // ---- run：鉴权与入参 ----
    const getRun = await request('GET', '/api/admin/run');
    if (getRun.status !== 405) throw new Error('GET run expected 405, got ' + getRun.status);
    log('PASS: GET /api/admin/run -> 405');

    const badJson = await request('POST', '/api/admin/run', undefined, '{not json');
    if (badJson.status !== 400) throw new Error('bad JSON expected 400, got ' + badJson.status);
    log('PASS: 非法 JSON -> 400');

    const badToken = await request('POST', '/api/admin/run', { token: 'wrong', cmd: 'ping' });
    if (badToken.status !== 403) throw new Error('bad token expected 403, got ' + badToken.status);
    const badTokenMotd = await request('POST', '/api/admin/motd', { token: '', motd: 'x' });
    if (badTokenMotd.status !== 403) throw new Error('empty token expected 403');
    log('PASS: 坏 token -> 403（run + motd）');

    const unknown = await request('POST', '/api/admin/run', { token: TOKEN, cmd: 'rm -rf /' });
    if (unknown.status !== 400 || !JSON.parse(unknown.body).msg.includes('unknown command')) {
        throw new Error('unknown cmd expected 400 unknown command: ' + unknown.body);
    }
    const noCmd = await request('POST', '/api/admin/run', { token: TOKEN });
    if (noCmd.status !== 400) throw new Error('missing cmd expected 400');
    log('PASS: 未知命令/缺 cmd -> 400（客户端不能附参数，只能选配置名）');

    // ---- run：白名单 ping ----
    const ping = await request('POST', '/api/admin/run', { token: TOKEN, cmd: 'ping' });
    if (ping.status !== 200) throw new Error('ping expected 200, got ' + ping.status);
    const pj = JSON.parse(ping.body);
    if (pj.code !== 0 || pj.exit !== 0) throw new Error('ping exit bad: ' + JSON.stringify(pj));
    // Windows 走 cmd.exe，标准输出行为 \r\n；Unix 的 echo 为 \n，两者都接受
    if (pj.stdout !== 'fakefish-pong\n' && pj.stdout !== 'fakefish-pong\r\n') {
        throw new Error('ping stdout mismatch: ' + JSON.stringify(pj.stdout));
    }
    log('PASS: process.run 白名单 ping -> stdout="fakefish-pong", exit=0');

    // ---- motd：中文写入/回读/落盘/登录下发 ----
    const stamp = Date.now() % 1000000;
    const notice = 'Phase17公告-' + stamp + ' 欢迎来到金币球战场';
    const setOk = await request('POST', '/api/admin/motd', { token: TOKEN, motd: notice });
    if (setOk.status !== 200 || JSON.parse(setOk.body).code !== 0) {
        throw new Error('motd set failed: ' + setOk.status + ' ' + setOk.body);
    }

    const get1 = await request('GET', '/api/motd');
    const gj = JSON.parse(get1.body);
    if (gj.motd !== notice) throw new Error('motd GET mismatch: ' + JSON.stringify(gj.motd));
    log('PASS: 中文公告写入并 GET 回读一致');

    const onDisk = fs.readFileSync(MOTD_FILE, 'utf8').replace(/[\r\n]+$/, '');
    if (onDisk !== notice) throw new Error('motd file content mismatch: ' + JSON.stringify(onDisk));
    log('PASS: 公告原子落盘 data/motd.txt（写 .tmp + rename）');

    const ws = await openWs();
    const username = 'adm' + stamp + String(Math.floor(Math.random() * 100)).padStart(2, '0');
    const login = waitFrame(ws, (m) => m.type === 'login_ok' || m.type === 'register_fail', 8000);
    ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
    const lm = await login;
    if (lm.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(lm));
    if (lm.motd !== notice) throw new Error('login_ok.motd mismatch: ' + JSON.stringify(lm.motd));
    log('PASS: login_ok.motd 随登录帧下发');
    ws.close();

    // ---- motd：非法输入不覆盖原公告 ----
    const tooLong = '汉'.repeat(201);
    const r1 = await request('POST', '/api/admin/motd', { token: TOKEN, motd: tooLong });
    if (r1.status !== 400 || !JSON.parse(r1.body).msg.includes('too long')) {
        throw new Error('201 CJK chars expected 400 too long: ' + r1.body);
    }
    const r2 = await request('POST', '/api/admin/motd', { token: TOKEN, motd: 'a\rb' });
    if (r2.status !== 400 || !JSON.parse(r2.body).msg.includes('CR')) {
        throw new Error('CR expected 400: ' + r2.body);
    }
    const r3 = await request('POST', '/api/admin/motd', { token: TOKEN, motd: 12345 });
    if (r3.status !== 400) throw new Error('non-string motd expected 400');
    const get2 = await request('GET', '/api/motd');
    if (JSON.parse(get2.body).motd !== notice) {
        throw new Error('rejected requests must not overwrite motd');
    }
    log('PASS: 超长 201 汉字 / CR / 非字符串 -> 400 且原公告不变（按字符限长 200）');

    // ---- 收尾：清空公告，删除文件 ----
    const clear = await request('POST', '/api/admin/motd', { token: TOKEN, motd: null });
    if (clear.status !== 200) throw new Error('clear motd failed: ' + clear.status);
    const get3 = await request('GET', '/api/motd');
    const j3 = JSON.parse(get3.body);
    if (j3.motd !== null) throw new Error('motd expected null after clear: ' + JSON.stringify(j3));
    if (fs.existsSync(MOTD_FILE)) throw new Error('motd file should be removed');
    log('PASS: motd 清空，data/motd.txt 已删除（清理完成）');

    console.log('=== [Admin API E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Admin API E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
