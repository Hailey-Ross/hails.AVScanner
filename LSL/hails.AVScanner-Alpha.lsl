string API_URL = "https://YOUR-SITE-HERE.com/attachments_ingest.php";
string API_KEY = "YOUR-API-KEY";

integer DEBUG = FALSE;
integer MAX_RECORDS_PER_REQUEST = 2;

float REQUEST_DELAY = 1.0;
float RESCAN_DELAY = 30.0;

list gAgents = [];
integer gAgentIndex = 0;

list gCurrentAttachments = [];
integer gAttachmentIndex = 0;

string gCurrentAvatarId = "";
string gCurrentAvatarName = "";

key gActiveRequest = NULL_KEY;
integer gScanInProgress = FALSE;
integer gWaitingToContinue = FALSE;
integer gWaitingToRescan = FALSE;

owner_say(string msg)
{
    llOwnerSay(msg);
}

// MEH Aplha stuff
//string json_escape(string s)
//{
//    s = llDumpList2String(llParseStringKeepNulls(s, ["\\"], []), "\\\\");
//    s = llDumpList2String(llParseStringKeepNulls(s, ["\""], []), "\\\"");
//    s = llDumpList2String(llParseStringKeepNulls(s, ["\n"], []), "\\n");
//    s = llDumpList2String(llParseStringKeepNulls(s, ["\r"], []), "\\r");
//    s = llDumpList2String(llParseStringKeepNulls(s, ["\t"], []), "\\t");
//    return s;
//}

string json_escape(string s)
{
    s = llDumpList2String(llParseString2List(s, ["\\"], []), "\\\\");
    s = llDumpList2String(llParseString2List(s, ["\""], []), "\\\"");
    return s;
}

integer is_agent_list_error(list agents)
{
    if (llGetListLength(agents) == 1)
    {
        if (llGetListEntryType(agents, 0) == TYPE_STRING)
        {
            return TRUE;
        }
    }
    return FALSE;
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

reset_current_avatar()
{
    gCurrentAttachments = [];
    gAttachmentIndex = 0;
    gCurrentAvatarId = "";
    gCurrentAvatarName = "";
}

schedule_continue()
{
    gWaitingToContinue = TRUE;
    gWaitingToRescan = FALSE;
    llSetTimerEvent(REQUEST_DELAY);
}

schedule_rescan()
{
    gWaitingToContinue = FALSE;
    gWaitingToRescan = TRUE;
    llSetTimerEvent(RESCAN_DELAY);
}

finish_scan()
{
    if (DEBUG)
    {
        owner_say("Scan complete. Free memory: " + (string)llGetFreeMemory());
        owner_say("Waiting " + (string)((integer)RESCAN_DELAY) + " seconds before next scan.");
    }

    gAgents = [];
    gAgentIndex = 0;
    reset_current_avatar();
    gActiveRequest = NULL_KEY;
    gScanInProgress = FALSE;

    schedule_rescan();
}

send_current_avatar_chunk()
{
    if (gActiveRequest != NULL_KEY)
    {
        return;
    }

    integer totalAttachments = llGetListLength(gCurrentAttachments);
    if (gAttachmentIndex >= totalAttachments)
    {
        reset_current_avatar();
        schedule_continue();
        return;
    }

    integer added = 0;
    string recordsJson = "";

    while (gAttachmentIndex < totalAttachments && added < MAX_RECORDS_PER_REQUEST)
    {
        key attachmentId = llList2Key(gCurrentAttachments, gAttachmentIndex);
        gAttachmentIndex++;

        if (attachmentId == NULL_KEY)
        {
            jump continue_attachment;
        }

        list details = llGetObjectDetails(
            attachmentId,
            [OBJECT_NAME, OBJECT_DESC, OBJECT_ATTACHED_POINT]
        );

        if (llGetListLength(details) < 3)
        {
            jump continue_attachment;
        }

        string attachmentName = llList2String(details, 0);
        string attachmentDesc = llList2String(details, 1);
        integer attachedPoint = llList2Integer(details, 2);

        if (attachmentName == "")
        {
            jump continue_attachment;
        }

        string oneRecord = make_record_json(
            gCurrentAvatarId,
            gCurrentAvatarName,
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

@continue_attachment;
    }

    if (recordsJson == "")
    {
        if (gAttachmentIndex >= totalAttachments)
        {
            reset_current_avatar();
        }
        schedule_continue();
        return;
    }

    string payload = "{"
        + "\"api_key\":\"" + json_escape(API_KEY) + "\","
        + "\"records\":[" + recordsJson + "]"
        + "}";

    if (DEBUG)
    {
        owner_say(
            "Sending " + (string)added
            + " record(s) for " + gCurrentAvatarName
            + " | free memory: " + (string)llGetFreeMemory()
        );
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
        payload
    );
}

process_next_step()
{
    if (!gScanInProgress)
    {
        return;
    }

    if (gActiveRequest != NULL_KEY)
    {
        return;
    }

    if (gCurrentAvatarId != "" && gAttachmentIndex < llGetListLength(gCurrentAttachments))
    {
        send_current_avatar_chunk();
        return;
    }

    reset_current_avatar();

    integer totalAgents = llGetListLength(gAgents);

    while (gAgentIndex < totalAgents)
    {
        key avatarId = llList2Key(gAgents, gAgentIndex);
        gAgentIndex++;

        if (avatarId == NULL_KEY)
        {
            jump continue_avatar;
        }

        string avatarName = llKey2Name(avatarId);
        if (avatarName == "")
        {
            jump continue_avatar;
        }

        list attachments = llGetAttachedList(avatarId);

        if (llGetListLength(attachments) == 0)
        {
            jump continue_avatar;
        }

        if (llGetListLength(attachments) == 1)
        {
            string one = llList2String(attachments, 0);
            if (one == "NOT FOUND" || one == "NOT ON REGION")
            {
                jump continue_avatar;
            }
        }

        gCurrentAvatarId = (string)avatarId;
        gCurrentAvatarName = avatarName;
        gCurrentAttachments = attachments;
        gAttachmentIndex = 0;

        if (DEBUG)
        {
            owner_say(
                "Scanning avatar: " + gCurrentAvatarName
                + " | attachments: " + (string)llGetListLength(gCurrentAttachments)
                + " | free memory: " + (string)llGetFreeMemory()
            );
        }

        send_current_avatar_chunk();
        return;

@continue_avatar;
    }

    finish_scan();
}

start_scan()
{
    if (gScanInProgress)
    {
        if (DEBUG)
        {
            owner_say("Scan already in progress.");
        }
        return;
    }

    llSetTimerEvent(0.0);
    gWaitingToContinue = FALSE;
    gWaitingToRescan = FALSE;

    gAgents = llGetAgentList(AGENT_LIST_REGION, []);

    if (is_agent_list_error(gAgents))
    {
        if (DEBUG)
        {
            owner_say("llGetAgentList error: " + llList2String(gAgents, 0));
        }
        gAgents = [];
        schedule_rescan();
        return;
    }

    gAgentIndex = 0;
    reset_current_avatar();
    gActiveRequest = NULL_KEY;
    gScanInProgress = TRUE;

    if (DEBUG)
    {
        owner_say("Scan started. Avatars in region: " + (string)llGetListLength(gAgents));
        owner_say("Free memory at start: " + (string)llGetFreeMemory());
    }

    process_next_step();
}

default
{
    state_entry()
    {
        owner_say("Attachment scanner ready.");
        owner_say("Free memory on start: " + (string)llGetFreeMemory());
        start_scan();
    }

    touch_start(integer total_number)
    {
        if (llDetectedKey(0) != llGetOwner())
        {
            return;
        }

        start_scan();
    }

    http_response(key request_id, integer status, list metadata, string body)
    {
        if (request_id != gActiveRequest)
        {
            return;
        }

        if (DEBUG)
        {
            owner_say("HTTP " + (string)status + " | " + body);
        }

        gActiveRequest = NULL_KEY;

        if (status == 420)
        {
            llSetTimerEvent(2.5);
            gWaitingToContinue = TRUE;
            gWaitingToRescan = FALSE;

            if (DEBUG)
            {
                owner_say("HTTP throttle hit. Backing off.");
            }
            return;
        }

        schedule_continue();
    }

    timer()
    {
        llSetTimerEvent(0.0);

        if (gWaitingToContinue)
        {
            gWaitingToContinue = FALSE;
            process_next_step();
            return;
        }

        if (gWaitingToRescan)
        {
            gWaitingToRescan = FALSE;
            start_scan();
            return;
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
