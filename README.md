# hails.AVScanner

Scan nearby avatars in Second Life, collect visible attachment data, and stream it to a backend for storage and analysis.

---

## Project Overview

`hails.AVScanner` is an attachment scanning system designed to:

- Scan all avatars in a region
- Collect visible attachment data per avatar
- Send structured data to a backend API
- Track changes over time via historical records

---

## Architecture

The system uses a **coordinator + node** model across a multi-prim linkset. The root prim runs the Coordinator; each child prim runs a Node. Nodes work in parallel — more child prims means more concurrent workers.

### Scripts

| Script | Role |
|---|---|
| `hails.AVScanner-Coordinator.lsl` | Builds avatar queue, dispatches assignments to ready nodes, tracks completion, rescans on timer |
| `hails.AVScanner-Node.lsl` | Receives one avatar per assignment, collects attachments, POSTs to API in small chunks, handles HTTP 420 throttle backoff and retry |
| ~~`hails.AVScanner-Alpha.lsl`~~ | **Deprecated. Do not use.** Replaced by the coordinator/node system. |

### Communication

Coordinator and nodes communicate via `llMessageLinked` using large random integer constants to avoid collisions with other scripts in the linkset:

| Constant | Value | Direction | Meaning |
|---|---|---|---|
| `MSG_NODE_READY` | 3101520 | Node → Coordinator | Node is idle and ready for work |
| `MSG_ASSIGN` | 5676979 | Coordinator → Node | Assign an avatar UUID to scan |
| `MSG_NODE_DONE` | 2195870 | Node → Coordinator | Avatar scan completed successfully |
| `MSG_NODE_ERROR` | 8190093 | Node → Coordinator | Avatar scan failed (avatar left, no attachments, etc.) |
| `MSG_RESET_NODES` | 1210977 | Coordinator → Nodes | Reset all node state on startup or linkset change |
| `MSG_ABORT_SCAN` | 2798014 | Coordinator → Nodes | Abort current work (owner/region change) |
| `MSG_SET_DEBUG` | 4927361 | Coordinator → Nodes | Relay debug level change to all nodes |

> **Do not change these to small sequential integers.** Prior incident: small values collided with other scripts sharing the linkset, causing nodes to reset instead of scan.

---

## Data Flow

1. Coordinator scans the region with `llGetAgentList`
2. Avatars already scanned within the last 3 minutes are skipped (cooldown)
3. Queued avatar UUIDs are dispatched to ready nodes one at a time
4. Each node fetches the avatar's attachment list via `llGetAttachedList`
5. Attachment details are POSTed to the API in small batches (`MAX_RECORDS_PER_REQUEST`)
6. On HTTP 420 throttle, the node backs off and retries the same chunk
7. Node reports done/error, re-registers as ready, and watchdog timer resets
8. Coordinator rescans after `RESCAN_DELAY` (default 30s) once all nodes finish

---

## System Components

### 1. Coordinator (`hails.AVScanner-Coordinator.lsl`)

- Runs in the root prim of the linkset
- Calls `llGetAgentList(AGENT_LIST_REGION, [])` to build the scan queue
- Skips avatars scanned within `SCAN_COOLDOWN` (180 seconds) to avoid redundant work
- Dispatches avatar UUIDs to ready nodes via linked messages
- Tracks pending count; calls `finish_scan()` when all nodes have reported back
- Listens on **channel 2** for owner chat commands (see Commands section)
- Resets automatically on owner, region, or linkset change
- On linkset change (`CHANGED_LINK`): clears node lists, re-broadcasts `MSG_RESET_NODES`, and re-collects all nodes — preserving cooldown history

### 2. Node (`hails.AVScanner-Node.lsl`)

- One copy per child prim; scales horizontally
- Handles one avatar at a time
- Fetches `llGetAttachedList` and iterates attachments in chunks
- Retries on HTTP 420 with configurable backoff (`THROTTLE_BACKOFF`)
- **Watchdog timer**: if no coordinator message is received within `WATCHDOG_TIMEOUT` (120s), the node turns blue and re-registers itself automatically
- On linkset change (`CHANGED_LINK`): updates its link number — re-registration follows when coordinator sends `MSG_RESET_NODES`
- Config values set per-node:

```lsl
string  API_URL                 = "https://yourdomain.com/attachments_ingest.php";
string  API_KEY                 = "YOUR-API-KEY";
integer MAX_RECORDS_PER_REQUEST = 2;
float   REQUEST_DELAY           = 1.0;
float   THROTTLE_BACKOFF        = 2.5;
integer WATCHDOG_TIMEOUT        = 120;
```

### 3. API Layer (`attachments_ingest.php`)

- Accepts JSON POST payloads
- Validates API key via `hash_equals`
- Normalises and sanitises all input fields
- Runs inserts/updates in a single transaction per request
- Returns counters: `inserted`, `updated`, `ignored`, `invalid`

### 4. Database (`run_me_first.sql`)

#### `attachments_current`
Latest known state of each attachment per avatar, keyed on `(avatar_uuid, attachment_uuid)`.

#### `stale_attachments`
Historical snapshots moved here whenever an attachment record changes. Links back to `current_row_id`.

---

## Owner Commands (Channel 2)

Type these in local chat on **channel 2** (prefix with `/2`). Only the object owner is heard.

| Command | Effect |
|---|---|
| `hailsAV debug` | Toggle standard debug output on/off (level 0 ↔ 1) |
| `hailsAV debug verbose` | Toggle verbose debug output on/off (level 0 ↔ 2) |
| `hailsAV disable` | Pause scanning after the current cycle completes |
| `hailsAV enable` | Resume scanning |

Debug level is relayed to all nodes automatically via `MSG_SET_DEBUG`.

---

## Debug Levels

| Level | How to set | Output |
|---|---|---|
| `0` (off) | Default; `hailsAV debug` when on | Complete silence |
| `1` (standard) | `hailsAV debug` | Scan start/complete, node DONE/ERROR counts, cooldown notices, watchdog events |
| `2` (verbose) | `hailsAV debug verbose` | Everything in level 1, plus per-avatar assignment, HTTP status per chunk, memory readouts, node registration details |

Command acknowledgments (`Debug ON`, `Scanning paused`, etc.) are always shown regardless of level.

---

## What You'll Need

- **Second Life** obviously
- **Multi-prim in-world object** — root prim for Coordinator, one or more child prims for Nodes
- **Webserver** — Apache or Nginx recommended
- **Database** — MySQL / MariaDB
- **PHP** — PHP 8+ recommended

---

## Setup Instructions

### 1. Database

Run `SQL/run_me_first.sql` to create the database and both tables.

### 2. Backend Config

Edit `Secure/config.php` with your database credentials and a strong API key. Store this file **outside your web root**.

```php
define('DB_SERVER',          'localhost');
define('DB_USERNAME',        'your-db-user');
define('DB_PASSWORD',        'your-db-password');
define('ATTACHMENTS_DB_NAME','your_db_name');
define('ATTACHMENTS_API_KEY','your-secret-key');
```

### 3. Deploy PHP

Upload `PHP/attachments_ingest.php` to your web root. Update the `require_once` path at the top to point at your config file.

### 4. Configure the Node Script

Set `API_URL` and `API_KEY` in `hails.AVScanner-Node.lsl` to match your backend before placing scripts in-world.

### 5. Build the In-World Object

1. Create a linkset — one root prim plus as many child prims as you want parallel nodes (2–4 is a reasonable start)
2. Place `hails.AVScanner-Coordinator.lsl` in the **root prim**
3. Place `hails.AVScanner-Node.lsl` in each **child prim**
4. Scripts start automatically; nodes register with the coordinator during the 3-second startup window

You can add or remove node prims at any time — `CHANGED_LINK` triggers automatic re-collection of all nodes.

### 6. Start a Scan

Touch the object. The owner can touch to trigger a manual scan at any time. The system rescans automatically after each cycle completes.

---

## Limitations

- Only **public attachments** are visible — HUD attachments are not accessible
- `llGetAttachedList` requires the avatar to still be in region when the node processes them
- Subject to LSL HTTP throttling (handled via backoff, but adds latency)
- LSL memory limits apply per script; keep `MAX_RECORDS_PER_REQUEST` small (1–3)

---

## CRITICAL SECURITY NOTES

- **Store `config.php` outside your web root**
- **Do NOT expose your API key**
- **Do NOT log raw payloads publicly**
- **Never trust incoming data without validation** — the PHP layer normalises all fields

> If your API endpoint or config is publicly accessible, your system is compromised.

---

## Common Issues

| Symptom | Likely cause |
|---|---|
| Node immediately reports error | Avatar left the region before the node processed them |
| HTTP 420 loops | Too many nodes hitting the API too fast; increase `REQUEST_DELAY` or reduce node count |
| Stack-Heap Collision | LSL memory exceeded; reduce `MAX_RECORDS_PER_REQUEST` |
| No data in database | Check API key match, PHP error log, DB connectivity |
| Node stuck blue and not working | Watchdog should recover it within 120s; if not, reset the object |
| Same avatar scanned every cycle | Check `SCAN_COOLDOWN` — default is 180s between rescans of the same avatar |

---

Built by Hails
