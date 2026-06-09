// ── Message protocol constants (must match Coordinator script) ──
integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;

// ── Config ──
// DEBUG levels: 0 = silent, 1 = standard, 2 = verbose
// Controlled by coordinator via MSG_SET_DEBUG relay
string  API_URL                 = "https://YOUR-SITE-HERE.com/attachments_ingest.php";
string  API_KEY                 = "YOUR-API-KEY";
integer DEBUG                   = 0;
integer MAX_RECORDS_PER_REQUEST = 2;
float   REQUEST_DELAY           = 1.0;
float   THROTTLE_BACKOFF        = 2.5;
integer WATCHDOG_TIMEOUT        = 120;  // seconds of coordinator silence before re-registering

vector COLOR_IDLE    = <0.0, 1.0, 0.0>;
vector COLOR_WORKING = <0.0, 0.0, 1.0>;
vector COLOR_ERROR   = <1.0, 0.0, 0.0>;

integer gMyLinkNumber      = 0;
string  gAvatarId          = "";
string  gAvatarName        = "";
list    gAttachments       = [];
integer gAttachmentIndex   = 0;
string  gPendingChunkJson  = "";
key     gActiveRequest     = NULL_KEY;
integer gWaitingToContinue = FALSE;

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
    llSetTimerEvent(0.0);
}

announce_ready()
{
    if (DEBUG >= 1)
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] ANNOUNCE_READY scanning=" + (string)(gAvatarId != ""));
    llSetColor(COLOR_IDLE, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_READY, "", NULL_KEY);
    llSetTimerEvent(WATCHDOG_TIMEOUT);
}

report_done()
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] REPORT_DONE");
    llMessageLinked(LINK_ROOT, MSG_NODE_DONE, "", NULL_KEY);
    llSetTimerEvent(WATCHDOG_TIMEOUT);
}

report_error(string reason)
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] REPORT_ERROR: " + reason);
    llSetColor(COLOR_ERROR, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_ERROR, reason, NULL_KEY);
    llSetTimerEvent(WATCHDOG_TIMEOUT);
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
}

start_avatar_scan(string avatarUuidStr)
{
    if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] START_SCAN: " + avatarUuidStr);
    llSetColor(COLOR_WORKING, ALL_SIDES);

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
        gMyLinkNumber = llGetLinkNumber();
        reset_node_state();
        if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Ready.");
        announce_ready();
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (sender_num != LINK_ROOT) return;

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
            llSetTimerEvent(WATCHDOG_TIMEOUT);
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
        if (request_id != gActiveRequest)
        {
            return;
        }

        gActiveRequest = NULL_KEY;

        if (DEBUG >= 2)
        {
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP " + (string)status);
        }

        if (status == 420)
        {
            if (DEBUG >= 2)
            {
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] Throttled. Retrying in " + (string)THROTTLE_BACKOFF + "s.");
            }
            gWaitingToContinue = TRUE;
            llSetTimerEvent(THROTTLE_BACKOFF);
            return;
        }

        gPendingChunkJson = "";

        if (status < 200 || status >= 300)
        {
            if (DEBUG >= 2)
            {
                llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP error " + (string)status + ". Skipping chunk.");
            }
        }

        gWaitingToContinue = TRUE;
        llSetTimerEvent(REQUEST_DELAY);
    }

    timer()
    {
        llSetTimerEvent(0.0);

        if (gWaitingToContinue)
        {
            gWaitingToContinue = FALSE;

            if (gPendingChunkJson != "")
            {
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
                return;
            }

            send_next_chunk();
            return;
        }

        // Watchdog: no coordinator contact for WATCHDOG_TIMEOUT seconds
        if (DEBUG >= 1) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Watchdog: re-registering.");
        reset_node_state();
        llSetColor(COLOR_WORKING, ALL_SIDES);
        llMessageLinked(LINK_ROOT, MSG_NODE_READY, "", NULL_KEY);
        llSetTimerEvent(WATCHDOG_TIMEOUT);
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
