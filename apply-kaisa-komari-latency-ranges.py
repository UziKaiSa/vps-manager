#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path


LATENCY_PATCH_SCRIPT = r'''<script id="kaisa-latency-range-patch">
(() => {
  const DAY_RANGES = [
    { label: "1 天", hours: 24 },
    { label: "3 天", hours: 72 },
    { label: "7 天", hours: 168 },
    { label: "10 天", hours: 240 },
    { label: "30 天", hours: 720 },
    { label: "60 天", hours: 1440 },
    { label: "90 天", hours: 2160 },
  ];

  const state = {
    selectedHours: 24,
    pendingOverrideHours: null,
    lastRealTriggerAt: 0,
  };

  const isPingRecordsRequest = (payload) => {
    const items = Array.isArray(payload) ? payload : [payload];
    return items.some((item) => (
      item &&
      item.method === "common:getRecords" &&
      item.params &&
      item.params.type === "ping" &&
      typeof item.params.hours === "number"
    ));
  };

  const rewritePayload = (payload) => {
    const rewriteOne = (item) => {
      if (
        item &&
        item.method === "common:getRecords" &&
        item.params &&
        item.params.type === "ping" &&
        typeof item.params.hours === "number" &&
        state.pendingOverrideHours
      ) {
        return {
          ...item,
          params: {
            ...item.params,
            hours: state.pendingOverrideHours,
          },
        };
      }
      return item;
    };

    if (Array.isArray(payload)) {
      return payload.map(rewriteOne);
    }
    return rewriteOne(payload);
  };

  const originalFetch = window.fetch;
  window.fetch = function patchedFetch(input, init) {
    try {
      const body = init && init.body;
      if (typeof body === "string") {
        const payload = JSON.parse(body);
        if (isPingRecordsRequest(payload)) {
          init = {
            ...init,
            body: JSON.stringify(rewritePayload(payload)),
          };
        }
      }
    } catch (_) {}
    return originalFetch.call(this, input, init);
  };

  const originalSend = WebSocket.prototype.send;
  WebSocket.prototype.send = function patchedSend(data) {
    try {
      if (typeof data === "string") {
        const payload = JSON.parse(data);
        if (isPingRecordsRequest(payload)) {
          data = JSON.stringify(rewritePayload(payload));
        }
      }
    } catch (_) {}
    return originalSend.call(this, data);
  };

  const normalizeText = (value) => (value || "").replace(/\s+/g, "");

  const isVisible = (node) => {
    const rect = node.getBoundingClientRect();
    const style = window.getComputedStyle(node);
    return rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
  };

  const CONTROL_LABEL_SETS = [
    ["1小时", "6小时", "12小时", "1天"],
    ["实时", "4小时", "1天", "3天", "7天", "30天"],
  ];

  const hasAllLabels = (text, labels) => labels.every((label) => text.includes(label));

  const findLatencySegmentRoot = () => {
    const candidates = Array.from(document.body.querySelectorAll("div, section, nav, [role='tablist'], .rt-SegmentedControlRoot"))
      .filter((node) => {
        if (node.dataset.kaisaLatencyPatched === "true" || !isVisible(node)) return false;
        const text = normalizeText(node.textContent);
        return CONTROL_LABEL_SETS.some((labels) => hasAllLabels(text, labels));
      })
      .sort((a, b) => normalizeText(a.textContent).length - normalizeText(b.textContent).length);

    return candidates[0] || null;
  };

  const findRealTrigger = (root, normalizedLabel) => {
    const hit = Array.from(root.querySelectorAll("*"))
      .filter((node) => normalizeText(node.textContent) === normalizedLabel)
      .sort((a, b) => normalizeText(a.textContent).length - normalizeText(b.textContent).length)[0];
    if (!hit) return null;
    return hit.closest("button, [role='tab'], .rt-SegmentedControlItem, [data-state]") || hit;
  };

  const activateRealTrigger = (trigger) => {
    trigger.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true, pointerType: "mouse", button: 0 }));
    trigger.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }));
    trigger.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, cancelable: true, pointerType: "mouse", button: 0 }));
    trigger.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, cancelable: true, button: 0 }));
    trigger.click();
  };

  const setActive = (panel, hours) => {
    panel.querySelectorAll("[data-kaisa-latency-hours]").forEach((button) => {
      button.dataset.active = String(Number(button.dataset.kaisaLatencyHours) === hours);
    });
  };

  const mountPanel = () => {
    const root = findLatencySegmentRoot();
    if (!root || root.dataset.kaisaLatencyPatched === "true") return;

    const oneDayTrigger = findRealTrigger(root, "1天");
    const maxTrigger =
      findRealTrigger(root, "90天") ||
      findRealTrigger(root, "30天") ||
      findRealTrigger(root, "7天") ||
      Array.from(root.querySelectorAll("button, [role='tab'], .rt-SegmentedControlItem, [data-state]")).at(-1);
    if (!oneDayTrigger || !maxTrigger) return;

    root.dataset.kaisaLatencyPatched = "true";
    root.style.display = "none";

    const panel = document.createElement("div");
    panel.className = "kaisa-latency-range-panel";
    panel.setAttribute("role", "tablist");

    DAY_RANGES.forEach(({ label, hours }) => {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = label;
      button.dataset.kaisaLatencyHours = String(hours);
      button.className = "kaisa-latency-range-button";
      button.addEventListener("click", () => {
        state.selectedHours = hours;
        state.lastRealTriggerAt = Date.now();
        setActive(panel, hours);

        if (hours === 24) {
          state.pendingOverrideHours = null;
          activateRealTrigger(oneDayTrigger);
          return;
        }

        state.pendingOverrideHours = null;
        activateRealTrigger(oneDayTrigger);

        window.setTimeout(() => {
          state.pendingOverrideHours = hours;
          state.lastRealTriggerAt = Date.now();
          activateRealTrigger(maxTrigger);
        }, 80);

        window.setTimeout(() => {
          if (Date.now() - state.lastRealTriggerAt >= 1400) {
            state.pendingOverrideHours = null;
          }
        }, 1500);
      });
      panel.appendChild(button);
    });

    root.insertAdjacentElement("afterend", panel);
    setActive(panel, state.selectedHours);
  };

  const style = document.createElement("style");
  style.id = "kaisa-latency-range-patch-style";
  style.textContent = `
    .kaisa-latency-range-panel {
      display: inline-flex;
      align-items: stretch;
      overflow: hidden;
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 8px;
      background: rgba(0, 0, 0, 0.24);
      box-shadow: inset 0 0 0 1px rgba(255,255,255,0.04);
    }
    .kaisa-latency-range-button {
      min-width: 82px;
      padding: 8px 18px;
      color: rgba(246, 248, 255, 0.88);
      background: transparent;
      border: 0;
      border-right: 1px solid rgba(255, 255, 255, 0.12);
      font: inherit;
      cursor: pointer;
    }
    .kaisa-latency-range-button:last-child {
      border-right: 0;
    }
    .kaisa-latency-range-button[data-active="true"] {
      color: rgba(255,255,255,0.98);
      background: rgba(255,255,255,0.10);
      box-shadow: inset 0 0 0 1px rgba(255,255,255,0.12);
    }
  `;
  document.head.appendChild(style);

  const observer = new MutationObserver(() => {
    window.requestAnimationFrame(mountPanel);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });

  window.addEventListener("popstate", () => window.setTimeout(mountPanel, 300));
  window.setInterval(mountPanel, 1000);
  mountPanel();
})();
</script>'''


BASE_OPTIONS_SCRIPT = '''<script id="kaisa-personal-dashboard-options">
window.ShowNetTransfer = true;
window.FixedTopServerName = true;
</script>'''


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply KaiSa latency range patch to a Komari SQLite database."
    )
    parser.add_argument(
        "--db",
        default=os.environ.get("KOMARI_DB_PATH", "./data/komari.db"),
        help="Komari SQLite DB path. Default: KOMARI_DB_PATH or ./data/komari.db",
    )
    parser.add_argument(
        "--backup-dir",
        default=os.environ.get("KOMARI_THEME_BACKUP_DIR"),
        help="Backup directory. Default: <db_dir>/theme-backups",
    )
    parser.add_argument(
        "--ping-preserve-hours",
        type=int,
        default=int(os.environ.get("KOMARI_PING_PRESERVE_HOURS", "2160")),
        help="Ping record preserve time in hours. Default: 2160 (90 days).",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Do not create a DB backup before writing configs.",
    )
    return parser.parse_args()


def resolve_path(path_value: str) -> Path:
    return Path(path_value).expanduser().resolve()


def upsert_config(conn: sqlite3.Connection, key: str, value: str) -> None:
    updated = conn.execute(
        "UPDATE configs SET value = ? WHERE key = ?",
        (value, key),
    )
    if updated.rowcount == 0:
        conn.execute(
            "INSERT INTO configs (key, value) VALUES (?, ?)",
            (key, value),
        )


def main() -> int:
    args = parse_args()
    db_path = resolve_path(args.db)
    backup_dir = resolve_path(args.backup_dir) if args.backup_dir else db_path.parent / "theme-backups"

    if not db_path.exists():
        print(f"Komari DB not found: {db_path}", file=sys.stderr)
        print("Pass --db /path/to/komari.db or set KOMARI_DB_PATH.", file=sys.stderr)
        return 1

    if args.ping_preserve_hours < 2160:
        print("ping preserve time must be at least 2160 hours for 90-day range.", file=sys.stderr)
        return 1

    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    backup_path = backup_dir / f"{db_path.name}.before-kaisa-latency-ranges-{timestamp}"

    if not args.no_backup:
        backup_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(db_path, backup_path)

    custom_body = BASE_OPTIONS_SCRIPT + "\n\n" + LATENCY_PATCH_SCRIPT

    with sqlite3.connect(db_path) as conn:
        upsert_config(conn, "custom_body", json.dumps(custom_body, ensure_ascii=False))
        upsert_config(conn, "ping_record_preserve_time", str(args.ping_preserve_hours))
        conn.commit()

    if not args.no_backup:
        print(f"Backup created: {backup_path}")
    print(f"Applied latency ranges patch to: {db_path}")
    print(f"Set ping_record_preserve_time={args.ping_preserve_hours}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
