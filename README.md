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
| `LSL/hails.AVScanner-Coordinator.lsl` | In-world script for the root prim (Coordinator A) |
| `LSL/hails.AVScanner-Coordinator-B.lsl` | In-world script for the Coordinator B child prim (dual-coordinator mode) |
| `LSL/hails.AVScanner-Deployer.lsl` | In-world script for the root prim; manages remote node script deployment |
| `LSL/hails.AVScanner-Node.lsl` | In-world script for each node child prim |
| `PHP/attachments_ingest.php` | Backend ingest endpoint the nodes POST to |
| `Secure/config.php` | Backend config template (DB credentials + API key); deploy it **outside your web root** |
| `SQL/run_me_first.sql` | Database schema: tables, `sp_process_staging()`, and stats views |
| `SQL/migrate_v1_to_v2.sql` | Upgrade path from the old two-table schema |
| `SQL/scanned-AVs.sql` | Example queries against the stats views (current attachments, wear history, name history) |
| `SQL/grafana/` | Ready-made Grafana panel queries |

---

## Architecture

The system uses a **dual-coordinator + node** model across a multi-prim linkset. The root prim runs Coordinator A and the Deployer; a designated child prim runs Coordinator B; every other child prim runs a Node.

The two coordinators split the node pool by link slot: Coordinator A owns slot-0 nodes (link offset from `NODE_START_LINK` mod `NUM_COORDINATORS` == 0) and Coordinator B owns slot-1 nodes (mod == 1). Coordinator B does not manage the scan queue directly; it requests avatar assignments from Coordinator A one at a time via the inter-coordinator protocol. Both coordinators cap concurrent assignments at `MAX_ACTIVE_WORKERS` (default 10).

Nodes work in parallel on the lookup side, but all nodes share one outbound HTTP budget: LSL throttles `llHTTPRequest` at **25 requests per 20 seconds per object** (the whole linkset, not per script). Nodes automatically pace their sends to stay under it, so throughput comes from batching records per request rather than from adding more prims.

### Scripts

| Script | Role |
|---|---|
| `hails.AVScanner-Coordinator.lsl` | Builds avatar queue, dispatches assignments to slot-0 nodes and to Coordinator B, tracks completion, rescans on timer |
| `hails.AVScanner-Coordinator-B.lsl` | Manages the slot-1 half of the node pool; requests avatar assignments from Coordinator A one at a time |
| `hails.AVScanner-Deployer.lsl` | Runs in the root prim alongside Coordinator A; pushes node scripts to child prims via `llRemoteLoadScriptPin` |
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
| `MSG_SET_PACING` | 6602143 | Coordinator → Nodes | Concurrent worker count for HTTP send pacing (minimum of ready nodes, queued avatars, and `MAX_ACTIVE_WORKERS`), broadcast at scan start and re-broadcast as late-registering workers ramp the count up |
| `MSG_WIPE_NODES` | 7245013 | Coordinator → Nodes | Node-script cleanup in each prim. `str` = script name to keep (cleanup after deploy); empty `str` = delete everything including self (full wipe) |
| `MSG_COORD_REQUEST` | 9341782 | Coord B → Coord A | Coordinator B has a ready node and requests an avatar assignment |
| `MSG_COORD_ASSIGN` | 4862305 | Coord A → Coord B | Coordinator A assigns an avatar UUID to Coordinator B |
| `MSG_COORD_DONE` | 6183947 | Coord B → Coord A | Coordinator B reports a node completed its avatar scan |
| `MSG_COORD_ERROR` | 3729516 | Coord B → Coord A | Coordinator B reports a node failed its avatar scan |
| `MSG_SCAN_STARTED` | 5094821 | Coord A → Coord B | Coordinator A notifies Coordinator B that a new scan cycle has begun |

> **Do not change these to small sequential integers.** Prior incident: small values collided with other scripts sharing the linkset, causing nodes to reset instead of scan.

---

## Data Flow

1. Coordinator A scans the region with `llGetAgentList`
2. Avatars already scanned within the last 3 minutes are skipped (cooldown); the cooldown list is pruned in-place at the start of each cycle to avoid unbounded memory growth
3. Queued avatar UUIDs are dispatched to ready nodes one at a time, with at most `MAX_ACTIVE_WORKERS` (default 10) avatars per coordinator in flight at once. Coordinator A handles slot-0 nodes directly; it also responds to `MSG_COORD_REQUEST` from Coordinator B to serve slot-1 nodes
4. Each node fetches the avatar's attachment list via `llGetAttachedList`
5. Attachment details are POSTed to the API in batches (`MAX_RECORDS_PER_REQUEST`, default 8), with each node spacing its sends by `REQUEST_DELAY * concurrent workers` to respect the object-wide throttle (idle nodes don't count against pacing)
6. The API commits the raw records to `ingest_staging`, then `sp_process_staging()` normalises them into `avatars`, `avatar_names`, `objects`, and `sightings`
7. If a send is throttled or fails in transit (`llHTTPRequest` returns `NULL_KEY`, or HTTP 420/429/499/503), the node backs off with jitter and retries the same chunk
8. Node reports done/error, re-registers as ready, and watchdog timer resets
9. Coordinator A rescans after `RESCAN_DELAY` (default 30s) once all nodes and Coordinator B finish

---

## System Components

### 1. Coordinator A (`hails.AVScanner-Coordinator.lsl`)

- Runs in the root prim of the linkset
- Calls `llGetAgentList(AGENT_LIST_REGION, [])` to build the scan queue
- Skips avatars scanned within `SCAN_COOLDOWN` (180 seconds) to avoid redundant work; prunes the cooldown list in-place at scan start to keep memory flat
- Dispatches avatar UUIDs to slot-0 nodes, capped at `MAX_ACTIVE_WORKERS` (10) concurrent assignments
- Also serves avatar assignments to Coordinator B on demand via `MSG_COORD_REQUEST` / `MSG_COORD_ASSIGN`
- Tracks pending count across both direct nodes and Coordinator B; calls `finish_scan()` when all have reported back
- Listens on **channel 2** for owner chat commands (see Commands section)
- Resets automatically on owner, region, or linkset change
- On linkset change (`CHANGED_LINK`): clears node lists, re-broadcasts `MSG_RESET_NODES`, and re-collects all nodes while preserving cooldown history

### 2. Coordinator B (`hails.AVScanner-Coordinator-B.lsl`)

- Runs in a designated child prim (set `COORD_B_LINK` in all scripts to match its link number)
- Manages slot-1 nodes (link offset from `NODE_START_LINK` mod `NUM_COORDINATORS` == 1)
- Does not manage the avatar scan queue; requests assignments from Coordinator A one at a time via `MSG_COORD_REQUEST` / `MSG_COORD_ASSIGN`
- Caps concurrent assignments at `MAX_ACTIVE_WORKERS` (10); nodes that register while all slots are full wait in the ready pool until a slot frees
- Reports per-avatar completion (`MSG_COORD_DONE` / `MSG_COORD_ERROR`) back to Coordinator A so cooldown records stay centralised in one place

### 3. Node (`hails.AVScanner-Node.lsl`)

- One copy per node child prim; more prims parallelise lookups, but HTTP capacity is fixed per object
- Handles one avatar at a time
- Fetches `llGetAttachedList` and iterates attachments in chunks
- Paces HTTP sends using the concurrent worker count broadcast by Coordinator A (`MSG_SET_PACING`)
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

### 4. API Layer (`attachments_ingest.php`)

- Accepts JSON POST payloads
- Validates API key via `hash_equals`
- Normalises and sanitises all input fields
- Inserts raw rows into `ingest_staging` (committed first, so data is never lost), then calls `sp_process_staging()` to normalise them, retrying briefly on deadlocks between parallel nodes
- If processing still fails, the rows stay in staging and the next ingest call drains them
- Returns counters: `received`, `invalid`, plus `processed=yes|deferred`

### 5. Database (`run_me_first.sql`)

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

### 6. Grafana Queries (`SQL/grafana/`)

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
| `hailsAV deploy` | Push the staged node script from the root prim into every node prim, then report how many nodes registered. Deletes nothing |
| `hailsAV cleanup` | After a verified deploy: purge old node-script versions from the prims (keeping the deployed name), remove the staged copy from the root, and start scanning |
| `hailsAV redeploy` | `deploy`, then automatic `cleanup` if every prim registered; otherwise it leaves everything in place and tells you to run `cleanup` manually |
| `hailsAV deploy-coord` | Push coordinator scripts from the root prim to their respective prims: Coordinator A script to link 1, Coordinator B script to `COORD_B_LINK`. Scanning resumes when the coordinators restart |

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

The coordinator prims do not change color.

---

## What You'll Need

- **Second Life**
- **Multi-prim in-world object**: root prim for Coordinator A and the Deployer, one designated child prim for Coordinator B, and as many additional child prims as you want for Nodes
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

### 4. Configure the Scripts

Set `API_URL` and `API_KEY` in `hails.AVScanner-Node.lsl` to match your backend before placing scripts in-world.

Set `COORD_B_LINK` to the link number of your Coordinator B prim in all three scripts that carry it: Coordinator A, Coordinator B, and the Deployer. All must agree.

### 5. Build the In-World Object

1. Create a linkset: one root prim, one child prim designated as Coordinator B, and as many additional child prims as you want for nodes. Each node prim adds parallel lookup capacity; HTTP throughput is fixed per object, so node count mainly affects how fast large avatar queues drain
2. Note the link number of your Coordinator B prim. Set `COORD_B_LINK` to that value in all three scripts before installing
3. Place `hails.AVScanner-Coordinator.lsl` and `hails.AVScanner-Deployer.lsl` in the **root prim** (link 1)
4. Place `hails.AVScanner-Coordinator-B.lsl` in the **Coordinator B child prim**
5. Place `hails.AVScanner-Node.lsl` in each **remaining child prim**
6. Scripts start automatically; scanning begins immediately with whatever nodes are ready, and the rest join the worker pool as they register (no startup wait)

You can add or remove node prims at any time. `CHANGED_LINK` triggers automatic re-collection of all nodes.

### 6. Deploying Node Script Updates

After the initial manual install, node script upgrades are one chat command:

1. Drop the new versioned node script (e.g. `hails.AVScanner_Node 2.1`) into the **root prim** alongside the Coordinator. Exactly one script starting with `hails.AVScanner_Node` may be present. The staged copy detects it is in the root prim and stays dormant.
2. Say `/2 hailsAV redeploy`. The coordinator pushes the copy into every node prim via `llRemoteLoadScriptPin` (same-named scripts are silently replaced), waits 10 seconds, and reports how many nodes registered. If all of them did, it automatically purges old script versions from the prims and removes the staged root copy; otherwise it leaves everything in place and tells you to say `hailsAV cleanup` once you're satisfied.

The order matters and is deliberate: **deploy first, clean up after verification, never wipe before deploying.** A failed `llRemoteLoadScriptPin` only shouts on the DEBUG_CHANNEL, so node registrations are the only reliable success signal, and nothing is deleted until they confirm the loads worked.

To update coordinator scripts, say `/2 hailsAV deploy-coord`. The Deployer pushes Coordinator A to link 1 and Coordinator B to `COORD_B_LINK`. Scanning pauses while the coordinators restart.

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
| Coordinator A stack-heap collision | Reported as a script error in the viewer. Fixed in the current version by in-place list filtering in `start_scan()`. If it recurs on extremely large sims (200+ avatars), lower `SCAN_COOLDOWN` to keep the cooldown history shorter |
| Coordinator B "Pending" exceeds 10 | Indicates the `MAX_ACTIVE_WORKERS` guard is not applied; ensure the deployed Coordinator B script is current |
| No data in database | Check API key match, PHP error log, DB connectivity |
| `ingest_staging` keeps growing | `sp_process_staging()` is failing outright (occasional `processed=deferred` responses are normal; persistent growth is not). Check the procedure exists and the PHP error log |
| Node stuck blue and not working | The idle heartbeat recovers it within 10 minutes; to recover immediately, reset the object |
| Same avatar scanned every cycle | Check `SCAN_COOLDOWN` (default 180s between rescans of the same avatar) |
| Pacing holds over 20 seconds | Ensure the deployed Coordinator A script is current; older versions double-counted worker count via a `NUM_COORDINATORS` multiplier |

---

Built by Hails ❤️
