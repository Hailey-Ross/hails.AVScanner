# hails.AVScanner (ALPHA)

Scan nearby avatars in Second Life, collect visible attachment data, and stream it to a backend for storage and analysis.

> ⚠️ **THIS PROJECT IS CURRENTLY IN ALPHA**
>
> Expect bugs, incomplete features, and structural changes.
> Do NOT rely on this for production use of any kind.

---

## Project Overview

`hails.AVScanner` is an attachment scanning system designed to:

- Scan avatars in a region
- Collect visible attachment data
- Send structured data to a backend API
- Track changes over time

This is a **data collection layer**, not a full platform (yet).

---

## Current State (ALPHA)

- Core scanning logic implemented
- Per-avatar processing (memory-safe)
- HTTP batching with throttle handling
- Database ingestion endpoint functional
- Basic schema for current + historical data

Still evolving:
- Data normalization
- Visualization workflows
- Performance tuning
- Edge case handling

---

## What You'll Need

- **Second Life**
  - Obviously.
- **Webserver**
  - Apache or Nginx recommended
- **Database**
  - MySQL / MariaDB
- **PHP**
  - PHP 8+ recommended

---

## LIMITATIONS

- Only **public attachments** are visible
  - HUD attachments are NOT accessible
- Dependent on LSL memory limits
- Subject to HTTP throttling
- String handling in LSL is fragile (be cautious)

---

## CRITICAL SECURITY NOTES

- **ALL config files MUST be stored outside your web root**
- **DO NOT expose your API key**
- **DO NOT log raw payloads publicly**
- **NEVER trust incoming data without validation**

> If your API endpoint or config is publicly exposed, your system is compromised.

---

## System Architecture

### 1. LSL Scanner
- `hails.AVScanner`
- Runs in-world (HUD or object)
- Collects:
  - avatar UUID
  - avatar name
  - attachment UUID
  - attachment name
  - attachment description
  - attachment point

### 2. API Layer
- `attachments_ingest.php`
- Accepts JSON payloads
- Validates and processes incoming data

### 3. Database Layer

#### `attachments_current`
Stores latest known state of attachments

#### `stale_attachments`
Stores previous versions when changes occur

---

## Data Flow

1. LSL scans avatars in region
2. Processes one avatar at a time (memory-safe)
3. Sends small batches via HTTP
4. API validates + stores data
5. Changes move old data → `stale_attachments`

---

## Behavior

- Scans entire region
- Processes avatars sequentially
- Sends data in small batches
- Handles HTTP throttling automatically
- Waits 30 seconds after scan completion
- Repeats continuously

---

## Setup Instructions

### 1. Configure API Endpoint

Set in LSL script:

```
string API_URL = "https://yourdomain.com/attachments_ingest.php";
string API_KEY = "YOUR-SECRET-KEY";
```

---

### 2. Configure Backend

Ensure:
- API key matches between LSL and PHP
- Database connection is working
- Tables are created

---

### 3. Deploy Script

- Place `hails.AVScanner-Alpha.lsl` into a HUD or object
- Script starts automatically

---

## Debugging

The script outputs:
- Memory usage
- Scan progress
- HTTP responses
- Throttle events

If issues occur, check:

- API response body
- Database connection
- HTTP throttling
- Memory limits

---

## Common Issues

- Stack-Heap Collision (memory overflow)
- HTTP 420 (throttling)
- Corrupted strings (LSL parsing issues)
- Missing attachments (expected behavior)

---

## Future Plans

- Improved data normalization?
- Better batching efficiency?
- Real-time dashboards?
- Advanced analytics?
- Event-based tracking instead of polling?

---

## Notes

- Designed with memory safety first
- Uses incremental processing, not full buffering
- Prioritizes stability over speed (for now)

---

## Final Notes

This is an early-stage system.

Things will change:
- API structure
- Database schema
- LSL logic

If something breaks, check:

- API path
- API key
- DB connectivity
- LSL memory usage
- HTTP throttling

---

Built by Hails ❤️
