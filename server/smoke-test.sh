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
FILE_DIR="${SCRIPT_DIR}/.smoke-files"
MAX_FILE_BYTES=2097152
USER_FILE_QUOTA_BYTES=3145728
GLOBAL_FILE_QUOTA_BYTES=6291456
SERVER_PID=""
BIG_PAYLOAD="${SCRIPT_DIR}/.smoke-oversize-payload.json"
FILE1="${SCRIPT_DIR}/.smoke-file-1.bin"
FILE1_DL="${SCRIPT_DIR}/.smoke-file-1.download"
FILE_REAL="${SCRIPT_DIR}/.smoke-file-real.bin"
FILE_REAL_DL="${SCRIPT_DIR}/.smoke-file-real.download"
BIG1="${SCRIPT_DIR}/.smoke-file-big-1.bin"
MISMATCH1="${SCRIPT_DIR}/.smoke-file-mismatch-1.bin"
MISMATCH_BODY="${SCRIPT_DIR}/.smoke-mismatch-body.json"
RATE_BODY="${SCRIPT_DIR}/.smoke-rate-body.json"
RATE_HEADERS="${SCRIPT_DIR}/.smoke-rate-headers.txt"

cleanup() {
  stop_server
  rm -f "${DB}" "${DB}-journal" "${DB}-wal" "${DB}-shm"
  rm -f "${BIG_PAYLOAD}" "${FILE1}" "${FILE1_DL}" "${FILE_REAL}" "${FILE_REAL_DL}" "${BIG1}" \
    "${MISMATCH1}" "${MISMATCH_BODY}" "${RATE_BODY}" "${RATE_HEADERS}" "${SCRIPT_DIR}/.smoke-sync-seq.txt"
  rm -rf "${FILE_DIR}"
}
trap cleanup EXIT

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

start_server() {
  echo "==> 启动测试服务器 (PORT=${TEST_PORT})"
  PORT="${TEST_PORT}" FILE_DIR="${FILE_DIR}" MAX_FILE_BYTES="${MAX_FILE_BYTES}" \
    USER_FILE_QUOTA_BYTES="${USER_FILE_QUOTA_BYTES}" GLOBAL_FILE_QUOTA_BYTES="${GLOBAL_FILE_QUOTA_BYTES}" \
    AUTH_MAX_USER_REQUESTS=5 AUTH_MAX_IP_REQUESTS=6 AUTH_WINDOW_MS=2000 \
    CRASH_MAX_IP_REQUESTS=5 CRASH_MAX_USER_REQUESTS=3 CRASH_WINDOW_MS=60000 \
    node "${SCRIPT_DIR}/index.js" &
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
}

start_server

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

echo "==> 10. 文件上传（200KB 随机密文，元数据走 header）"
b64url() { node -e 'process.stdout.write(Buffer.from(process.argv[1], "utf8").toString("base64url"))' "$1"; }
B64_NAME=$(b64url "report.pdf")
B64_MIME=$(b64url "application/pdf")
B64_DEVICE=$(b64url "smoke-device")
B64_DEVICE_NAME=$(b64url "Smoke Mac")
B64_PLATFORM=$(b64url "macos")
B64_MARKER=$(b64url "FILE_MARKER_CIPHER")
FILE1_ID="smoke-history-file-1"
node -e 'require("fs").writeFileSync(process.argv[1], require("crypto").randomBytes(200 * 1024))' "${FILE1}"
FILE1_SIZE=$(wc -c < "${FILE1}" | tr -d ' ')
curl -fsS -X POST "${BASE}/file" -H "$AUTH" -H 'Content-Type: application/octet-stream' \
  -H "x-clipflow-history-id: ${FILE1_ID}" \
  -H "x-clipflow-hash: HASH_FILE_1" \
  -H "x-clipflow-file-name: ${B64_NAME}" \
  -H "x-clipflow-file-size: ${FILE1_SIZE}" \
  -H "x-clipflow-mime-type: ${B64_MIME}" \
  -H "x-clipflow-source-device: ${B64_DEVICE}" \
  -H "x-clipflow-source-device-name: ${B64_DEVICE_NAME}" \
  -H "x-clipflow-source-platform: ${B64_PLATFORM}" \
  -H "x-clipflow-timestamp: 1700000005000" \
  -H "x-clipflow-marker: ${B64_MARKER}" \
  --data-binary "@${FILE1}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.id!=="smoke-history-file-1"){console.error("FAIL file upload: "+s);process.exit(1)}
  console.log("    ok (id="+j.id+")");
})'

echo "==> 11. /api/clipboard：file 行返回元数据 + marker，history_id 一致"
curl -fsS "${BASE}/clipboard" -H "$AUTH" | FILE1_SIZE="${FILE1_SIZE}" node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const d=j.data;
  if(j.code!=="SUCCESS"||!d){console.error("FAIL clipboard: "+s);process.exit(1)}
  if(d.type!=="file"){console.error("FAIL clipboard type: "+d.type);process.exit(1)}
  if(d.file_name!=="report.pdf"){console.error("FAIL file_name: "+d.file_name);process.exit(1)}
  if(d.file_size!==Number(process.env.FILE1_SIZE)){console.error("FAIL file_size: "+d.file_size);process.exit(1)}
  if(d.mime_type!=="application/pdf"){console.error("FAIL mime_type: "+d.mime_type);process.exit(1)}
  if(!d.file_key){console.error("FAIL file_key missing");process.exit(1)}
  if(!d.content){console.error("FAIL marker content empty");process.exit(1)}
  if(d.history_id!=="smoke-history-file-1"){console.error("FAIL history_id: "+d.history_id);process.exit(1)}
  console.log("    ok");
})'

echo "==> 12. /api/history：file 行 content 为空、元数据与 hash 存在"
FILE1_KEY=$(curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | FILE1_SIZE="${FILE1_SIZE}" node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-file-1");
  if(!r){console.error("FAIL file history row missing");process.exit(1)}
  if(r.type!=="file"){console.error("FAIL type: "+r.type);process.exit(1)}
  if(r.content!==""){console.error("FAIL file content not stripped");process.exit(1)}
  if(r.file_name!=="report.pdf"||r.file_size!==Number(process.env.FILE1_SIZE)||r.mime_type!=="application/pdf"){console.error("FAIL file metadata");process.exit(1)}
  if(!r.file_key||!r.hash){console.error("FAIL file_key/hash missing");process.exit(1)}
  process.stdout.write(r.file_key);
})')
echo "    ok (file_key=${FILE1_KEY})"

echo "==> 13. /api/file/:id/content 与上传字节级一致"
curl -fsS "${BASE}/file/${FILE1_ID}/content" -H "$AUTH" -o "${FILE1_DL}"
if ! cmp -s "${FILE1}" "${FILE1_DL}"; then
  echo "FAIL: downloaded file differs" >&2
  exit 1
fi
echo "    ok (bytes=$(wc -c < "${FILE1_DL}" | tr -d ' '))"

echo "==> 14. 无 token 访问文件端点应 401"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/file/${FILE1_ID}/content")
if [ "$CODE" != "401" ]; then
  echo "FAIL: expect 401 got ${CODE}" >&2
  exit 1
fi
echo "    ok"

echo "==> 14b. 真实客户端形态：声明明文 204800 字节、发送密文 204830 字节应 200 且 file_size 记录明文"
REAL_ID="smoke-history-file-real-1"
node -e 'require("fs").writeFileSync(process.argv[1], require("crypto").randomBytes(204830))' "${FILE_REAL}"
REAL_DECLARED=204800
curl -fsS -X POST "${BASE}/file" -H "$AUTH" -H 'Content-Type: application/octet-stream' \
  -H "x-clipflow-history-id: ${REAL_ID}" \
  -H "x-clipflow-hash: HASH_FILE_REAL" \
  -H "x-clipflow-file-name: ${B64_NAME}" \
  -H "x-clipflow-file-size: ${REAL_DECLARED}" \
  -H "x-clipflow-mime-type: ${B64_MIME}" \
  -H "x-clipflow-source-device: ${B64_DEVICE}" \
  -H "x-clipflow-source-device-name: ${B64_DEVICE_NAME}" \
  -H "x-clipflow-source-platform: ${B64_PLATFORM}" \
  -H "x-clipflow-timestamp: 1700000005500" \
  -H "x-clipflow-marker: ${B64_MARKER}" \
  --data-binary "@${FILE_REAL}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.id!=="smoke-history-file-real-1"){console.error("FAIL real upload: "+s);process.exit(1)}
  console.log("    ok (id="+j.id+")");
})'
curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-file-real-1");
  if(!r){console.error("FAIL real history row missing");process.exit(1)}
  if(r.file_size!==204800){console.error("FAIL real file_size should be plaintext 204800, got "+r.file_size);process.exit(1)}
  console.log("    ok (file_size=204800 plaintext)");
})'
curl -fsS "${BASE}/file/${REAL_ID}/content" -H "$AUTH" -o "${FILE_REAL_DL}"
if ! cmp -s "${FILE_REAL}" "${FILE_REAL_DL}"; then
  echo "FAIL: real downloaded file differs" >&2
  exit 1
fi
echo "    ok (ciphertext byte-exact, bytes=$(wc -c < "${FILE_REAL_DL}" | tr -d ' '))"

echo "==> 15. 声明 file-size 超过 MAX_FILE_BYTES 应 413"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/file" -H "$AUTH" -H 'Content-Type: application/octet-stream' \
  -H "x-clipflow-history-id: smoke-history-file-oversize" \
  -H "x-clipflow-hash: HASH_FILE_OVERSIZE" \
  -H "x-clipflow-file-name: ${B64_NAME}" \
  -H "x-clipflow-file-size: 3145728" \
  -H "x-clipflow-mime-type: ${B64_MIME}" \
  -H "x-clipflow-marker: ${B64_MARKER}" \
  --data-binary "@${FILE1}" || true)
if [ "$CODE" != "413" ]; then
  echo "FAIL: expect 413 got ${CODE}" >&2
  exit 1
fi
echo "    ok"

echo "==> 15b. 声明 file-size 为 1 但实际发送 1.6MB：应 400 FILE_SIZE_MISMATCH，且不上库、不落盘"
node -e 'require("fs").writeFileSync(process.argv[1], Buffer.alloc(1600000, 9))' "${MISMATCH1}"
MISMATCH_CODE=$(curl -s -o "${MISMATCH_BODY}" -w '%{http_code}' -X POST "${BASE}/file" \
  -H "$AUTH" -H 'Content-Type: application/octet-stream' \
  -H "x-clipflow-history-id: smoke-history-file-mismatch-1" \
  -H "x-clipflow-hash: HASH_FILE_MISMATCH" \
  -H "x-clipflow-file-name: ${B64_NAME}" \
  -H "x-clipflow-file-size: 1" \
  -H "x-clipflow-mime-type: ${B64_MIME}" \
  -H "x-clipflow-marker: ${B64_MARKER}" \
  --data-binary "@${MISMATCH1}" || true)
if [ "$MISMATCH_CODE" != "400" ]; then
  echo "FAIL: expect 400 got ${MISMATCH_CODE}" >&2
  exit 1
fi
node -e '
const fs = require("fs");
const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (body.code !== "ERROR" || !String(body.message || "").includes("FILE_SIZE_MISMATCH")) {
  console.error("FAIL mismatch response: " + fs.readFileSync(process.argv[1], "utf8"));
  process.exit(1);
}
console.log("    ok (400 " + body.message + ")");
' "${MISMATCH_BODY}"
curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.data.records.some(x=>x.id==="smoke-history-file-mismatch-1")){console.error("FAIL mismatch row exists in history");process.exit(1)}
  console.log("    ok (no history row)");
})'
if [ -n "$(find "${FILE_DIR}" -name '*.part' -type f 2>/dev/null)" ]; then
  echo "FAIL: leftover .part after mismatch upload" >&2
  exit 1
fi
MISMATCH_DISK_COUNT=$(find "${FILE_DIR}/user_smoke_v13" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$MISMATCH_DISK_COUNT" != "2" ]; then
  echo "FAIL: expect the two existing referenced files on disk, got ${MISMATCH_DISK_COUNT}" >&2
  exit 1
fi
echo "    ok (no new file on disk, referenced files intact)"

echo "==> 16. 用户文件配额：连续上传两个 1.6MB 文件，第二个应 507"
BIG1_ID="smoke-history-file-big-1"
node -e 'require("fs").writeFileSync(process.argv[1], Buffer.alloc(1600000, 7))' "${BIG1}"
BIG1_SIZE=$(wc -c < "${BIG1}" | tr -d ' ')
curl -fsS -X POST "${BASE}/file" -H "$AUTH" -H 'Content-Type: application/octet-stream' \
  -H "x-clipflow-history-id: ${BIG1_ID}" \
  -H "x-clipflow-hash: HASH_FILE_BIG_1" \
  -H "x-clipflow-file-name: ${B64_NAME}" \
  -H "x-clipflow-file-size: ${BIG1_SIZE}" \
  -H "x-clipflow-mime-type: ${B64_MIME}" \
  -H "x-clipflow-source-device: ${B64_DEVICE}" \
  -H "x-clipflow-source-device-name: ${B64_DEVICE_NAME}" \
  -H "x-clipflow-source-platform: ${B64_PLATFORM}" \
  -H "x-clipflow-timestamp: 1700000006000" \
  -H "x-clipflow-marker: ${B64_MARKER}" \
  --data-binary "@${BIG1}" >/dev/null
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/file" -H "$AUTH" -H 'Content-Type: application/octet-stream' \
  -H "x-clipflow-history-id: smoke-history-file-big-2" \
  -H "x-clipflow-hash: HASH_FILE_BIG_2" \
  -H "x-clipflow-file-name: ${B64_NAME}" \
  -H "x-clipflow-file-size: ${BIG1_SIZE}" \
  -H "x-clipflow-mime-type: ${B64_MIME}" \
  -H "x-clipflow-source-device: ${B64_DEVICE}" \
  -H "x-clipflow-source-device-name: ${B64_DEVICE_NAME}" \
  -H "x-clipflow-source-platform: ${B64_PLATFORM}" \
  -H "x-clipflow-timestamp: 1700000007000" \
  -H "x-clipflow-marker: ${B64_MARKER}" \
  --data-binary "@${BIG1}" || true)
if [ "$CODE" != "507" ]; then
  echo "FAIL: expect 507 got ${CODE}" >&2
  exit 1
fi
BIG1_KEY=$(curl -fsS "${BASE}/history?limit=100" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const r=j.data.records.find(x=>x.id==="smoke-history-file-big-1");
  if(!r||!r.file_key){console.error("FAIL big1 file_key missing");process.exit(1)}
  process.stdout.write(r.file_key);
})')
echo "    ok (quota rejected, big1 key=${BIG1_KEY})"

echo "==> 17. 磁盘清理：删除 history 行后重启触发 prune"
stop_server
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const info = db.prepare("DELETE FROM history WHERE id = ?").run(process.argv[3]);
if (info.changes !== 1) {
  console.error("FAIL: history row not deleted");
  process.exit(1);
}
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${BIG1_ID}"
start_server
if [ -f "${FILE_DIR}/user_smoke_v13/${BIG1_KEY}" ]; then
  echo "FAIL: orphan file still on disk: ${BIG1_KEY}" >&2
  exit 1
fi
if [ ! -f "${FILE_DIR}/user_smoke_v13/${FILE1_KEY}" ]; then
  echo "FAIL: referenced file missing after prune" >&2
  exit 1
fi
echo "    ok (orphan removed, referenced file kept)"

echo "==> 18. 倾倒垃圾桶：软删 file 行 → DELETE /api/history/trash 清空记录并删除磁盘文件"
curl -fsS -X DELETE "${BASE}/history/${FILE1_ID}" -H "$AUTH" >/dev/null
curl -fsS -X DELETE "${BASE}/history/trash" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL trash delete: "+s);process.exit(1)}
  if(typeof j.deleted!=="number"||j.deleted<1){console.error("FAIL deleted count: "+s);process.exit(1)}
  console.log("    ok (deleted="+j.deleted+")");
})'
curl -fsS "${BASE}/history/trash" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const records=j.data&&j.data.records||[];
  if(j.code!=="SUCCESS"||records.length!==0){console.error("FAIL trash not empty after dump: "+s);process.exit(1)}
  console.log("    ok (trash empty)");
})'
if [ -f "${FILE_DIR}/user_smoke_v13/${FILE1_KEY}" ]; then
  echo "FAIL: trash file still on disk: ${FILE1_KEY}" >&2
  exit 1
fi
echo "    ok (disk file removed)"

echo "==> 19. userId 桶限流：同 XFF IP + 同 userId 连发 6 次，第 6 次 429 + Retry-After；窗口后恢复"
RATE_IP="203.0.113.10"
RATE_USER="user_smoke_rate_a"
ok=1
for i in $(seq 1 5); do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${RATE_IP}" -d "{\"userId\":\"${RATE_USER}\"}" || true)
  if [ "$CODE" != "200" ]; then
    echo "FAIL: rate attempt $i expect 200 got ${CODE}" >&2
    ok=0
    break
  fi
done
if [ "$ok" = "1" ]; then
  CODE=$(curl -sS -D "${RATE_HEADERS}" -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${RATE_IP}" -d "{\"userId\":\"${RATE_USER}\"}" || true)
  if [ "$CODE" != "429" ]; then
    echo "FAIL: rate attempt 6 expect 429 got ${CODE}" >&2
    ok=0
  elif ! grep -qi '^Retry-After:' "${RATE_HEADERS}"; then
    echo "FAIL: Retry-After header missing" >&2
    ok=0
  else
    node -e '
const fs = require("fs");
const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (body.code !== "RATE_LIMITED" || typeof body.retryAfterMs !== "number" || body.retryAfterMs < 1000) {
  console.error("FAIL rate body: " + fs.readFileSync(process.argv[1], "utf8"));
  process.exit(1);
}
console.log("    ok (429 RATE_LIMITED retryAfterMs=" + body.retryAfterMs + ")");
' "${RATE_BODY}"
  fi
fi
if [ "$ok" != "1" ]; then
  exit 1
fi
sleep 2.2
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${RATE_IP}" -d "{\"userId\":\"${RATE_USER}\"}" || true)
if [ "$CODE" != "200" ]; then
  echo "FAIL: rate limit should recover after window, got ${CODE}" >&2
  exit 1
fi
echo "    ok (window recovered -> 200)"

echo "==> 20. IP 桶限流：同 XFF IP 换 7 个 userId，第 7 次 429；独立 IP 不受影响"
RATE_IP2="203.0.113.20"
ok=1
for i in $(seq 1 6); do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${RATE_IP2}" -d "{\"userId\":\"user_smoke_rate_b_${i}\"}" || true)
  if [ "$CODE" != "200" ]; then
    echo "FAIL: ip attempt $i expect 200 got ${CODE}" >&2
    ok=0
    break
  fi
done
if [ "$ok" = "1" ]; then
  CODE=$(curl -sS -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${RATE_IP2}" -d '{"userId":"user_smoke_rate_b_7"}' || true)
  if [ "$CODE" != "429" ]; then
    echo "FAIL: ip attempt 7 expect 429 got ${CODE}" >&2
    ok=0
  else
    echo "    ok (429 via IP bucket)"
  fi
fi
if [ "$ok" != "1" ]; then
  exit 1
fi
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: 203.0.113.30" -d '{"userId":"user_smoke_rate_c"}' || true)
if [ "$CODE" != "200" ]; then
  echo "FAIL: independent IP should not be limited, got ${CODE}" >&2
  exit 1
fi
echo "    ok (independent IP not limited)"


echo "==> 21. 崩溃上报：带 token POST /api/crash -> 200 SUCCESS，直查库断言入库字段"
CRASH_IP_A="198.51.100.10"
curl -fsS -X POST "${BASE}/crash" -H "$AUTH" -H 'Content-Type: application/json' \
  -H "X-Forwarded-For: ${CRASH_IP_A}" \
  -d '{"exceptionType":"TestCrash","message":"boom","stack":"Test stack line 1\nline 2","platform":"macos","deviceModel":"MacBookPro18,3","appVersion":"1.5.0+1","deviceId":"smoke-device"}' \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"){console.error("FAIL crash upload: "+s);process.exit(1)}console.log("    ok (code=SUCCESS)")})'
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const rows = db.prepare("SELECT * FROM crash_reports WHERE exception_type = ? ORDER BY reported_at DESC LIMIT 1").all("TestCrash");
if (rows.length !== 1) { console.error("FAIL: no crash row"); process.exit(1); }
const r = rows[0];
if (r.user_id !== "user_smoke_v13") { console.error("FAIL user_id: " + r.user_id); process.exit(1); }
if (r.stack !== "Test stack line 1\nline 2") { console.error("FAIL stack: " + r.stack); process.exit(1); }
if (r.app_version !== "1.5.0+1") { console.error("FAIL app_version: " + r.app_version); process.exit(1); }
if (r.platform !== "macos") { console.error("FAIL platform: " + r.platform); process.exit(1); }
if (typeof r.reported_at !== "number" || r.reported_at <= 0) { console.error("FAIL reported_at: " + r.reported_at); process.exit(1); }
console.log("    ok (row: user_id/app_version/platform/stack/reported_at)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}"

echo "==> 22. 崩溃上报：匿名（无 token）-> 200，直查库断言 user_id IS NULL"
CRASH_IP_B="198.51.100.11"
curl -fsS -X POST "${BASE}/crash" -H 'Content-Type: application/json' \
  -H "X-Forwarded-For: ${CRASH_IP_B}" \
  -d '{"exceptionType":"AnonymousCrash","message":"anonymous","stack":"anon stack","platform":"android","deviceModel":"Xiaomi 15","appVersion":"1.5.0+1"}' \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"){console.error("FAIL anonymous crash: "+s);process.exit(1)}console.log("    ok (code=SUCCESS)")})'
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const rows = db.prepare("SELECT * FROM crash_reports WHERE exception_type = ? ORDER BY reported_at DESC LIMIT 1").all("AnonymousCrash");
if (rows.length !== 1) { console.error("FAIL: no anonymous crash row"); process.exit(1); }
if (rows[0].user_id !== null) { console.error("FAIL: expected user_id NULL, got " + rows[0].user_id); process.exit(1); }
console.log("    ok (user_id NULL)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}"

echo "==> 23. 崩溃上报：缺 stack -> 400"
CRASH_IP_C="198.51.100.12"
CODE=$(curl -sS -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/crash" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${CRASH_IP_C}" -d '{"exceptionType":"NoStack","message":"no stack"}' || true)
if [ "$CODE" != "400" ]; then
  echo "FAIL: missing stack expect 400 got ${CODE}" >&2
  exit 1
fi
node -e '
const fs = require("fs");
const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (body.code !== "ERROR") { console.error("FAIL missing stack body: " + fs.readFileSync(process.argv[1], "utf8")); process.exit(1); }
console.log("    ok (400 ERROR)");
' "${RATE_BODY}"

echo "==> 24. 崩溃上报 IP 桶限流：同 XFF IP 连发 6 次，第 6 次 429 + Retry-After"
CRASH_IP_RATE="198.51.100.99"
ok=1
for i in $(seq 1 5); do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/crash" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${CRASH_IP_RATE}" -d "{\"stack\":\"rate test ${i}\"}" || true)
  if [ "$CODE" != "200" ]; then
    echo "FAIL: crash ip attempt $i expect 200 got ${CODE}" >&2
    ok=0
    break
  fi
done
if [ "$ok" = "1" ]; then
  CODE=$(curl -sS -D "${RATE_HEADERS}" -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/crash" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${CRASH_IP_RATE}" -d '{"stack":"rate limit test"}' || true)
  if [ "$CODE" != "429" ]; then
    echo "FAIL: crash ip attempt 6 expect 429 got ${CODE}" >&2
    ok=0
  elif ! grep -qi '^Retry-After:' "${RATE_HEADERS}"; then
    echo "FAIL: Retry-After header missing on crash 429" >&2
    ok=0
  else
    echo "    ok (429 via crash IP bucket + Retry-After)"
  fi
fi
if [ "$ok" != "1" ]; then
  exit 1
fi

echo "==> 25. 崩溃上报 userId 桶限流：同 token 用户连发 4 次，第 4 次 429"
CRASH_USER_IP="198.51.100.50"
CRASH_USER="user_smoke_crash_bucket"
CRASH_USER_TOKEN=$(curl -fsS -X POST "${BASE}/auth" -H 'Content-Type: application/json' \
  -H "X-Forwarded-For: ${CRASH_USER_IP}" -d "{\"userId\":\"${CRASH_USER}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.token)})')
CRASH_USER_AUTH="Authorization: Bearer ${CRASH_USER_TOKEN}"
ok=1
for i in $(seq 1 3); do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/crash" -H "$CRASH_USER_AUTH" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${CRASH_USER_IP}" -d "{\"stack\":\"user bucket ${i}\"}" || true)
  if [ "$CODE" != "200" ]; then
    echo "FAIL: crash user attempt $i expect 200 got ${CODE}" >&2
    ok=0
    break
  fi
done
if [ "$ok" = "1" ]; then
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/crash" -H "$CRASH_USER_AUTH" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${CRASH_USER_IP}" -d '{"stack":"user bucket limit"}' || true)
  if [ "$CODE" != "429" ]; then
    echo "FAIL: crash user attempt 4 expect 429 got ${CODE}" >&2
    ok=0
  else
    echo "    ok (429 via crash userId bucket)"
  fi
fi
if [ "$ok" != "1" ]; then
  exit 1
fi


echo "==> 26. LAN 票据：取票 + 校验 + token deviceId 一致性"
LAN_IP_A="198.51.100.70"
LAN_IP_B="198.51.100.71"
LAN_IP_C="198.51.100.72"
LAN_USER="user_smoke_lan"
LAN_DEV_A="lan-smoke-device-a"
LAN_DEV_B="lan-smoke-device-b"
LAN_DEV_C="lan-smoke-device-c"
LAN_TOKEN_A=$(curl -fsS -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${LAN_IP_A}" -d "{\"userId\":\"${LAN_USER}\",\"deviceId\":\"${LAN_DEV_A}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.token)})')
LAN_AUTH_A="Authorization: Bearer ${LAN_TOKEN_A}"
# 注册设备 A
curl -fsS -X POST "${BASE}/device" -H "$LAN_AUTH_A" -H 'Content-Type: application/json' \
  -d "{\"id\":\"${LAN_DEV_A}\",\"name\":\"Lan Smoke A\",\"platform\":\"macos\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"){console.error("FAIL register device: "+s);process.exit(1)}})'
# 取票（带 token）→ 200 + ticket/expiresAtMs
curl -fsS -X POST "${BASE}/lan/ticket" -H "$LAN_AUTH_A" -H 'Content-Type: application/json' \
  -d "{\"deviceId\":\"${LAN_DEV_A}\"}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL lan ticket: "+s);process.exit(1)}
  const d=j.data;
  if(typeof d.ticket!=="string"||d.ticket.length<20){console.error("FAIL ticket missing: "+s);process.exit(1)}
  if(typeof d.expiresAtMs!=="number"||d.expiresAtMs<=Date.now()){console.error("FAIL expiresAtMs: "+s);process.exit(1)}
  console.log("    ok (ticket="+d.ticket.slice(0,16)+"..., expiresAtMs="+d.expiresAtMs+")");
})'
TICKET_A=$(curl -fsS -X POST "${BASE}/lan/ticket" -H "$LAN_AUTH_A" -H 'Content-Type: application/json' \
  -d "{\"deviceId\":\"${LAN_DEV_A}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.ticket)})')
# 校验 → 200 + userId/deviceId
curl -fsS -X POST "${BASE}/lan/ticket/verify" -H 'Content-Type: application/json' \
  -d "{\"ticket\":\"${TICKET_A}\"}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL lan verify: "+s);process.exit(1)}
  const d=j.data;
  if(d.userId!=="user_smoke_lan"){console.error("FAIL verify userId: "+JSON.stringify(d));process.exit(1)}
  if(d.deviceId!=="lan-smoke-device-a"){console.error("FAIL verify deviceId: "+JSON.stringify(d));process.exit(1)}
  console.log("    ok (userId="+d.userId+", deviceId="+d.deviceId+")");
})'
# token deviceId 一致性：body deviceId 与 token 绑定的 deviceId 不一致 → 400
LAN_MISMATCH_CODE=$(curl -sS -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/lan/ticket" -H "$LAN_AUTH_A" -H 'Content-Type: application/json' -d '{"deviceId":"some-other-device"}' || true)
if [ "$LAN_MISMATCH_CODE" != "400" ]; then
  echo "FAIL: lan ticket deviceId mismatch expect 400 got ${LAN_MISMATCH_CODE}" >&2
  exit 1
fi
node -e '
const fs=require("fs");
const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(b.code!=="ERROR"){console.error("FAIL mismatch body: "+fs.readFileSync(process.argv[1],"utf8"));process.exit(1)}
console.log("    ok (deviceId mismatch -> 400 ERROR)");
' "${RATE_BODY}"

echo "==> 27. LAN 票据：设备移除后取票/校验 403"
# 27a. 正常移除设备后，已签发票据校验 → 403（撤销实时生效）
LAN_TOKEN_B=$(curl -fsS -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${LAN_IP_B}" -d "{\"userId\":\"${LAN_USER}\",\"deviceId\":\"${LAN_DEV_B}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.token)})')
LAN_AUTH_B="Authorization: Bearer ${LAN_TOKEN_B}"
curl -fsS -X POST "${BASE}/device" -H "$LAN_AUTH_B" -H 'Content-Type: application/json' \
  -d "{\"id\":\"${LAN_DEV_B}\",\"name\":\"Lan Smoke B\",\"platform\":\"macos\"}" >/dev/null
TICKET_B=$(curl -fsS -X POST "${BASE}/lan/ticket" -H "$LAN_AUTH_B" -H 'Content-Type: application/json' \
  -d "{\"deviceId\":\"${LAN_DEV_B}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.ticket)})')
# 用设备 A 的 token 移除设备 B（移除后设备 B 的 token 全部删除）
curl -fsS -X DELETE "${BASE}/device/${LAN_DEV_B}" -H "$LAN_AUTH_A" >/dev/null
LAN_VERIFY_B_CODE=$(curl -sS -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/lan/ticket/verify" -H 'Content-Type: application/json' -d "{\"ticket\":\"${TICKET_B}\"}" || true)
if [ "$LAN_VERIFY_B_CODE" != "403" ]; then
  echo "FAIL: verify after removal expect 403 got ${LAN_VERIFY_B_CODE}" >&2
  exit 1
fi
echo "    ok (verify removed device ticket -> 403)"
# 27b. 模拟带外移除（直改 removed_at，token 仍有效）→ 取票 403
LAN_TOKEN_C=$(curl -fsS -X POST "${BASE}/auth" -H 'Content-Type: application/json' -H "X-Forwarded-For: ${LAN_IP_C}" -d "{\"userId\":\"${LAN_USER}\",\"deviceId\":\"${LAN_DEV_C}\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).data.token)})')
LAN_AUTH_C="Authorization: Bearer ${LAN_TOKEN_C}"
curl -fsS -X POST "${BASE}/device" -H "$LAN_AUTH_C" -H 'Content-Type: application/json' \
  -d "{\"id\":\"${LAN_DEV_C}\",\"name\":\"Lan Smoke C\",\"platform\":\"macos\"}" >/dev/null
node -e '
const Database=require(process.argv[1]);
const db=new Database(process.argv[2]);
const info=db.prepare("UPDATE devices SET removed_at = ? WHERE id = ?").run(Date.now(), process.argv[3]);
if(info.changes!==1){console.error("FAIL direct removal update");process.exit(1)}
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${LAN_DEV_C}"
LAN_TICKET_C_CODE=$(curl -sS -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/lan/ticket" -H "$LAN_AUTH_C" -H 'Content-Type: application/json' -d "{\"deviceId\":\"${LAN_DEV_C}\"}" || true)
if [ "$LAN_TICKET_C_CODE" != "403" ]; then
  echo "FAIL: ticket after removal expect 403 got ${LAN_TICKET_C_CODE}" >&2
  exit 1
fi
echo "    ok (ticket for removed device -> 403)"


echo "==> 28. sync/commit delete：op log + tombstone + deleted_at 置位；changes 游标返回；重复 commit 幂等；同 opId 换 entryId -> 409"
SYNC_DEL_ID="smoke-sync-del-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_DEL_CIPHER\",\"hash\":\"HASH_SYNC_DEL_1\",\"type\":\"text\",\"historyId\":\"${SYNC_DEL_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000008000}" \
  >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_DEL_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_DEL_ID}\"}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL commit delete: "+s);process.exit(1)}
  if(typeof j.data.seq!=="number"||j.data.seq<=0){console.error("FAIL seq: "+s);process.exit(1)}
  process.stdout.write(String(j.data.seq));
})' > "${SCRIPT_DIR}/.smoke-sync-seq.txt"
SYNC_DEL_SEQ=$(cat "${SCRIPT_DIR}/.smoke-sync-seq.txt")
echo "    ok (seq=${SYNC_DEL_SEQ})"
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const ops = db.prepare("SELECT * FROM sync_operations WHERE operation_id = ?").all(process.argv[3]);
if (ops.length !== 1) { console.error("FAIL: sync_operations rows = " + ops.length); process.exit(1); }
if (ops[0].kind !== "delete" || ops[0].entry_id !== "smoke-sync-del-1") { console.error("FAIL op fields: " + JSON.stringify(ops[0])); process.exit(1); }
const h = db.prepare("SELECT * FROM history WHERE id = ?").get("smoke-sync-del-1");
if (!h || typeof h.deleted_at !== "number") { console.error("FAIL: deleted_at not set"); process.exit(1); }
const t = db.prepare("SELECT * FROM sync_tombstones WHERE entry_id = ?").get("smoke-sync-del-1");
if (!t || !t.snapshot) { console.error("FAIL: tombstone snapshot missing"); process.exit(1); }
console.log("    ok (op log 1 row, deleted_at set, tombstone snapshot present)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "del:${SYNC_DEL_ID}"
curl -fsS "${BASE}/sync/changes?after=0" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL changes: "+s);process.exit(1)}
  const d=j.data;
  if(typeof d.cursor!=="number"||d.cursor<0){console.error("FAIL cursor: "+s);process.exit(1)}
  const ch=(d.changes||[]).find(c=>c.operationId==="del:smoke-sync-del-1");
  if(!ch){console.error("FAIL delete op missing in changes: "+s);process.exit(1)}
  if(ch.kind!=="delete"||ch.entryId!=="smoke-sync-del-1"){console.error("FAIL change fields: "+JSON.stringify(ch));process.exit(1)}
  console.log("    ok (changes has delete op, cursor="+d.cursor+", hasMore="+d.hasMore+")");
})'
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_DEL_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_DEL_ID}\"}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.data.duplicate!==true){console.error("FAIL duplicate flag: "+s);process.exit(1)}
  if(String(j.data.seq)!==process.argv[1]){console.error("FAIL duplicate seq mismatch: "+s);process.exit(1)}
  console.log("    ok (duplicate=true seq="+j.data.seq+")");
})' "${SYNC_DEL_SEQ}"
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const n = db.prepare("SELECT COUNT(*) AS n FROM sync_operations WHERE operation_id = ?").get(process.argv[3]).n;
if (n !== 1) { console.error("FAIL: duplicate committed second op row, count=" + n); process.exit(1); }
console.log("    ok (op log still 1 row after duplicate)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "del:${SYNC_DEL_ID}"
CODE=$(curl -sS -o "${RATE_BODY}" -w '%{http_code}' -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_DEL_ID}\",\"kind\":\"delete\",\"entryId\":\"other-id\"}" || true)
if [ "$CODE" != "409" ]; then
  echo "FAIL: same opId different entryId expect 409 got ${CODE}" >&2
  exit 1
fi
echo "    ok (same opId different entryId -> 409)"

echo "==> 29. sync/commit restore：行还在 → 现行恢复 + pinned 保留；changes 返回 restore op + row"
SYNC_REST_ID="smoke-sync-rest-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_REST_CIPHER\",\"hash\":\"HASH_SYNC_REST_1\",\"type\":\"text\",\"historyId\":\"${SYNC_REST_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000009000}" \
  >/dev/null
curl -fsS -X PATCH "${BASE}/history/${SYNC_REST_ID}" -H "$AUTH" -H 'Content-Type: application/json' -d '{"pinned":true}' >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_REST_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_REST_ID}\"}" >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"rest:${SYNC_REST_ID}\",\"kind\":\"restore\",\"entryId\":\"${SYNC_REST_ID}\"}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL commit restore: "+s);process.exit(1)}
  if(typeof j.data.seq!=="number"||j.data.seq<=0){console.error("FAIL restore seq: "+s);process.exit(1)}
  if(!j.data.row||j.data.row.id!=="smoke-sync-rest-1"){console.error("FAIL restore row missing: "+s);process.exit(1)}
  if(j.data.row.deleted_at!==null){console.error("FAIL restore row deleted_at: "+s);process.exit(1)}
  if(j.data.row.pinned!==1){console.error("FAIL restore row pinned lost: "+s);process.exit(1)}
  console.log("    ok (restore seq="+j.data.seq+", row.id="+j.data.row.id+", pinned="+j.data.row.pinned+")");
})'
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(process.argv[3]);
if (!h || h.deleted_at !== null) { console.error("FAIL: history not restored"); process.exit(1); }
if (typeof h.restored_at !== "number") { console.error("FAIL: restored_at not set"); process.exit(1); }
if (h.pinned !== 1) { console.error("FAIL: pinned not preserved"); process.exit(1); }
const t = db.prepare("SELECT * FROM sync_tombstones WHERE entry_id = ?").get(process.argv[3]);
if (!t || typeof t.restored_at !== "number") { console.error("FAIL: tombstone restored_at not set"); process.exit(1); }
console.log("    ok (history restored, deleted_at NULL, restored_at set, pinned=1, tombstone restored_at set)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_REST_ID}"
curl -fsS "${BASE}/sync/changes?after=0" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const ch=(j.data.changes||[]).find(c=>c.operationId==="rest:smoke-sync-rest-1");
  if(!ch){console.error("FAIL restore op missing in changes: "+s);process.exit(1)}
  if(ch.kind!=="restore"||!ch.row||ch.row.id!=="smoke-sync-rest-1"){console.error("FAIL restore change row: "+JSON.stringify(ch));process.exit(1)}
  console.log("    ok (changes has restore op with row)");
})'

echo "==> 30. 空 clipboard 可达：无最新 clipboard 行时 /api/sync/changes 仍返回 tombstone；物理删除后快照恢复"
SYNC_EMPTY_ID="smoke-sync-empty-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_EMPTY_CIPHER\",\"hash\":\"HASH_SYNC_EMPTY_1\",\"type\":\"text\",\"historyId\":\"${SYNC_EMPTY_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000010000}" \
  >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_EMPTY_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_EMPTY_ID}\"}" >/dev/null
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
db.prepare("DELETE FROM clipboard WHERE user_id = ?").run(process.argv[3]);
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "user_smoke_v13"
curl -fsS "${BASE}/sync/changes?after=0" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL empty-clipboard changes: "+s);process.exit(1)}
  const ch=(j.data.changes||[]).find(c=>c.operationId==="del:smoke-sync-empty-1");
  if(!ch){console.error("FAIL empty-clipboard tombstone missing: "+s);process.exit(1)}
  console.log("    ok (empty clipboard: tombstone still reachable via /api/sync/changes)");
})'
SYNC_PHYS_ID="smoke-sync-phys-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_PHYS_CIPHER\",\"hash\":\"HASH_SYNC_PHYS_1\",\"type\":\"text\",\"historyId\":\"${SYNC_PHYS_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000011000}" \
  >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_PHYS_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_PHYS_ID}\"}" >/dev/null
curl -fsS -X DELETE "${BASE}/history/trash" -H "$AUTH" >/dev/null
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(process.argv[3]);
if (h) { console.error("FAIL: history row should be physically deleted"); process.exit(1); }
console.log("    ok (row physically removed by trash)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_PHYS_ID}"
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"rest:${SYNC_PHYS_ID}\",\"kind\":\"restore\",\"entryId\":\"${SYNC_PHYS_ID}\"}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL snapshot restore: "+s);process.exit(1)}
  if(!j.data.row||j.data.row.id!=="smoke-sync-phys-1"){console.error("FAIL snapshot restore row: "+s);process.exit(1)}
  console.log("    ok (snapshot restore seq="+j.data.seq+")");
})'
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(process.argv[3]);
if (!h || h.deleted_at !== null || typeof h.restored_at !== "number") {
  console.error("FAIL: history not rebuilt from snapshot"); process.exit(1);
}
if (h.content !== "SYNC_PHYS_CIPHER") { console.error("FAIL: rebuilt content mismatch: " + h.content); process.exit(1); }
console.log("    ok (history rebuilt from snapshot, content preserved)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_PHYS_ID}"

echo "==> 31. 重启持久化：commit delete/restore 后重启，changes 仍返回"
SYNC_RST_ID="smoke-sync-rst-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_RST_CIPHER\",\"hash\":\"HASH_SYNC_RST_1\",\"type\":\"text\",\"historyId\":\"${SYNC_RST_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000012000}" \
  >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_RST_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_RST_ID}\"}" >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"rest:${SYNC_RST_ID}\",\"kind\":\"restore\",\"entryId\":\"${SYNC_RST_ID}\"}" >/dev/null
stop_server
start_server
curl -fsS "${BASE}/sync/changes?after=0" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL restart changes: "+s);process.exit(1)}
  const ids=(j.data.changes||[]).map(c=>c.operationId);
  if(!ids.includes("del:smoke-sync-rst-1")||!ids.includes("rest:smoke-sync-rst-1")){
    console.error("FAIL ops missing after restart: "+JSON.stringify(ids));process.exit(1);
  }
  console.log("    ok (ops persisted across restart)");
})'

echo "==> 32. changes 游标分页：after 续页、hasMore、limit 钳制"
CURSOR_A=$(curl -fsS "${BASE}/sync/changes?after=0&limit=2" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const d=j.data;
  if(d.changes.length>2){console.error("FAIL limit not honored: "+d.changes.length);process.exit(1)}
  process.stdout.write(String(d.cursor));
})')
echo "    ok (page1 cursor=${CURSOR_A}, hasMore expected)"
CURSOR_B=$(curl -fsS "${BASE}/sync/changes?after=${CURSOR_A}" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const d=j.data;
  if(d.changes.length===0){console.error("FAIL page2 empty (should have more ops)");process.exit(1)}
  const seqs=d.changes.map(c=>c.seq);
  for(const seq of seqs){if(seq<=Number(process.argv[1])){console.error("FAIL seq not > after: "+seq);process.exit(1)}}
  process.stdout.write(String(d.cursor));
})' "${CURSOR_A}")
echo "    ok (page2 cursor=${CURSOR_B})"
curl -fsS "${BASE}/sync/changes?after=${CURSOR_B}&limit=500" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const d=j.data;
  if(d.changes.length>100){console.error("FAIL limit clamp >100: "+d.changes.length);process.exit(1)}
  if(d.hasMore!==false){console.error("FAIL final page hasMore: "+s);process.exit(1)}
  console.log("    ok (limit clamped to 100, hasMore=false at tail)");
})'
curl -fsS "${BASE}/sync/changes?after=0&limit=0" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"){console.error("FAIL limit=0 tolerance: "+s);process.exit(1)}
  console.log("    ok (after=0/limit=0 tolerated)");
})'

echo "==> 33. GC：直改 DB 造 8 天前数据，重启后 pruneSyncState 清理 ops 与 tombstones"
SYNC_GC_ID="smoke-sync-gc-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_GC_CIPHER\",\"hash\":\"HASH_SYNC_GC_1\",\"type\":\"text\",\"historyId\":\"${SYNC_GC_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000013000}" \
  >/dev/null
curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"operationId\":\"del:${SYNC_GC_ID}\",\"kind\":\"delete\",\"entryId\":\"${SYNC_GC_ID}\"}" >/dev/null
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const eightDaysAgo = Date.now() - 8 * 24 * 60 * 60 * 1000;
db.prepare("UPDATE sync_operations SET created_at = ? WHERE entry_id = ?").run(eightDaysAgo, process.argv[3]);
db.prepare("UPDATE sync_tombstones SET deleted_at = ? WHERE entry_id = ?").run(eightDaysAgo, process.argv[3]);
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_GC_ID}"
stop_server
start_server
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const op = db.prepare("SELECT COUNT(*) AS n FROM sync_operations WHERE entry_id = ?").get(process.argv[3]).n;
const t = db.prepare("SELECT COUNT(*) AS n FROM sync_tombstones WHERE entry_id = ?").get(process.argv[3]).n;
if (op !== 0) { console.error("FAIL: old op not pruned, count=" + op); process.exit(1); }
if (t !== 0) { console.error("FAIL: old tombstone not pruned, count=" + t); process.exit(1); }
console.log("    ok (old op + tombstone pruned on startup)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_GC_ID}"
echo "==> 34. 删除→恢复→再删除周期：第二次删除/恢复必须产生新 op（新 seq）并置位 deleted_at，changes 下发；重复提交幂等保持"
SYNC_CYCLE_ID="smoke-sync-cycle-1"
curl -fsS -X POST "${BASE}/clipboard" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content\":\"SYNC_CYCLE_CIPHER\",\"hash\":\"HASH_SYNC_CYCLE_1\",\"type\":\"text\",\"historyId\":\"${SYNC_CYCLE_ID}\",\"sourceDevice\":\"smoke-device\",\"sourceDeviceName\":\"Smoke Mac\",\"sourcePlatform\":\"macos\",\"timestamp\":1700000014000}" \
  >/dev/null
commit_op() {
  # $1 = operationId, $2 = kind, $3 = entryId；输出 JSON data（含 seq/duplicate）
  curl -fsS -X POST "${BASE}/sync/commit" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"operationId\":\"$1\",\"kind\":\"$2\",\"entryId\":\"$3\"}"
}
# 第一轮：delete → restore
CYCLE_DEL1=$(commit_op "del:${SYNC_CYCLE_ID}" "delete" "${SYNC_CYCLE_ID}" | node -e 'let s="";process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"||typeof j.data.seq!=="number"){console.error("FAIL cycle del1: "+s);process.exit(1)}process.stdout.write(String(j.data.seq))})')
CYCLE_REST1=$(commit_op "rest:${SYNC_CYCLE_ID}" "restore" "${SYNC_CYCLE_ID}" | node -e 'let s="";process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"||typeof j.data.seq!=="number"){console.error("FAIL cycle rest1: "+s);process.exit(1)}process.stdout.write(String(j.data.seq))})')
# 第二次删除：必须产生新 op（新 seq），不得 duplicate
CYCLE_DEL2=$(commit_op "del:${SYNC_CYCLE_ID}" "delete" "${SYNC_CYCLE_ID}" | node -e 'let s="";process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"){console.error("FAIL cycle del2: "+s);process.exit(1)}if(j.data.duplicate===true){console.error("FAIL: second delete swallowed as duplicate: "+s);process.exit(1)}if(typeof j.data.seq!=="number"||j.data.seq<=Number(process.argv[1])){console.error("FAIL: second delete seq not new: "+s);process.exit(1)}process.stdout.write(String(j.data.seq))})' "${CYCLE_REST1}")
echo "    ok (del1=${CYCLE_DEL1} rest1=${CYCLE_REST1} del2=${CYCLE_DEL2}: new event, not duplicate)"
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const id = process.argv[3];
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(id);
if (!h || typeof h.deleted_at !== "number") { console.error("FAIL: deleted_at not set after second delete"); process.exit(1); }
const ops = db.prepare("SELECT operation_id, kind FROM sync_operations WHERE entry_id = ? ORDER BY seq").all(id);
const ids = ops.map(o => o.operation_id);
if (!ids.includes("del:" + id) || !ids.includes("rest:" + id) || !ids.includes("del:" + id + "#1")) {
  console.error("FAIL: op log missing cycle ops: " + JSON.stringify(ids)); process.exit(1);
}
if (ops.length !== 3) { console.error("FAIL: op log count = " + ops.length + ", expected 3"); process.exit(1); }
const t = db.prepare("SELECT * FROM sync_tombstones WHERE entry_id = ?").get(id);
if (!t || t.restored_at !== null) { console.error("FAIL: tombstone restored_at not reset to NULL after second delete"); process.exit(1); }
console.log("    ok (deleted_at set, op log = " + ids.join(",") + ", tombstone restored_at NULL)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_CYCLE_ID}"
curl -fsS "${BASE}/sync/changes?after=0" -H "$AUTH" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  const id=process.argv[1];
  const ch=(j.data.changes||[]).find(c=>c.operationId==="del:"+id+"#1");
  if(!ch){console.error("FAIL: second delete op missing in changes: "+s);process.exit(1)}
  if(ch.kind!=="delete"||ch.entryId!==id){console.error("FAIL: cycle delete change fields: "+JSON.stringify(ch));process.exit(1)}
  console.log("    ok (changes has del:"+id+"#1)");
})' "${SYNC_CYCLE_ID}"
# 幂等重放保持：重复提交 del:<id>#1（网络重试）→ duplicate:true，不产生新 op
commit_op "del:${SYNC_CYCLE_ID}#1" "delete" "${SYNC_CYCLE_ID}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.data.duplicate!==true){console.error("FAIL: retry of del:#1 should be duplicate: "+s);process.exit(1)}
  console.log("    ok (retry del:"+process.argv[1]+"#1 -> duplicate:true, idempotent)");
})' "${SYNC_CYCLE_ID}"
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const n = db.prepare("SELECT COUNT(*) AS n FROM sync_operations WHERE entry_id = ?").get(process.argv[3]).n;
if (n !== 3) { console.error("FAIL: retry added op row, count=" + n); process.exit(1); }
console.log("    ok (op log still 3 rows after retry)");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_CYCLE_ID}"
# 再恢复：必须产生新 op（新 seq），不得 duplicate；deleted_at 归 NULL
CYCLE_REST2=$(commit_op "rest:${SYNC_CYCLE_ID}" "restore" "${SYNC_CYCLE_ID}" | node -e 'let s="";process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"){console.error("FAIL cycle rest2: "+s);process.exit(1)}if(j.data.duplicate===true){console.error("FAIL: second restore swallowed as duplicate: "+s);process.exit(1)}if(typeof j.data.seq!=="number"||j.data.seq<=Number(process.argv[1])){console.error("FAIL: second restore seq not new: "+s);process.exit(1)}if(!j.data.row||j.data.row.deleted_at!==null){console.error("FAIL: second restore row deleted_at: "+s);process.exit(1)}process.stdout.write(String(j.data.seq))})' "${CYCLE_DEL2}")
echo "    ok (rest2=${CYCLE_REST2}: new event, not duplicate, row active)"
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const id = process.argv[3];
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(id);
if (!h || h.deleted_at !== null) { console.error("FAIL: deleted_at not NULL after second restore"); process.exit(1); }
const ids = db.prepare("SELECT operation_id FROM sync_operations WHERE entry_id = ?").all(id).map(r=>r.operation_id);
if (!ids.includes("rest:" + id + "#1")) { console.error("FAIL: rest:#1 op missing: " + JSON.stringify(ids)); process.exit(1); }
if (ids.length !== 4) { console.error("FAIL: op log count = " + ids.length + ", expected 4"); process.exit(1); }
console.log("    ok (deleted_at NULL after second restore, op log = " + ids.join(",") + ")");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_CYCLE_ID}"
# 多轮：第三次 delete（同 base opId）→ 继续生成新周期后缀 del:<id>#2
CYCLE_DEL3=$(commit_op "del:${SYNC_CYCLE_ID}" "delete" "${SYNC_CYCLE_ID}" | node -e 'let s="";process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{const j=JSON.parse(s);if(j.code!=="SUCCESS"||j.data.duplicate===true||typeof j.data.seq!=="number"){console.error("FAIL cycle del3: "+s);process.exit(1)}process.stdout.write(String(j.data.seq))})')
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const id = process.argv[3];
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(id);
if (!h || typeof h.deleted_at !== "number") { console.error("FAIL: deleted_at not set after third delete"); process.exit(1); }
const ids = db.prepare("SELECT operation_id FROM sync_operations WHERE entry_id = ?").all(id).map(r=>r.operation_id);
if (!ids.includes("del:" + id + "#2")) { console.error("FAIL: del:#2 op missing: " + JSON.stringify(ids)); process.exit(1); }
if (ids.length !== 5) { console.error("FAIL: op log count = " + ids.length + ", expected 5"); process.exit(1); }
console.log("    ok (del3=" + process.argv[4] + ": del:" + id + "#2 generated, deleted_at set, op log=" + ids.join(",") + ")");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_CYCLE_ID}" "${CYCLE_DEL3}"
# 第二轮恢复（rest base opId）→ 新事件 rest:<id>#2；deleted_at 归 NULL，闭环多轮收敛
CYCLE_REST3=$(commit_op "rest:${SYNC_CYCLE_ID}" "restore" "${SYNC_CYCLE_ID}" | node -e '
let s="";
process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{
  const j=JSON.parse(s);
  if(j.code!=="SUCCESS"||j.data.duplicate===true||typeof j.data.seq!=="number"){console.error("FAIL cycle rest3: "+s);process.exit(1)}
  if(!j.data.row||j.data.row.deleted_at!==null){console.error("FAIL cycle rest3 row: "+s);process.exit(1)}
  process.stdout.write(String(j.data.seq));
})')
node -e '
const Database = require(process.argv[1]);
const db = new Database(process.argv[2]);
const id = process.argv[3];
const h = db.prepare("SELECT * FROM history WHERE id = ?").get(id);
if (!h || h.deleted_at !== null) { console.error("FAIL: deleted_at not NULL after rest3"); process.exit(1); }
const ids = db.prepare("SELECT operation_id FROM sync_operations WHERE entry_id = ?").all(id).map(r=>r.operation_id);
if (!ids.includes("rest:" + id + "#2")) { console.error("FAIL: rest:#2 op missing: " + JSON.stringify(ids)); process.exit(1); }
if (ids.length !== 6) { console.error("FAIL: op log count = " + ids.length + ", expected 6"); process.exit(1); }
console.log("    ok (rest3=" + process.argv[4] + ": rest:" + id + "#2 generated, deleted_at NULL, multi-round converged, op log=" + ids.join(",") + ")");
db.close();
' "${SCRIPT_DIR}/node_modules/better-sqlite3" "${DB}" "${SYNC_CYCLE_ID}" "${CYCLE_REST3}"

echo "SMOKE TEST PASSED"
