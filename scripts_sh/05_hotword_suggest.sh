#!/usr/bin/env bash
# 從實際 log 挖出「被聽歪而漏接的呼叫」,建議加進熱詞清單
#
# 為什麼需要:STT 把「Doro」聽成什麼是無法預測的 —— 實測出現過
# 大佬 / 喉嚨 / 龍龍 / 洛狗 / D O R O / D U R O。字面比對救不了「大佬」,
# 只能把實際發生過的變體收進清單。這支就是幫你把它們找出來。
#
# 用法:
#   ./scripts_sh/05_hotword_suggest.sh          # 看所有 log
#   ./scripts_sh/05_hotword_suggest.sh 3        # 只看最近 3 天
#
# 挑好之後貼進:設定 → STT → 熱詞(逗號或頓號分隔)

set -euo pipefail
DAYS="${1:-0}"
LOG_DIR="$HOME/Library/Application Support/Godot/app_userdata/DoroPet/logs"

if [[ ! -d "$LOG_DIR" ]]; then
  echo "找不到 log 目錄:$LOG_DIR" >&2
  exit 1
fi

python3 - "$LOG_DIR" "$DAYS" <<'PY'
import sys, os, json, re, glob
from collections import Counter

log_dir, days = sys.argv[1], int(sys.argv[2])
files = sorted(glob.glob(os.path.join(log_dir, "*.jsonl")))
if days > 0:
    files = files[-days:]

ignored, called = [], []
for fp in files:
    for line in open(fp, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        t = r.get("type")
        if t == "discord_no_hotword":
            ignored.append(r.get("text", ""))
        elif t == "discord_speech":
            called.append(r.get("text", ""))

if not ignored:
    print("沒有被擋下的句子 —— 熱詞清單目前夠用,或還沒在 Discord 講過話。")
    raise SystemExit

# 開頭的稱呼最可能是被聽歪的名字:切到第一個標點為止。
# 不能用空白切 —— STT 把英文名字逐字母吐出來時就是「D O R O」,
# 用空白切會變成單一個 "D",整個變體就漏掉了
def head(s):
    return re.split(r"[，,。．.！!？?、]", s.strip(), maxsplit=1)[0].strip()

heads = Counter(head(t) for t in ignored if 1 < len(head(t)) <= 10)

# 已知的誤聽特徵:含 D/O/R/O 字母、或聽起來像 Doro 的常見中文
pat = re.compile(r"[Dd]\s*[OoUu0]\s*[Rr]\s*[Oo]|洛|羅|囉|咯|龍|佬|嚨|多羅|朵洛|逗留|都露")

print(f"掃了 {len(files)} 天的 log:{len(called)} 句成功觸發、{len(ignored)} 句被擋下\n")
print("=== 疑似被聽歪的呼叫(建議加進熱詞)===")
sus = [(h, n) for h, n in heads.most_common() if pat.search(h)]
if sus:
    for h, n in sus:
        print(f"  {h:12s} 出現 {n} 次")
    print("\n  可以直接貼的格式:")
    print("  " + "、".join(h for h, _ in sus))
else:
    print("  (沒找到明顯的誤聽變體)")

print("\n=== 其他被擋下的開頭詞(多半是真的閒聊,自行判斷)===")
for h, n in [(h, n) for h, n in heads.most_common(12) if not pat.search(h)]:
    print(f"  {h:12s} {n} 次")
PY
