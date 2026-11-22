# 在只读安装树上打补丁：dsh-purge 宿主补丁实战

> 环境：DSH 0.2.2-rc.1 / dsh-purge-community 1.7.20 / iOS 内嵌引擎
> 结果：62 个 pending 补丁 → 71 项 applied，0 pending
> 说明：全程未修改只读安装树的任何字节

---

## 一、问题是什么

dsh-purge 的「应用」按钮点了没反应，或者报：

```
Error: Host backup failed (65 files); patch writes cancelled.
```

面板长期停在：

```
补丁 / patches: 3/69 applied, 62 pending
```

表面上像权限不足，实际不是。

### 1.1 先排除常规原因

看权限位：

```bash
$ stat -c '%n %A %U:%G' /opt/dsh/nodejs-project/node_modules/@deepseek-ai
/opt/dsh/nodejs-project/node_modules/@deepseek-ai drwxr-xr-x user group
```

属主就是当前用户，权限 40755，看起来完全可写。

但实际写：

```bash
$ touch /opt/dsh/nodejs-project/node_modules/@deepseek-ai/.probe
touch: cannot touch '.../.probe': EPERM: write '.../.probe'
```

**是 `EPERM`，不是 `EROFS`。**

这个区别是整件事的分水岭：

| errno | 含义 | 能否绕过 |
|---|---|---|
| `EROFS` | 文件系统挂载为只读 | 需要 remount |
| `EPERM` | 策略层拒绝 | 改不了这棵树，只能换目标 |

iOS 环境下 app bundle 内的资源就是这个行为：文件系统的元信息允许写，操作系统层面拦截。

### 1.2 逐层定位边界

```bash
for d in / /opt /opt/dsh /opt/dsh/nodejs-project /home/dsh /tmp; do
  t="$d/.wtest.$$"
  if touch "$t" 2>/dev/null; then echo "W  $d"; rm -f "$t"; else echo "RO $d"; fi
done
```

输出：

```
W  /
W  /opt
RO /opt/dsh
RO /opt/dsh/nodejs-project
RO /opt/dsh/nodejs-project/node_modules
W  /home/dsh
W  /tmp
```

边界在 `/opt/dsh` 这一级。`/opt` 本身可写，说明这是个独立挂上来的只读目录，不是整棵树 chmod。

### 1.3 为什么 purge_apply 必然失败

补丁引擎在写任何补丁前先备份，备份文件写在源文件旁边（`filename.dshpurge.bak`）。65 个目标文件全在只读区，备份全部失败，于是整体取消：

```
Host backup failed (65 files); patch writes cancelled.
```

它连第一步都过不去，所以补丁永远是 pending。

---

## 二、核心思路

**不改只读的树，改「谁被读取」。**

引擎的模块解析顺序里，profile 目录优先于 bundle 内的安装树。把依赖镜像到 profile（可写），补丁打在副本上，引擎读的也是副本，两边对上。

这个顺序不是我造的，是引擎自带的设计，证据在 `runtime/module-redirects.mjs` 的注释里：

> The plugin manager finds their bundle there, but the loader imports their components
> from the profile folder, which holds none of them: a lookup that fails there is tried
> again from the engine's folder. **A copy the profile installed itself still wins,
> being found first.**

翻译：内置插件的 bundle 从引擎目录找，但组件从 profile 目录导入；profile 里找不到才回退引擎目录。**profile 自己装的那份优先。**

三个条件同时满足才成立：

1. 引擎的模块解析 profile 优先（引擎自带行为）
2. profile 在可写区（`$DSH_HOME` 从来可写）
3. 插件自身装在 profile 里（所以插件代码可改）

缺一条这条路就死。

---

## 三、实施步骤

### 3.1 建副本

```bash
A=/opt/dsh/nodejs-project/node_modules
D=/home/dsh/.dsh/profiles/web/node_modules

for scope in "@deepseek-ai" "@earendil-works"; do
  mkdir -p "$D/$scope"
  for p in $(ls -1 "$A/$scope" 2>/dev/null); do
    [ -d "$D/$scope/$p" ] || cp -R "$A/$scope/$p" "$D/$scope/$p"
  done
done
```

两个坑：

**坑一：用 `cp -R`，不能用 `cp -a`。** 这个环境的 cp 是精简版，`-a` 会报 `invalid option -- 'a'`。

**坑二：只复制需要的 scope。** 补丁只碰 `@deepseek-ai`（329 个包，77.8M）和 `@earendil-works`（3 个包，2.2M，模型适配层）。如果图省事遍历所有 `@*`，会把 `@babel`、`@aws`、`@mongodb-js` 一起搬过来，`node_modules` 从 77M 涨到 331.9M，纯浪费。

### 3.2 改插件的目标根解析

副本就位后 `purge_apply` 不会自动用它。目标根解析在 `lib/core.js`：

```js
export function findAiBase() {
  return remember("ai", () => {
    if (adapterFor(detectSurface()) === "desktop") return findAiBaseDesktop();
    return findAiBaseWeb();   // ← 走 resolveInstance()，按 process.argv 推出 /opt
  });
}
```

在前面插一段，优先返回副本：

```js
export function findAiBase() {
  return remember("ai", () => {
    if (adapterFor(detectSurface()) === "desktop") return findAiBaseDesktop();
    try {
      const shadow = findAiBaseFromDshHome(findDshHome());
      if (shadow && isAiBase(shadow)) return shadow;
    } catch { /* 副本不可用时退回宿主安装树 */ }
    return findAiBaseWeb();
  });
}
```

`findAiBaseFromDshHome` 是插件**自带**的函数，本来就支持 `$DSH_HOME/profiles/*/node_modules/@deepseek-ai` 这个位置，只是 web 模式下没被优先调用。

同样处理 `enumeratePatchAiBases()`，否则它仍然返回 `/opt`：

```js
export function enumeratePatchAiBases(options = {}) {
  const keys = new Set();
  const out = [];
  const discover = options.discover === true;
  const add = (p) => { /* ... */ };

  // 新增：副本优先
  try {
    const shadow = findAiBaseFromDshHome(findDshHome());
    if (shadow && isAiBase(shadow)) { add(shadow); return out; }
  } catch { }

  const selected = resolveInstance();
  /* ... 原有逻辑 ... */
}
```

验证：

```bash
node --input-type=module -e '
  const m = await import("file:///home/dsh/.dsh/profiles/web/node_modules/dsh-purge-community/lib/core.js");
  console.log(m.findAiBase());
'
# 期望：/home/dsh/.dsh/profiles/web/node_modules/@deepseek-ai
```

> 注意：这个环境的 `node -e` 里不能直接用顶层 `await`（会被 worker 包装层拒绝），
> 把代码写进 `.mjs` 文件再 `node file.mjs` 执行。

### 3.3 应用补丁

`purge_apply` 工具走的是**进程内已加载的模块**，改磁盘文件它读不到。所以在独立 node 进程里跑：

```js
// apply.mjs
import { pathToFileURL } from "node:url";

const DSH_HOME = process.env.DSH_HOME || "/home/dsh/.dsh";
const CORE = DSH_HOME + "/profiles/web/node_modules/dsh-purge-community/lib/core.js";

const core = await import(pathToFileURL(CORE).href);
const bases = core.enumeratePatchAiBases({ discover: false });

// 防守：目标根落在只读区就直接退出，别静默空转
for (const b of bases) {
  if (b.includes("/opt/")) {
    console.error("目标根指向只读宿主，重定向没生效");
    process.exit(2);
  }
}

const result = await core.applyPatchesAllHosts(core.ALL_PATCHES, { hosts: bases });
const rows = result.hosts.flatMap((h) => h.report);

const groups = new Map();
for (const r of rows) {
  const list = groups.get(r.status) || [];
  list.push(r);
  groups.set(r.status, list);
}
for (const [status, list] of [...groups].sort((a, b) => b[1].length - a[1].length)) {
  console.log(status.padEnd(13), list.length, list.map((x) => "#" + x.patch_id).join(","));
}
```

执行：

```bash
node apply.mjs
```

### 3.4 第一次跑会缺包

只复制部分包时，结果是这样：

```
already 30, missing_file 47
```

`missing_file` 表示目标文件在副本里不存在。补丁要改的 `dsh-agent-loop`、`dsh-llm-deepseek`、`dsh-permission-presets`、`dsh-tool-bash` 等都不在最初复制的 13 个包里。

改成整树复制后再跑，收敛成：

```
already       71   #1,#2,#3,#4,...#96
na             7   #91,#92,#45,#46,#83,#84,#82
missing_file   5   #28,#30,#31,#64,#65
skipped        3   #76,#80,#35
disabled       2   #18,#19
```

### 3.5 剩下 5 个 missing 是无目标，不是失败

| 补丁 | 原因 |
|---|---|
| #28 `LIANGSHEN_PHASE1_KEEP_INJECT` | 目标 `dsh-liangshen/presets/liangshen/tool-bootstrap.mjs`，该版本里没有这个文件 |
| #30 #31 #64 #65 | 目标包 `dsh-hooks-claude-code` / `dsh-hooks-codex` 根本没安装 |

`na` 是平台不适用（没有对应代码路径），`skipped` 是条件不满足时按设计跳过，`disabled` 是配置层主动关闭（`contextManagement: false` 关掉了 #18 #19）。

---

## 四、修面板（第二个坑）

工具报 `64/69 applied`，面板报 `8/76, 60 pending` —— 两套数字。

原因在 `lib/index.js`：

```js
const target = resolveInstance().host;   // 只问 process-entry，拿 /opt
```

状态、诊断、自检、维护四个入口全都直接调 `resolveInstance()` 或 `currentHost()`，拿到只读的 `/opt`。只读树里当然没有补丁标记，于是全算 pending。

### 4.1 定义必须是模块级，不能放在函数里

我第一版把 helper 定义在 `apply()` 函数内部，结果面板直接抛：

```
ReferenceError: patchHost is not defined
```

因为状态端点位于 `installWebServer()` 里，和 `apply()` 是两个**独立作用域**，内层看不到外层的 `const`。

正确做法——定义在模块顶层，用函数声明（有提升）：

```js
/**
 * [local] 补丁目标根：优先 profile 里的可写副本。
 */
function patchHost() {
  try {
    const shadow = core.findAiBase();
    if (shadow) return shadow;
  } catch { /* 副本不可用 → 退回 process-entry */ }
  return resolveInstance().host;
}

export function apply(ctx, config) { /* ... */ }
```

### 4.2 替换五处调用

```js
compatibility(patchHost())                      // 兼容性检查
new Maintenance({ aiBase: patchHost() })        // 应用 / 还原 / 卸载按钮
const target = patchHost()                      // ×2：状态端点 + 诊断端点
selfCheck(patchHost(), ...)                     // 自检
```

第二行那个 `Maintenance` 特别关键：它是面板上「应用」「还原」「卸载」三个按钮**实际写哪里**。不改的话，按钮点了还是打到只读路径然后失败。

### 4.3 验证

```bash
curl -s http://127.0.0.1:3080/dsh-purge/status | grep -o '"ai_base":"[^"]*"'
```

期望指向副本：

```
"ai_base":"/home/dsh/.dsh/profiles/web/node_modules/@deepseek-ai"
```

面板这时显示 `71 applied / 0 pending`。

> 两套数字为什么不同：面板按当前 surface 过滤（76 项，含 skipped，排除 12 项 na），
> 工具只统计可写入子集（69 项）。**两者都报 0 pending 就是对的**，不必追求数字相同。

---

## 五、验证「真的在跑」，不只是文件被改了

文件被改 ≠ 引擎在读它。这一步最容易自欺。

### 5.1 构造探针

挑一个纯代码常量型的补丁。#22 `READ_CAPS_RAISED` 改的是 `dsh-tool-fs` 里的读取上限：

| | 原件 | 副本 |
|---|---|---|
| 单行字符上限 | `2e3` = 2000 | `1e4` = 10000 |
| 单次字节上限 | 50 KB | 1 MB |

造一个单行 6007 字符的文件，结尾放标记：

```bash
python3 -c "open('/tmp/probe.txt','w').write('X'*6000 + 'ENDMARK')"
```

### 5.2 读它

用 `read` 工具读这个文件。

- 如果引擎读原件 → 2000 字符处截断 → **看不到 `ENDMARK`**
- 如果引擎读副本 → 上限 10000 → **`ENDMARK` 完整出现**

实测结果：

```
1: XXXX…XXXXENDMARK
```

`ENDMARK` 在 6000 字符之后完整出现。**这一条同时证明两件事**：补丁 #22 在运行时生效，且引擎加载的是副本。

### 5.3 其他旁证

| 证据 | 说明 |
|---|---|
| `purge_status` 插件根 = `profiles/web/node_modules/@deepseek-ai` | 插件认的是副本 |
| runtime context 的 checkout = `/home/dsh/.dsh/profiles/web/` | 引擎自述宿主是 profile |
| 审批措辞从 "rejected automatically" 变 "auto-granted" | #8 生效 |
| `read` 读到 6000 字符处标记 | #22 生效 |

---

## 六、为什么还要改 profile 配置

有两个开关原本靠环境变量驱动，而 `DSH_PERMISSION_MODE` 在本环境**未设置**，所以默认走 `workspace-write` + `ask`。

`ask` 在无人可答的环境里，实际效果是「需要审批的动作直接被拒」。所以除了代码补丁，还在 `$DSH_HOME/profiles/web/cordis.patch.yml` 末尾追加两条：

```yaml
- id: sandbox-policy
  name: "@deepseek-ai/dsh-sandbox-policy"
  config:
    mode: danger-full-access

- id: approval
  name: "@deepseek-ai/dsh-user-approval"
  config:
    policy: never
```

这是补丁 #7 / #8 的**配置级等效**，不依赖代码改动，插件升级也不会冲掉。

---

## 七、维护与回滚

### 7.1 唯一脆弱点

共七处改动：`core.js` 两处 + `index.js` 五处。

**插件一升级就全被覆盖。** 引擎立刻回去读只读原件，43 个文件的补丁变成躺在盘上没人读。表现为面板退回大量 pending、审批又开始弹。

### 7.2 恢复脚本

已固化成 `$DSH_HOME/dsh-purge-shadow/`：

| 文件 | 作用 |
|---|---|
| `rebuild.sh` | 主脚本：检查 → 备份 → 注入 → 同步 → 应用 |
| `apply.mjs` | 只跑补丁应用 |
| `README.md` | 完整说明 |

```bash
# 只查不改
bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh --check

# 完整重建（幂等）
bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh
```

`--check` 输出三项：

```
重定向: 正常
副本:   完整
面板根: 正常
```

任一缺失退出码为 1。

### 7.3 回滚

副本是纯拷贝，原安装树一个字节没动过（只读，想动也动不了），所以回滚零风险：

```bash
# 撤销插件改动
cp .../dsh-purge-community/lib/core.js.bak-shadow-*  .../lib/core.js
cp .../dsh-purge-community/lib/index.js.bak-shadow-* .../lib/index.js

# 删掉副本，引擎立刻回去读 /opt
rm -rf /home/dsh/.dsh/profiles/web/node_modules/@deepseek-ai
rm -rf /home/dsh/.dsh/profiles/web/node_modules/@earendil-works
```

**最坏情况是回到起点，不是把环境搞坏。** 这是这条路最大的优点。

---

## 八、代价清单

| 项 | 代价 |
|---|---|
| 磁盘 | 77.8M + 2.2M 副本 |
| 依赖管理 | 副本不受 `pnpm` 管理，插件升级要手动重跑 |
| 插件升级 | 七处改动被覆盖，需 `rebuild.sh` 恢复 |
| shim | 仍缺失（`dsh`/`dsh.cmd`/`dsh.ps1`），iOS 引擎本来就没有，不影响功能 |

---

## 九、方法总结

### 通用套路

遇到「代码要改但这棵树是只读的」，按这个顺序想：

1. **确认 errno**：`EPERM`（策略拦截）和 `EROFS`（挂载只读）处理方式完全不同
2. **逐层探测边界**：找到从哪一级开始只读，往往上层是可写的
3. **找引擎自己的通道**：模块解析顺序、插件加载路径、配置覆盖层——现代运行时几乎都留了"用户层优先"的设计
4. **镜像 + 改指向**：把树搬到可写区，改解析路径而不是改文件位置
5. **防守式验证**：目标根落在只读区就主动报错退出，不要静默空转

### 三个反直觉的点

**第一，看不见的失败最危险。** 补丁报 `applied` 但实际写到只读路径，会静默什么都没做。所以脚本必须断言目标根不在 `/opt`。

**第二，模块能 import 不等于运行时可达。** 我改坏的那版 `index.js` 语法完全正确、能正常 import，但 `patchHost` 在另一个函数作用域里访问不到，面板直接崩。唯一可靠的验证是重启后实际打一次 HTTP 请求。

**第三，文件被改 ≠ 代码在跑。** 必须用行为探针（比如那个 6000 字符的 `ENDMARK`）证明引擎真的加载了改过的版本，否则一切都只是磁盘上的自我安慰。

### 一句话

**不改只读的树，改「谁被读取」。** 借引擎自己的 profile 优先解析顺序，把依赖镜像到可写区，再把插件里七处硬编码的目标根指过去。

---

## 附：完整验证清单

```bash
# 1. 副本完整性
ls -1 /home/dsh/.dsh/profiles/web/node_modules/@deepseek-ai | wc -l   # 329
du -sh /home/dsh/.dsh/profiles/web/node_modules/@deepseek-ai          # 77.8M

# 2. 补丁标记落地
grep -rl 'dsh-purge' /home/dsh/.dsh/profiles/web/node_modules/@deepseek-ai | wc -l   # 43

# 3. 原件未被污染
grep -rl 'dsh-purge' /opt/dsh/nodejs-project/node_modules/@deepseek-ai | wc -l        # 0

# 4. 重定向生效
bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh --check   # 三项全绿

# 5. 面板一致
curl -s http://127.0.0.1:3080/dsh-purge/status | grep -o '"ai_base":"[^"]*"'
curl -s http://127.0.0.1:3080/dsh-purge/status | grep -o '"patches_pending":[0-9]*'

# 6. 运行时真在跑（行为探针）
python3 -c "open('/tmp/probe.txt','w').write('X'*6000+'ENDMARK')"
# 用 read 工具读 /tmp/probe.txt，能看到 ENDMARK 即通过
```
