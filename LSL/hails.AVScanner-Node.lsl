// ── Message protocol constants (must match Coordinator script) ──
integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;
integer MSG_SET_PACING  = 6602143;
integer MSG_WIPE_NODES  = 7245013;

// ── Deployment (must match Coordinator script) ──
// The PIN lets the coordinator push script updates into this prim via
// llRemoteLoadScriptPin. Deploys REPLACE same-named scripts and clean up
// stale versions afterwards; never wipe a prim before deploying into it
// (PIN persistence after a full wipe is undocumented; see debugging.md).
integer DEPLOY_PIN         = 84150193;
string  NODE_SCRIPT_PREFIX = "hails.AVScanner_Node";

// ── Config ──
// DEBUG levels: 0 = silent, 1 = standard, 2 = verbose
// Controlled by coordinator via MSG_SET_DEBUG relay
string  API_URL                 = "https://YOUR-SITE-HERE.com/attachments_ingest.php";
string  API_KEY                 = "YOUR-API-KEY";
integer DEBUG                   = 0;
integer MAX_RECORDS_PER_REQUEST = 8;
// The HTTP throttle is 25 requests/20s for the WHOLE OBJECT, shared by every
// node in the linkset. REQUEST_DELAY is the per-object pacing target; each
// node spaces its sends by REQUEST_DELAY * concurrent workers, where the
// worker count (min of ready nodes and queued avatars) comes from
// MSG_SET_PACING at each scan start.
float   REQUEST_DELAY           = 0.9;
float   THROTTLE_BACKOFF        = 5.0;  // base wait when throttled (plus jitter)
integer MAX_THROTTLE_RETRIES    = 5;    // consecutive throttle retries per chunk
// Idle heartbeat: an unneeded node sits quiet and only re-registers if the
// coordinator hasn't contacted it in this long
integer WATCHDOG_TIMEOUT        = 600;
// How long a node stays Ready (green) waiting for an assignment before it
// concludes it is unneeded and goes Idle (purple)
float   READY_GRACE             = 15.0;

vector COLOR_READY      = <0.0, 1.0, 0.0>;  // green:  registered, awaiting an assignment
vector COLOR_IDLE       = <0.5, 0.0, 1.0>;  // purple: unneeded; dozing in the heartbeat wait
vector COLOR_WORKING    = <0.0, 0.0, 1.0>;  // blue:   scanning an assigned avatar
vector COLOR_ERROR      = <1.0, 0.0, 0.0>;  // red:    error or aborted
vector COLOR_REREGISTER = <1.0, 1.0, 0.0>;  // yellow: re-announcing to the coordinator

integer gMyLinkNumber      = 0;
integer gPayload           = FALSE;  // TRUE when staged in the root prim awaiting deploy; stays dormant
string  gAvatarId          = "";
string  gAvatarName        = "";
list    gAttachments       = [];
integer gAttachmentIndex   = 0;
string  gPendingChunkJson  = "";
key     gActiveRequest     = NULL_KEY;
integer gWaitingToContinue = FALSE;
float   gSendGap           = 0.9;  // min seconds between this node's sends (REQUEST_DELAY * workers); set via MSG_SET_PACING
float   gNextSendTime      = 0.0;  // llGetTime() before which we must not send
integer gThrottleRetries   = 0;
integer gIdlePhase         = 0;    // 0 = working/none, 1 = Ready grace, 2 = Idle heartbeat wait

string json_escape(string s)
{
    s = llDumpList2String(llParseString2List(s, ["\\"], []), "\\\\");
    s = llDumpList2String(llParseString2List(s, ["\""], []), "\\\"");
    return s;
}

string make_record_json(
    string avatarUuid,
    string avatarName,
    string attachmentUuid,
    string attachmentName,
    string attachmentDesc,
    integer attachedPoint
)
{
    return "{"
        + "\"avatar_uuid\":\"" + avatarUuid + "\","
        + "\"avatar_name\":\"" + json_escape(avatarName) + "\","
        + "\"attachment_uuid\":\"" + attachmentUuid + "\","
        + "\"attachment_name\":\"" + json_escape(attachmentName) + "\","
        + "\"attachment_desc\":\"" + json_escape(attachmentDesc) + "\","
        + "\"attached_point\":" + (string)attachedPoint
        + "}";
}

reset_node_state()
{
    gAvatarId          = "";
    gAvatarName        = "";
    gAttachments       = [];
    gAttachmentIndex   = 0;
    gPendingChunkJson  = "";
    gActiveRequest     = NULL_KEY;
    gWaitingToContinue = FALSE;
    gThrottleRetries   = 0;
    gIdlePhase         = 0;
    // gSendGap and gNextSendTime survive resets: pacing tracks the object-wide
    // HTTP budget, which doesn't care about assignment boundaries
    llSetTimerEvent(0.0);
}

announce_ready()
{
    if (DEBUG >= 1)
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] ANNOUNCE_READY scanning=" + (string)(gAvatarId != ""));
    llSetColor(COLOR_READY, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_READY, "", NULL_KEY);
    gIdlePhase = 1;
    llSetTimerEvent(READY_GRACE);
}

report_done()
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] REPORT_DONE");
    llSetColor(COLOR_READY, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_DONE, "", NULL_KEY);
    gIdlePhase = 1;
    llSetTimerEvent(READY_GRACE);
}

report_error(string reason)
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] REPORT_ERROR: " + reason);
    // Stay red through the Ready grace so the error is visible; the idle
    // transition replaces it with purple if no new assignment arrives
    llSetColor(COLOR_ERROR, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_ERROR, reason, NULL_KEY);
    gIdlePhase = 1;
    llSetTimerEvent(READY_GRACE);
}

throttle_backoff(string reason)
{
    gThrottleRetries++;
    if (gThrottleRetries > MAX_THROTTLE_RETRIES)
    {
        reset_node_state();
        report_error("THROTTLED");
        return;
    }

    float delay = THROTTLE_BACKOFF + llFrand(2.0);
    if (DEBUG >= 2)
    {
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Throttled (" + reason
            + "). Retry " + (string)gThrottleRetries + "/" + (string)MAX_THROTTLE_RETRIES
            + " in " + (string)delay + "s.");
    }
    gWaitingToContinue = TRUE;
    llSetTimerEvent(delay);
}

// Send gPendingChunkJson as soon as pacing allows: immediately if this node's
// send gap has elapsed, otherwise after a timer wait
dispatch_pending_chunk()
{
    // Epsilon absorbs timer drift; without it the re-check after a pacing
    // wait often produces a second hold of a few milliseconds
    float wait = gNextSendTime - llGetTime();
    if (wait > 0.05)
    {
        if (DEBUG >= 2)
        {
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] Pacing hold: " + (string)wait + "s");
        }
        gWaitingToContinue = TRUE;
        llSetTimerEvent(wait);
        return;
    }

    gActiveRequest = llHTTPRequest(
        API_URL,
        [
            HTTP_METHOD, "POST",
            HTTP_MIMETYPE, "application/json",
            HTTP_VERIFY_CERT, TRUE,
            HTTP_VERBOSE_THROTTLE, FALSE,
            HTTP_EXTENDED_ERROR, TRUE
        ],
        gPendingChunkJson
    );
    gNextSendTime = llGetTime() + gSendGap;

    if (gActiveRequest == NULL_KEY)
    {
        // Simulator refused the call (object-wide throttle exceeded); no
        // http_response will ever arrive, so resend the same chunk later
        throttle_backoff("NULL_KEY");
    }
}

send_next_chunk()
{
    if (gActiveRequest != NULL_KEY)
    {
        return;
    }

    integer totalAttachments = llGetListLength(gAttachments);

    if (gAttachmentIndex >= totalAttachments)
    {
        reset_node_state();
        report_done();
        return;
    }

    integer added       = 0;
    string  recordsJson = "";

    while (gAttachmentIndex < totalAttachments && added < MAX_RECORDS_PER_REQUEST)
    {
        key attachmentId = llList2Key(gAttachments, gAttachmentIndex);
        gAttachmentIndex++;

        if (attachmentId == NULL_KEY)
        {
            jump next_attachment;
        }

        list details = llGetObjectDetails(
            attachmentId,
            [OBJECT_NAME, OBJECT_DESC, OBJECT_ATTACHED_POINT]
        );

        if (llGetListLength(details) < 3)
        {
            jump next_attachment;
        }

        string  attachmentName = llList2String(details, 0);
        string  attachmentDesc = llList2String(details, 1);
        integer attachedPoint  = llList2Integer(details, 2);

        if (attachmentName == "")
        {
            jump next_attachment;
        }

        string oneRecord = make_record_json(
            gAvatarId,
            gAvatarName,
            (string)attachmentId,
            attachmentName,
            attachmentDesc,
            attachedPoint
        );

        if (recordsJson == "")
        {
            recordsJson = oneRecord;
        }
        else
        {
            recordsJson += "," + oneRecord;
        }

        added++;

@next_attachment;
    }

    if (recordsJson == "")
    {
        if (DEBUG >= 2)
        {
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] Chunk produced 0 records for "
                + gAvatarName + " | processed=" + (string)gAttachmentIndex
                + "/" + (string)totalAttachments);
        }
        if (gAttachmentIndex >= totalAttachments)
        {
            reset_node_state();
            report_done();
        }
        else
        {
            gWaitingToContinue = TRUE;
            llSetTimerEvent(REQUEST_DELAY);
        }
        return;
    }

    gPendingChunkJson = "{\"api_key\":\"" + json_escape(API_KEY) + "\",\"records\":[" + recordsJson + "]}";

    if (DEBUG >= 2)
    {
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Sending " + (string)added
            + " record(s) for " + gAvatarName
            + " | free memory: " + (string)llGetFreeMemory());
    }

    dispatch_pending_chunk();
}

start_avatar_scan(string avatarUuidStr)
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] START_SCAN: " + avatarUuidStr);
    llSetColor(COLOR_WORKING, ALL_SIDES);
    gIdlePhase = 0;
    // Mid-work stall safety net; the HTTP pacing/backoff timers overwrite it
    llSetTimerEvent(WATCHDOG_TIMEOUT);

    key avatarId = (key)avatarUuidStr;

    list attachments = llGetAttachedList(avatarId);

    if (llGetListLength(attachments) == 0)
    {
        if (DEBUG >= 2) llOwnerSay("[Node " + (string)gMyLinkNumber + "] No attachments: " + avatarUuidStr);
        report_done();
        return;
    }

    if (llGetListLength(attachments) == 1)
    {
        string sentinel = llList2String(attachments, 0);
        if (sentinel == "NOT FOUND" || sentinel == "NOT ON REGION")
        {
            if (DEBUG >= 2) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Sentinel '" + sentinel + "': " + avatarUuidStr);
            report_error(sentinel);
            return;
        }
    }

    string avatarName = llKey2Name(avatarId);
    if (avatarName == "")
    {
        avatarName = avatarUuidStr;
    }

    gAvatarId        = avatarUuidStr;
    gAvatarName      = avatarName;
    gAttachments     = attachments;
    gAttachmentIndex = 0;

    if (DEBUG >= 2)
    {
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Scanning: " + gAvatarName
            + " | attachments: " + (string)llGetListLength(gAttachments));
    }

    send_next_chunk();
}

default
{
    state_entry()
    {
        llSetRemoteScriptAccessPin(DEPLOY_PIN);
        gMyLinkNumber = llGetLinkNumber();
        reset_node_state();

        // A copy staged in the root prim (alongside the Coordinator) is a
        // deploy payload, not a worker: stay dormant, never announce or scan
        if (gMyLinkNumber == 1 && llGetNumberOfPrims() > 1)
        {
            gPayload = TRUE;
            return;
        }

        if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Ready.");
        announce_ready();
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (gPayload) return;
        if (sender_num != LINK_ROOT) return;

        if (num == MSG_SET_DEBUG)
        {
            DEBUG = (integer)str;
            return;
        }

        if (num == MSG_SET_PACING)
        {
            integer workerCount = (integer)str;
            if (workerCount < 1) workerCount = 1;
            gSendGap = REQUEST_DELAY * (float)workerCount;
            if (DEBUG >= 2)
            {
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] Pacing: "
                    + (string)workerCount + " concurrent workers, send gap " + (string)gSendGap + "s");
            }
            return;
        }

        if (num == MSG_RESET_NODES)
        {
            if (DEBUG >= 1)
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] RESET from link " + (string)sender_num);
            reset_node_state();
            announce_ready();
            return;
        }

        if (num == MSG_ABORT_SCAN)
        {
            reset_node_state();
            // Red through the heartbeat wait, then re-register (yellow)
            llSetColor(COLOR_ERROR, ALL_SIDES);
            gIdlePhase = 2;
            llSetTimerEvent(WATCHDOG_TIMEOUT);
            return;
        }

        if (num == MSG_ASSIGN)
        {
            start_avatar_scan((string)id);
            return;
        }

        if (num == MSG_WIPE_NODES)
        {
            // str carries the script name to KEEP ("" = full wipe).
            // Cleanup pass (str set): old versions delete only themselves;
            // the kept version sweeps any other stale copies in its prim.
            // Full wipe (str empty): delete every node script, self last
            // because llRemoveInventory on self ends execution.
            string keepName = str;
            string self     = llGetScriptName();

            if (keepName != "" && self != keepName)
            {
                llRemoveInventory(self);
                return;
            }

            // Iterate backwards: removing items shifts inventory indices
            integer i;
            for (i = llGetInventoryNumber(INVENTORY_SCRIPT) - 1; i >= 0; i--)
            {
                string itemName = llGetInventoryName(INVENTORY_SCRIPT, i);
                if (itemName != self && itemName != keepName
                    && llSubStringIndex(itemName, NODE_SCRIPT_PREFIX) == 0)
                {
                    llRemoveInventory(itemName);
                }
            }
            if (keepName == "")
            {
                llRemoveInventory(self);
            }
            return;
        }
    }

    http_response(key request_id, integer status, list metadata, string body)
    {
        if (request_id != gActiveRequest)
        {
            return;
        }

        gActiveRequest = NULL_KEY;

        if (DEBUG >= 2)
        {
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP " + (string)status);
        }

        // 499 is SL's "request failed" (connection timeout/refused), typically
        // the backend buckling under a burst; the chunk is intact, so retry it
        if (status == 420 || status == 429 || status == 499 || status == 503)
        {
            throttle_backoff("HTTP " + (string)status);
            return;
        }

        gPendingChunkJson = "";
        gThrottleRetries  = 0;

        if (status < 200 || status >= 300)
        {
            if (DEBUG >= 2)
            {
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP error " + (string)status + ". Skipping chunk.");
            }
        }

        // Pacing is enforced inside dispatch_pending_chunk, so no fixed
        // inter-chunk delay is needed here
        send_next_chunk();
    }

    timer()
    {
        llSetTimerEvent(0.0);

        if (gWaitingToContinue)
        {
            gWaitingToContinue = FALSE;

            if (gPendingChunkJson != "")
            {
                dispatch_pending_chunk();
                return;
            }

            send_next_chunk();
            return;
        }

        if (gIdlePhase == 1)
        {
            // Ready grace expired with no assignment: we are unneeded, doze
            // until the heartbeat. The coordinator may still assign us work
            // at any time; purple only means "nothing lately".
            gIdlePhase = 2;
            llSetColor(COLOR_IDLE, ALL_SIDES);
            if (DEBUG >= 2) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Idle.");
            llSetTimerEvent(WATCHDOG_TIMEOUT);
            return;
        }

        // Heartbeat (Idle wait elapsed) or stalled work: re-register.
        // Yellow holds until an assignment arrives (blue) or the Ready
        // grace expires (purple).
        if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Re-registering.");
        reset_node_state();
        llSetColor(COLOR_REREGISTER, ALL_SIDES);
        llMessageLinked(LINK_ROOT, MSG_NODE_READY, "", NULL_KEY);
        gIdlePhase = 1;
        llSetTimerEvent(READY_GRACE);
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }

    changed(integer change)
    {
        if (change & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START))
        {
            llResetScript();
        }
        else if (change & CHANGED_LINK)
        {
            // Link numbers shift when prims are linked/unlinked — update ours
            // Coordinator will send MSG_RESET_NODES which triggers re-registration
            gMyLinkNumber = llGetLinkNumber();
        }
    }
}
