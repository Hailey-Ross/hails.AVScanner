integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;
integer MSG_SET_PACING  = 6602143;
integer MSG_WIPE_NODES  = 7245013;

integer DEPLOY_PIN         = 84150193;  // must match Coordinator and Deployer
string  NODE_SCRIPT_PREFIX = "hails.AVScanner_Node";

// Dual-coordinator mode: set COORD_B_LINK to the link number of the Coordinator B prim.
// Must match Coordinator A and Deployer constants.
integer NUM_COORDINATORS = 2;
integer NODE_START_LINK  = 2;
integer COORD_A_LINK     = 1;
integer COORD_B_LINK     = 5;

string  API_URL                 = "https://YOUR-SITE-HERE.com/attachments_ingest.php";
string  API_KEY                 = "YOUR-API-KEY";
integer DEBUG                   = 0;  // 0 = off  1 = standard  2 = verbose
integer MAX_RECORDS_PER_REQUEST = 8;
float   REQUEST_DELAY           = 0.9;
float   THROTTLE_BACKOFF        = 5.0;
integer MAX_THROTTLE_RETRIES    = 5;
integer WATCHDOG_TIMEOUT        = 120;
float   READY_GRACE             = 15.0;

vector COLOR_READY      = <0.0, 1.0, 0.0>;
vector COLOR_IDLE       = <0.5, 0.0, 1.0>;
vector COLOR_WORKING    = <0.0, 0.0, 1.0>;
vector COLOR_ERROR      = <1.0, 0.0, 0.0>;
vector COLOR_REREGISTER = <1.0, 1.0, 0.0>;

integer gMyLinkNumber      = 0;
integer gPayload           = FALSE;
string  gAvatarId          = "";
string  gAvatarName        = "";
list    gAttachments       = [];
integer gAttachmentIndex   = 0;
string  gPendingChunkJson  = "";
key     gActiveRequest     = NULL_KEY;
integer gWaitingToContinue = FALSE;
float   gSendGap           = 0.9;
float   gNextSendTime      = 0.0;
integer gThrottleRetries   = 0;
integer gIdlePhase         = 0;
integer gStartupPending    = 0;
integer gCoordLink         = 1;

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
    gNextSendTime      = 0.0;
    llSetTimerEvent(0.0);
}

announce_ready()
{
    gStartupPending = FALSE;
    if (DEBUG >= 1)
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] ANNOUNCE_READY scanning=" + (string)(gAvatarId != ""));
    llSetColor(COLOR_READY, ALL_SIDES);
    llMessageLinked(gCoordLink, MSG_NODE_READY, "", NULL_KEY);
    gIdlePhase = 1;
    llSetTimerEvent(READY_GRACE);
}

report_done()
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] REPORT_DONE");
    llSetColor(COLOR_READY, ALL_SIDES);
    llMessageLinked(gCoordLink, MSG_NODE_DONE, "", NULL_KEY);
    gIdlePhase = 1;
    llSetTimerEvent(READY_GRACE);
}

report_error(string reason)
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] REPORT_ERROR: " + reason);
    llSetColor(COLOR_ERROR, ALL_SIDES);
    llMessageLinked(gCoordLink, MSG_NODE_ERROR, reason, NULL_KEY);
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
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Throttled (" + reason
            + "). Retry " + (string)gThrottleRetries + "/" + (string)MAX_THROTTLE_RETRIES
            + " in " + (string)delay + "s.");
    gWaitingToContinue = TRUE;
    llSetTimerEvent(delay);
}

dispatch_pending_chunk()
{
    float wait = gNextSendTime - llGetTime();
    if (wait > 0.05)
    {
        if (DEBUG >= 2)
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] Pacing hold: " + (string)wait + "s");
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
        throttle_backoff("NULL_KEY");
}

send_next_chunk()
{
    if (gActiveRequest != NULL_KEY)
        return;

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
            jump next_attachment;

        list details = llGetObjectDetails(attachmentId, [OBJECT_NAME, OBJECT_DESC, OBJECT_ATTACHED_POINT]);
        if (llGetListLength(details) < 3)
            jump next_attachment;

        string  attachmentName = llList2String(details, 0);
        string  attachmentDesc = llList2String(details, 1);
        integer attachedPoint  = llList2Integer(details, 2);

        if (attachmentName == "")
            jump next_attachment;

        string oneRecord = make_record_json(
            gAvatarId, gAvatarName, (string)attachmentId,
            attachmentName, attachmentDesc, attachedPoint
        );
        if (recordsJson == "") recordsJson = oneRecord;
        else recordsJson += "," + oneRecord;
        added++;

@next_attachment;
    }

    if (recordsJson == "")
    {
        if (DEBUG >= 2)
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] Chunk 0 records for "
                + gAvatarName + " | " + (string)gAttachmentIndex + "/" + (string)totalAttachments);
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
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Sending " + (string)added
            + " record(s) for " + gAvatarName + " | free: " + (string)llGetFreeMemory());
    dispatch_pending_chunk();
}

start_avatar_scan(string avatarUuidStr)
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] START_SCAN: " + avatarUuidStr);
    llSetColor(COLOR_WORKING, ALL_SIDES);
    gIdlePhase = 0;
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
    if (avatarName == "") avatarName = avatarUuidStr;

    gAvatarId        = avatarUuidStr;
    gAvatarName      = avatarName;
    gAttachments     = attachments;
    gAttachmentIndex = 0;

    if (DEBUG >= 2)
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Scanning: " + gAvatarName
            + " | attachments: " + (string)llGetListLength(gAttachments));
    send_next_chunk();
}

default
{
    state_entry()
    {
        llSetRemoteScriptAccessPin(DEPLOY_PIN);
        gMyLinkNumber = llGetLinkNumber();
        reset_node_state();

        integer i;
        for (i = 0; i < llGetInventoryNumber(INVENTORY_SCRIPT); i++)
        {
            string sName = llGetInventoryName(INVENTORY_SCRIPT, i);
            if (llSubStringIndex(sName, NODE_SCRIPT_PREFIX) != 0
                && llSubStringIndex(sName, "hails.AVScanner_") == 0)
            {
                gPayload = TRUE;
                return;
            }
        }

        if (NUM_COORDINATORS > 1 && gMyLinkNumber == COORD_B_LINK)
        {
            gPayload = TRUE;
            return;
        }

        if (NUM_COORDINATORS > 1)
        {
            if ((gMyLinkNumber - NODE_START_LINK) % NUM_COORDINATORS == 0)
                gCoordLink = COORD_A_LINK;
            else
                gCoordLink = COORD_B_LINK;
        }
        else
        {
            gCoordLink = COORD_A_LINK;
        }

        gStartupPending = TRUE;
        float startDelay = 0.05 * (float)gMyLinkNumber + llFrand(0.5);
        llSetTimerEvent(startDelay);
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (gPayload) return;

        integer fromCoordA  = (sender_num == COORD_A_LINK);
        integer fromMyCoord = (sender_num == gCoordLink);
        if (!fromCoordA && !fromMyCoord) return;

        if (num == MSG_SET_DEBUG)
        {
            DEBUG = (integer)str;
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
            llSetColor(COLOR_ERROR, ALL_SIDES);
            gIdlePhase = 2;
            llSetTimerEvent(WATCHDOG_TIMEOUT);
            return;
        }
        if (num == MSG_WIPE_NODES)
        {
            string keepName = str;
            string self     = llGetScriptName();
            if (keepName != "" && self != keepName)
            {
                llRemoveInventory(self);
                return;
            }
            integer i;
            for (i = llGetInventoryNumber(INVENTORY_SCRIPT) - 1; i >= 0; i--)
            {
                string itemName = llGetInventoryName(INVENTORY_SCRIPT, i);
                if (itemName != self && itemName != keepName
                    && llSubStringIndex(itemName, NODE_SCRIPT_PREFIX) == 0)
                    llRemoveInventory(itemName);
            }
            if (keepName == "") llRemoveInventory(self);
            return;
        }

        if (!fromMyCoord) return;

        if (num == MSG_SET_PACING)
        {
            integer workerCount = (integer)str;
            if (workerCount < 1) workerCount = 1;
            gSendGap = REQUEST_DELAY * (float)workerCount;
            if (DEBUG >= 2)
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] Pacing: "
                    + (string)workerCount + " workers, gap " + (string)gSendGap + "s");
            return;
        }
        if (num == MSG_ASSIGN)
        {
            start_avatar_scan((string)id);
            return;
        }
    }

    http_response(key request_id, integer status, list metadata, string body)
    {
        if (request_id != gActiveRequest) return;
        gActiveRequest = NULL_KEY;
        if (DEBUG >= 2)
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP " + (string)status);
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
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP error " + (string)status + ". Skipping chunk.");
        }
        send_next_chunk();
    }

    timer()
    {
        llSetTimerEvent(0.0);
        if (gStartupPending)
        {
            if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Ready.");
            announce_ready();
            return;
        }
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
            gIdlePhase = 2;
            llSetColor(COLOR_IDLE, ALL_SIDES);
            if (DEBUG >= 2) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Idle.");
            llSetTimerEvent(WATCHDOG_TIMEOUT);
            return;
        }
        if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Re-registering.");
        reset_node_state();
        llSetColor(COLOR_REREGISTER, ALL_SIDES);
        llMessageLinked(gCoordLink, MSG_NODE_READY, "", NULL_KEY);
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
            llResetScript();
        else if (change & CHANGED_LINK)
            gMyLinkNumber = llGetLinkNumber();
    }
}
