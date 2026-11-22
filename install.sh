#!/bin/bash
# 把本仓库的三个文件装到 $DSH_HOME/dsh-purge-shadow/，与 rebuild.sh 的默认路径一致。
#
# 用法：
#   bash install.sh              # 装到 ~/.dsh/dsh-purge-shadow/
#   DSH_HOME=/path bash install.sh

set -eu

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DEST="$DSH_HOME/dsh-purge-shadow"
SRC="$(cd "$(dirname "$0")" && pwd)"

[ -d "$DSH_HOME" ] || { echo "找不到 DSH_HOME: $DSH_HOME（先用 DSH_HOME=... 指定）" >&2; exit 1; }
mkdir -p "$DEST"

for f in rebuild.sh apply.mjs README.md; do
  [ -f "$SRC/$f" ] || { echo "缺少 $SRC/$f" >&2; exit 1; }
  cp -f "$SRC/$f" "$DEST/$f"
  echo "已安装 $DEST/$f"
done
chmod +x "$DEST/rebuild.sh" 2>/dev/null || true

echo ""
echo "下一步："
echo "  1) bash \"$DEST/rebuild.sh\" --check   # 先只读检查，退出码 0 则为三项全绿"
echo "  2) bash \"$DEST/rebuild.sh\"           # 建副本、注入重定向、应用补丁"
echo "  3) 完全退出宿主再重新打开（插件会在进程内缓存目标根）"
