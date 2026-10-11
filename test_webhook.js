// FakeFish 出站 Webhook E2E（fakelua http.request）：
//   拉起一个端口隔离的子服务器，webhook.url 指向本测试内建的 HTTP 接收端，
//   金币雨周期调到 3s 并订阅 feast 事件；断言接收端在超时内收到
//   POST application/json 的 {"event":"feast", ...}。
//
// 不需要真人玩家：金币雨由 timer 心跳驱动，世界中无人也会触发。
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const CHILD_HTTP = 18090;
const CHILD_WS = 18091;
const HOOK_PORT = 18095;
const METRICS_PORT = 18098;
const CHILD_CONFIG = 'config.webhook-test.yaml';
const CHILD_LOG = 'webhook_child.log';
const BIN = path.join('.', 'build', 'fakefish');
const READY_TIMEOUT_MS = 120000; // 冷启动 JIT 编译
const FEAST_WAIT_MS = 30000;

function log(msg) { console.log('[webhook] ' + msg); }
const fsExists = (p) => { try { fs.accessSync(p); return true; } catch (e) { return false; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function waitHttpReady(port, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
        const attempt = () => {
            const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 3000 }, (res) => {
                res.resume();
                resolve();
            });
            req.on('error', () => {
                if (Date.now() > deadline) reject(new Error('child server not ready within ' + timeoutMs + 'ms'));
                else setTimeout(attempt, 1000);
            });
            req.on('timeout', () => req.destroy());
        };
        attempt();
    });
}

async function run() {
    if (!fsExists(BIN)) {
        console.log('=== [Webhook E2E Test] SKIP: build/fakefish binary not found ===');
        return;
    }
    if (!fsExists('config.yaml')) {
        console.log('=== [Webhook E2E Test] SKIP: config.yaml not found ===');
        return;
    }

    // 1. 内建 Webhook 接收端
    const received = [];
    const hookServer = http.createServer((req, res) => {
        let body = '';
        req.on('data', (c) => { body += c; });
        req.on('end', () => {
            received.push({
                method: req.method,
                url: req.url,
                contentType: req.headers['content-type'] || '',
                body
            });
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end('{"ok":true}');
        });
    });
    await new Promise((resolve) => hookServer.listen(HOOK_PORT, '127.0.0.1', resolve));
    log('hook receiver listening on 127.0.0.1:' + HOOK_PORT);

    // 2. 生成子实例配置
    const cfgSrc = fs.readFileSync('config.yaml', 'utf8');
    let cfgChild = cfgSrc
        .replace(/http_port:\s*\d+/, 'http_port: ' + CHILD_HTTP)
        .replace(/ws_port:\s*\d+/, 'ws_port: ' + CHILD_WS)
        // webhook 段：url + 订阅事件
        .replace(/url:\s*"[^"]*"/, 'url: "http://127.0.0.1:' + HOOK_PORT + '/hook"')
        .replace(/events:\s*\[.*\]/, 'events: ["kill", "feast"]')
        // 金币雨 3s，让事件尽快发生
        .replace(/feast_interval_s:\s*\d+/, 'feast_interval_s: 3')
        // metrics 换端口避免与主服务器冲突
        .replace(/port:\s*8092/, 'port: ' + METRICS_PORT)
        // 账本文件隔离，避免与主实例抢写
        .replace(/path:\s*"data\/events\.db"/, 'path: "data/events.webhook-test.db"');

    if (!new RegExp('http_port:\\s*' + CHILD_HTTP).test(cfgChild)
        || cfgChild.indexOf('http://127.0.0.1:' + HOOK_PORT + '/hook') < 0
        || cfgChild.indexOf('feast_interval_s: 3') < 0) {
        throw new Error('failed to rewrite child config for webhook test');
    }
    fs.writeFileSync(CHILD_CONFIG, cfgChild);

    // 3. 拉起子实例
    log('spawning child server on ' + CHILD_HTTP + '/' + CHILD_WS);
    const outFd = fs.openSync(CHILD_LOG, 'w');
    const child = spawn(BIN, ['--config=' + CHILD_CONFIG], {
        cwd: process.cwd(),
        stdio: ['ignore', outFd, outFd]
    });
    let childExit = null;
    child.on('exit', (code) => { childExit = code; });

    try {
        await waitHttpReady(CHILD_HTTP, READY_TIMEOUT_MS);
        log('child server ready, waiting for feast webhook...');

        // 4. 等待 feast 事件送达（feast 3s 一次 + 冷启动后首个周期）
        const deadline = Date.now() + FEAST_WAIT_MS;
        let hit = null;
        while (Date.now() < deadline) {
            hit = received.find((r) => {
                if (r.method !== 'POST') return false;
                if (r.contentType.indexOf('application/json') !== 0) return false;
                try { return JSON.parse(r.body).event === 'feast'; } catch (e) { return false; }
            });
            if (hit) break;
            await sleep(500);
        }

        if (!hit) {
            throw new Error('no feast webhook received within ' + FEAST_WAIT_MS
                            + 'ms (received=' + received.length + ')');
        }

        const payload = JSON.parse(hit.body);
        if (payload.event !== 'feast' || !payload.data || typeof payload.data.x !== 'number'
            || typeof payload.data.count !== 'number') {
            throw new Error('webhook payload malformed: ' + hit.body);
        }
        log('PASS: received feast webhook POST: ' + hit.body);

        console.log('=== [Webhook E2E Test] ALL PASSED ===');
    } finally {
        try { child.kill('SIGTERM'); } catch (e) {}
        await new Promise((r) => hookServer.close(r));
        try { fs.closeSync(outFd); } catch (e) {}
        await sleep(500);
        try { fs.unlinkSync(CHILD_CONFIG); } catch (e) {}
        if (childExit !== null && childExit !== 0) {
            log('child exited with code ' + childExit + ' (expected after SIGTERM)');
        }
    }
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Webhook E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    try {
        if (fs.existsSync(CHILD_LOG)) {
            console.error('--- child server log tail ---');
            console.error(fs.readFileSync(CHILD_LOG, 'utf8').split('\n').slice(-40).join('\n'));
        }
    } catch (e) {}
    process.exit(1);
});
