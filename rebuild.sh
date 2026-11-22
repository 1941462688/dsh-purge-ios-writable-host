#!/bin/bash
# 重建 dsh-purge 的可写补丁宿主。
#
# 背景：iOS 把 app bundle 里的 @deepseek-ai 目录挂成只读（write 返回 EPERM），
# 补丁写不进去。DSH 的 module-redirects 有一个行为——profile 里装的同名包
# 优先于引擎目录。于是把整棵依赖树镜像到 profile，让引擎读副本。
#
# 什么时候需要重跑：
#   1. dsh-purge 插件更新后（会覆盖 core.js 里的两处重定向）
#   2. profile 执行过 pnpm install --force / node_modules 被清
#   3. 补丁状态面板突然回到「大量 pending」
#
# 幂等：重复跑安全，已存在的副本不会重复复制，已注入的重定向不会重复注入。
#
# 用法：
#   bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh
#   bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh --check   # 只检查，不改动

set -u

DSH_HOME="${DSH_HOME:-/home/dsh/.dsh}"
PROFILE="$DSH_HOME/profiles/web"
ENGINE="/opt/dsh/nodejs-project/node_modules"
SHADOW="$PROFILE/node_modules"
PLUGIN="$SHADOW/dsh-purge-community/lib/core.js"
INDEXJS="$SHADOW/dsh-purge-community/lib/index.js"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say() { printf '%s\n' "$*"; }
fail() { printf '失败: %s\n' "$*" >&2; exit 1; }

say "== 1. 检查环境 =="
[ -d "$ENGINE/@deepseek-ai" ] || fail "找不到引擎依赖树 $ENGINE/@deepseek-ai"
[ -f "$PLUGIN" ] || fail "找不到插件 $PLUGIN（dsh-purge-community 没装？）"
say "  引擎: $ENGINE"
say "  副本: $SHADOW"
say "  插件: $PLUGIN"

# 只读性断言：宿主必须写不进去，否则根本不需要这套办法
if touch "$ENGINE/@deepseek-ai/.probe.$$" 2>/dev/null; then
  rm -f "$ENGINE/@deepseek-ai/.probe.$$"
  say "  注意: 宿主安装树可写，其实可以直接 purge_apply，不必用副本"
fi

say ""
say "== 2. 检查 core.js 重定向 =="
if grep -q 'findAiBaseFromDshHome(findDshHome())' "$PLUGIN" 2>/dev/null; then
  REDIRECT_N=$(grep -c 'findAiBaseFromDshHome(findDshHome())' "$PLUGIN")
  say "  已注入 ($REDIRECT_N 处)"
  NEED_PATCH=0
else
  say "  未注入 → 需要补"
  NEED_PATCH=1
fi

say ""
say "== 3. 检查副本完整性 =="
MISSING=0
if [ -d "$ENGINE/@deepseek-ai" ]; then
  TOTAL=$(ls -1 "$ENGINE/@deepseek-ai" | wc -l | tr -d ' ')
  HAVE=$(ls -1 "$SHADOW/@deepseek-ai" 2>/dev/null | wc -l | tr -d ' ')
  say "  @deepseek-ai  $HAVE/$TOTAL"
  [ "$HAVE" -lt "$TOTAL" ] && MISSING=1
fi
for scope in "@earendil-works"; do
  if [ -d "$ENGINE/$scope" ]; then
    TOTAL=$(ls -1 "$ENGINE/$scope" | wc -l | tr -d ' ')
    HAVE=$(ls -1 "$SHADOW/$scope" 2>/dev/null | wc -l | tr -d ' ')
    say "  $scope  $HAVE/$TOTAL"
    [ "$HAVE" -lt "$TOTAL" ] && MISSING=1
  fi
done

if [ "$CHECK_ONLY" = "1" ]; then
  say ""
  say "== 检查结果 =="
  say "  重定向: $([ "$NEED_PATCH" = "0" ] && echo 正常 || echo 缺失)"
  say "  副本:   $([ "$MISSING" = "0" ] && echo 完整 || echo 不完整)"
  if [ -f "$INDEXJS" ] && grep -q '^function patchHost' "$INDEXJS"; then
    say "  面板根: 正常"
  else
    say "  面板根: 缺失（面板会报另一套数字）"
  fi
  [ "$NEED_PATCH" = "0" ] && [ "$MISSING" = "0" ] && grep -q '^function patchHost' "$INDEXJS" 2>/dev/null && exit 0 || exit 1
fi

say ""
say "== 4. 备份 core.js =="
STAMP=$(date +%Y%m%d-%H%M%S)
if [ "$NEED_PATCH" = "1" ]; then
  cp -p "$PLUGIN" "$PLUGIN.bak-shadow-$STAMP" || fail "备份 core.js 失败"
  say "  已备份: $PLUGIN.bak-shadow-$STAMP"
else
  say "  跳过（无需改动）"
fi

say ""
say "== 5. 注入重定向 =="
if [ "$NEED_PATCH" = "1" ]; then
  node - "$PLUGIN" <<'NODE' || fail "注入 core.js 失败"
const fs = require("node:fs");
const file = process.argv[2];
let src = fs.readFileSync(file, "utf8");

const SHADOW_COMMENT = "// [local] iOS app bundle";
const FIND_BASE_NEEDLE = `export function findAiBase() {
  return remember("ai", () => {
    if (adapterFor(detectSurface()) === "desktop") return findAiBaseDesktop();
    return findAiBaseWeb();
  });
}`;
const FIND_BASE_PATCHED = `export function findAiBase() {
  return remember("ai", () => {
    if (adapterFor(detectSurface()) === "desktop") return findAiBaseDesktop();
    ${SHADOW_COMMENT} 的 @deepseek-ai 是只读的（EPERM），补丁写不进去。
    // 可写副本放在 $DSH_HOME/profiles/<name>/node_modules/@deepseek-ai，优先用它。
    try {
      const shadow = findAiBaseFromDshHome(findDshHome());
      if (shadow && isAiBase(shadow)) return shadow;
    } catch { /* 副本不可用时退回宿主安装树 */ }
    return findAiBaseWeb();
  });
}`;

const ENUM_NEEDLE = `  const selected = resolveInstance();
  if (selected.host || process.env.DSH_BASE || process.env.PURGE_DSH_CLI) {
    add(selected.host);
    return out;
  }`;
const ENUM_PATCHED = `  ${SHADOW_COMMENT} 只读宿主不可写时，改打可写副本；副本优先于 process-entry 判定。
  try {
    const shadow = findAiBaseFromDshHome(findDshHome());
    if (shadow && isAiBase(shadow)) {
      add(shadow);
      return out;
    }
  } catch { /* 副本不可用 → 走原有解析 */ }
  const selected = resolveInstance();
  if (selected.host || process.env.DSH_BASE || process.env.PURGE_DSH_CLI) {
    add(selected.host);
    return out;
  }`;

let hits = 0;
if (src.includes(FIND_BASE_NEEDLE)) { src = src.replace(FIND_BASE_NEEDLE, FIND_BASE_PATCHED); hits++; }
if (src.includes(ENUM_NEEDLE)) { src = src.replace(ENUM_NEEDLE, ENUM_PATCHED); hits++; }
if (hits === 0) { console.error("两个锚点都没命中，插件版本可能变了"); process.exit(1); }
if (hits < 2) { console.error("只命中 " + hits + " 处，另一处锚点已变，需人工核对"); process.exit(1); }
fs.writeFileSync(file, src);
console.log("  已注入 " + hits + " 处");
NODE
else
  say "  跳过（已存在）"
fi

say ""
say "== 5b. 注入面板目标根 =="
# 只有 core.js 的重定向还不够：面板/诊断/自检三个 HTTP 端点直接问
# resolveInstance()，拿到的是 process-entry 指向的只读 /opt，
# 于是出现「工具报 64/69、面板报 8/76」两套数字。这里统一改走 patchHost()。
if grep -q '^function patchHost' "$INDEXJS" 2>/dev/null; then
  say "  已注入"
else
  if [ ! -f "$INDEXJS" ]; then
    say "  跳过（找不到 $INDEXJS）"
  elif [ "$CHECK_ONLY" != "1" ]; then
    cp -p "$INDEXJS" "$INDEXJS.bak-shadow-$STAMP" || fail "备份 index.js 失败"
    node - "$INDEXJS" <<'NODE' || fail "注入 index.js 失败"
const fs = require("node:fs");
const f = process.argv[2];
let s = fs.readFileSync(f, "utf8");
if (/^function patchHost/m.test(s)) { console.log("  已存在"); process.exit(0); }
// 必须是模块顶层函数：apply() 与 installWebServer() 是两个独立作用域，
// 状态/诊断/自检/维护四条路径都在后者，函数内的定义够不到。
const ANCHOR = "export function apply(ctx, config) {";
if (!s.includes(ANCHOR)) { console.error("  锚点未命中"); process.exit(1); }
const HELPER = `/**
 * [local] 补丁目标根：优先 profile 里的可写副本。
 *
 * iOS app bundle 里的安装树是只读的（写入返回 EPERM），补丁写不进去，
 * 所以镜像一份到 $DSH_HOME/profiles/<name>/node_modules 再打。
 */
function patchHost() {
  try {
    const shadow = core.findAiBase();
    if (shadow) return shadow;
  } catch { /* 副本不可用 → 退回 process-entry */ }
  return resolveInstance().host;
}

` + ANCHOR;
s = s.replace(ANCHOR, HELPER);
let n = 0;
const t1 = "const target = resolveInstance().host;";
while (s.includes(t1)) { s = s.replace(t1, "const target = patchHost();"); n++; }
const t2 = "selfCheck(resolveInstance().host,";
while (s.includes(t2)) { s = s.replace(t2, "selfCheck(patchHost(),"); n++; }
const t3 = "aiBase: currentHost()";
while (s.includes(t3)) { s = s.replace(t3, "aiBase: patchHost()"); n++; }
fs.writeFileSync(f, s);
console.log("  已注入 helper + 改掉 " + n + " 处调用");
NODE
  else
    say "  缺失（--check 模式不改动）"
  fi
fi

say ""
say "== 6. 同步副本 =="
n=0
fail_n=0
# 只镜像补丁真正会碰到的 scope。整棵 node_modules 里有 @babel / @aws / @mongodb-js
# 这些与补丁无关的依赖，全量复制会多占几百 MB，没有任何收益。
for scope in "@deepseek-ai" "@earendil-works"; do
  [ -d "$ENGINE/$scope" ] || continue
  mkdir -p "$SHADOW/$scope"
  for p in $(ls -1 "$ENGINE/$scope" 2>/dev/null); do
    [ -d "$SHADOW/$scope/$p" ] && continue
    if cp -R "$ENGINE/$scope/$p" "$SHADOW/$scope/$p" 2>/dev/null; then
      n=$((n + 1))
    else
      fail_n=$((fail_n + 1))
    fi
  done
done
say "  新复制 $n 个包"$([ "$fail_n" -gt 0 ] && echo "，$fail_n 个失败")
say "  占用 $(du -sh "$SHADOW" 2>/dev/null | cut -f1)"

say ""
say "== 7. 应用补丁 =="
node "$SELF_DIR/apply.mjs"
RC=$?

say ""
say "== 完成 =="
if [ "$RC" = "0" ]; then
  say "补丁已就位。重启 DSH 生效："
  say "  - 面板应显示 插件根 = $SHADOW/@deepseek-ai"
  say "  - 补丁状态应为 64/69 applied, 0 pending"
else
  say "有补丁未命中（退出码 $RC），用 --verbose 看详情："
  say "  node $SELF_DIR/apply.mjs --verbose"
fi
exit "$RC"
