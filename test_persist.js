// FakeFish 跨重启持久化验证：
//   1. 在运行中的服务器注册新账号（INSERT 落 MySQL）
//   2. 拉起第二个服务器实例（全新进程，内存账号表为空，端口隔离）
//   3. 新实例必须从 MySQL 读到账号：正确密码 login_ok、错误密码 login_fail、
//      重复注册 register_fail；不存在的用户仍然 login_fail
//
// 无 MySQL（纯内存降级模式）时自动 SKIP 并以 0 退出。
const WebSocket = require('ws');
const net = require('net');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PARENT_WS = 'ws://127.0.0.1:8081/';
const CHILD_HTTP = 18080;
const CHILD_WS = 'ws://127.0.0.1:18081/';
const CHILD_CONFIG = 'config.persistence-test.yaml';
const CHILD_LOG = 'persist_child.log';
const BIN = path.join('.', 'build', 'fakefish');
const READY_TIMEOUT_MS = 120000; // 冷启动 JIT 编译约 30-55s，留足余量

function log(msg) { console.log('[persist] ' + msg); }

// 探测 3306 是否有 MySQL 服务（连上即会收到握手包），无依赖判定
function probeMysql(port = 3306, host = '127.0.0.1') {
    return new Promise((resolve) => {
        const sock = net.connect(port, host);
        let decided = false;
        const done = (v) => { if (!decided) { decided = true; try { sock.destroy(); } catch (e) {} resolve(v); } };
        sock.once('data', () => done(true));
        sock.once('error', () => done(false));
        sock.once('close', () => done(false));
        setTimeout(() => done(false), 2000);
    });
}

const fsExists = (p) => { try { fs.accessSync(p); return true; } catch (e) { return false; } };

function wsOnce(ws, predicate, timeoutMs = 10000) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            ws.removeListener('message', onMsg);
            reject(new Error('wait message timeout'));
        }, timeoutMs);
        function onMsg(buf) {
            let msg;
            try { msg = JSON.parse(buf.toString()); } catch (e) { return; }
            let hit = false;
            try { hit = predicate(msg); } catch (e) { return; }
            if (hit) { clearTimeout(timer); ws.removeListener('message', onMsg); resolve(msg); }
        }
        ws.on('message', onMsg);
    });
}

function wsSend(ws, obj) { ws.send(JSON.stringify(obj)); }

async function openWs(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
        ws.once('open', resolve);
        ws.once('error', reject);
    });
    return ws;
}

function waitHttpReady(port, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
        const attempt = () => {
            const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 3000 }, (res) => {
                res.resume();
                resolve();
            });
            req.on('error', () => {
                if (Date.now() > deadline) {
                    reject(new Error('child server not ready within ' + timeoutMs + 'ms'));
                } else {
                    setTimeout(attempt, 1000);
                }
            });
            req.on('timeout', () => req.destroy());
        };
        attempt();
    });
}

async function run() {
    // 前置：MySQL、二进制、config.yaml
    const mysqlUp = await probeMysql();
    if (!mysqlUp) {
        console.log('=== [Persist Test] SKIP: MySQL not reachable on 127.0.0.1:3306 (in-memory mode) ===');
        return;
    }
    if (!fsExists(BIN)) {
        console.log('=== [Persist Test] SKIP: build/fakefish binary not found ===');
        return;
    }
    if (!fsExists('config.yaml')) {
        console.log('=== [Persist Test] SKIP: config.yaml not found ===');
        return;
    }

    const username = 'Persist_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
    const password = 'abc123';

    // 1) 在父服务器注册，等待异步 INSERT 落盘
    log('registering fresh account on running server: ' + username);
    const wsReg = await openWs(PARENT_WS);
    const loginOkP = wsOnce(wsReg, (m) => m.type === 'login_ok' || m.type === 'register_fail');
    wsSend(wsReg, { type: 'register', username, password });
    const regMsg = await loginOkP;
    if (regMsg.type !== 'login_ok') {
        throw new Error('register on parent server failed: ' + JSON.stringify(regMsg));
    }
    wsReg.close();
    await new Promise((r) => setTimeout(r, 1500)); // 等异步 INSERT 完成

    // 2) 写端口隔离的临时配置
    const cfgSrc = fs.readFileSync('config.yaml', 'utf8');
    const cfgChild = cfgSrc
        .replace(/http_port:\s*\d+/, 'http_port: ' + CHILD_HTTP)
        .replace(/ws_port:\s*\d+/, 'ws_port: 18081');
    if (!/http_port:\s*18080/.test(cfgChild) || !/ws_port:\s*18081/.test(cfgChild)) {
        throw new Error('failed to rewrite ports in config.yaml');
    }
    fs.writeFileSync(CHILD_CONFIG, cfgChild);

    // 3) 拉起全新服务器实例（冷启动含 JIT 编译）
    log('spawning child server instance on ports ' + CHILD_HTTP + '/18081');
    const outFd = fs.openSync(CHILD_LOG, 'w');
    const child = spawn(BIN, ['--config=' + CHILD_CONFIG], {
        cwd: process.cwd(),
        stdio: ['ignore', outFd, outFd]
    });

    let childExit = null;
    child.on('exit', (code) => { childExit = code; });

    try {
        await waitHttpReady(CHILD_HTTP, READY_TIMEOUT_MS);
        log('child server ready');

        // 4a) 不存在的用户 → login_fail
        const ws1 = await openWs(CHILD_WS);
        let p = wsOnce(ws1, (m) => m.type === 'login_fail' || m.type === 'login_ok');
        wsSend(ws1, { type: 'login', username: 'NoSuchUser_' + Date.now(), password });
        let msg = await p;
        if (msg.type !== 'login_fail' || msg.reason !== '账号不存在，请先注册') {
            throw new Error('expected login_fail(账号不存在), got: ' + JSON.stringify(msg));
        }
        log('PASS: unknown user rejected after restart');
        ws1.close();

        // 4b) 老账号错误密码 → login_fail（证明 SELECT 命中且做了密码校验）
        const ws2 = await openWs(CHILD_WS);
        p = wsOnce(ws2, (m) => m.type === 'login_fail' || m.type === 'login_ok');
        wsSend(ws2, { type: 'login', username, password: 'wrong_pwd' });
        msg = await p;
        if (msg.type !== 'login_fail' || msg.reason !== '密码错误') {
            throw new Error('expected login_fail(密码错误), got: ' + JSON.stringify(msg));
        }
        log('PASS: wrong password rejected for persisted account');
        ws2.close();

        // 4c) 核心断言：重启后老账号 + 正确密码 → login_ok
        const ws3 = await openWs(CHILD_WS);
        p = wsOnce(ws3, (m) => m.type === 'login_ok' || m.type === 'login_fail');
        wsSend(ws3, { type: 'login', username, password });
        msg = await p;
        if (msg.type !== 'login_ok') {
            throw new Error('PERSISTENCE BROKEN: persisted account login failed after restart: ' + JSON.stringify(msg));
        }
        log('PASS: persisted account logs in after full server restart, player_id=' + msg.player_id);
        ws3.close();

        // 4d) 对已落库账号重复注册 → register_fail（修复前 INSERT 唯一键冲突被静默吞掉）
        const ws4 = await openWs(CHILD_WS);
        p = wsOnce(ws4, (m) => m.type === 'register_fail' || m.type === 'login_ok');
        wsSend(ws4, { type: 'register', username, password });
        msg = await p;
        if (msg.type !== 'register_fail' || msg.reason !== '用户名已被注册') {
            throw new Error('expected register_fail(用户名已被注册), got: ' + JSON.stringify(msg));
        }
        log('PASS: re-registering persisted username rejected');
        ws4.close();

        console.log('=== [Persist Test] ALL PASSED ===');
    } finally {
        try { child.kill('SIGTERM'); } catch (e) {}
        try { fs.closeSync(outFd); } catch (e) {}
        // 给子进程一点时间退出再删临时配置
        await new Promise((r) => setTimeout(r, 500));
        try { fs.unlinkSync(CHILD_CONFIG); } catch (e) {}
        if (childExit !== null && childExit !== 0 && childExit !== null) {
            // SIGTERM 导致的非零退出属正常；仅记录不判失败
            log('child exited with code ' + childExit + ' (expected after SIGTERM)');
        }
    }
}

run().then(() => {
    process.exit(0);
}).catch((err) => {
    console.error('=== [Persist Test] FAILED ===');
    console.error(err && err.stack ? err.stack : err);
    try {
        if (fs.existsSync(CHILD_LOG)) {
            console.error('--- child server log tail ---');
            const tail = fs.readFileSync(CHILD_LOG, 'utf8').split('\n').slice(-40).join('\n');
            console.error(tail);
        }
    } catch (e) {}
    process.exit(1);
});
