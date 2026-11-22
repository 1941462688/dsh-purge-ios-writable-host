# dsh-purge on iOS：在只读引擎树上打宿主补丁

> 实测环境：DSH `0.2.2-rc.4` · iOS 内嵌引擎 · `dsh-purge-community` 1.7.20
> 结果：`5/69 applied, 59 pending` → **`64/69 applied, 0 pending`**，只读安装树 **零字节改动**
>
> 一句话：**不改只读的树，改「谁被读取」。**

---

## 1. 问题：`EPERM`，不是 `EROFS`

DSH 跑在 iOS app 里时，引擎依赖树在：

```
/opt/dsh/nodejs-project/node_modules
```

它**只读**，但不是挂载只读：

```bash
$ stat -c '%n %A %U:%G' /opt/dsh/nodejs-project/node_modules/@deepseek-ai
/opt/dsh/nodejs-project/node_modules/@deepseek-ai drwxr-xr-x user group   # 权限 40755

$ touch /opt/dsh/nodejs-project/node_modules/@deepseek-ai/.probe
touch: cannot touch '.../.probe': EPERM: write '.../.probe'          # 是 EPERM
```

| errno | 含义 | 能否绕过 |
|---|---|---|
| `EROFS` | 文件系统挂载为只读 | 需要 remount |
| `EPERM` | 策略层拒绝 | 改不了这棵树，**只能换目标** |

逐层探测边界（`/opt` 可写、`/opt/dsh` 只读）：

```bash
for d in / /opt /opt/dsh /opt/dsh/nodejs-project /home/dsh /tmp; do
  t="$d/.wtest.$$"
  if touch "$t" 2>/dev/null; then echo "W  $d"; rm -f "$t"; else echo "RO $d"; fi
done
```

## 2. 为什么 `purge_apply` 必然失败

补丁引擎在写任何补丁前先做备份，备份文件写在**源文件旁边**（`<file>.dshpurge.bak`）。目标全在只读区，备份阶段整体失败：

```
Error: Host backup failed (65 files); patch writes cancelled.
```

它连第一步都过不去，所以补丁永远是 pending。给 `/opt` 提权、改权限位、重装插件都无效——这不是权限位的问题。

## 3. 核心思路

引擎的模块解析里，**profile 目录优先于 bundle 内的安装树**。把依赖镜像到 profile（可写区），补丁打在副本上，引擎读的也是副本，两边对上。

这是引擎自带的设计，证据在 `runtime/module-redirects.mjs` 的注释里：

> The plugin manager finds their bundle there, but the loader imports their components from the profile folder, which holds none of them: a lookup that fails there is tried again from the engine's folder. **A copy the profile installed itself still wins, being found first.**

三个条件同时满足才成立：

1. 引擎的模块解析 profile 优先（引擎自带行为）
2. profile 在可写区（`$DSH_HOME` 从来可写）
3. 插件自身装在 profile 里（所以插件代码可改）

缺一条这条路就死。如果插件也装在只读区，只能去重签宿主安装包，或改运行时（Frida 一类），那是另一条路。

---

## 4. 实施

### 4.1 建副本

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

- **用 `cp -R`，不要 `cp -a`**：精简版 cp 会报 `invalid option -- 'a'`。
- **只复制需要的 scope**：补丁只碰 `@deepseek-ai` 与 `@earendil-works`。遍历所有 `@*` 会把 `@babel`、`@aws` 一起搬来，体积从 ~116M 涨到 300M+。

### 4.2 改插件的目标根解析（7 处）

`lib/core.js` 两处：

```js
// findAiBase()：web 模式原本直接走 resolveInstance()，按 process.argv 推出 /opt
export function findAiBase() {
  return remember("ai", () => {
    if (adapterFor(detectSurface()) === "desktop") return findAiBaseDesktop();
    try {
      const shadow = findAiBaseFromDshHome(findDshHome());   // 副本优先
      if (shadow && isAiBase(shadow)) return shadow;
    } catch { /* 副本不可用时退回宿主安装树 */ }
    return findAiBaseWeb();
  });
}
```

```js
// enumeratePatchAiBases()：不加这段它仍然返回 /opt
try {
  const shadow = findAiBaseFromDshHome(findDshHome());
  if (shadow && isAiBase(shadow)) { add(shadow); return out; }
} catch { }
```

`findAiBaseFromDshHome` 是插件**自带**函数，本来就支持 `$DSH_HOME/profiles/*/node_modules/@deepseek-ai`，只是 web 模式没优先调用它。

`lib/index.js` 五处（面板 / 诊断 / 自检 / 维护按钮的目标根）：

```js
/**
 * [local] 补丁目标根：优先 profile 里的可写副本。
 * 必须是模块顶层函数声明——状态端点位于 installWebServer()，
 * 与 apply() 是两个独立作用域，函数内定义够不到。
 */
function patchHost() {
  try {
    const shadow = core.findAiBase();
    if (shadow) return shadow;
  } catch { /* 副本不可用 → 退回 process-entry */ }
  return resolveInstance().host;
}
```

替换点：`compatibility(patchHost())`、`new Maintenance({ aiBase: patchHost() })`、`const target = patchHost()`（×2）、`selfCheck(patchHost(), …)`。
其中 `Maintenance` 最关键：它是面板「应用 / 还原 / 卸载」三个按钮**实际写哪里**。

### 4.3 在独立进程里应用补丁

`purge_apply` 工具走的是**进程内已加载的模块**，改磁盘文件它读不到。所以用 `apply.mjs` 在独立 node 进程里跑，并且只在目标根可写时才写：

```bash
node /home/dsh/.dsh/dsh-purge-shadow/apply.mjs          # 应用
node /home/dsh/.dsh/dsh-purge-shadow/apply.mjs --verbose # 逐条看目标文件
```

脚本内置防守：目标根一旦落在 `/opt/` 就 `exit 2`，不做静默空转。

### 4.4 一条命令复原全部

`rebuild.sh` 把 4.1–4.3 串起来，幂等，可重复跑：

```bash
bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh --check   # 只检查，不改动（退出码 0 = 三项全绿）
bash /home/dsh/.dsh/dsh-purge-shadow/rebuild.sh           # 完整重建
```

---

## 5. 验证：文件被改 ≠ 代码在跑

### 5.1 清单

| # | 检查 | 期望 |
|---|---|---|
| 1 | 副本完整性 `ls -1 $D/@deepseek-ai \| wc -l` | 与引擎包数一致（rc.4 为 336） |
| 2 | 补丁标记落地 `grep -rl 'dsh-purge' $D/@deepseek-ai \| wc -l` | > 0（rc.4 实测 40 个文件） |
| 3 | 原件未被污染 `grep -rl 'dsh-purge' /opt/.../ @deepseek-ai \| wc -l` | **0** |
| 4 | `rebuild.sh --check` | 重定向 / 副本 / 面板根 三项全绿 |
| 5 | `curl -s http://127.0.0.1:3080/dsh-purge/status` | `ai_base` 指向 profile，`patches_pending: 0` |

### 5.2 行为探针（决定性的一条）

挑一个纯常量型补丁做探针。补丁 #22 `READ_CAPS_RAISED` 把 `dsh-tool-fs` 的单行字符上限从 `2e3` 改成 `1e4`：

```bash
python3 -c "open('/tmp/probe.txt','w').write('X'*6000+'ENDMARK')"
```

然后用文件读取工具读它：

- 读到 2000 字符处截断、看不到 `ENDMARK` → 引擎仍在读只读原件，补丁没生效
- **整行 6007 字符读完、结尾出现 `ENDMARK`** → 引擎加载的是副本，补丁真实生效

这一条同时证明两件事：补丁在运行时生效，且引擎读的是副本。**只重启前测、重启后再测一次**，两者对照才有意义。

### 5.3 数字口径（别被两套数字搞混）

- **工具** `purge_status`：只统计可写入子集 → `64/69 applied, 0 pending`
- **面板 / 接口**：按 surface 统计 76 项（含 skipped，排除 na）→ `71 applied, 0 pending`

两者都报 0 pending 就是对的，不必追求数字相同。`missing_file`（目标包没装）与 `na`（平台不适用）不是失败。

---

## 6. 维护

| 触发 | 要做的事 |
|---|---|
| **插件升级**（七处注入被覆盖） | 重跑 `rebuild.sh`，重启 |
| **App / 引擎更新**（引擎换版本） | 先删副本再重建，否则引擎会一直读旧副本：`rm -rf $D/@deepseek-ai $D/@earendil-works && bash rebuild.sh` |
| 执行过 `pnpm install` / 清过 node_modules | 副本被删 → `rebuild.sh` |
| 面板突然大量 pending | 先 `rebuild.sh --check` 定位是重定向丢了还是副本不全 |

副作用提示：`pnpm add` 会重写 `package.json`，可能顺手把 `dsh.profile.bundles` 里某个条目删掉、或把已装 bundle 补进 bundles 列表——装完插件后请核对 bundles 列表，再重启。

---

## 7. 回滚（零风险）

副本是纯拷贝，原安装树一个字节没动过：

```bash
# 撤销插件改动
cp $P/lib/core.js.bak-shadow-*  $P/lib/core.js
cp $P/lib/index.js.bak-shadow-* $P/lib/index.js

# 删掉副本，引擎立刻回去读 /opt
rm -rf $D/@deepseek-ai $D/@earendil-works
```

最坏情况是回到「注入生效但宿主闸门全锁」的起点，不会把环境搞坏。

---

## 8. 与相近方案的位置

| 路线 | 代表 | 适用 |
|---|---|---|
| **改解析（本项目）** | 本仓库；[Electron ASAR 的明文目录优先](https://www.electronjs.org/docs/latest/tutorial/asar-archives)、[Node loader hooks](https://nodejs.org/api/module.html) | 宿主只读、不可重签，但引擎留了「用户层优先」通道 |
| 改文件 | [pnpm patch](https://pnpm.io/cli/patch)、[patch-package](https://github.com/ds300/patch-package) | 目标 node_modules 可写 |
| 改安装包 | [TrollStore](https://github.com/opa334/TrollStore)、自签 IPA 重装 | 能自行签名；代价是版本与插件都要跟着重打 |
| 改运行时 | [Frida](https://github.com/frida/frida)、[fishhook](https://github.com/facebook/fishhook) | 有注入能力（越狱 / 可调试进程） |
| 整盘 overlay | [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) | 有 FUSE（iOS 没有） |

---

## 9. 本机实测数据（rc.4）

| 项 | 值 |
|---|---|
| 副本 | 336 个包 / 116.3M（`@deepseek-ai` + `@earendil-works` 3 个） |
| 全树逐字节比对 | 5626 个可比文件：**51 个不同**、5575 相同、0 缺失 |
| 补丁 | 面板 71 applied / 0 pending；工具 64/69 / 0 pending |
| 引擎原件污染 | 0 |
| 行为探针 | 6007 字符单行完整读出，`ENDMARK` 出现在末尾 |
| 运行时自述 | `Approval requests are auto-granted in this session (approval bypass, approval policy: never)` |

---

## 10. 免责与许可

仅用于你**自己拥有并获授权**的本机环境。补丁会修改宿主的系统提示与部分行为，后果自负。脚本按 MIT 发布，不附带任何担保。

Licensed under the [MIT License](./LICENSE).

---

### English (short)

When DSH runs inside an iOS app, the engine tree at `/opt/dsh/nodejs-project/node_modules` is read-only with `EPERM` (a policy/entitlement block, not `EROFS`). `dsh-purge`'s apply path backs up every target file next to the original, so it fails before writing anything.

This repo uses the engine's own resolution rule — **a copy the profile installed itself wins, being found first** — mirrors `@deepseek-ai` / `@earendil-works` into `$DSH_HOME/profiles/<name>/node_modules`, repoints the plugin's seven hard-coded target-root lookups, and applies all patches into the writable copy. The original tree is never touched; rollback is `rm -rf` of the copy.

Verification is behavioral, not cosmetic: raise a read cap via patch #22 and read a 6007-char line — if `ENDMARK` at the end is visible, the engine is really loading the copy.
