// FakeFish HTTP JSON API E2E 测试（无需 ws 依赖）
const BASE = "http://127.0.0.1:8080";

async function runApiTest() {
    console.log("=== [HTTP API E2E Test] Starting JSON API Test ===");
    let failures = 0;

    // 1. 静态首页仍可用
    const home = await fetch(BASE + "/");
    if (home.status !== 200) {
        console.error(`FAIL: GET / expected 200, got ${home.status}`);
        failures++;
    } else {
        const html = await home.text();
        if (!html.includes("FakeFish")) {
            console.error("FAIL: GET / body missing FakeFish title");
            failures++;
        } else {
            console.log("GET / -> 200, static page OK");
        }
    }

    // 2. /api/stats 结构
    const stats = await fetch(BASE + "/api/stats");
    if (stats.status !== 200) {
        console.error(`FAIL: GET /api/stats expected 200, got ${stats.status}`);
        failures++;
    } else {
        const j = await stats.json();
        if (j.code !== 0 || typeof j.online !== "number" || typeof j.bots !== "number"
            || typeof j.uptime_s !== "number" || !j.map || typeof j.map.width !== "number") {
            console.error("FAIL: /api/stats bad structure: " + JSON.stringify(j));
            failures++;
        } else {
            console.log(`GET /api/stats -> code=0 online=${j.online} bots=${j.bots} uptime_s=${j.uptime_s} map=${j.map.width}x${j.map.height}`);
        }
    }

    // 3. /api/rank 结构（list 可能为空表的 {} 编码，count 才是权威）
    const rank = await fetch(BASE + "/api/rank?limit=5");
    if (rank.status !== 200) {
        console.error(`FAIL: GET /api/rank expected 200, got ${rank.status}`);
        failures++;
    } else {
        const j = await rank.json();
        if (j.code !== 0 || typeof j.count !== "number" || j.count < 0 || j.count > 5) {
            console.error("FAIL: /api/rank bad structure: " + JSON.stringify(j));
            failures++;
        } else if (j.count > 0) {
            const first = (Array.isArray(j.list) ? j.list : [])[0];
            if (!first || !first.name || typeof first.best_gold !== "number") {
                console.error("FAIL: /api/rank entries malformed: " + JSON.stringify(j));
                failures++;
            } else {
                console.log(`GET /api/rank?limit=5 -> code=0 count=${j.count} #1 ${first.name} best_gold=${first.best_gold}`);
            }
        } else {
            console.log("GET /api/rank?limit=5 -> code=0 count=0 (empty cache)");
        }
    }

    // 4. /api/rank.csv 导出（fakelua csv.encode）
    const csv = await fetch(BASE + "/api/rank.csv?limit=5");
    if (csv.status !== 200) {
        console.error(`FAIL: GET /api/rank.csv expected 200, got ${csv.status}`);
        failures++;
    } else {
        const ct = csv.headers.get("content-type") || "";
        const text = await csv.text();
        const lines = text.trim().split("\n");
        if (ct.indexOf("text/csv") !== 0) {
            console.error("FAIL: /api/rank.csv content-type not text/csv: " + ct);
            failures++;
        } else if (lines[0] !== "rank,name,best_gold,kills") {
            console.error("FAIL: /api/rank.csv header mismatch: " + JSON.stringify(lines[0]));
            failures++;
        } else if (lines.length - 1 > 5) {
            console.error("FAIL: /api/rank.csv returned more rows than limit: " + (lines.length - 1));
            failures++;
        } else {
            console.log(`GET /api/rank.csv?limit=5 -> ${lines.length - 1} data rows, header OK`);
        }
    }

    // 5. /api/events 账本 API 结构（无 SQLite 时 list 为空也算正常降级）
    const events = await fetch(BASE + "/api/events?limit=3");
    if (events.status !== 200) {
        console.error(`FAIL: GET /api/events expected 200, got ${events.status}`);
        failures++;
    } else {
        const j = await events.json();
        if (j.code !== 0 || !Array.isArray(j.list) || j.count > 3) {
            console.error("FAIL: /api/events bad structure: " + JSON.stringify(j));
            failures++;
        } else {
            console.log(`GET /api/events?limit=3 -> code=0 count=${j.count}`);
        }
    }

    // 6. 未知 API 返回 404 JSON
    const miss = await fetch(BASE + "/api/nope");
    if (miss.status !== 404) {
        console.error(`FAIL: GET /api/nope expected 404, got ${miss.status}`);
        failures++;
    } else {
        console.log("GET /api/nope -> 404 JSON OK");
    }

    // 5. 目录穿越被拦截（fakelua string.find 是 ECMAScript 正则，旧检查拦截不住 ../）
    const trav = await fetch(BASE + "/api/%2e%2e/config.yaml");
    const trav2 = await fetch(BASE + "/..%2fconfig.yaml");
    if (trav.status === 200 || trav2.status === 200) {
        console.error(`FAIL: path traversal not blocked (${trav.status}/${trav2.status})`);
        failures++;
    } else {
        console.log(`Path traversal blocked (${trav.status}/${trav2.status}) OK`);
    }

    if (failures > 0) {
        console.error(`=== [HTTP API E2E Test] FAILED with ${failures} failure(s) ===`);
        process.exit(1);
    }
    console.log("=== [HTTP API E2E Test] ALL PASSED ===");
}

runApiTest().catch(err => {
    console.error("API test error:", err.message);
    process.exit(1);
});
