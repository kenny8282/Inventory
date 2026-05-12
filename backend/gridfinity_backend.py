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

APP_VERSION = "1.5.2"  # per-label print timeout 30s -> 60s for batch reliability

# Where data lives. Change with env var if you want a different path.
DATA_DIR = Path(os.environ.get("GFLF_DATA_DIR", "/var/lib/gridfinity"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

# Keys the frontend uses. Any other key would be rejected.
ALLOWED_KEYS = {
    "gflf:used",
    "gflf:registry",
    "gflf:rows",
    "gflf:config",
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

        # Strategy for cuts: every label always gets --precut so its leading
        # edge is cut cleanly (drops the 25mm leader as a single waste piece
        # before printing label 1). For batches, --chain on all but the
        # last label skips the trailing feed so the next label's --precut
        # is the trailing cut of the previous one.
        #
        # ptouch-print v1.8 flag semantics:
        #   --chain   = skip final feed/cut after this label
        #   --precut  = cut tape BEFORE printing this label
        #
        # Single label:
        #   ptouch-print --image L.png --precut
        #   -> feed 25mm leader, CUT (waste), print L, auto-cut at end.
        #   -> Result: 40mm label with clean cuts on both ends.
        #
        # Batch of N labels (clean cuts on both ends of every label):
        #   All labels:      ptouch-print --image Lk.png --precut --chain
        #   Last label:      ptouch-print --image LN.png --precut
        #   -> Only ONE 25mm leader-waste piece for the entire batch.

        all_results = []
        n = len(tmp_paths)
        for c in range(copies):
            for i, p in enumerate(tmp_paths):
                is_last = (i == n - 1)
                cmd = [PTOUCH_BIN, "--image", p, "--precut"]
                if not is_last:
                    cmd.append("--chain")
                r = subprocess.run(
                    cmd,
                    capture_output=True, text=True,
                    timeout=60,  # per-label; ptouch-print can take 5-10s and chained labels longer
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


if __name__ == "__main__":
    # For development only. In production, use gunicorn (see systemd unit).
    app.run(host="127.0.0.1", port=8765, debug=False)
