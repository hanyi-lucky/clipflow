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
    "${MISMATCH1}" "${MISMATCH_BODY}" "${RATE_BODY}" "${RATE_HEADERS}"
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

echo "SMOKE TEST PASSED"
