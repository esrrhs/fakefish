// FakeFish 大鱼吃小鱼真实对抗与吞噬结算测试
const WebSocket = require('ws');

async function runCombatVerification() {
    console.log("=== [Combat E2E Test] Starting Hunter vs Prey Eat & Respawn Test ===");

    const wsHunter = new WebSocket("ws://127.0.0.1:8081/");
    const wsPrey = new WebSocket("ws://127.0.0.1:8081/");

    let hunterId = null;
    let preyId = null;
    let eatEvent = null;
    let diedEvent = null;

    // Wait for both connections to open
    await new Promise((resolve) => {
        let count = 0;
        const check = () => { count++; if (count === 2) resolve(); };
        wsHunter.onopen = check;
        wsPrey.onopen = check;
    });

    const hName = "Hunter_" + Math.floor(Math.random() * 10000);
    const pName = "Prey_" + Math.floor(Math.random() * 10000);

    // Set up message handlers BEFORE sending any messages (prevents race condition)
    let hunter = null;
    let prey = null;
    let foods = [];
    let zone = null;  // snapshot 下发的当前安全区 {x,y,r,...}，无圈环境为 null
    let hunterChaseState = "grow";  // "grow"（圈内吃豆）| "strike"（直扑猎物）

    // 点 (x,y) 是否在安全区内（margin 预留边距，收缩中也不贴边）
    function inZone(x, y, margin) {
        if (!zone) return true;
        return Math.hypot(x - zone.x, y - zone.y) < zone.r - margin;
    }

    // 发育用豆子：优先圈内、并尽量偏向猎物一侧（缩短随后的冲刺距离）；
    // 圈内暂时无豆则接受任意豆子
    function pickGrowFood() {
        if (!hunter || foods.length === 0) return null;
        let pool = foods.filter((f) => inZone(f.x, f.y, 20));
        if (pool.length === 0) pool = foods;
        let best = null;
        let bestScore = Infinity;
        for (const f of pool) {
            const score = Math.hypot(f.x - hunter.x, f.y - hunter.y)
                + 0.5 * Math.hypot(f.x - prey.x, f.y - prey.y);
            if (score < bestScore) {
                bestScore = score;
                best = f;
            }
        }
        return best;
    }

    // 猎人移动决策（50ms 一次）：
    //  - 体型满足吞噬阈值（r >= prey.r*1.15 且 gold 更多，1.05 判定留 10% 余量）
    //    时直扑猎物；冲刺途中若掉到实际判定线（1.05）以下则放弃，回圈重新发育；
    //  - 否则在圈内吃豆发育，人先回到圈内；CI 缩圈环境（12s/6s）下站桩猎物会在
    //    圈外被 zone_dps(20/s) 慢慢耗到 r=15，猎人只要不陪它在圈外掉金即可。
    function hunterMove() {
        if (!hunter || !prey) return;
        let tx, ty;
        const canStrike = hunter.r >= prey.r * 1.15 && hunter.gold > prey.gold;
        const stillEatable = hunter.r > prey.r * 1.05 && hunter.gold > prey.gold;
        const striking = hunterChaseState === "strike";
        if ((striking && stillEatable) || (!striking && canStrike)) {
            hunterChaseState = "strike";
            tx = prey.x;
            ty = prey.y;
        } else {
            hunterChaseState = "grow";
            if (zone && !inZone(hunter.x, hunter.y, 45)) {
                // 出圈太远：先回圈心，避免被 20 dps 耗死
                tx = zone.x;
                ty = zone.y;
            } else {
                const f = pickGrowFood();
                if (!f) return;
                tx = f.x;
                ty = f.y;
            }
        }
        const dx = tx - hunter.x;
        const dy = ty - hunter.y;
        const dist = Math.hypot(dx, dy);
        if (dist > 1) {
            wsHunter.send(JSON.stringify({ type: "move", dx: dx / dist, dy: dy / dist }));
        }
    }

    // Wait for login_ok from both clients
    const loginPromise = new Promise((resolve) => {
        let logins = 0;
        const onLogin = () => { logins++; if (logins === 2) resolve(); };

        wsHunter.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "login_ok") { hunterId = d.player_id; onLogin(); }
        });
        wsPrey.addEventListener("message", (m) => {
            const d = JSON.parse(m.data);
            if (d.type === "login_ok") { preyId = d.player_id; onLogin(); }
        });
    });

    // NOW send register messages (handlers are already set up)
    wsHunter.send(JSON.stringify({ type: "register", username: hName, password: "123" }));
    wsPrey.send(JSON.stringify({ type: "register", username: pName, password: "123" }));

    // Wait for both logins
    await loginPromise;

    console.log(`Hunter (ID: ${hunterId}) and Prey (ID: ${preyId}) logged in.`);

    // 模拟真实客户端心跳，避免被服务端 conn_timeout_s 踢掉
    const pingTimer = setInterval(() => {
        wsHunter.send(JSON.stringify({ type: "ping" }));
        wsPrey.send(JSON.stringify({ type: "ping" }));
    }, 3000);

    // Add additional listeners for snapshot and eat events
    wsHunter.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "snapshot") {
            if (d.foods) foods = d.foods;
            if (d.zone) zone = d.zone;
            for (const p of d.players) {
                if (p.id === hunterId) hunter = p;
                if (p.id === preyId) prey = p;
            }
        } else if (d.type === "eat") {
            // 只关心猎人发动的吞噬（机器人也会捕猎，不能算数）
            if (d.eater_id === hunterId) {
                eatEvent = d;
                console.log(`[Server Event] EAT TRIGGERED! Eater: ${d.eater_id}, Victim: ${d.victim_id}, Gain: +${d.gold}`);
            }
        }
    });

    wsPrey.addEventListener("message", (m) => {
        const d = JSON.parse(m.data);
        if (d.type === "you_died") {
            diedEvent = d;
            console.log(`[Server Event] YOU_DIED TRIGGERED! Victim respawned with ${d.gold} gold at (${d.x}, ${d.y})`);
        }
    });

    // 阶段 1：猎人在安全区内吃豆发育到 125 gold（半径 40.0 -> 42.96 > 40*1.05=42.0）。
    // CI 缩圈环境下站在圈外会被 zone_dps 耗金，发育移动必须贴着圈内走。
    console.log("Phase 1: Hunter collecting pellets inside zone to grow bigger...");
    const moveTimer = setInterval(hunterMove, 50);

    // 等待猎人体型超过猎物 (阈值 125 gold)
    // Windows 上 fakelua 按上游约定 -O0 构建、JIT 走 gcc 子进程，加上共享 runner 降速，
    // 吃豆发育明显慢于 Unix，固定 15s 会来不及达到 125 就进入 Phase 2，于是全程停在
    // grow 模式、永远不 strike，最终 30s 追逐超时。与 HOTFIX_TIMEOUT_MS 同一套路：
    // 超时预算由环境变量给出，判定逻辑本身不变。
    const P1_MS = Number(process.env.COMBAT_PHASE1_MS || 15000);
    const P2_MS = Number(process.env.COMBAT_PHASE2_MS || 30000);
    const p1Start = Date.now();
    while (Date.now() - p1Start < P1_MS) {
        if (hunter && hunter.gold >= 125) {
            console.log(`Hunter grew to ${hunter.gold} gold (radius: ${hunter.r}) > Prey (${prey ? prey.gold : 100} gold)`);
            break;
        }
        await new Promise(r => setTimeout(r, 100));
    }

    // 阶段 2：猎物保持不动，猎人体型够就直扑、不够就回圈内吃豆，可反复往返。
    // 两个失败源都要扛：
    //  1) 金币雨（CI feast=12s）奖励豆刷在猎物身边会让它暂时变大 → 继续发育；
    //  2) 缩圈把圈外站桩猎物耗到 r=15 → 此时双方同尺寸永远无法满足 1.05 吞噬比，
    //     猎人必须保住圈内体型再短促出击。
    console.log("Phase 2: Hunter zone-aware adaptive chase (strike when big enough)...");
    const p2Start = Date.now();
    let lastLog = Date.now();
    while (Date.now() - p2Start < P2_MS) {
        if (eatEvent && diedEvent) {
            console.log("Phase 2 Complete: Hunter devoured Prey successfully!");
            break;
        }
        if (Date.now() - lastLog > 2000) {
            lastLog = Date.now();
            if (hunter && prey) {
                const dist = Math.hypot(hunter.x - prey.x, hunter.y - prey.y).toFixed(1);
                const zr = zone ? `zone.r=${Math.round(zone.r)}` : "no-zone";
                console.log(`  -> [${hunterChaseState}] Hunter (${hunter.x}, ${hunter.y}, gold=${hunter.gold}, r=${hunter.r}) vs Prey (${prey.x}, ${prey.y}, gold=${prey.gold}, r=${prey.r}), dist=${dist}, ${zr}`);
            }
        }
        await new Promise(r => setTimeout(r, 100));
    }

    clearInterval(moveTimer);
    clearInterval(pingTimer);
    wsHunter.close();
    wsPrey.close();

    if (!eatEvent || !diedEvent) {
        console.error("Combat eat not completed in timeout, will check status.");
        process.exit(1);
    }
    if (typeof eatEvent.eater_name !== "string" || typeof eatEvent.victim_name !== "string") {
        console.error("FAIL: eat event missing eater_name/victim_name: " + JSON.stringify(eatEvent));
        process.exit(1);
    }

    console.log("=== [Combat E2E Test] FULLY PASSED AND VERIFIED! ===");
}

runCombatVerification().catch(err => {
    console.error("Combat verification error:", err);
    process.exit(1);
});
