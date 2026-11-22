// 在可写副本上应用 dsh-purge 的全部补丁，并汇总结果。
//
// 为什么需要它：iOS app bundle 里的 /opt/dsh/nodejs-project/node_modules
// 是只读的（write 返回 EPERM），purge_apply 的备份阶段就失败。
// rebuild.sh 把安装树镜像到 profile，并让插件的补丁引擎认这个副本；
// 这个脚本负责真正落补丁，可以脱离宿主进程单独跑。
//
// 用法：
//   node /home/dsh/.dsh/dsh-purge-shadow/apply.mjs
//   node /home/dsh/.dsh/dsh-purge-shadow/apply.mjs --verbose

import { pathToFileURL } from "node:url";
import path from "node:path";

const DSH_HOME = process.env.DSH_HOME || "/home/dsh/.dsh";
const CORE = path.join(
  DSH_HOME,
  "profiles/web/node_modules/dsh-purge-community/lib/core.js",
);

const verbose = process.argv.includes("--verbose");

// 正常落地的状态。disabled 是配置层主动关掉的补丁（#18/#19），
// 它按设计不写入文件，不是失败。
const OK = new Set(["applied", "already", "na", "skipped", "disabled"]);
// 已知无目标：目标包根本没安装（hooks 系列），或该版本没有那个文件。
// 这类不是失败，只是没有可打的地方，不该让脚本报错退出。
const NO_TARGET = new Set(["missing_file"]);

const core = await import(pathToFileURL(CORE).href);

const bases = core.enumeratePatchAiBases({ discover: false });
if (bases.length === 0) {
  console.error("没有可用的补丁目标根。先跑 rebuild.sh 建副本。");
  process.exit(1);
}

console.log("补丁目标根:");
for (const b of bases) console.log("  " + b);

for (const b of bases) {
  if (b.includes("/opt/")) {
    console.error("");
    console.error("目标根指向只读的宿主安装树，写入会失败。");
    console.error("多半是 core.js 的重定向被插件更新覆盖了，重跑 rebuild.sh。");
    process.exit(2);
  }
}

const started = Date.now();
const result = await core.applyPatchesAllHosts(core.ALL_PATCHES, { hosts: bases });
const rows = result.hosts.flatMap((h) => h.report);

const groups = new Map();
for (const r of rows) {
  const list = groups.get(r.status) || [];
  list.push(r);
  groups.set(r.status, list);
}

const okCount = rows.filter((r) => OK.has(r.status)).length;
const noTargetCount = rows.filter((r) => NO_TARGET.has(r.status)).length;
const badCount = rows.length - okCount - noTargetCount;

console.log("");
console.log(`共 ${rows.length} 项，用时 ${((Date.now() - started) / 1000).toFixed(1)}s`);
for (const [status, list] of [...groups].sort((a, b) => b[1].length - a[1].length)) {
  console.log(`  ${status.padEnd(13)} ${String(list.length).padStart(3)}  ${list.map((x) => "#" + x.patch_id).join(",")}`);
}

if (verbose) {
  console.log("");
  for (const [status, list] of groups) {
    if (OK.has(status) && status !== "applied") continue;
    console.log(`[${status}]`);
    for (const r of list) {
      const target = (r.path || "").replace(DSH_HOME + "/", "~/");
      console.log(`  #${r.patch_id} ${r.name} → ${target}${r.reason ? "  (" + r.reason + ")" : ""}`);
    }
  }
}

console.log("");
if (noTargetCount > 0) {
  console.log(`结果: ${okCount}/${rows.length} 正常，${noTargetCount} 项无目标（包未安装或文件不存在），${badCount} 项异常`);
} else {
  console.log(`结果: ${okCount}/${rows.length} 正常${badCount ? `，${badCount} 项异常` : ""}`);
}
process.exit(badCount > 0 ? 3 : 0);
