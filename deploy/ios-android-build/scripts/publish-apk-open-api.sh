#!/usr/bin/env bash
# ============================================================
# 通过开放接口（AK/SK 签名）上传安装包并发布到官网
#
# 支持 Android 官网直装 APK 与 Windows 官网直装安装包（.exe），两者共用同一套接口。
#
# 用法：
#   OPEN_API_BASE_URL=https://admin-api.example.com \
#   OPEN_API_AK=AKxxxxxxxx \
#   OPEN_API_SK=xxxxxxxx \
#   ./publish-apk-open-api.sh <安装包文件> <packageName> <appName> <versionName> <versionCode> [更新说明]
#
# 流程：
#   1) 计算安装包的 SHA256/MD5/大小
#   2) POST /api/open/v1/apk/upload   → 上传到 COS
#   3) POST /api/open/v1/apk/publish  → 登记 app_version（官网随即可见）
#   4) GET  /api/open/v1/apk/latest   → 自检发布结果
#
# 可选环境变量：
#   OPEN_API_UPDATE_TYPE  更新类型：1 普通更新（默认）、2 强制更新。
#                         自动化发布默认走普通更新；确需强制更新时再显式设为 2，
#                         或发布后在管理平台「APK 管理」中改更新类型。
#
# 依赖：curl、openssl、jq、sha256sum/md5sum（GitHub ubuntu-latest 自带）
# ============================================================
set -euo pipefail

PKG_FILE="${1:?缺少参数：安装包文件路径}"
PACKAGE_NAME="${2:?缺少参数：packageName}"
APP_NAME="${3:?缺少参数：appName}"
VERSION_NAME="${4:?缺少参数：versionName}"
VERSION_CODE="${5:?缺少参数：versionCode（数字版本号）}"
UPDATE_DESC="${6:-自动构建发布}"

: "${OPEN_API_BASE_URL:?未设置 OPEN_API_BASE_URL}"
: "${OPEN_API_AK:?未设置 OPEN_API_AK}"
: "${OPEN_API_SK:?未设置 OPEN_API_SK}"

# 去掉末尾斜杠，避免拼出 //api/open
API_BASE="${OPEN_API_BASE_URL%/}"

UPLOAD_PATH="/api/open/v1/apk/upload"
PUBLISH_PATH="/api/open/v1/apk/publish"
LATEST_PATH="/api/open/v1/apk/latest"

# 空 request body 的 SHA256（GET 请求使用）
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

log() { echo "[open-api] $*"; }
fail() { echo "[open-api][ERROR] $*" >&2; exit 1; }

command -v curl >/dev/null || fail "缺少 curl"
command -v openssl >/dev/null || fail "缺少 openssl"
command -v jq >/dev/null || fail "缺少 jq"

# 更新类型：默认普通更新（1），仅显式配置 OPEN_API_UPDATE_TYPE=2 时才为强制更新
UPDATE_TYPE="${OPEN_API_UPDATE_TYPE:-1}"
case "$UPDATE_TYPE" in
  1|2) ;;
  *) fail "OPEN_API_UPDATE_TYPE 只能是 1（普通更新）或 2（强制更新），当前为 '$UPDATE_TYPE'" ;;
esac

[ -f "$PKG_FILE" ] || fail "安装包文件不存在：$PKG_FILE"

PKG_SHA256=$(sha256sum "$PKG_FILE" | awk '{print $1}')
PKG_MD5=$(md5sum "$PKG_FILE" | awk '{print $1}')
PKG_SIZE=$(wc -c < "$PKG_FILE" | tr -d ' ')
log "安装包: $PKG_FILE (${PKG_SIZE} bytes, sha256=${PKG_SHA256})"

# ------------------------------------------------------------
# 签名并执行请求
#   sign_and_call <METHOD> <PATH> <QUERY> <CONTENT_SHA256> <额外 curl 参数...>
# 输出的响应体写入 $RESP_FILE，HTTP 状态码写入 stdout
# ------------------------------------------------------------
RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

# 规范化 query：按 & 拆分后字典序排序（与服务端 OpenApiSignUtils 一致）
canonical_query() {
  local raw="$1"
  if [ -z "$raw" ]; then
    printf ''
    return
  fi
  printf '%s' "$raw" | tr '&' '\n' | LC_ALL=C sort | paste -sd'&' -
}

sign_and_call() {
  local method="$1" path="$2" query="$3" content_sha="$4"
  shift 4

  local ts nonce sorted canonical signature
  ts=$(date +%s)
  nonce=$(openssl rand -hex 16)
  sorted=$(canonical_query "$query")
  # 注意：行数与 Java 端 String.join("\n", ...) 完全一致（末尾无换行）
  canonical=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    "$method" "$path" "$sorted" "$ts" "$nonce" "$content_sha")
  signature=$(printf '%s' "$canonical" | openssl dgst -sha256 -hmac "$OPEN_API_SK" -binary | openssl base64 -A)

  local url="${API_BASE}${path}"
  if [ -n "$query" ]; then
    url="${url}?${query}"
  fi

  curl -sS -o "$RESP_FILE" -w '%{http_code}' -X "$method" "$url" \
    -H "X-Access-Key: ${OPEN_API_AK}" \
    -H "X-Timestamp: ${ts}" \
    -H "X-Nonce: ${nonce}" \
    -H "X-Content-Sha256: ${content_sha}" \
    -H "X-Signature: ${signature}" \
    "$@"
}

print_response() {
  echo "----------------------------------------"
  cat "$RESP_FILE"
  echo ""
  echo "----------------------------------------"
}

# ------------------------------------------------------------
# 1) 上传安装包（不写死 Content-Type：apk/exe 均由服务端按扩展名识别）
# ------------------------------------------------------------
UPLOAD_QUERY="packageName=${PACKAGE_NAME}&versionCode=${VERSION_CODE}&versionName=${VERSION_NAME}"
log "上传安装包到开放接口..."
HTTP_CODE=$(sign_and_call "POST" "$UPLOAD_PATH" "$UPLOAD_QUERY" "$PKG_SHA256" \
  -F "file=@${PKG_FILE}")

if [ "$HTTP_CODE" != "200" ]; then
  print_response
  fail "上传失败（HTTP ${HTTP_CODE}）"
fi

FILE_URL=$(jq -r '.data.fileUrl' "$RESP_FILE")
if [ -z "$FILE_URL" ] || [ "$FILE_URL" = "null" ]; then
  print_response
  fail "上传响应缺少 fileUrl"
fi
log "上传成功：$FILE_URL"

# ------------------------------------------------------------
# 2) 发布版本（写入 app_version，官网随即可见）
# ------------------------------------------------------------
BODY_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE" "$BODY_FILE"' EXIT

jq -n \
  --arg appName "$APP_NAME" \
  --arg packageName "$PACKAGE_NAME" \
  --arg versionName "$VERSION_NAME" \
  --argjson versionCode "$VERSION_CODE" \
  --arg fileUrl "$FILE_URL" \
  --argjson fileSize "$PKG_SIZE" \
  --arg md5 "$PKG_MD5" \
  --arg sha256 "$PKG_SHA256" \
  --arg updateDesc "$UPDATE_DESC" \
  --argjson updateType "$UPDATE_TYPE" \
  '{appName:$appName, packageName:$packageName, versionName:$versionName,
    versionCode:$versionCode, fileUrl:$fileUrl, fileSize:$fileSize,
    md5:$md5, sha256:$sha256, updateDesc:$updateDesc,
    updateType:$updateType, minSdk:21, status:1}' > "$BODY_FILE"

BODY_SHA256=$(sha256sum "$BODY_FILE" | awk '{print $1}')
log "发布版本 ${VERSION_NAME} (${VERSION_CODE})，更新类型=${UPDATE_TYPE}（1 普通 / 2 强制）..."
HTTP_CODE=$(sign_and_call "POST" "$PUBLISH_PATH" "" "$BODY_SHA256" \
  -H "Content-Type: application/json" --data-binary "@${BODY_FILE}")

if [ "$HTTP_CODE" != "200" ]; then
  print_response
  fail "发布失败（HTTP ${HTTP_CODE}）"
fi
log "发布成功"
print_response

# ------------------------------------------------------------
# 3) 自检：查询官网当前最新版本
# ------------------------------------------------------------
LATEST_QUERY="packageName=${PACKAGE_NAME}"
log "校验官网最新版本..."
HTTP_CODE=$(sign_and_call "GET" "$LATEST_PATH" "$LATEST_QUERY" "$EMPTY_SHA256")

if [ "$HTTP_CODE" != "200" ]; then
  print_response
  fail "查询最新版本失败（HTTP ${HTTP_CODE}）"
fi

LATEST_CODE=$(jq -r '.data.versionCode' "$RESP_FILE")
if [ "$LATEST_CODE" != "$VERSION_CODE" ]; then
  print_response
  fail "发布结果校验失败：官网最新 versionCode=${LATEST_CODE}，期望 ${VERSION_CODE}"
fi

log "✅ 完成：官网最新版本 ${VERSION_NAME} (${VERSION_CODE}) 已生效（官网最新版本接口有 60 秒缓存）"
