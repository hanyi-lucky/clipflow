#!/usr/bin/env bash
# ClipFlow 服务器同步冒烟测试（本地验证，无需部署）
# 覆盖：图片上传 → 历史列表瘦身(content='') → /content 完整密文 → 文本回归
#       → 长文本列表截断 ≤10000 → /content 长文本完整返回（含 >50000 字符密文
#         字节级一致，证明服务端不静默截断） → 未授权 401
set -euo pipefail

TEST_PORT="${SMOKE_PORT:-3210}"
BASE="http://127.0.0.1:${TEST_PORT}/api"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${SCRIPT_DIR}/clipflow.db"
SERVER_PID=""
BIG_PAYLOAD="${SCRIPT_DIR}/.smoke-oversize-payload.json"

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "${DB}" "${DB}-journal" "${DB}-wal" "${DB}-shm"
  rm -f "${BIG_PAYLOAD}"
}
trap cleanup EXIT

echo "==> 启动测试服务器 (PORT=${TEST_PORT})"
PORT="${TEST_PORT}" node "${SCRIPT_DIR}/index.js" &
SERVER_PID=$!

ready=0
for _ in $(seq 1 30); do
  if curl -fsS "${BASE}/ping" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.3
done
if [ "$ready" != "1" ]; then
  echo "FAIL: server did not start" >&2
  exit 1
fi

echo "==> 1. auth"
TOKEN=$(curl -fsS -X POST "${BASE}/auth" -H 'Content-Type: application/json' \
  -d '{"userId":"user_smoke_v13"}' \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.token)})')
echo "    token=${TOKEN:0:8}..."
AUTH="Authorization: Bearer ${TOKEN}"

echo "==> 2. 上传图片载荷"
IMG_ID="smoke-history-image-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"FULL_CIPHER\",\"thumb\":\"THUMB_CIPHER\",\"hash\":\"HASH_IMAGE_1\",\"type\":\"image\",\"width\":100,\"height\":50,\"format\":\"jpeg\",\"historyId\":\"${IMG_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000000000}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"){console.error("FAIL upload image: "+s);process.exit(1)}})'
echo "    ok"

echo "==> 3. 历史列表：图片行 content 为空、thumb/width/height/format/hash 存在"
curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-image-1");
  if(!r){console.error("FAIL history row missing");process.exit(1)}
  if(r.type!=="image"){console.error("FAIL type: "+r.type);process.exit(1)}
  if(r.content!==""){console.error("FAIL image content not stripped: "+r.content);process.exit(1)}
  if(r.thumb!=="THUMB_CIPHER"){console.error("FAIL thumb: "+r.thumb);process.exit(1)}
  if(r.width!==100||r.height!==50){console.error("FAIL dims: "+r.width+"x"+r.height);process.exit(1)}
  if(r.format!=="jpeg"){console.error("FAIL format: "+r.format);process.exit(1)}
  if(r.hash!=="HASH_IMAGE_1"){console.error("FAIL hash: "+r.hash);process.exit(1)}
  console.log("    ok");
})'

echo "==> 4. /api/history/:id/content 返回完整密文"
curl -fsS "${BASE}/history/${IMG_ID}/content" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.data.content!=="FULL_CIPHER"){console.error("FAIL content endpoint: "+s);process.exit(1)}
  console.log("    ok");
})'

echo "==> 5. 文本路径回归"
TEXT_ID="smoke-history-text-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"TEXT_CIPHER\",\"hash\":\"HASH_TEXT_1\",\"type\":\"text\",\"historyId\":\"${TEXT_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000001000}" \
  >/dev/null
curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-text-1");
  if(!r){console.error("FAIL text row missing");process.exit(1)}
  if(r.content!=="TEXT_CIPHER"){console.error("FAIL text content changed: "+r.content);process.exit(1)}
  console.log("    ok");
})'

echo "==> 6. /api/clipboard 最新记录保留完整 content + history_id 与历史行对齐"
curl -fsS "${BASE}/clipboard" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.data.content!=="TEXT_CIPHER"){console.error("FAIL clipboard content: "+s);process.exit(1)}
  if(j.data.history_id!=="smoke-history-text-1"){console.error("FAIL clipboard history_id: "+j.data.history_id);process.exit(1)}
  console.log("    ok");
})'

echo "==> 7. 长文本行：列表 content 截断 ≤10000，/content 返回完整 20000 字符"
LONG_ID="smoke-history-long-text-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  --data-binary "$(node -e 'const t="L".repeat(20000);process.stdout.write(JSON.stringify({content:t,hash:"HASH_TEXT_LONG",type:"text",historyId:"smoke-history-long-text-1",sourceDevice:"smoke-device",sourceDeviceName:"Smoke Mac",sourcePlatform:"macos",timestamp:1700000002000}))')" \
  >/dev/null
curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-long-text-1");
  if(!r){console.error("FAIL long text row missing");process.exit(1)}
  if(r.content.length>10000){console.error("FAIL list content not truncated: "+r.content.length);process.exit(1)}
  if(r.content.length===0){console.error("FAIL list content unexpectedly empty");process.exit(1)}
  console.log("    ok (list length="+r.content.length+")");
})'
curl -fsS "${BASE}/history/${LONG_ID}/content" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const len=(j.data&&j.data.content&&j.data.content.length)||0;
  if(j.code!=="SUCCESS"||len!==20000){console.error("FAIL content endpoint not full: "+len);process.exit(1)}
  console.log("    ok (full length="+len+")");
})'

echo "==> 7b. 超长密文（60000 字符 > 旧 50000 截断上限）上传：列表截断 ≤10000，/content 与上传字节级一致"
LONG2_ID="smoke-history-long-text-2"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  --data-binary "$(node -e 'const t="C".repeat(60000);process.stdout.write(JSON.stringify({content:t,hash:"HASH_TEXT_LONG2",type:"text",historyId:"smoke-history-long-text-2",sourceDevice:"smoke-device",sourceDeviceName:"Smoke Mac",sourcePlatform:"macos",timestamp:1700000003000}))')" \
  >/dev/null
curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-long-text-2");
  if(!r){console.error("FAIL long2 row missing");process.exit(1)}
  if(r.content.length>10000){console.error("FAIL long2 list content not truncated: "+r.content.length);process.exit(1)}
  if(r.content.length===0){console.error("FAIL long2 list content unexpectedly empty");process.exit(1)}
  console.log("    ok (list length="+r.content.length+")");
})'
curl -fsS "${BASE}/history/${LONG2_ID}/content" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const v=(j.data&&j.data.content)||"";
  if(j.code!=="SUCCESS"){console.error("FAIL long2 content endpoint: "+s);process.exit(1)}
  if(v!=="C".repeat(60000)){console.error("FAIL long2 content corrupted: len="+v.length);process.exit(1)}
  console.log("    ok (full length="+v.length+", byte-exact match)");
})'

echo "==> 8. 无 token 访问 /content 应 401"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/history/${IMG_ID}/content")
if [ "$CODE" != "401" ]; then
  echo "FAIL: expect 401 got ${CODE}" >&2
  exit 1
fi
echo "    ok"

echo "==> 9. 超过 express 50mb 上限的请求应返回 413（而非 500）"
node -e 'const t="X".repeat(51*1024*1024);require("fs").writeFileSync(process.argv[1],JSON.stringify({content:t,hash:"HASH_OVERSIZE",type:"text",historyId:"smoke-history-oversize-1",sourceDevice:"smoke-device",sourceDeviceName:"Smoke Mac",sourcePlatform:"macos",timestamp:1700000004000}))' "${BIG_PAYLOAD}"
BIG_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  --data-binary "@${BIG_PAYLOAD}")
if [ "$BIG_CODE" != "413" ]; then
  echo "FAIL: expect 413 got ${BIG_CODE}" >&2
  exit 1
fi
echo "    ok"

echo "SMOKE TEST PASSED"
