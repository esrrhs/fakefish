// FakeFish 分裂球（split）E2E 测试
// 流程：吃豆攒金币 → 顶到上墙边 → 朝墙分裂 → 冷却后上墙合体
// 需在无机器人世界运行（与 feast/zone 同一测试阶段）
const WebSocket = require('ws');

async function runSplitTest() {
    console.log("=== [Split E2E Test] Starting Split/Merge Test ===");

    const ws = new WebSocket("ws://127.0.0.1:8081/");

    let playerId = null;
    let lastSnap = null;
    let selfEatObserved = false;

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

    const name = "SplitTest_" + Math.floor(Math.random() * 10000);
    ws.send(JSON.stringify({ type: "register", username: name, password: "123" }));
    await loginOk;
    console.log(`Player ${name} (ID: ${playerId}) logged in.`);

    const pingTimer = setInterval(() => ws.send(JSON.stringify({ type: "ping" })), 3000);

    ws.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "snapshot") {
            lastSnap = d;
        } else if (d.type === "eat" && d.eater_id === d.victim_id) {
            selfEatObserved = true;
        }
    });

    const sleep100 = () => new Promise(r => setTimeout(r, 100));

    function ownCells() {
        if (!lastSnap) return [];
        return lastSnap.players.filter(p => p.id === playerId);
    }

    function ownGold() {
        let sum = 0;
        for (const c of ownCells()) sum += c.gold;
        return sum;
    }

    function ownBig() {
        let big = null;
        for (const c of ownCells()) {
            if (big === null || c.r > big.r) big = c;
        }
        return big;
    }

    function sendDir(tx, ty) {
        ws.send(JSON.stringify({ type: "move", dx: tx, dy: ty }));
    }

    // 朝地图坐标移动，直到自身最大细胞与目标距离 ≤ reach
    async function driveTo(tx, ty, reach, timeoutS) {
        const t0 = Date.now();
        while (Date.now() - t0 < timeoutS * 1000) {
            const big = ownBig();
            if (big === null) return false;
            const dx = tx - big.x;
            const dy = ty - big.y;
            const d = Math.hypot(dx, dy);
            if (d <= reach) {
                sendDir(0, 0);
                return true;
            }
            sendDir(dx / d, dy / d);
            await sleep100();
        }
        return false;
    }

    // 1. 吃豆攒金币到 110（初始 100，吃 2 颗即可）
    console.log("Eating pellets to reach gold 110...");
    const tGather = Date.now();
    while (ownGold() < 110 && Date.now() - tGather < 60000) {
        const big = ownBig();
        if (!lastSnap || big === null) { await sleep100(); continue; }
        // 找最近的金币豆
        let near = null, nd = 1e9;
        for (const f of lastSnap.foods) {
            const d = Math.hypot(f.x - big.x, f.y - big.y);
            if (d < nd) { nd = d; near = f; }
        }
        if (near === null) { await sleep100(); continue; }
        if (!(await driveTo(near.x, near.y, 6, 8))) {
            console.error("FAIL: could not reach a pellet");
            process.exit(1);
        }
        await sleep100();
    }
    const gatheredGold = ownGold();
    if (gatheredGold < 110) {
        console.error("FAIL: could not gather gold, got " + gatheredGold);
        process.exit(1);
    }
    console.log(`Gold gathered: ${gatheredGold}`);

    // 1.5 移动到地图中心再分裂，保证合体等待期间始终在安全区内
    if (!(await driveTo(1000, 1000, 80, 60))) {
        console.error("FAIL: could not reach map center");
        process.exit(1);
    }

    // 2. 停止移动，原地朝北分裂（分裂前一刻捕获金币）
    sendDir(0, 0);
    await sleep100();
    sendDir(0, -1);
    await sleep100();
    const goldBeforeSplit = ownGold();
    ws.send(JSON.stringify({ type: "split" }));

    // 等待出现 2 个细胞
    let cells = ownCells();
    const tSplit = Date.now();
    while (cells.length < 2 && Date.now() - tSplit < 4000) {
        await sleep100();
        cells = ownCells();
    }
    if (cells.length !== 2) {
        console.error("FAIL: expected 2 cells after split, got " + cells.length);
        process.exit(1);
    }
    for (const c of cells) {
        if (!Number.isInteger(c.cell) || c.cell < 1 || !(c.r > 0)) {
            console.error("FAIL: malformed cell entry: " + JSON.stringify(c));
            process.exit(1);
        }
    }
    // 两个细胞必须分开（新细胞沿分裂方向产生）
    const sep = Math.hypot(cells[0].x - cells[1].x, cells[0].y - cells[1].y);
    const goldRightAfter = ownGold();
    console.log(`Split OK: cells=${cells.length}, gold=${goldRightAfter}, separation=${Math.round(sep)}`);

    if (goldRightAfter !== goldBeforeSplit) {
        console.error(`FAIL: gold not conserved after split: ${goldBeforeSplit} -> ${goldRightAfter}`);
        process.exit(1);
    }
    if (sep < 5) {
        console.error(`FAIL: split cells did not separate (sep=${sep})`);
        process.exit(1);
    }
    if (selfEatObserved) {
        console.error("FAIL: self eat event observed");
        process.exit(1);
    }

    // 4. 合体冷却（默认 merge_cooldown_s=12；等 15s 留余量）。
    //    期间不移动，避免跑到圈外吃毒；冷却后吸附力自动把细胞拉到一起
    console.log("Waiting merge cooldown (15s)...");
    sendDir(0, 0);
    const tCd = Date.now();
    while (Date.now() - tCd < 15000) {
        await sleep100();
    }

    // 5. 等待吸附合体为 1 个细胞（冷却后约 2-4s 靠拢）
    const tMerge = Date.now();
    while (ownCells().length > 1 && Date.now() - tMerge < 10000) {
        await sleep100();
    }
    sendDir(0, 0);
    clearInterval(pingTimer);

    const after = ownCells();
    if (after.length !== 1) {
        console.error("FAIL: cells did not merge, still " + after.length);
        process.exit(1);
    }
    // 合体后金币不减少（吸附路径上可能吃到金币豆，允许变多）
    if (after[0].gold < goldBeforeSplit) {
        console.error(`FAIL: gold lost after merge: expected >= ${goldBeforeSplit}, got ${after[0].gold}`);
        process.exit(1);
    }
    console.log(`Merge OK: 1 cell, gold=${after[0].gold}`);

    ws.close();
    console.log("=== [Split E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runSplitTest().catch(err => {
    console.error("Split test error:", err.message);
    process.exit(1);
});
