// FakeFish AI 机器人与历史排行 E2E 测试
const WebSocket = require('ws');

async function runBotAndRankTest() {
    console.log("=== [Bots & Rank E2E Test] Starting Bot Spawn + Persistent Rank Test ===");

    const ws = new WebSocket("ws://127.0.0.1:8081/");

    let playerId = null;
    let rankMsg = null;

    // 先挂 handler 再发消息（避免 race condition）
    const loginOk = new Promise((resolve, reject) => {
        ws.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "login_ok") {
                playerId = d.player_id;
                resolve();
            } else if (d.type === "login_fail" || d.type === "register_fail") {
                reject(new Error("auth failed: " + d.reason));
            }
        });
        ws.addEventListener("error", () => reject(new Error("ws error")));
    });

    await new Promise((resolve, reject) => {
        ws.onopen = resolve;
        ws.addEventListener("error", () => reject(new Error("connect failed")));
    });

    const name = "BotTest_" + Math.floor(Math.random() * 10000);
    ws.send(JSON.stringify({ type: "register", username: name, password: "123" }));
    await loginOk;
    console.log(`Player ${name} (ID: ${playerId}) logged in.`);

    // 阶段 1：快照中出现机器人，且机器人在移动
    console.log("Phase 1: Checking bots in snapshots...");
    const snapPlayers = [];
    ws.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "snapshot") {
            snapPlayers.push(d.players || []);
        }
    });

    const t0 = Date.now();
    while (Date.now() - t0 < 6000) {
        await new Promise(r => setTimeout(r, 200));
    }

    if (snapPlayers.length < 5) {
        console.error(`FAIL: expected >= 5 snapshots, got ${snapPlayers.length}`);
        process.exit(1);
    }

    const bots = snapPlayers[snapPlayers.length - 1].filter(p => p.bot === true);
    if (bots.length < 1) {
        console.error(`FAIL: expected >= 1 bot in snapshot, got ${bots.length}`);
        process.exit(1);
    }
    console.log(`Found ${bots.length} bots in snapshot: ${bots.map(b => b.name).join(", ")}`);

    // 验证机器人确实在移动（对比两次快照里同一 bot 的坐标）
    const firstSnap = snapPlayers[0];
    const lastSnap = snapPlayers[snapPlayers.length - 1];
    let moved = false;
    for (const b of bots) {
        const before = firstSnap.find(p => p.id === b.id);
        if (before && (Math.abs(before.x - b.x) > 1 || Math.abs(before.y - b.y) > 1)) {
            moved = true;
            console.log(`  Bot ${b.name} moved from (${before.x}, ${before.y}) to (${b.x}, ${b.y})`);
        }
    }
    if (!moved) {
        console.error("FAIL: bots did not move between snapshots");
        process.exit(1);
    }

    // 阶段 2：get_rank 返回 rank 消息（历史排行）
    console.log("Phase 2: Requesting persistent rank...");
    const rankPromise = new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("rank response timeout")), 10000);
        ws.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "rank") {
                clearTimeout(timer);
                rankMsg = d;
                resolve();
            }
        });
    });

    ws.send(JSON.stringify({ type: "get_rank", limit: 10 }));
    await rankPromise;

    // 空 Lua table 会被 json.encode 成 {}（对象），视为空数组
    const list = Array.isArray(rankMsg.list) ? rankMsg.list : [];
    console.log(`Rank list received: ${list.length} entries`);
    for (const item of list) {
        if (!item.name || typeof item.best_gold !== "number") {
            console.error("FAIL: bad rank entry: " + JSON.stringify(item));
            process.exit(1);
        }
        console.log(`  #${list.indexOf(item) + 1} ${item.name} best_gold=${item.best_gold} kills=${item.kills || 0}`);
    }

    // 刚注册的账号 best_gold >= 初始金币，且应出现在排行里（数据量少时）
    const mine = list.find(e => e.name === name);
    if (mine && mine.best_gold < 100) {
        console.error(`FAIL: fresh account best_gold should be >= 100, got ${mine.best_gold}`);
        process.exit(1);
    }

    ws.close();
    console.log("=== [Bots & Rank E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runBotAndRankTest().catch(err => {
    console.error("Bots & rank test error:", err.message);
    process.exit(1);
});
