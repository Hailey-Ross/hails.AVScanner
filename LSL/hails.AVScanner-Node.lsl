integer MSG_NODE_READY  = 1;
integer MSG_ASSIGN      = 2;
integer MSG_NODE_DONE   = 3;
integer MSG_NODE_ERROR  = 4;
integer MSG_RESET_NODES = 5;
integer MSG_ABORT_SCAN  = 6;

string  API_URL                 = "https://YOUR-SITE-HERE.com/attachments_ingest.php";
string  API_KEY                 = "YOUR-API-KEY";
integer DEBUG                   = TRUE;
integer MAX_RECORDS_PER_REQUEST = 2;
float   REQUEST_DELAY           = 1.0;
float   THROTTLE_BACKOFF        = 2.5;

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
    llSetColor(COLOR_IDLE, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_READY, "", NULL_KEY);
}

report_done()
{
    llMessageLinked(LINK_ROOT, MSG_NODE_DONE, "", NULL_KEY);
    announce_ready();
}

report_error(string reason)
{
    if (DEBUG)
    {
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Error: " + reason);
    }
    llSetColor(COLOR_ERROR, ALL_SIDES);
    llMessageLinked(LINK_ROOT, MSG_NODE_ERROR, reason, NULL_KEY);
    llMessageLinked(LINK_ROOT, MSG_NODE_READY, "", NULL_KEY);
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
        if (DEBUG)
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

    if (DEBUG)
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
    llSetColor(COLOR_WORKING, ALL_SIDES);

    key avatarId = (key)avatarUuidStr;

    list attachments = llGetAttachedList(avatarId);

    if (llGetListLength(attachments) == 0)
    {
        if (DEBUG) llOwnerSay("[Node " + (string)gMyLinkNumber + "] No attachments: " + avatarUuidStr);
        report_done();
        return;
    }

    if (llGetListLength(attachments) == 1)
    {
        string sentinel = llList2String(attachments, 0);
        if (sentinel == "NOT FOUND" || sentinel == "NOT ON REGION")
        {
            if (DEBUG) llOwnerSay("[Node " + (string)gMyLinkNumber + "] Sentinel '" + sentinel + "': " + avatarUuidStr);
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

    if (DEBUG)
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
        llOwnerSay("[Node " + (string)gMyLinkNumber + "] Ready.");
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == MSG_RESET_NODES)
        {
            reset_node_state();
            announce_ready();
            return;
        }

        if (num == MSG_ABORT_SCAN)
        {
            reset_node_state();
            llSetColor(COLOR_ERROR, ALL_SIDES);
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

        if (DEBUG)
        {
            llOwnerSay("[Node " + (string)gMyLinkNumber + "] HTTP " + (string)status);
        }

        if (status == 420)
        {
            if (DEBUG)
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
            if (DEBUG)
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
        }
    }

    changed(integer change)
    {
        if (change & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START))
        {
            llResetScript();
        }
    }
}
