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

## Repository Layout

| Path | Contents |
|---|---|
| `LSL/hails.AVScanner-Coordinator.lsl` | In-world script for the root prim |
| `LSL/hails.AVScanner-Node.lsl` | In-world script for each child prim |
| `PHP/attachments_ingest.php` | Backend ingest endpoint the nodes POST to |
| `Secure/config.php` | Backend config template (DB credentials + API key); deploy it **outside your web root** |
| `SQL/run_me_first.sql` | Database schema: tables, `sp_process_staging()`, and stats views |
| `SQL/migrate_v1_to_v2.sql` | Upgrade path from the old two-table schema |
| `SQL/scanned-AVs.sql` | Example queries against the stats views (current attachments, wear history, name history) |
| `SQL/grafana/` | Ready-made Grafana panel queries |

---

## Architecture

The system uses a **coordinator + node** model across a multi-prim linkset. The root prim runs the Coordinator; each child prim runs a Node. Nodes work in parallel on the lookup side, but all nodes share one outbound HTTP budget: LSL throttles `llHTTPRequest` at **25 requests per 20 seconds per object** (the whole linkset, not per script). Nodes automatically pace their sends to stay under it, so throughput comes from batching records per request rather than from adding more prims.

### Scripts

| Script | Role |
|---|---|
| `hails.AVScanner-Coordinator.lsl` | Builds avatar queue, dispatches assignments to ready nodes, tracks completion, rescans on timer |
| `hails.AVScanner-Node.lsl` | Receives one avatar per assignment, collects attachments, POSTs to API in batched chunks, paces sends against the object-wide HTTP throttle with backoff and retry |
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
| `MSG_SET_PACING` | 6602143 | Coordinator → Nodes | Concurrent worker count for HTTP send pacing (min of ready nodes, queued avatars, and `MAX_ACTIVE_WORKERS`), broadcast at scan start and re-broadcast as late-registering workers ramp the count up |
| `MSG_WIPE_NODES` | 7245013 | Coordinator → Nodes | Node-script cleanup in each prim. `str` = script name to keep (cleanup after deploy); empty `str` = delete everything including self (full wipe) |

> **Do not change these to small sequential integers.** Prior incident: small values collided with other scripts sharing the linkset, causing nodes to reset instead of scan.

---

## Data Flow

1. Coordinator scans the region with `llGetAgentList`
2. Avatars already scanned within the last 3 minutes are skipped (cooldown)
3. Queued avatar UUIDs are dispatched to ready nodes one at a time, with at most `MAX_ACTIVE_WORKERS` (default 10) avatars in flight at once
4. Each node fetches the avatar's attachment list via `llGetAttachedList`
5. Attachment details are POSTed to the API in batches (`MAX_RECORDS_PER_REQUEST`, default 8), with each node spacing its sends by `REQUEST_DELAY * concurrent workers` to respect the object-wide throttle (idle nodes don't count against pacing)
6. The API commits the raw records to `ingest_staging`, then `sp_process_staging()` normalises them into `avatars`, `avatar_names`, `objects`, and `sightings`
7. If a send is throttled or fails in transit (`llHTTPRequest` returns `NULL_KEY`, or HTTP 420/429/499/503), the node backs off with jitter and retries the same chunk
8. Node reports done/error, re-registers as ready, and watchdog timer resets
9. Coordinator rescans after `RESCAN_DELAY` (default 30s) once all nodes finish

---

## System Components

### 1. Coordinator (`hails.AVScanner-Coordinator.lsl`)

- Runs in the root prim of the linkset
- Calls `llGetAgentList(AGENT_LIST_REGION, [])` to build the scan queue
- Skips avatars scanned within `SCAN_COOLDOWN` (180 seconds) to avoid redundant work
- Dispatches avatar UUIDs to ready nodes via linked messages, capped at `MAX_ACTIVE_WORKERS` (10) concurrent assignments to avoid burst-flooding the backend
- Tracks pending count; calls `finish_scan()` when all nodes have reported back
- Listens on **channel 2** for owner chat commands (see Commands section)
- Resets automatically on owner, region, or linkset change
- On linkset change (`CHANGED_LINK`): clears node lists, re-broadcasts `MSG_RESET_NODES`, and re-collects all nodes while preserving cooldown history

### 2. Node (`hails.AVScanner-Node.lsl`)

- One copy per child prim; more prims parallelise lookups, but HTTP capacity is fixed per object
- Handles one avatar at a time
- Fetches `llGetAttachedList` and iterates attachments in chunks
- Paces HTTP sends using the concurrent worker count broadcast by the coordinator (`MSG_SET_PACING`)
- Retries throttled or failed sends (`NULL_KEY` return or HTTP 420/429/499/503) with configurable backoff (`THROTTLE_BACKOFF` + jitter), up to `MAX_THROTTLE_RETRIES` consecutive attempts per chunk
- **Idle heartbeat**: an unneeded node sits quiet waiting for work; if no coordinator message arrives within `WATCHDOG_TIMEOUT` (600s / 10 minutes), it turns yellow and re-registers itself automatically
- On linkset change (`CHANGED_LINK`): updates its link number; re-registration follows when the coordinator sends `MSG_RESET_NODES`
- Config values set per-node:

```lsl
string  API_URL                 = "https://yourdomain.com/attachments_ingest.php";
string  API_KEY                 = "YOUR-API-KEY";
integer MAX_RECORDS_PER_REQUEST = 8;
float   REQUEST_DELAY           = 0.9;  // per-object pacing target; node send gap = this * concurrent workers
float   THROTTLE_BACKOFF        = 5.0;  // base backoff on throttle, plus up to 2s jitter
integer MAX_THROTTLE_RETRIES    = 5;
integer WATCHDOG_TIMEOUT        = 600;  // idle heartbeat: re-register after 10 min of coordinator silence
float   READY_GRACE             = 15.0; // how long a node shows Ready (green) before going Idle (purple)
```

### 3. API Layer (`attachments_ingest.php`)

- Accepts JSON POST payloads
- Validates API key via `hash_equals`
- Normalises and sanitises all input fields
- Inserts raw rows into `ingest_staging` (committed first, so data is never lost), then calls `sp_process_staging()` to normalise them, retrying briefly on deadlocks between parallel nodes
- If processing still fails, the rows stay in staging and the next ingest call drains them
- Returns counters: `received`, `invalid`, plus `processed=yes|deferred`

### 4. Database (`run_me_first.sql`)

Normalised schema. UUIDs are stored as `BINARY(16)`; names and descriptions are stored once and referenced by ID.

| Table | Purpose |
|---|---|
| `avatars` | One row per avatar UUID: latest name, first/last seen |
| `avatar_names` | Every name an avatar has been seen with (name history) |
| `objects` | Deduplicated attachment definitions (name + description) |
| `sightings` | One row per (avatar, object, attach point) with a `first_seen`/`last_seen` range. Current state and history in one table |
| `ingest_staging` | Raw landing zone; drained by `sp_process_staging()` on every ingest |

Attachment UUIDs change on every relog/reattach, so an item's identity is its name + description + attach point per avatar. Relogs simply bump `last_seen` on the existing sighting row; renamed or moved items start a new row and the old one stops updating.

#### Stats views

| View | Gives you |
|---|---|
| `v_current_attachments` | What every avatar is wearing right now |
| `v_avatar_stats` | Per avatar: current item count, all-time item count, seen range |
| `v_object_popularity` | Per item: distinct wearers, total sightings, last seen |

A sighting counts as "current" when its `last_seen` is within 10 minutes of the avatar's `last_seen` (a full scan of one avatar completes well inside that window).

### 5. Grafana Queries (`SQL/grafana/`)

Ready-made panel queries for a Grafana dashboard pointed at the scanner database (MySQL data source). Paste them into a panel's SQL editor in **Code** mode.

| File | Panel type | Shows |
|---|---|---|
| `current-attachments-table.sql` | Table | Everything currently worn. Avatars blocked together, most recently active first; each avatar's items in the order their entries were received |
| `avatar-current-attachment-counts.sql` | Table | Per avatar: how many items they are wearing right now, plus last seen |
| `avatar-items-all-time.sql` | Bar/table | Per avatar: distinct items ever seen on them, including items no longer worn |
| `attachment-popularity.sql` | Bar/table | Most popular items, counted by distinct wearers (with total sightings for reference) |
| `scan-activity-timeseries.sql` | Time series | Scan activity over time (`time`/`value` shape); includes a commented variant for first-time discoveries instead |

All of them read from the stats views above, so they stay correct even if the underlying tables change.

---

## Owner Commands (Channel 2)

Type these in local chat on **channel 2** (prefix with `/2`). Only the object owner is heard.

| Command | Effect |
|---|---|
| `hailsAV debug` | Toggle standard debug output on/off (level 0 to 1) |
| `hailsAV debug verbose` | Toggle verbose debug output on/off (level 0 to 2) |
| `hailsAV disable` | Pause scanning after the current cycle completes |
| `hailsAV enable` | Resume scanning |
| `hailsAV wipenodes` | Delete ALL node scripts from the child prims. Must be said twice within 30 seconds to confirm |
| `hailsAV deploy` | Push the staged node script from the root prim into every child prim (same-named scripts are replaced), then report how many nodes registered. Deletes nothing |
| `hailsAV cleanup` | After a verified deploy: purge old node-script versions from the prims (keeping the deployed name), remove the staged copy from the root, and start scanning |
| `hailsAV redeploy` | `deploy`, then automatic `cleanup` if every prim registered; otherwise it leaves everything in place and tells you to run `cleanup` manually |

Debug level is relayed to all nodes automatically via `MSG_SET_DEBUG`.

---

## Debug Levels

| Level | How to set | Output |
|---|---|---|
| `0` (off) | Default; or `hailsAV debug` when already on | Complete silence |
| `1` (standard) | `hailsAV debug` | Scan start/complete, node DONE/ERROR counts, cooldown notices, watchdog events |
| `2` (verbose) | `hailsAV debug verbose` | Everything in level 1, plus per-avatar assignment, HTTP status per chunk, memory readouts, node registration details |

Command acknowledgments (`Debug ON`, `Scanning paused`, etc.) are always shown regardless of level.

---

## Node Status Colors

Each node prim tints itself (`llSetColor`, all sides) to show its state at a glance:

| Color | State | When |
|---|---|---|
| 🟩 Green | Ready | Registered with the coordinator and awaiting an assignment (shown for `READY_GRACE`, 15s, after registering or finishing an avatar) |
| 🟪 Purple | Idle | No assignment arrived during the Ready grace: the node is unneeded and dozes until the 10-minute heartbeat. The coordinator can still assign it work at any time; purple just means "nothing lately" |
| 🟨 Yellow | Re-registering | The heartbeat fired and the node is re-announcing to the coordinator (also the rescue path for a stalled node). Turns blue if work arrives, purple if not |
| 🟦 Blue | Working | Scanning an assigned avatar and sending its data |
| 🟥 Red | Error / aborted | Last scan failed (avatar left the region, throttle retries exhausted) or work was aborted by the coordinator (owner/region change, deploy push) |

Typical lifecycle: green on registration, blue while working, green again for a few seconds after each avatar, then purple once the scan no longer needs it, with a yellow blink every 10 minutes. Red is not sticky: it holds through the Ready grace so you can see it, then fades to purple or gets replaced by the next assignment. A node stuck red or blue past the heartbeat interval is genuinely wedged; reset the object.

The coordinator (root) prim does not change color.

---

## What You'll Need

- **Second Life**
- **Multi-prim in-world object**: root prim for Coordinator, one or more child prims for Nodes
- **Webserver**: Apache or Nginx recommended
- **Database**: MySQL or MariaDB
- **PHP**: PHP 8+ recommended

---

## Setup Instructions

### 1. Database

Run `SQL/run_me_first.sql` to create the database, tables, the `sp_process_staging()` procedure, and the stats views.

If you are upgrading from the old two-table schema, run `SQL/migrate_v1_to_v2.sql` afterwards (see the sequence documented at the top of that file).

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

1. Create a linkset with one root prim and as many child prims as you want parallel nodes (2-4 is a reasonable start)
2. Place `hails.AVScanner-Coordinator.lsl` in the **root prim**
3. Place `hails.AVScanner-Node.lsl` in each **child prim**
4. Scripts start automatically; scanning begins immediately with whatever nodes are ready, and the rest join the worker pool as they register (no startup wait)

You can add or remove node prims at any time. `CHANGED_LINK` triggers automatic re-collection of all nodes.

### 6. Deploying Node Script Updates

After the initial manual install, node script upgrades are one chat command:

1. Drop the new versioned node script (e.g. `hails.AVScanner_Node 2.1`) into the **root prim** alongside the Coordinator. Exactly one script starting with `hails.AVScanner_Node` may be present. The staged copy detects it is in the root prim and stays dormant.
2. Say `/2 hailsAV redeploy`. The coordinator pushes the copy into every child prim via `llRemoteLoadScriptPin` (same-named scripts are silently replaced), waits 10 seconds, and reports how many nodes registered. If all of them did, it automatically purges old script versions from the prims and removes the staged root copy; otherwise it leaves everything in place and tells you to say `hailsAV cleanup` once you're satisfied.

The order matters and is deliberate: **deploy first, clean up after verification, never wipe before deploying.** A failed `llRemoteLoadScriptPin` only shouts on the DEBUG_CHANNEL, so node registrations are the only reliable success signal, and nothing is deleted until they confirm the loads worked.

Notes:

- **One-time bootstrap**: deployment relies on a remote-load PIN that each node script sets on its prim when it first runs (`llSetRemoteScriptAccessPin`). A prim that has never run a current node script (fresh prims, or prims still on a pre-PIN version) must get one manual install first.
- `llRemoteLoadScriptPin` force-sleeps the script 3 seconds per prim, so a large linkset takes a few minutes. Progress is reported every 10 prims.
- A few freshly deployed nodes may miss the first registration window if the linkset is very large; their idle heartbeat re-registers them within 10 minutes (`WATCHDOG_TIMEOUT`), after which `hailsAV cleanup` finishes the upgrade.
- Between `deploy` and `cleanup`, prims may briefly hold both the old and new script versions. Scanning is fully paused for that window: the push aborts in-flight node work (`MSG_ABORT_SCAN`), and touches, `hailsAV enable`, and rescan timers are all refused until `cleanup` finishes the upgrade and restarts scanning.

### 7. Start a Scan

Touch the object. The owner can touch to trigger a manual scan at any time. The system rescans automatically after each cycle completes.

---

## Limitations

- Only **public attachments** are visible; HUD attachments are not accessible
- `llGetAttachedList` requires the avatar to still be in region when the node processes them
- Subject to LSL HTTP throttling: 25 requests per 20 seconds for the whole object plus 1000/20s per owner region-wide (handled via pacing and backoff, but caps total throughput)
- LSL memory limits apply per script (~64KB heap); `MAX_RECORDS_PER_REQUEST = 8` is ~4KB per request body, so there is headroom, but watch free memory in verbose debug before raising it

---

## CRITICAL SECURITY NOTES

- **Store `config.php` outside your web root**
- **Do NOT expose your API key**
- **Do NOT log raw payloads publicly**
- **Never trust incoming data without validation.** The PHP layer normalises all fields.

> If your API endpoint or config is publicly accessible, your system is compromised.

---

## Common Issues

| Symptom | Likely cause |
|---|---|
| Node immediately reports error | Avatar left the region before the node processed them |
| Repeated throttle retries in debug output | The linkset is at its 25 requests/20s object budget; increase `MAX_RECORDS_PER_REQUEST` (fewer requests for the same data) or raise `REQUEST_DELAY`. Adding more node prims will NOT help |
| Repeated `HTTP 499` retries | The web server can't keep up with concurrent POSTs; lower `MAX_ACTIVE_WORKERS` in the Coordinator or check backend/PHP performance |
| Stack-Heap Collision | LSL memory exceeded; reduce `MAX_RECORDS_PER_REQUEST` |
| No data in database | Check API key match, PHP error log, DB connectivity |
| `ingest_staging` keeps growing | `sp_process_staging()` is failing outright (occasional `processed=deferred` responses are normal; persistent growth is not). Check the procedure exists and the PHP error log |
| Node stuck blue and not working | The idle heartbeat recovers it within 10 minutes; to recover immediately, reset the object |
| Same avatar scanned every cycle | Check `SCAN_COOLDOWN` (default 180s between rescans of the same avatar) |

---

Built by Hails ❤️
