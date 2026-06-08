// ── Message protocol constants (must match Node script) ──
integer MSG_NODE_READY  = 1;
integer MSG_ASSIGN      = 2;
integer MSG_NODE_DONE   = 3;
integer MSG_NODE_ERROR  = 4;
integer MSG_RESET_NODES = 5;
integer MSG_ABORT_SCAN  = 6;

// ── Config ──
integer DEBUG           = FALSE;
float   RESCAN_DELAY    = 30.0;
float   NODE_WAIT_DELAY = 3.0;

// ── State ──
list    gAvatarQueue     = [];
integer gQueueIndex      = 0;
integer gPendingCount    = 0;
list    gReadyNodes      = [];
list    gAssignedNodes   = [];
integer gScanActive      = FALSE;
integer gWaitingToRescan = FALSE;
integer gCollectingNodes = FALSE;

// ─────────────────────────────────────────────────────────────────────────────

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

dispatch_to_ready_nodes()
{
    integer queueLen = llGetListLength(gAvatarQueue);
    while (llGetListLength(gReadyNodes) > 0 && gQueueIndex < queueLen)
    {
        integer nodeLink = llList2Integer(gReadyNodes, 0);
        gReadyNodes = llDeleteSubList(gReadyNodes, 0, 0);

        key avatarId = llList2Key(gAvatarQueue, gQueueIndex);
        gQueueIndex++;
        gPendingCount++;
        gAssignedNodes += [nodeLink];

        llMessageLinked(nodeLink, MSG_ASSIGN, (string)avatarId, avatarId);

        if (DEBUG)
        {
            llOwnerSay("[Coord] -> Node " + (string)nodeLink + " | " + (string)avatarId);
        }
    }
}

check_scan_complete()
{
    if (gPendingCount <= 0 && gQueueIndex >= llGetListLength(gAvatarQueue))
    {
        finish_scan();
    }
}

finish_scan()
{
    if (DEBUG)
    {
        llOwnerSay("[Coord] Scan complete. Free memory: " + (string)llGetFreeMemory());
    }

    gAvatarQueue   = [];
    gQueueIndex    = 0;
    gPendingCount  = 0;
    gAssignedNodes = [];
    gScanActive    = FALSE;

    gWaitingToRescan = TRUE;
    llSetTimerEvent(RESCAN_DELAY);
}

start_scan()
{
    llSetTimerEvent(0.0);
    gWaitingToRescan = FALSE;

    gAvatarQueue = llGetAgentList(AGENT_LIST_REGION, []);

    if (is_agent_list_error(gAvatarQueue))
    {
        if (DEBUG)
        {
            llOwnerSay("[Coord] llGetAgentList error: " + llList2String(gAvatarQueue, 0));
        }
        gAvatarQueue     = [];
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    integer agentCount = llGetListLength(gAvatarQueue);

    if (agentCount == 0)
    {
        if (DEBUG)
        {
            llOwnerSay("[Coord] No avatars in region. Rescanning in " + (string)((integer)RESCAN_DELAY) + "s.");
        }
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    gQueueIndex    = 0;
    gPendingCount  = 0;
    gAssignedNodes = [];
    gScanActive    = TRUE;

    if (DEBUG)
    {
        llOwnerSay("[Coord] Scan started. Avatars: " + (string)agentCount
            + " | Ready nodes: " + (string)llGetListLength(gReadyNodes)
            + " | Free memory: " + (string)llGetFreeMemory());
    }

    dispatch_to_ready_nodes();
}

// ─────────────────────────────────────────────────────────────────────────────

default
{
    state_entry()
    {
        gScanActive      = FALSE;
        gCollectingNodes = TRUE;
        gWaitingToRescan = FALSE;
        gReadyNodes      = [];
        gAvatarQueue     = [];
        gAssignedNodes   = [];
        gQueueIndex      = 0;
        gPendingCount    = 0;

        llOwnerSay("[Coord] Ready. Collecting nodes for " + (string)((integer)NODE_WAIT_DELAY) + "s...");

        llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
        llSetTimerEvent(NODE_WAIT_DELAY);
    }

    touch_start(integer total_number)
    {
        if (llDetectedKey(0) != llGetOwner())
        {
            return;
        }

        if (gScanActive)
        {
            if (DEBUG)
            {
                llOwnerSay("[Coord] Scan already in progress.");
            }
            return;
        }

        start_scan();
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == MSG_NODE_READY)
        {
            integer nodeLink = sender_num;

            // If this node was mid-assignment when it reset, credit the lost work
            integer idx = llListFindList(gAssignedNodes, [nodeLink]);
            if (idx != -1)
            {
                gAssignedNodes = llDeleteSubList(gAssignedNodes, idx, idx);
                if (gPendingCount > 0)
                {
                    gPendingCount--;
                }
                if (DEBUG)
                {
                    llOwnerSay("[Coord] Node " + (string)nodeLink + " re-registered mid-scan. Crediting lost assignment.");
                }
            }

            if (gScanActive && gQueueIndex < llGetListLength(gAvatarQueue))
            {
                key avatarId = llList2Key(gAvatarQueue, gQueueIndex);
                gQueueIndex++;
                gPendingCount++;
                gAssignedNodes += [nodeLink];

                llMessageLinked(nodeLink, MSG_ASSIGN, (string)avatarId, avatarId);

                if (DEBUG)
                {
                    llOwnerSay("[Coord] -> Node " + (string)nodeLink + " | " + (string)avatarId);
                }
            }
            else
            {
                if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                {
                    gReadyNodes += [nodeLink];
                }

                if (DEBUG)
                {
                    llOwnerSay("[Coord] Node " + (string)nodeLink + " registered. Ready: "
                        + (string)llGetListLength(gReadyNodes));
                }

                if (gScanActive)
                {
                    check_scan_complete();
                }
            }
        }
        else if (num == MSG_NODE_DONE || num == MSG_NODE_ERROR)
        {
            integer nodeLink = sender_num;

            integer idx = llListFindList(gAssignedNodes, [nodeLink]);
            if (idx != -1)
            {
                gAssignedNodes = llDeleteSubList(gAssignedNodes, idx, idx);
            }
            if (gPendingCount > 0)
            {
                gPendingCount--;
            }

            if (DEBUG)
            {
                string label = "DONE";
                if (num == MSG_NODE_ERROR) { label = "ERROR"; }
                llOwnerSay("[Coord] Node " + (string)nodeLink + " " + label
                    + " | Pending: " + (string)gPendingCount
                    + " | Queue: " + (string)gQueueIndex + "/" + (string)llGetListLength(gAvatarQueue));
            }

            if (gScanActive)
            {
                check_scan_complete();
            }
        }
    }

    timer()
    {
        llSetTimerEvent(0.0);

        if (gCollectingNodes)
        {
            gCollectingNodes = FALSE;
            start_scan();
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
            llMessageLinked(LINK_ALL_OTHERS, MSG_ABORT_SCAN, "", NULL_KEY);
            llResetScript();
        }
    }
}
