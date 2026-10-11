// FakeFish 可选 Redis 能力 E2E（server/redis_store.lua）：
//   前置：127.0.0.1:6379 可达，否则 SKIP（与 test_persist 对 MySQL 的处理一致）。
//
//   拉起一个 redis.enabled=true 的端口隔离子实例，验证：
//   1. 全局排行 ZSET 镜像：注册进场后，服务端周期把本服 top 镜像到共享 ZSET，
//      /api/rank?scope=global 能从 Redis 拉回该玩家；
//   2. 跨服世界聊天（LPUSH/LRANGE 拉模式）：用裸 RESP 连接直接向共享 list
//      LPUSH 一条「其他实例」的聊天 JSON，本服 WS 客户端应在数秒内收到广播帧。
const net = require('net');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');

const CHILD_HTTP = 18300;
const CHILD_WS_URL = 'ws://127.0.0.1:18301/';
const METRICS_PORT = 18392;
const REDIS_PORT = 6379;
const CHILD_CONFIG = 'config.redis-test.yaml';
const CHILD_LOG = 'redis_child.log';
const BIN = path.join('.', 'build', 'fakefish');
const READY_TIMEOUT_MS = 120000;

function log(msg) { console.log('[redis] ' + msg); }
const fsExists = (p) => { try { fs.accessSync(p); return true; } catch (e) { return false; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function probeTcp(port, host = '127.0.0.1') {
    return new Promise((resolve) => {
        const sock = net.connect(port, host);
        let decided = false;
        const done = (v) => { if (!decided) { decided = true; try { sock.destroy(); } catch (e) {} resolve(v); } };
        sock.once('connect', () => done(true));
        sock.once('error', () => done(false));
        sock.once('close', () => done(false));
        setTimeout(() => done(false), 2000);
    });
}

function waitHttpReady(port, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
        const attempt = () => {
            const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 3000 }, (res) => {
                res.resume(); resolve();
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

async function openWs(url) {
    const ws = new WebSocket(url);
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

// 构造 RESP inline 数组命令（bulk string 二进制安全）
function respCommand(argv) {
    let out = '*' + argv.length + '\r\n';
    for (const a of argv) {
        const b = Buffer.from(a, 'utf8');
        out += '$' + b.length + '\r\n';
        out += a + '\r\n';
    }
    return out;
}

async function run() {
    if (!(await probeTcp(REDIS_PORT))) {
        console.log('=== [Redis E2E Test] SKIP: Redis not reachable on 127.0.0.1:6379 ===');
        return;
    }
    if (!fsExists(BIN)) {
        console.log('=== [Redis E2E Test] SKIP: build/fakefish binary not found ===');
        return;
    }
    if (!fsExists('config.yaml')) {
        console.log('=== [Redis E2E Test] SKIP: config.yaml not found ===');
        return;
    }

    const stamp = Date.now() % 1000000;
    const username = 'r' + stamp + String(Math.floor(Math.random() * 100)).padStart(2, '0');

    // 1. 子实例配置：启用 redis，端口/账本/指标口全部隔离
    const cfgSrc = fs.readFileSync('config.yaml', 'utf8');
    let cfgChild = cfgSrc
        .replace(/http_port:\s*\d+/, 'http_port: ' + CHILD_HTTP)
        .replace(/ws_port:\s*\d+/, 'ws_port: 18301')
        // redis 段的 enabled 必须锚定替换：全局第一个 "enabled:false" 可能是
        // redis 段上方注释里的文字（“# …或 enabled:false 时静默降级”），
        // 裸 /enabled:\s*false/ 会只改掉注释、真实开关仍为 false。
        .replace(/(^redis:\s*\n\s*enabled:\s*)false/m, '$1true')
        // CI 准备脚本会把配置里的 MySQL 密码 sed 成 "changeme"（全局替换会连带
        // 改掉 redis 段），而 CI 的 redis service 无密码。本测试的前置探测不带
        // AUTH，故锚定 redis 段强制清空密码，避免 "AUTH called without password"。
        .replace(/(^redis:\s*\n(?:[ \t]+\S[^\n]*\n)*?[ \t]+password:[ \t]*)"[^"\n]*"/m, '$1""')
        .replace(/port:\s*8092/, 'port: ' + METRICS_PORT)
        .replace(/path:\s*"data\/events\.db"/, 'path: "data/events.redis-test.db"')
        // 子实例不需要金币雨，拉长间隔避免日志噪音
        .replace(/feast_interval_s:\s*\d+/, 'feast_interval_s: 0');

    if (!/http_port:\s*18300/.test(cfgChild) || !/ws_port:\s*18301/.test(cfgChild)
        || !/^redis:\s*\n\s*enabled:\s*true/m.test(cfgChild)
        || !/^redis:\s*\n(?:[ \t]+\S[^\n]*\n)*?[ \t]+password:[ \t]*""/m.test(cfgChild)) {
        throw new Error('failed to rewrite child config for redis test');
    }
    fs.writeFileSync(CHILD_CONFIG, cfgChild);

    log('spawning redis-enabled child on ' + CHILD_HTTP + '/18301');
    const outFd = fs.openSync(CHILD_LOG, 'w');
    const child = spawn(BIN, ['--config=' + CHILD_CONFIG], {
        cwd: process.cwd(),
        stdio: ['ignore', outFd, outFd]
    });
    let childExit = null;
    child.on('exit', (code) => { childExit = code; });

    // 启动后必须在日志里看到真实连接成功标记：ZSET 查询在 Redis 不可用时会静默
    // 回退本服榜，仅看 /api/rank?scope=global 无法区分“真走 Redis”。
    async function waitLogMark(mark, timeoutMs) {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
            try {
                if (fs.readFileSync(CHILD_LOG, 'utf8').indexOf(mark) >= 0) return true;
            } catch (e) { /* 日志尚未生成 */ }
            await sleep(500);
        }
        return false;
    }

    try {
        await waitHttpReady(CHILD_HTTP, READY_TIMEOUT_MS);
        log('child ready');
        if (!(await waitLogMark('[RedisStore] connected', 10000))) {
            throw new Error('child did not connect to redis within 10s (see ' + CHILD_LOG + ')');
        }

        // 2. WS 注册进场
        const ws = await openWs(CHILD_WS_URL);
        const login = waitFrame(ws, (m) => m.type === 'login_ok' || m.type === 'register_fail', 8000);
        ws.send(JSON.stringify({ type: 'register', username, password: 'abc123' }));
        const lm = await login;
        if (lm.type !== 'login_ok') throw new Error('register failed: ' + JSON.stringify(lm));
        log('registered ' + username + ', waiting for global rank mirror...');

        // 3. 全局榜：本服排行 5s 刷新缓存 + Redis 10s 镜像，轮询到 25s
        let globalHit = null;
        for (let i = 0; i < 25; i++) {
            await sleep(1000);
            const res = await fetch('http://127.0.0.1:' + CHILD_HTTP + '/api/rank?scope=global&limit=20');
            const j = await res.json();
            if (j.code === 0 && Array.isArray(j.list)) {
                globalHit = j.list.find((e) => e.name === username);
                if (globalHit) break;
            }
        }
        if (!globalHit) {
            throw new Error('player ' + username + ' not found in Redis global rank within 25s');
        }
        if (typeof globalHit.best_gold !== 'number' || globalHit.best_gold < 100) {
            throw new Error('global rank entry malformed: ' + JSON.stringify(globalHit));
        }
        log('PASS: global rank mirrored via Redis ZSET: ' + JSON.stringify(globalHit));

        // 4. 裸 RESP 注入「其他实例」聊天 → 本服客户端应收到跨服广播
        const remoteName = '邻服_' + stamp;
        const msgId = 'ext-' + stamp + '-1';
        const chatPayload = JSON.stringify({
            id: msgId,
            origin: 'external-' + stamp,
            ts: Math.floor(Date.now() / 1000),
            name: remoteName,
            content: '跨服你好 ' + stamp
        });

        const frameP = waitFrame(ws, (m) => m.type === 'chat' && m.name === remoteName, 8000);
        const redisSock = net.connect(REDIS_PORT, '127.0.0.1');
        await new Promise((resolve, reject) => {
            redisSock.once('connect', resolve);
            redisSock.once('error', reject);
        });
        redisSock.write(respCommand(['LPUSH', 'fakefish:chat', chatPayload]));
        log('injected cross-server chat via raw RESP LPUSH');

        const frame = await frameP;
        if (frame.content !== '跨服你好 ' + stamp) {
            throw new Error('cross-server chat content mismatch: ' + JSON.stringify(frame));
        }
        if (!frame.from || frame.from.indexOf('external-') !== 0) {
            throw new Error('cross-server chat missing/malformed from field: ' + JSON.stringify(frame));
        }
        log('PASS: cross-server chat received: ' + frame.name + ': ' + frame.content
            + ' (from=' + frame.from + ')');

        redisSock.destroy();
        ws.close();
        console.log('=== [Redis E2E Test] ALL PASSED ===');
    } finally {
        try { child.kill('SIGTERM'); } catch (e) {}
        try { fs.closeSync(outFd); } catch (e) {}
        await sleep(500);
        try { fs.unlinkSync(CHILD_CONFIG); } catch (e) {}
        if (childExit !== null && childExit !== 0) {
            log('child exited with code ' + childExit + ' (expected after SIGTERM)');
        }
    }
}

run().then(() => process.exit(0)).catch((err) => {
    console.error('=== [Redis E2E Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    try {
        if (fs.existsSync(CHILD_LOG)) {
            console.error('--- child server log tail ---');
            console.error(fs.readFileSync(CHILD_LOG, 'utf8').split('\n').slice(-40).join('\n'));
        }
    } catch (e) {}
    process.exit(1);
});
