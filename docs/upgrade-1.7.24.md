# 后续版本：dsh-purge 1.7.24（iOS）

本仓库记录的是 **1.7.20** 时期的方法：iOS 引擎树只读（`EPERM`）时，把 `@deepseek-ai` 镜像到 profile 并改插件目标根，让补丁打在可写副本上。

**方法本身在 1.7.24 上没有失效**——`core.js` 的两处重定向锚点、`index.js` 的四处调用点都还在，升级后重跑一次 `rebuild.sh` 即恢复。

升级带来的变化记录在另一个仓库：

## → [summit-leen/dsh-purge-ios-1.7.24-upgrade](https://github.com/summit-leen/dsh-purge-ios-1.7.24-upgrade)

那一份包含：

| 内容 | 说明 |
|---|---|
| [体验差异](https://github.com/summit-leen/dsh-purge-ios-1.7.24-upgrade/blob/main/docs/experience-diff.md) | iOS 端升级前 vs 升级后逐场景对照：新增注入开关、插件自带回退退役、审批/沙箱/破甲实测未变 |
| [补丁口径](https://github.com/summit-leen/dsh-purge-ios-1.7.24-upgrade/blob/main/docs/patch-inventory.md) | 补丁表 88 → 74、14 条权限补丁下线逐条清单、`58/58` 与 `69/74` 两种分母 |
| [升级日志](https://github.com/summit-leen/dsh-purge-ios-1.7.24-upgrade/blob/main/docs/upgrade-log.md) | 时间线、命令、哈希核对、状态文件变化 |
| [rebuild.sh 修复](https://github.com/summit-leen/dsh-purge-ios-1.7.24-upgrade/blob/main/docs/rebuild-fix.md) | 旧脚本 `node - <<'NODE'` 在本环境静默失效（退出码仍 0），改为独立 `inject-redirect.mjs` |

## 两处需要注意的差异

1. **权限/沙箱/审批那 14 条宿主补丁在 1.7.24 被上游删除**（总数 88 → 74）。行为边界改由配置承担，本机是 `profiles/web/cordis.patch.yml` 里的 `mode: danger-full-access` + `policy: never`，以及保留下来的提示词补丁 #5 / #34。
2. **`rebuild.sh` 必须用新仓库里的版本**。本仓库根目录的旧脚本靠 heredoc 给 node 喂代码，在 iOS 内嵌环境下不会传进去，结果是「什么都没做、退出码 0」——插件一更新就会静默失去重定向。

本仓库的 `apply.mjs` 与镜像方案无需改动，继续使用。
