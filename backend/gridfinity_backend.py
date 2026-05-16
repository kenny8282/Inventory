"""
Gridfinity Label Forge — Shared Backend
========================================
Tiny Flask app that stores label data on the Pi's disk so all devices on
the network see the same registry, plus prints labels to a Brother
P-Touch tape printer via ptouch-print.

API endpoints:
  GET    /api/health          → { ok: true, version: "..." }
  GET    /api/kv/<key>        → { value: "..." }   or 404
  PUT    /api/kv/<key>        → body { value: "..." }
  GET    /api/registry-hash   → { hash: "abc123..." }  (for sync polling)
  GET    /api/export          → full v1 inventory JSON
  POST   /api/import          → merge a v1 inventory JSON (atomic)
  POST   /api/reset           → wipe everything (use with care)
  GET    /api/printer/status  → { connected, model, tape_width_mm, error }
  POST   /api/print           → render+print a label (body: see below)

Data is stored as JSON files in DATA_DIR. Atomic writes via tempfile+rename.
A file lock (fcntl) prevents concurrent writes from corrupting state.
"""

import json
import os
import subprocess
import hashlib
import tempfile
import fcntl
import io
import base64
from pathlib import Path
from flask import Flask, request, jsonify, abort

APP_VERSION = "1.14.0"  # Forge: Tape Output panel removed, manual tape override in status strip, height-grouped sheet pagination, color in Label Format

# Where data lives. Change with env var if you want a different path.
DATA_DIR = Path(os.environ.get("GFLF_DATA_DIR", "/var/lib/gridfinity"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

# Keys the frontend uses. Any other key would be rejected.
ALLOWED_KEYS = {
    "gflf:used",
    "gflf:registry",
    "gflf:rows",            # legacy (pre-v1.12) — kept readable for the one-time migration archive
    "gflf:rows_archive",    # v1.12 archive of pre-restructure rows (so users can recover if needed)
    "gflf:maker_rows",      # v1.12+: Label Maker tab rows
    "gflf:printer_rows",    # v1.12+: Printer tab rows
    "gflf:config",
    "gflf:tape_presets",    # user-saved {id,name,desc,w,h} for Label Maker tab
    "gflf:sheet_presets",   # user-saved {id,name,desc,w,h} for Printer tab
}

app = Flask(__name__)

# ------------------------------------------------------------------
# File helpers — atomic write + lock
# ------------------------------------------------------------------

def _safe_path(key: str) -> Path:
    # Replace : with _ for filesystem safety
    safe = key.replace(":", "_").replace("/", "_")
    return DATA_DIR / f"{safe}.json"

def _read_file(key: str):
    p = _safe_path(key)
    if not p.exists():
        return None
    try:
        with open(p, "r") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_SH)
            try:
                return f.read()
            finally:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
    except Exception as e:
        app.logger.warning(f"read failed for {key}: {e}")
        return None

def _write_file(key: str, value: str):
    p = _safe_path(key)
    # Atomic write: write to tempfile, then rename
    tmp = tempfile.NamedTemporaryFile(
        mode="w",
        delete=False,
        dir=str(DATA_DIR),
        prefix=p.stem + ".",
        suffix=".tmp",
    )
    try:
        fcntl.flock(tmp.fileno(), fcntl.LOCK_EX)
        tmp.write(value)
        tmp.flush()
        os.fsync(tmp.fileno())
        fcntl.flock(tmp.fileno(), fcntl.LOCK_UN)
        tmp.close()
        os.replace(tmp.name, p)
    except Exception:
        try:
            tmp.close()
            os.unlink(tmp.name)
        except Exception:
            pass
        raise

# ------------------------------------------------------------------
# Routes
# ------------------------------------------------------------------

@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({
        "ok": True,
        "version": APP_VERSION,
        "schema": "gridfinity-inventory/v1",
        "data_dir": str(DATA_DIR),
    })

@app.route("/api/kv/<key>", methods=["GET"])
def kv_get(key):
    if key not in ALLOWED_KEYS:
        abort(400, description=f"unknown key: {key}")
    val = _read_file(key)
    if val is None:
        abort(404)
    return jsonify({"key": key, "value": val})

@app.route("/api/kv/<key>", methods=["PUT"])
def kv_put(key):
    if key not in ALLOWED_KEYS:
        abort(400, description=f"unknown key: {key}")
    body = request.get_json(silent=True)
    if body is None or "value" not in body:
        abort(400, description="body must be JSON with 'value' field")
    value = body["value"]
    if not isinstance(value, str):
        abort(400, description="'value' must be a string")
    if len(value) > 50 * 1024 * 1024:  # 50MB cap per key
        abort(413, description="value too large")
    try:
        _write_file(key, value)
    except Exception as e:
        app.logger.exception("write failed")
        abort(500, description=str(e))
    return jsonify({"ok": True, "key": key})

@app.route("/api/registry-hash", methods=["GET"])
def registry_hash():
    """Returns a hash of the registry file so clients can poll for changes
    cheaply without downloading the full payload every time."""
    val = _read_file("gflf:registry") or ""
    h = hashlib.sha256(val.encode("utf-8")).hexdigest()[:16]
    return jsonify({"hash": h})

@app.route("/api/export", methods=["GET"])
def export_inventory():
    """Returns the full registry as a v1 inventory file."""
    raw = _read_file("gflf:registry") or "{}"
    try:
        registry = json.loads(raw)
    except Exception:
        registry = {}
    from datetime import datetime, timezone
    items = sorted(
        registry.values(),
        key=lambda r: r.get("created", "")
    )
    return jsonify({
        "schema": "gridfinity-inventory/v1",
        "exported": datetime.now(timezone.utc).isoformat(),
        "items": items,
    })

@app.route("/api/import", methods=["POST"])
def import_inventory():
    """Merge a v1 inventory file. Skips items whose IDs already exist."""
    data = request.get_json(silent=True)
    if not data or data.get("schema", "").split("/")[0] != "gridfinity-inventory":
        abort(400, description="not a gridfinity-inventory file")
    incoming = data.get("items") or []
    if not isinstance(incoming, list):
        abort(400, description="items must be a list")

    # Load existing
    raw_reg = _read_file("gflf:registry") or "{}"
    raw_used = _read_file("gflf:used") or "[]"
    try:
        registry = json.loads(raw_reg)
        used = set(json.loads(raw_used))
    except Exception:
        registry = {}
        used = set()

    added = 0
    skipped = 0
    for it in incoming:
        if not isinstance(it, dict):
            continue
        rid = it.get("id")
        if not rid:
            continue
        if rid in registry:
            skipped += 1
            continue
        registry[rid] = it
        used.add(rid)
        added += 1

    # Write atomically
    _write_file("gflf:registry", json.dumps(registry))
    _write_file("gflf:used", json.dumps(sorted(used)))

    return jsonify({"ok": True, "added": added, "skipped": skipped})

@app.route("/api/reset", methods=["POST"])
def reset_all():
    """Wipe all stored data. Requires confirm=true in body."""
    body = request.get_json(silent=True) or {}
    if body.get("confirm") is not True:
        abort(400, description="set confirm=true to wipe")
    for key in ALLOWED_KEYS:
        p = _safe_path(key)
        if p.exists():
            p.unlink()
    return jsonify({"ok": True, "reset": True})


# ------------------------------------------------------------------
# Printer integration (Brother P-Touch via ptouch-print)
# ------------------------------------------------------------------

PTOUCH_BIN = os.environ.get("PTOUCH_BIN", "/usr/local/bin/ptouch-print")


def _ptouch_info():
    """Query the printer for its current state. Returns dict or None if no printer."""
    if not os.path.exists(PTOUCH_BIN):
        return {"error": "ptouch-print not installed", "connected": False}
    try:
        result = subprocess.run(
            [PTOUCH_BIN, "--info"],
            capture_output=True, text=True, timeout=8,
        )
    except subprocess.TimeoutExpired:
        return {"error": "printer query timed out", "connected": False}
    except Exception as e:
        return {"error": f"ptouch-print failed: {e}", "connected": False}

    out = (result.stdout or "") + "\n" + (result.stderr or "")
    info = {"connected": False, "raw": out.strip()}

    # Detect "no printer" states across ptouch-print versions:
    #   v1.5 - "No printers found"
    #   v1.8 - "No P-Touch printer found on USB (remember to put switch to position E)"
    no_printer_phrases = [
        "no p-touch printer found",
        "no printers found",
        "no printer found",
    ]
    out_lower = out.lower()
    is_missing = any(p in out_lower for p in no_printer_phrases)

    if is_missing:
        info["connected"] = False
        # Friendly hint for the most common cause
        if "switch to position" in out_lower or "plite" in out_lower:
            info["hint"] = "Hold the PLite button on the printer for ~2 seconds — the green LED should turn OFF"
        return info

    # Connected detection — accept any of these markers:
    #   v1.5: "PT-XYZ found on USB bus 1, device 4"
    #   v1.8: "printer has 180 dpi, maximum printing width is 128 px"
    #   v1.8 also: "maximum printing width for this tape is 76px"
    connected_markers = [
        "found on usb",
        "maximum printing width",
        "printer has",
        "media width",
    ]
    if any(m in out_lower for m in connected_markers):
        info["connected"] = True

    # Parse details from the output
    for line in out.splitlines():
        line = line.strip()
        # v1.5 model line: "PT-P700 found on USB bus 1, device 8"
        if "found on USB" in line:
            parts = line.split(" found on USB")
            if parts and parts[0].strip():
                info["model"] = parts[0].strip()
        # Tape width — appears in both versions
        if line.startswith("media width"):
            try:
                mm = int(line.split("=")[1].strip().split()[0])
                info["tape_width_mm"] = mm
            except Exception:
                pass
        # Tape printable width in pixels — v1.8 phrasing
        if "maximum printing width for this tape" in line.lower():
            # e.g. "maximum printing width for this tape is 76px"
            try:
                import re
                m = re.search(r"(\d+)\s*px", line)
                if m:
                    info["max_print_px"] = int(m.group(1))
            except Exception:
                pass
        # Or older style: "max width = 70 px"
        elif line.startswith("max width"):
            try:
                px = int(line.split("=")[1].strip().split()[0])
                info["max_print_px"] = px
            except Exception:
                pass
        if line.startswith("tape color"):
            info["tape_color"] = line.split("=")[1].strip()
        if line.startswith("text color"):
            info["text_color"] = line.split("=")[1].strip()
        # Error code — flag only if non-zero
        if line.lower().startswith("error"):
            err = line.split("=")[1].strip() if "=" in line else ""
            # Strip 0x prefix and accept either "0000" or "0x0000" as OK
            err_clean = err.lower().replace("0x", "").strip()
            if err_clean and err_clean != "0000" and err_clean != "0":
                info["printer_error"] = err
                info["connected"] = False

    # If we still don't have a model name, try to extract one from the
    # output. Fall back to a generic label.
    if info.get("connected") and not info.get("model"):
        # Look for typical Brother model identifiers
        import re
        m = re.search(r"\bPT[-_]?[A-Z0-9]+\b", out)
        if m:
            info["model"] = m.group(0).replace("_", "-")
        else:
            info["model"] = "P-Touch printer"

    if result.returncode != 0 and not info["connected"]:
        info["error"] = (result.stderr or "ptouch-print returned an error").strip()

    return info


@app.route("/api/printer/status", methods=["GET"])
def printer_status():
    """Returns the current state of the connected tape printer."""
    info = _ptouch_info() or {"connected": False}
    return jsonify(info)


@app.route("/api/print", methods=["POST"])
def print_label():
    """Print one or more labels to the tape printer.

    Body (use one of these shapes):

      Single label:
        { "png_base64": "<data>", "copies": 1 }
        -> ptouch-print --image label.png  (repeated `copies` times)

      Batch (multiple different labels in one job):
        { "pngs_base64": ["<data1>", "<data2>", ...], "copies": 1 }
        -> ptouch-print --image l1.png --image l2.png --image l3.png
        -> One front leader for the whole batch, auto-cut between each label.
    """
    body = request.get_json(silent=True) or {}

    copies = int(body.get("copies", 1) or 1)
    if copies < 1 or copies > 50:
        abort(400, description="copies must be 1-50")

    # Accept either single PNG or list of PNGs
    pngs_b64 = body.get("pngs_base64")
    single_b64 = body.get("png_base64")

    if pngs_b64 is None and single_b64 is None:
        abort(400, description="png_base64 or pngs_base64 is required")

    if pngs_b64 is not None:
        if not isinstance(pngs_b64, list) or not pngs_b64:
            abort(400, description="pngs_base64 must be a non-empty list")
        png_list = pngs_b64
    else:
        png_list = [single_b64]

    if len(png_list) > 100:
        abort(400, description="too many labels in batch (max 100)")

    # Decode each PNG, write to its own temp file
    tmp_paths = []
    try:
        for idx, b64 in enumerate(png_list):
            if "," in b64 and b64.startswith("data:"):
                b64 = b64.split(",", 1)[1]
            try:
                png_bytes = base64.b64decode(b64)
            except Exception:
                abort(400, description=f"label #{idx+1}: invalid base64")
            if not png_bytes or png_bytes[:8] != b"\x89PNG\r\n\x1a\n":
                abort(400, description=f"label #{idx+1}: not a PNG")
            t = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
            t.write(png_bytes)
            t.flush()
            t.close()
            tmp_paths.append(t.name)

        # Pre-flight: confirm printer is connected
        info = _ptouch_info()
        if not info.get("connected"):
            return jsonify({
                "ok": False,
                "error": "printer not connected",
                "detail": info,
            }), 503

        # Cut strategy for the farixembedded ptouch-print fork:
        #
        # This fork doesn't have --precut. Cuts work like this:
        #   - Every ptouch-print invocation feeds + auto-cuts at the END.
        #   - --chain skips the final feed/cut so the next label can chain on.
        #   - --cutmark prints a small mark where the user should manually cut.
        #
        # Best UX: print each label as its own invocation so each one gets a
        # clean auto-cut at the end. The printer's mandatory 25mm leader only
        # appears on the very first label of a print session (the printer
        # remembers where it is on the tape). Multi-label batches can group
        # multiple --image flags in one invocation for tighter packing, but
        # that requires manual cutting between them via --cutmark.
        #
        # Single label:           ptouch-print --image L.png
        #   -> prints L, auto-cuts at end
        # Multiple discrete labels (each fully cut):
        #   -> separate ptouch-print invocations per label

        all_results = []
        n = len(tmp_paths)
        for c in range(copies):
            for i, p in enumerate(tmp_paths):
                cmd = [PTOUCH_BIN, "--image", p]
                r = subprocess.run(
                    cmd,
                    capture_output=True, text=True,
                    timeout=60,  # per-label; ptouch-print can take 5-10s
                )
                all_results.append({
                    "copy": c + 1,
                    "label": i + 1,
                    "cmd": " ".join(cmd),
                    "returncode": r.returncode,
                    "stdout": (r.stdout or "").strip(),
                    "stderr": (r.stderr or "").strip(),
                })
                if r.returncode != 0:
                    return jsonify({
                        "ok": False,
                        "error": "ptouch-print failed",
                        "copy": c + 1,
                        "label": i + 1,
                        "results": all_results,
                    }), 500

        return jsonify({
            "ok": True,
            "labels": len(png_list),
            "copies": copies,
            "printer": info.get("model", "unknown"),
            "tape_width_mm": info.get("tape_width_mm"),
        })
    finally:
        for p in tmp_paths:
            try:
                os.unlink(p)
            except Exception:
                pass


# ------------------------------------------------------------------
# Inventory app endpoints
# ------------------------------------------------------------------
# Item types: "container" (default) | "bin" | "unknown" (just printed, no scan yet)
# A container has: description, bin_id (where it lives), quantity, notes, etc.
# A bin has: location (free text), nothing else required.
# The registry holds both kinds in the same JSON. The "type" field
# distinguishes them. Old label-only records have no type → treated as
# "unknown" until first scan.

import time

def _load_registry():
    raw = _read_file("gflf:registry") or "{}"
    try:
        return json.loads(raw)
    except Exception:
        return {}

def _save_registry(reg):
    _write_file("gflf:registry", json.dumps(reg))

def _now_iso():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


@app.route("/api/items/<item_id>", methods=["GET"])
def get_item(item_id):
    """Look up a single item by ID. Returns 404 if not in registry yet."""
    reg = _load_registry()
    rec = reg.get(item_id)
    if not rec:
        return jsonify({"id": item_id, "exists": False}), 404
    # If it's a bin, also include the list of containers in it
    if rec.get("type") == "bin":
        contents = [
            v for v in reg.values()
            if v.get("type") == "container" and v.get("bin_id") == item_id
        ]
        rec = dict(rec)  # don't mutate the stored copy
        rec["contents"] = contents
    # If it's a container, include the bin's friendly info for display.
    # Provides name fields the UI can show without re-fetching the bin.
    elif rec.get("type") == "container" and rec.get("bin_id"):
        bin_rec = reg.get(rec["bin_id"])
        if bin_rec:
            rec = dict(rec)
            # Combined hierarchical path (e.g. "Home · Garage · Shelf 2") or legacy
            rec["bin_location"] = bin_rec.get("location", "")
            # Friendly name candidates so the UI can fall through
            rec["bin_description"] = bin_rec.get("description")
            rec["bin_lines"] = bin_rec.get("lines")
            rec["bin_location_property"] = bin_rec.get("location_property")
            rec["bin_location_room"] = bin_rec.get("location_room")
            rec["bin_location_spot"] = bin_rec.get("location_spot")
    return jsonify({"id": item_id, "exists": True, "record": rec})


@app.route("/api/items/<item_id>", methods=["PUT", "POST"])
def upsert_item(item_id):
    """Create or update an item. Body is a partial record — fields are
    merged into the existing record. Pass type to set bin vs container."""
    body = request.get_json(silent=True) or {}
    reg = _load_registry()
    existing = reg.get(item_id, {})
    # Merge fields, but never let the client overwrite the id
    merged = {**existing, **body, "id": item_id}
    merged["updated"] = _now_iso()
    if "created" not in merged:
        merged["created"] = _now_iso()
    reg[item_id] = merged
    _save_registry(reg)
    # Also track the ID as issued
    used_raw = _read_file("gflf:used") or "[]"
    try:
        used = set(json.loads(used_raw))
    except Exception:
        used = set()
    used.add(item_id)
    _write_file("gflf:used", json.dumps(sorted(used)))
    return jsonify({"ok": True, "record": merged})


@app.route("/api/items/<item_id>", methods=["DELETE"])
def delete_item(item_id):
    """Soft-delete: removes the record but keeps the ID reserved."""
    reg = _load_registry()
    if item_id in reg:
        del reg[item_id]
        _save_registry(reg)
    return jsonify({"ok": True})


@app.route("/api/items", methods=["GET"])
def list_items():
    """List all items, optionally filtered by ?type=bin|container."""
    reg = _load_registry()
    type_filter = request.args.get("type")
    items = list(reg.values())
    if type_filter:
        items = [i for i in items if i.get("type") == type_filter]
    # Sort by created date
    items.sort(key=lambda i: i.get("created", ""))
    return jsonify({"items": items, "count": len(items)})


@app.route("/api/items/lookup", methods=["POST"])
def lookup_items():
    """Bulk lookup. Body: {"ids": ["JN6EE", "FVVMA", ...]}.
    Returns: {"JN6EE": {"exists": true, "type": "container", ...},
              "FVVMA": {"exists": false}, ...}.
    Used by the inventory app to color-code multiple QRs on screen."""
    body = request.get_json(silent=True) or {}
    ids = body.get("ids") or []
    if not isinstance(ids, list):
        abort(400, description="ids must be a list")
    if len(ids) > 100:
        abort(400, description="too many ids (max 100)")
    reg = _load_registry()
    out = {}
    for raw_id in ids:
        if not isinstance(raw_id, str): continue
        rid = raw_id.upper().strip()
        rec = reg.get(rid)
        if rec:
            out[rid] = {
                "exists": True,
                "type": rec.get("type", "unknown"),
                "description": rec.get("description"),
                "location": rec.get("location"),
                "location_property": rec.get("location_property"),
                "location_room": rec.get("location_room"),
                "location_spot": rec.get("location_spot"),
                "bin_id": rec.get("bin_id"),
                "lines": rec.get("lines"),  # original label lines from Label Forge
            }
        else:
            out[rid] = {"exists": False}
    return jsonify(out)


@app.route("/api/locations", methods=["GET"])
def list_locations():
    """Return autocomplete suggestions for each hierarchical location level.
    Optionally filters by parent field (e.g. rooms_in?property=Home returns
    just the rooms used at the Home property).

    Returns: {
      "properties": [{"name": "Home", "uses": 24}, ...],
      "rooms":      [{"name": "Garage", "uses": 12}, ...],
      "spots":      [{"name": "Shelf 2", "uses": 4}, ...],
      "legacy":     ["Old single-field location 1", ...]  # for migration
    }
    """
    reg = _load_registry()
    props, rooms, spots, legacy_set = {}, {}, {}, {}
    # Optional parent filtering (e.g. ?property=Home returns only rooms at Home)
    filter_prop = (request.args.get("property") or "").strip().lower()
    filter_room = (request.args.get("room") or "").strip().lower()
    for rec in reg.values():
        if rec.get("type") != "bin":
            continue
        p = (rec.get("location_property") or "").strip()
        r = (rec.get("location_room") or "").strip()
        s = (rec.get("location_spot") or "").strip()
        legacy = (rec.get("location") or "").strip()
        if legacy and not (p or r or s):
            legacy_set[legacy] = legacy_set.get(legacy, 0) + 1
        if p:
            props[p] = props.get(p, 0) + 1
        if r and (not filter_prop or p.lower() == filter_prop):
            rooms[r] = rooms.get(r, 0) + 1
        if s and (not filter_prop or p.lower() == filter_prop) \
              and (not filter_room or r.lower() == filter_room):
            spots[s] = spots.get(s, 0) + 1

    def sorted_list(d):
        return [{"name": k, "uses": v}
                for k, v in sorted(d.items(), key=lambda kv: (-kv[1], kv[0].lower()))]

    return jsonify({
        "properties": sorted_list(props),
        "rooms":      sorted_list(rooms),
        "spots":      sorted_list(spots),
        "legacy":     sorted_list(legacy_set),
    })


@app.route("/api/stats", methods=["GET"])
def stats():
    """Quick counts for the home page."""
    reg = _load_registry()
    counts = {"total": len(reg), "bin": 0, "container": 0, "unknown": 0}
    homeless = 0  # containers with no bin assigned
    for rec in reg.values():
        t = rec.get("type") or "unknown"
        counts[t] = counts.get(t, 0) + 1
        if t == "container" and not rec.get("bin_id"):
            homeless += 1
    return jsonify({
        "counts": counts,
        "homeless_containers": homeless,
    })


# ------------------------------------------------------------------
# Error handlers (JSON output)
# ------------------------------------------------------------------

@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(413)
@app.errorhandler(500)
def _json_error(e):
    return jsonify({
        "error": getattr(e, "name", "error"),
        "message": getattr(e, "description", str(e)),
    }), getattr(e, "code", 500)


# ============================================================================
# WIFI MANAGEMENT (NetworkManager via nmcli)
# ============================================================================
# Lets the user configure WiFi from the web UI so the Pi can run wireless after
# initial ethernet bootstrap. Uses nmcli, which is the default on Pi OS Bookworm.
# Older systems using dhcpcd will see "not supported" responses.
#
# Security:
#   - nmcli is invoked via sudo with a narrow sudoers stub (/etc/sudoers.d/...)
#   - passwords are NEVER logged or echoed back; on error we return generic msgs
#   - enterprise (802.1X) networks are filtered out of scan results

import re
import shlex


def _nmcli(*args, timeout=15, capture_password=False):
    """Run an nmcli subcommand via sudo. Returns CompletedProcess.
    If capture_password is True, the args list contains a password that must
    NEVER be logged or echoed; we redact it from any error output."""
    cmd = ["sudo", "-n", "nmcli"] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    except FileNotFoundError:
        return None
    # Redact the password from stderr if it appears
    if capture_password and r.stderr:
        for arg in args:
            if "password" in arg.lower() or len(arg) > 7:
                r.stderr = r.stderr.replace(arg, "***")
    return r


_WIFI_CACHE = {"value": None, "ts": 0, "reason": ""}


def _wifi_available():
    """Check whether nmcli + a wifi device are present.
    Returns (bool, reason_string). The reason explains why if unavailable."""
    import time
    now = time.time()
    if _WIFI_CACHE["value"] is True and now - _WIFI_CACHE["ts"] < 30:
        return True, "ok"
    if _WIFI_CACHE["value"] is False and now - _WIFI_CACHE["ts"] < 5:
        return False, _WIFI_CACHE["reason"]
    r = _nmcli("-t", "-f", "TYPE", "device")
    if r is None:
        reason = "nmcli not installed or subprocess failed (NoNewPrivileges blocks sudo?)"
        _WIFI_CACHE.update(value=False, ts=now, reason=reason)
        return False, reason
    if r.returncode != 0:
        err = (r.stderr or "").strip()[:160]
        if "sudo: a password is required" in err.lower() or "no tty" in err.lower():
            reason = "passwordless sudo for nmcli not configured"
        elif "no new privileges" in err.lower() or "operation not permitted" in err.lower():
            reason = "NoNewPrivileges=true in systemd unit blocks sudo"
        else:
            reason = f"nmcli exit {r.returncode}: {err or 'no error message'}"
        _WIFI_CACHE.update(value=False, ts=now, reason=reason)
        return False, reason
    has_wifi = any(line.strip() == "wifi" for line in r.stdout.splitlines())
    reason = "ok" if has_wifi else "no wifi device in nmcli output"
    _WIFI_CACHE.update(value=has_wifi, ts=now, reason=reason)
    return has_wifi, reason


@app.route("/api/wifi/status", methods=["GET"])
def wifi_status():
    """Current connection state: which network are we on, signal, IP, mode.
    Also detects whether comitup is currently in HOTSPOT (AP) mode, which
    affects how the home page renders."""
    ok, _reason = _wifi_available()
    if not ok:
        return jsonify({"available": False, "reason": _reason})

    # AP-mode detection: comitup running in HOTSPOT state.
    # We try the comitup-cli command first; if it's not installed, fall back
    # to checking for the AP IP on wlan0 (10.41.0.1 is comitup's default).
    ap_mode = False
    ap_ssid = None
    try:
        cr = subprocess.run(
            ["comitup-cli", "i"],
            capture_output=True, text=True, timeout=4,
        )
        if cr.returncode == 0:
            # Output includes lines like "state=HOTSPOT" and "connection=Gridfinity-A2F1"
            for line in cr.stdout.splitlines():
                s = line.strip()
                if s.startswith("state=") and "HOTSPOT" in s.upper():
                    ap_mode = True
                if s.startswith("connection=") and ap_mode:
                    ap_ssid = s.split("=", 1)[1].strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        # comitup-cli not installed (this Pi doesn't have AP bootstrap),
        # or it hung — fall through to address-based detection.
        pass

    if not ap_mode:
        # Address-based fallback: comitup uses 10.41.0.0/24 for its AP
        try:
            ar = subprocess.run(
                ["ip", "-4", "-o", "addr", "show", "dev", "wlan0"],
                capture_output=True, text=True, timeout=3,
            )
            if ar.returncode == 0 and "10.41.0." in ar.stdout:
                ap_mode = True
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

    # Active connections (the NAME field is the connection profile name,
    # which on netplan-managed systems looks like "netplan-wlan0-<SSID>" —
    # not the user-facing SSID. We'll resolve the real SSID below.)
    r = _nmcli("-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active")
    if r is None or r.returncode != 0:
        return jsonify({"available": True, "connected": False, "error": "nmcli failed"})

    wifi_profile = None  # the connection profile name (may be netplan-wlan0-XXX)
    ethernet_active = None
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) < 3: continue
        name, ctype, device = parts[0], parts[1], parts[2]
        if ctype == "802-11-wireless":
            wifi_profile = {"profile": name, "device": device}
        elif ctype == "802-3-ethernet":
            ethernet_active = {"name": name, "device": device}

    # Pull current IP for whatever's primary
    ip_addr = None
    try:
        rip = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3)
        ip_addr = (rip.stdout or "").strip().split()[0] if rip.stdout.strip() else None
    except Exception:
        pass

    # Resolve the real SSID and signal % from the active wifi (if any).
    # We use 'device wifi list' which returns the actual broadcast SSID,
    # then filter to the row marked as in-use (*).
    wifi_active = None
    if wifi_profile:
        ssid = None
        signal = None
        rs = _nmcli("-t", "-f", "IN-USE,SIGNAL,SSID", "device", "wifi", "list")
        if rs and rs.returncode == 0:
            for line in rs.stdout.splitlines():
                # Format: IN-USE:SIGNAL:SSID. SSID may have colons (escaped with \)
                fields = re.split(r"(?<!\\):", line, maxsplit=2)
                if len(fields) >= 3 and fields[0].strip() == "*":
                    try:
                        signal = int(fields[1])
                    except ValueError:
                        pass
                    ssid = fields[2].replace("\\:", ":").strip()
                    break

        # Fallback: ask nmcli for the SSID stored in the connection profile
        if not ssid:
            rp = _nmcli("-t", "-f", "802-11-wireless.ssid", "connection", "show", wifi_profile["profile"])
            if rp and rp.returncode == 0:
                out = (rp.stdout or "").strip()
                if ":" in out:
                    ssid = out.split(":", 1)[1].strip()

        # Last resort: strip the netplan- prefix from the profile name
        if not ssid:
            prof = wifi_profile["profile"]
            if prof.startswith("netplan-"):
                # Format is "netplan-<device>-<ssid>", but device name may have hyphens
                # Trim "netplan-" then trim the leading device name
                tail = prof[len("netplan-"):]
                if tail.startswith(wifi_profile["device"] + "-"):
                    ssid = tail[len(wifi_profile["device"]) + 1:]
                else:
                    ssid = tail
            else:
                ssid = prof

        wifi_active = {"ssid": ssid, "device": wifi_profile["device"], "signal": signal}

    return jsonify({
        "available": True,
        "connected": bool(wifi_active or ethernet_active),
        "wifi": wifi_active,
        "ethernet": ethernet_active,
        "ip": ip_addr,
        "ap_mode": ap_mode,
        "ap_ssid": ap_ssid,
    })


@app.route("/api/wifi/scan", methods=["GET"])
def wifi_scan():
    """Scan for nearby networks. Filters out enterprise (802.1X)."""
    ok, _reason = _wifi_available()
    if not ok:
        return jsonify({"available": False, "networks": []})

    # Force a rescan then list
    _nmcli("device", "wifi", "rescan", timeout=8)
    r = _nmcli("-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE", "device", "wifi", "list")
    if r is None or r.returncode != 0:
        return jsonify({"available": True, "networks": [], "error": "scan failed"})

    seen = {}  # dedupe by SSID, keep strongest signal
    for line in r.stdout.splitlines():
        # Fields: SSID:SIGNAL:SECURITY:IN-USE
        # nmcli escapes colons in SSID with backslash; split with negative lookbehind
        parts = re.split(r"(?<!\\):", line)
        if len(parts) < 4: continue
        ssid = parts[0].replace("\\:", ":").strip()
        if not ssid or ssid == "--":
            continue
        try:
            signal = int(parts[1])
        except ValueError:
            signal = 0
        security = (parts[2] or "").strip()
        in_use = parts[3].strip() == "*"
        # Skip enterprise/802.1X networks - they need extra setup
        if "802.1X" in security or "WPA-EAP" in security or "EAP" in security:
            continue
        # Dedupe
        if ssid in seen and seen[ssid]["signal"] >= signal:
            continue
        seen[ssid] = {
            "ssid": ssid,
            "signal": signal,
            "security": security or "Open",
            "secured": bool(security and security != "--"),
            "in_use": in_use,
        }

    networks = sorted(seen.values(), key=lambda n: -n["signal"])
    return jsonify({"available": True, "networks": networks})


def _resolve_ssid_for_profile(profile_name, device_name=None):
    """Given a NetworkManager connection profile name, return the actual SSID.
    On netplan-managed systems the profile name is something like
    'netplan-wlan0-MyNetwork' instead of just 'MyNetwork'.

    Strategy: ask nmcli for the profile's 802-11-wireless.ssid setting.
    Fall back to stripping the 'netplan-<device>-' prefix if that fails."""
    # Primary: query nmcli for the stored SSID
    r = _nmcli("-t", "-f", "802-11-wireless.ssid", "connection", "show", profile_name)
    if r and r.returncode == 0:
        # Output is "802-11-wireless.ssid:MyNetwork"
        line = (r.stdout or "").strip()
        if ":" in line:
            ssid = line.split(":", 1)[1].strip()
            if ssid:
                return ssid

    # Fallback: strip netplan prefix
    if profile_name.startswith("netplan-"):
        tail = profile_name[len("netplan-"):]
        if device_name and tail.startswith(device_name + "-"):
            return tail[len(device_name) + 1:]
        # Strip any 'wlanN-' prefix as a generic fallback
        import re as _re
        m = _re.match(r"^wlan\d+-(.+)$", tail)
        if m:
            return m.group(1)
        return tail

    return profile_name


@app.route("/api/wifi/saved", methods=["GET"])
def wifi_saved():
    """List saved (autoconnect) WiFi profiles. Display name is the actual SSID,
    not the netplan-mangled profile name.

    Filters out comitup's internal AP profiles (e.g. 'comitup-203') and any
    hotspot/AP profiles — these are infrastructure, not user-chosen networks,
    and showing them confuses the user."""
    ok, _reason = _wifi_available()
    if not ok:
        return jsonify({"available": False, "networks": []})

    r = _nmcli("-t", "-f", "NAME,TYPE,AUTOCONNECT", "connection", "show")
    if r is None or r.returncode != 0:
        return jsonify({"available": True, "networks": [], "error": "list failed"})

    out = []
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) < 3: continue
        profile_name, ctype, autoconnect = parts[0], parts[1], parts[2]
        if ctype != "802-11-wireless": continue

        # Skip comitup's internal AP profiles
        if profile_name.startswith("comitup-"):
            continue

        # Skip any profile in AP/hotspot mode (we manage those, not the user)
        mr = _nmcli("-t", "-f", "802-11-wireless.mode", "connection", "show", profile_name)
        if mr and mr.returncode == 0:
            mode = (mr.stdout or "").strip().split(":", 1)[-1].lower()
            if mode in ("ap", "adhoc"):
                continue

        ssid = _resolve_ssid_for_profile(profile_name)
        out.append({
            "name": ssid,                # what we DISPLAY to the user
            "profile": profile_name,     # what we PASS BACK for forget/edit ops
            "autoconnect": autoconnect.lower() == "yes",
        })
    return jsonify({"available": True, "networks": out})


@app.route("/api/wifi/connect", methods=["POST"])
def wifi_connect():
    """Save WiFi credentials and reboot. We don't try to live-switch from
    AP mode -> client mode because that race-conditions with comitup's own
    state machine and frequently leaves the Pi stuck mid-transition.

    Instead:
      1. Save (or create) the connection profile for this SSID + password
      2. Mark it autoconnect=yes so comitup picks it up on next boot
      3. Schedule a reboot in 5 seconds (via systemd-run so we can return
         a response to the captive portal before going down)
      4. On reboot, comitup sees the saved profile and connects to it.
         AP mode goes away naturally.

    The password is sent over HTTPS only. We never log or echo it.
    """
    ok, _reason = _wifi_available()
    if not ok:
        abort(400, description="WiFi not available on this device")

    body = request.get_json(silent=True) or {}
    ssid = (body.get("ssid") or "").strip()
    password = body.get("password") or ""
    if not ssid:
        abort(400, description="ssid required")
    if len(ssid) > 64:
        abort(400, description="ssid too long")
    if password and (len(password) < 8 or len(password) > 128):
        abort(400, description="password length must be 8-128 chars (WPA requirement)")

    # Step 1: Clean up any existing profile for this SSID so we build fresh.
    # This avoids nmcli's "key-mgmt property is missing" error which happens
    # when there's a partial profile from a previous attempt.
    list_r = _nmcli("-t", "-f", "NAME,TYPE", "connection", "show")
    if list_r and list_r.returncode == 0:
        for line in list_r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) < 2: continue
            profile_name, ctype = parts[0], parts[1]
            if ctype != "802-11-wireless": continue
            # Don't touch comitup's own AP profiles
            if profile_name.startswith("comitup-"): continue
            existing_ssid = _resolve_ssid_for_profile(profile_name)
            if existing_ssid == ssid:
                _nmcli("connection", "delete", profile_name, timeout=10)

    # Step 2: Add a new connection profile. This stores the SSID and password
    # but doesn't activate it. We choose security type WPA-PSK if a password
    # was provided, none otherwise.
    add_args = [
        "connection", "add",
        "type", "wifi",
        "ifname", "wlan0",
        "con-name", ssid,
        "ssid", ssid,
        "connection.autoconnect", "yes",
        "connection.autoconnect-priority", "10",
    ]
    if password:
        add_args += [
            "wifi-sec.key-mgmt", "wpa-psk",
            "wifi-sec.psk", password,
        ]
    r = _nmcli(*add_args, timeout=15, capture_password=True)
    if r is None or r.returncode != 0:
        err = (r.stderr if r else "nmcli unavailable") or "profile add failed"
        return jsonify({"ok": False, "error": err.strip()}), 500

    # Step 3: Schedule a reboot in 5 seconds. systemd-run makes the reboot
    # command outlive the gunicorn worker so we can return our JSON response
    # to the captive portal browser first.
    try:
        rb = subprocess.run(
            ["sudo", "-n", "systemd-run",
             "--unit=gridfinity-reboot-runner",
             "--collect",
             "--no-block",
             "--on-active=5",   # delay 5 seconds before firing
             "/sbin/reboot"],
            capture_output=True, text=True, timeout=10,
        )
        if rb.returncode != 0:
            # Fallback: try direct reboot without delay if systemd-run failed
            subprocess.Popen(
                ["sudo", "-n", "/sbin/reboot"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
    except Exception:
        pass

    return jsonify({
        "ok": True,
        "ssid": ssid,
        "rebooting": True,
        "message": "Saved. The Pi will reboot in 5 seconds and connect to your WiFi.",
    })


@app.route("/api/wifi/saved/<path:ssid>", methods=["DELETE"])
def wifi_forget(ssid):
    """Forget a saved WiFi network. The URL param is treated as either the
    nmcli profile name OR the SSID — we try the literal value first, and if
    that doesn't match anything, we look up the profile by SSID."""
    ok, _reason = _wifi_available()
    if not ok:
        abort(400, description="WiFi not available")
    target = ssid.strip()
    if not target:
        abort(400, description="ssid required")

    # Try the literal target first (might be the profile name already)
    r = _nmcli("connection", "delete", target, timeout=10)
    if r and r.returncode == 0:
        return jsonify({"ok": True})

    # That failed - the target might be the SSID, so resolve to a profile name
    list_r = _nmcli("-t", "-f", "NAME,TYPE", "connection", "show")
    if list_r and list_r.returncode == 0:
        for line in list_r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) < 2: continue
            profile_name, ctype = parts[0], parts[1]
            if ctype != "802-11-wireless": continue
            if _resolve_ssid_for_profile(profile_name) == target:
                r2 = _nmcli("connection", "delete", profile_name, timeout=10)
                if r2 and r2.returncode == 0:
                    return jsonify({"ok": True})

    err = (r.stderr if r else "not found") or "delete failed"
    return jsonify({"ok": False, "error": err.strip()}), 400


# ============================================================================
# UPDATE SYSTEM
# ============================================================================
# The Pi keeps a persistent git clone at /opt/gridfinity/src/. We can check
# whether origin/main has commits we don't have, and apply them via update.sh.
#
# Update state is cached at /var/lib/gridfinity/update-cache.json so the home
# page doesn't have to hit GitHub on every load. A daily cron refreshes it,
# but users can force a check via /api/system/update-check?refresh=1.

SRC_DIR = "/opt/gridfinity/src"
UPDATE_CACHE = DATA_DIR / "update-cache.json"
UPDATE_SCRIPT = "/opt/gridfinity/update.sh"


def _git(*args, cwd=SRC_DIR, timeout=15):
    """Run a git subcommand in the src dir. Returns CompletedProcess or None."""
    try:
        return subprocess.run(
            ["git"] + list(args),
            cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def _git_short(commit):
    return (commit or "")[:7]


def _read_update_cache():
    """Read the cached update state. Returns dict or None."""
    try:
        with open(UPDATE_CACHE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _write_update_cache(data):
    """Persist update state to disk."""
    try:
        with open(UPDATE_CACHE, "w") as f:
            json.dump(data, f)
    except OSError:
        pass


def _check_for_updates(do_fetch=True):
    """Probe the local git clone for available updates.
    Returns a dict with the current state, suitable for caching and serving
    to the home page."""
    import time

    if not Path(SRC_DIR).exists():
        return {
            "available": False,
            "supported": False,
            "reason": "No git source directory at /opt/gridfinity/src — install via newer install.sh",
            "checked_at": int(time.time()),
        }

    if do_fetch:
        # Try to fetch the latest refs from origin. If offline, we'll fall
        # back to whatever the last fetch saw.
        _git("fetch", "--quiet", "origin", timeout=20)

    r_local = _git("rev-parse", "HEAD")
    r_remote = _git("rev-parse", "origin/main")
    if not r_local or not r_remote or r_local.returncode != 0 or r_remote.returncode != 0:
        return {
            "available": False,
            "supported": True,
            "reason": "Could not read git refs (no network?)",
            "checked_at": int(time.time()),
        }

    local = r_local.stdout.strip()
    remote = r_remote.stdout.strip()

    # How many commits is local behind?
    r_count = _git("rev-list", "--count", f"{local}..{remote}")
    behind = 0
    if r_count and r_count.returncode == 0:
        try:
            behind = int(r_count.stdout.strip())
        except ValueError:
            behind = 0

    # Try to pull a remote version string from backend file if it differs.
    # We grep for the APP_VERSION assignment in the remote file via git show.
    remote_version = None
    r_show = _git("show", f"origin/main:backend/gridfinity_backend.py")
    if r_show and r_show.returncode == 0:
        import re as _re
        m = _re.search(r'^APP_VERSION\s*=\s*"([^"]+)"', r_show.stdout, _re.MULTILINE)
        if m:
            remote_version = m.group(1)

    return {
        "available": behind > 0,
        "supported": True,
        "current_hash": _git_short(local),
        "latest_hash": _git_short(remote),
        "commits_behind": behind,
        "current_version": APP_VERSION,
        "latest_version": remote_version or APP_VERSION,
        "checked_at": int(time.time()),
    }


@app.route("/api/system/update-check", methods=["GET"])
def system_update_check():
    """Return cached update status, or refresh if ?refresh=1."""
    refresh = request.args.get("refresh", "").lower() in ("1", "true", "yes")
    if refresh:
        data = _check_for_updates(do_fetch=True)
        _write_update_cache(data)
        return jsonify(data)
    # Serve from cache if recent (less than 24h), else refresh
    cache = _read_update_cache()
    import time
    if cache and (int(time.time()) - cache.get("checked_at", 0)) < 86400:
        cache["from_cache"] = True
        return jsonify(cache)
    data = _check_for_updates(do_fetch=True)
    _write_update_cache(data)
    return jsonify(data)


@app.route("/api/system/update", methods=["POST"])
def system_update():
    """Run update.sh. The service will restart mid-call so the response
    may never reach the client — that's expected. The client should poll
    /api/health afterwards to detect when it comes back up.

    We use systemd-run to launch update.sh as a transient unit so it
    survives the systemctl restart that update.sh itself triggers. If we
    spawned with subprocess.Popen, update.sh would be a child of gunicorn,
    and gunicorn dies when the service restarts — killing update.sh
    half-way through (silent failure).
    """
    if not Path(UPDATE_SCRIPT).exists():
        return jsonify({"ok": False, "error": "update.sh not present — run a fresh install"}), 500

    # systemd-run --unit=... creates a transient service that's owned by
    # systemd (PID 1), so it can outlive the gunicorn worker that requested it.
    # --collect cleans up the unit after it finishes.
    try:
        r = subprocess.run(
            ["sudo", "-n", "systemd-run",
             "--unit=gridfinity-update-runner",
             "--collect",
             "--no-block",
             "/bin/bash", UPDATE_SCRIPT],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            return jsonify({"ok": False, "error": f"systemd-run failed: {r.stderr.strip()}"}), 500
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

    # Clear the cache so next check picks up the new version
    try:
        UPDATE_CACHE.unlink()
    except FileNotFoundError:
        pass

    return jsonify({"ok": True, "message": "Update started — service will restart in ~10s"})


if __name__ == "__main__":
    # For development only. In production, use gunicorn (see systemd unit).
    app.run(host="127.0.0.1", port=8765, debug=False)
