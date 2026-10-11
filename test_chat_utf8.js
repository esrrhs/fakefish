// FakeFish 世界聊天 UTF-8 按字符限长 E2E：
//   发送 90 个汉字（旧实现按字节截断会切成半个字符产生乱码/UTF-8 非法序列），
//   服务端应按字符截到 chat_max_len(80) 个「字符」原样广播，且仍是合法 UTF-8。
const WebSocket = require('ws');

const WS_URL = 'ws://127.0.0.1:8081/';
const CHAT_MAX_CHARS = 80;

function log(msg) { console.log('[chat] ' + msg); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const charLen = (s) => [...s].length;   // 按码点计数（代理对算 1 字符）

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
    const ws = await openWs();
    const stamp = Date.now() % 1000000;
    const username = 'u' + stamp + String(Math.floor(Math.random() * 100)).padStart(2, '0');

    const login = waitFrame(ws, (m) => m.type === 'login_ok' || m.type === 'register_fail', 8000);
    ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
    const lm = await login;
    if (lm.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(lm));
    log('registered as ' + username);

    // 90 个汉字：服务端按字符截到 80，按字节则会切成 30 个完整汉字且可能带半个字符
    const sent = '汉'.repeat(90);
    const expectPrefix = '汉'.repeat(CHAT_MAX_CHARS);

    const echo = waitFrame(ws, (m) => m.type === 'chat' && m.name === username, 8000);
    ws.send(JSON.stringify({ type: 'chat', content: sent }));
    const frame = await echo;

    if (charLen(frame.content) !== CHAT_MAX_CHARS) {
        throw new Error('expected ' + CHAT_MAX_CHARS + ' chars, got ' + charLen(frame.content)
                        + ' (bytes=' + Buffer.byteLength(frame.content) + ')');
    }
    if (frame.content !== expectPrefix) {
        throw new Error('truncated content mismatch (garbled multibyte cut?)');
    }
    // 必须仍是合法 UTF-8：Buffer.toString 默认替换非法字节，重新 encode 比对可探测
    const buf = Buffer.from(frame.content, 'utf8');
    if (buf.toString('utf8') !== frame.content) {
        throw new Error('content is not valid UTF-8');
    }
    log('PASS: 90 汉字按字符截断为 80 字符且 UTF-8 合法（' + buf.length + ' 字节）');

    // ASCII 混合场景：中英文混排也应按字符计数
    await sleep(2200); // chat_cooldown_s = 2
    const mixed = 'a'.repeat(50) + '字'.repeat(50); // 100 字符
    const echo2 = waitFrame(ws, (m) => m.type === 'chat' && m.name === username
                                    && charLen(m.content) === CHAT_MAX_CHARS, 8000);
    ws.send(JSON.stringify({ type: 'chat', content: mixed }));
    const f2 = await echo2;
    if (f2.content !== 'a'.repeat(50) + '字'.repeat(30)) {
        throw new Error('mixed ascii/cjk truncation mismatch: ' + f2.content);
    }
    log('PASS: 中英混排 100 字符截为 80 字符（50 ASCII + 30 汉字）');

    ws.close();
    console.log('=== [Chat UTF-8 E2E Test] ALL PASSED ===');
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Chat UTF-8 E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
