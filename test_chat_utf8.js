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

// 发送聊天并按冷却周期重发，直到收到匹配帧。
// 服务端主循环按固定 50ms tick 累加 world_time（非墙钟），CI runner 满载或懒 JIT
// 卡顿时 world_time 落后墙钟，冷却（2s）内到达的消息会被静默丢弃且不刷新冷却时间；
// 本测试只验证截断，不断言冷却，因此重发到命中为止最稳妥。
function sendChatUntilEcho(ws, content, matchFrame, timeoutMs = 15000) {
    const frameP = waitFrame(ws, matchFrame, timeoutMs);
    const msg = JSON.stringify({ type: 'chat', content });
    ws.send(msg);
    const resend = setInterval(() => ws.send(msg), 1000);
    return frameP.finally(() => clearInterval(resend));
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

    // 匹配条件带上完整期望内容，避免与第二条消息的回帧互相误匹配
    const frame = await sendChatUntilEcho(
        ws, sent,
        (m) => m.type === 'chat' && m.name === username && m.content === expectPrefix);

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

    // ASCII 混合场景：中英文混排也应按字符计数。无需固定 sleep 等冷却——
    // sendChatUntilEcho 会在消息因冷却被丢弃时自动按 1s 周期重发。
    const mixed = 'a'.repeat(50) + '字'.repeat(50); // 100 字符
    const mixedExpect = 'a'.repeat(50) + '字'.repeat(30);
    const f2 = await sendChatUntilEcho(
        ws, mixed,
        (m) => m.type === 'chat' && m.name === username && m.content === mixedExpect);
    if (charLen(f2.content) !== CHAT_MAX_CHARS) {
        throw new Error('mixed content expected ' + CHAT_MAX_CHARS + ' chars, got '
                        + charLen(f2.content));
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
