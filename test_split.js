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

    // 1.5 移动到地图中心 30 单位内再分裂
    if (!(await driveTo(1000, 1000, 30, 60))) {
        console.error("FAIL: could not reach map center");
        process.exit(1);
    }

    // 1.6 等待安全区足够大（圆心恒为地图中心）。新细胞分裂冲量最远滑行约 150 单位，
    //    加上到达余量 30、出生偏移（r/2+6，高金币时约 80），细胞中心最多偏离 ~260。
    //    r>=500 时分裂，冷却期内即使再收缩一阶（0.7x=350）仍覆盖该位移，绝不出圈吃毒。
    const tZoneGate = Date.now();
    let zoneGateLogged = false;
    while (!(lastSnap.zone && lastSnap.zone.r >= 500)) {
        if (!zoneGateLogged) {
            console.log(`Zone radius ${lastSnap.zone ? lastSnap.zone.r : "?"} < 500, waiting for a fresh cycle...`);
            zoneGateLogged = true;
        }
        if (Date.now() - tZoneGate > 90000) {
            console.error("FAIL: zone never reached safe radius for split");
            process.exit(1);
        }
        await sleep100();
    }

    // 1.7 穿毒圈赶路可能被扣过金币，而服务端要求 gold>100 才允许分裂。
    //    只在距地图中心 200 的绝对安全盘内补吃（细胞中心最远到 206，最小圈 r=250 也覆盖），
    //    附近没豆就原地等金币雨；人在中心不会掉金币
    const tTopUp = Date.now();
    let topUpLogged = false;
    while (ownGold() < 110) {
        if (!topUpLogged) {
            console.log(`Gold ${ownGold()} below split threshold, topping up near center...`);
            topUpLogged = true;
        }
        if (Date.now() - tTopUp > 90000) {
            console.error("FAIL: could not top up gold near center, got " + ownGold());
            process.exit(1);
        }
        let near = null, nd = 1e9;
        for (const f of lastSnap.foods) {
            const d = Math.hypot(f.x - 1000, f.y - 1000);
            if (d < 200 && d < nd) { nd = d; near = f; }
        }
        if (near !== null) {
            if (!(await driveTo(near.x, near.y, 6, 10))) {
                console.error("FAIL: could not reach near-center pellet");
                process.exit(1);
            }
            await driveTo(1000, 1000, 30, 20);
        } else {
            await new Promise(r => setTimeout(r, 500));
        }
    }

    // 2. 朝北分裂。注意：采样窗口内细胞仍可能吃到金币豆（世界按帧异步推进），
    //    不能直接比较窗口两侧金币——用快照中食物集合的差集精确核算吃豆数量。
    //    每颗金币豆价值 5（server/world.lua food_val，无机器人世界里豆只可能被自己吃）。
    const FOOD_VAL = 5;
    function foodCounts(snap) {
        const m = new Map();
        for (const f of snap.foods) {
            const k = f.x + "," + f.y;
            m.set(k, (m.get(k) || 0) + 1);
        }
        return m;
    }
    function pelletsEaten(before, after) {
        let n = 0;
        for (const [k, c0] of before) {
            const c1 = after.get(k) || 0;
            if (c0 > c1) n += c0 - c1;
        }
        return n;
    }

    sendDir(0, 0);
    await sleep100();
    sendDir(0, -1);
    await sleep100();
    const baseSnap = lastSnap;                       // 分裂前基准快照
    const goldBeforeSplit = baseSnap.players
        .filter(p => p.id === playerId)
        .reduce((s, p) => s + p.gold, 0);
    const foodBefore = foodCounts(baseSnap);
    ws.send(JSON.stringify({ type: "split" }));
    // 立刻清空移动意图：冲量仍朝北（服务端零意图时也默认向上），但不再持续游走出安全区
    sendDir(0, 0);

    // 等待出现 2 个细胞
    let cells = ownCells();
    const tSplit = Date.now();
    let twoCellSnap = null;
    while (Date.now() - tSplit < 4000) {
        await sleep100();
        cells = ownCells();
        if (cells.length >= 2) { twoCellSnap = lastSnap; break; }
    }
    if (cells.length !== 2 || twoCellSnap === null) {
        console.error("FAIL: expected 2 cells after split, got " + cells.length);
        process.exit(1);
    }
    for (const c of cells) {
        if (!Number.isInteger(c.cell) || c.cell < 1 || !(c.r > 0)) {
            console.error("FAIL: malformed cell entry: " + JSON.stringify(c));
            process.exit(1);
        }
    }

    // 几何保证：朝北分裂，y 较大（靠南）的是未动的母细胞，另一个是新细胞。
    // 新细胞静止位置 ≤ 母细胞到中心距离 + (新半径+6) + 冲量极限滑行 150；
    // 该上界必须 < 最小安全区半径 252，冷却期内毒圈怎么收缩都扣不到金币
    const oldCell = cells[0].y >= cells[1].y ? cells[0] : cells[1];
    const newCell = oldCell === cells[0] ? cells[1] : cells[0];
    const oldDist = Math.hypot(oldCell.x - 1000, oldCell.y - 1000);
    const restBound = oldDist + newCell.r + 6 + 150;
    if (oldDist > 45 || restBound > 245) {
        console.error(`FAIL: split geometry outside guaranteed-safe disk: oldDist=${Math.round(oldDist)}, bound=${Math.round(restBound)}, gold=${goldBeforeSplit}`);
        process.exit(1);
    }
    // 两个细胞必须分开（新细胞沿分裂方向产生）
    const sep = Math.hypot(cells[0].x - cells[1].x, cells[0].y - cells[1].y);
    const goldRightAfter = cells.reduce((s, c) => s + c.gold, 0);
    const eatenInWindow = pelletsEaten(foodBefore, foodCounts(twoCellSnap));
    console.log(`Split OK: cells=${cells.length}, gold=${goldRightAfter}, separation=${Math.round(sep)}, pellets eaten in window=${eatenInWindow}`);

    // 分裂本身不创造/销毁金币；窗口内金币增量必须恰好等于吃掉的豆数 × 5。
    // 注意这只在「无机器人」的世界里成立：金币豆被吃掉后会移到新坐标，快照里的
    // 豆集合减少既可能是本玩家吃的、也可能是 bot 吃的，两者无法区分。有 bot 时
    // 用下面的宽松断言（分裂前后金币不减少），避免误报。
    const botsPresent = lastSnap.players.some(p => p.bot === true || p.id >= 800000);
    if (botsPresent) {
        console.log("  (bots present: skipping strict gold conservation, they can eat pellets too)");
        if (goldRightAfter < goldBeforeSplit) {
            console.error(`FAIL: gold decreased across split: ${goldBeforeSplit} -> ${goldRightAfter}`);
            process.exit(1);
        }
    } else if (goldRightAfter !== goldBeforeSplit + eatenInWindow * FOOD_VAL) {
        console.error(`FAIL: gold not conserved after split: ${goldBeforeSplit} -> ${goldRightAfter}`
            + ` (expected ${goldBeforeSplit + eatenInWindow * FOOD_VAL}, ${eatenInWindow} pellets eaten)`);
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

    // 3. 等待冷却（merge_cooldown_s=12 世界时间）结束并吸附合体。
    //    世界时间按帧推进（每帧 dt=0.05），共享 CI runner 上真实帧率可能明显低于 20Hz，
    //    因此不能按真实时间死等冷却；直接用 60s 总预算轮询合体结果，覆盖慢至 ~6Hz 的帧速
    console.log("Waiting for cooldown & merge (up to 60s)...");
    const tMerge = Date.now();
    while (ownCells().length > 1 && Date.now() - tMerge < 60000) {
        await sleep100();
    }
    clearInterval(pingTimer);

    const after = ownCells();
    if (after.length !== 1) {
        const cur = ownCells().map(c => `(${Math.round(c.x)},${Math.round(c.y)},r${c.r.toFixed(1)},g${c.gold})`).join(" ");
        console.error(`FAIL: cells did not merge after 60s, still ${after.length}: ${cur}`);
        process.exit(1);
    }
    // 合体后金币不减少：等待期间细胞始终在安全区内，只可能吃到金币豆。
    // 有 bot 时该前提不成立（细胞可能被 bot 吃掉而损失金币），故跳过此断言——
    // 合体本身已由上面的「after.length === 1」验证。
    if (!botsPresent && after[0].gold < goldRightAfter) {
        console.error(`FAIL: gold lost after merge: expected >= ${goldRightAfter}, got ${after[0].gold}`);
        process.exit(1);
    }
    console.log(`Merge OK: 1 cell, gold=${after[0].gold}, elapsed=${((Date.now() - tMerge) / 1000).toFixed(1)}s`);

    ws.close();
    console.log("=== [Split E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runSplitTest().catch(err => {
    console.error("Split test error:", err.message);
    process.exit(1);
});
