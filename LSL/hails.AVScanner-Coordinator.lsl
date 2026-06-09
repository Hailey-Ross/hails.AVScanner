// ── Message protocol constants (must match Node script) ──
integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;

// ── Config ──
// DEBUG levels: 0 = silent, 1 = standard, 2 = verbose
// Toggle with '/2 hailsAV debug' (standard) or '/2 hailsAV debug verbose'
integer DEBUG           = 0;
float   RESCAN_DELAY    = 30.0;
float   NODE_WAIT_DELAY = 3.0;
integer SCAN_COOLDOWN   = 180;    // seconds before an avatar is eligible for rescan

// ── State ──
list    gAvatarQueue     = [];
integer gQueueIndex      = 0;
integer gPendingCount    = 0;
list    gReadyNodes      = [];
list    gAssignedNodes   = [];
list    gAssignedAvatars = [];  // parallel to gAssignedNodes
list    gRetryQueue      = [];  // avatars to re-attempt before advancing queue
list    gSkippedAvatars  = [];  // avatars that already used their one retry
list    gScannedAvatars  = [];  // UUIDs scanned this session; parallel with gScannedTimes
list    gScannedTimes    = [];  // llGetUnixTime() of each avatar's last successful scan
integer gScanActive      = FALSE;
integer gWaitingToRescan = FALSE;
integer gCollectingNodes = FALSE;
integer gDisabled        = FALSE;
integer gListenHandle    = 0;

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
    while (llGetListLength(gReadyNodes) > 0
           && (llGetListLength(gRetryQueue) > 0 || gQueueIndex < queueLen))
    {
        integer nodeLink = llList2Integer(gReadyNodes, 0);
        gReadyNodes = llDeleteSubList(gReadyNodes, 0, 0);

        key avatarId;
        if (llGetListLength(gRetryQueue) > 0)
        {
            avatarId    = llList2Key(gRetryQueue, 0);
            gRetryQueue = llDeleteSubList(gRetryQueue, 0, 0);
        }
        else
        {
            avatarId = llList2Key(gAvatarQueue, gQueueIndex);
            gQueueIndex++;
        }

        gPendingCount++;
        gAssignedNodes   += [nodeLink];
        gAssignedAvatars += [avatarId];

        llMessageLinked(nodeLink, MSG_ASSIGN, (string)avatarId, avatarId);

        if (DEBUG >= 2)
        {
            llOwnerSay("[Coord] -> Node " + (string)nodeLink + " | " + (string)avatarId);
        }
    }
}

check_scan_complete()
{
    if (gPendingCount <= 0
        && gQueueIndex >= llGetListLength(gAvatarQueue)
        && llGetListLength(gRetryQueue) == 0)
    {
        finish_scan();
    }
}

finish_scan()
{
    if (DEBUG >= 1)
    {
        llOwnerSay("[Coord] Scan complete. Free memory: " + (string)llGetFreeMemory());
    }

    gAvatarQueue     = [];
    gQueueIndex      = 0;
    gPendingCount    = 0;
    gAssignedNodes   = [];
    gAssignedAvatars = [];
    gRetryQueue      = [];
    gSkippedAvatars  = [];
    gScanActive      = FALSE;

    if (gDisabled)
    {
        if (DEBUG >= 1) llOwnerSay("[Coord] Scanning paused.");
        return;
    }

    gWaitingToRescan = TRUE;
    llSetTimerEvent(RESCAN_DELAY);
}

start_scan()
{
    llSetTimerEvent(0.0);
    gWaitingToRescan = FALSE;

    if (gDisabled) return;

    gAvatarQueue = llGetAgentList(AGENT_LIST_REGION, []);

    if (is_agent_list_error(gAvatarQueue))
    {
        if (DEBUG >= 2)
        {
            llOwnerSay("[Coord] llGetAgentList error: " + llList2String(gAvatarQueue, 0));
        }
        gAvatarQueue     = [];
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    if (llGetListLength(gAvatarQueue) == 0)
    {
        if (DEBUG >= 2)
        {
            llOwnerSay("[Coord] No avatars in region. Rescanning in " + (string)((integer)RESCAN_DELAY) + "s.");
        }
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    // Prune expired cooldown entries
    integer now = llGetUnixTime();
    list keptAvatars = [];
    list keptTimes   = [];
    integer i;
    for (i = 0; i < llGetListLength(gScannedAvatars); i++)
    {
        if (now - llList2Integer(gScannedTimes, i) < SCAN_COOLDOWN)
        {
            keptAvatars += [llList2Key(gScannedAvatars, i)];
            keptTimes   += [llList2Integer(gScannedTimes, i)];
        }
    }
    gScannedAvatars = keptAvatars;
    gScannedTimes   = keptTimes;

    // Filter queue to avatars not currently on cooldown
    list filteredQueue = [];
    for (i = 0; i < llGetListLength(gAvatarQueue); i++)
    {
        key av = llList2Key(gAvatarQueue, i);
        if (llListFindList(gScannedAvatars, [av]) == -1)
            filteredQueue += [av];
    }

    if (llGetListLength(filteredQueue) == 0)
    {
        if (DEBUG >= 1) llOwnerSay("[Coord] All avatars on cooldown. Rechecking in " + (string)((integer)RESCAN_DELAY) + "s.");
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    gAvatarQueue = filteredQueue;
    integer agentCount = llGetListLength(gAvatarQueue);

    gQueueIndex      = 0;
    gPendingCount    = 0;
    gAssignedNodes   = [];
    gAssignedAvatars = [];
    gRetryQueue      = [];
    gSkippedAvatars  = [];
    gScanActive      = TRUE;

    if (DEBUG >= 1)
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
        gDisabled        = FALSE;
        gReadyNodes      = [];
        gAvatarQueue     = [];
        gAssignedNodes   = [];
        gAssignedAvatars = [];
        gRetryQueue      = [];
        gSkippedAvatars  = [];
        gScannedAvatars  = [];
        gScannedTimes    = [];
        gQueueIndex      = 0;
        gPendingCount    = 0;

        gListenHandle = llListen(2, "", llGetOwner(), "");

        if (DEBUG >= 1)
            llOwnerSay("[Coord] Ready. Collecting nodes for " + (string)((integer)NODE_WAIT_DELAY) + "s...");

        llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
        llSetTimerEvent(NODE_WAIT_DELAY);
    }

    listen(integer channel, string name, key id, string message)
    {
        list labels = ["OFF", "ON", "VERBOSE"];

        if (message == "hailsAV debug verbose")
        {
            if (DEBUG == 2) DEBUG = 0;
            else DEBUG = 2;
            llMessageLinked(LINK_ALL_OTHERS, MSG_SET_DEBUG, (string)DEBUG, NULL_KEY);
            llOwnerSay("[Coord] Debug " + llList2String(labels, DEBUG) + ".");
        }
        else if (message == "hailsAV debug")
        {
            if (DEBUG > 0) DEBUG = 0;
            else DEBUG = 1;
            llMessageLinked(LINK_ALL_OTHERS, MSG_SET_DEBUG, (string)DEBUG, NULL_KEY);
            llOwnerSay("[Coord] Debug " + llList2String(labels, DEBUG) + ".");
        }
        else if (message == "hailsAV disable")
        {
            gDisabled = TRUE;
            if (gWaitingToRescan)
            {
                llSetTimerEvent(0.0);
                gWaitingToRescan = FALSE;
            }
            llOwnerSay("[Coord] Scanning paused. Current scan will complete then stop.");
        }
        else if (message == "hailsAV enable")
        {
            gDisabled = FALSE;
            llOwnerSay("[Coord] Scanning enabled.");
            if (!gScanActive && !gCollectingNodes)
            {
                start_scan();
            }
        }
    }

    touch_start(integer total_number)
    {
        if (llDetectedKey(0) != llGetOwner())
        {
            return;
        }

        if (gDisabled)
        {
            llOwnerSay("[Coord] Scanning is paused. Say 'hailsAV enable' on channel 2 to resume.");
            return;
        }

        if (gScanActive)
        {
            if (DEBUG >= 2) llOwnerSay("[Coord] Scan already in progress.");
            return;
        }

        start_scan();
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == MSG_NODE_READY)
        {
            integer nodeLink = sender_num;
            integer idx = llListFindList(gAssignedNodes, [nodeLink]);

            if (idx != -1)
            {
                // Node re-registered while it had a pending assignment
                key lostAvatar = llList2Key(gAssignedAvatars, idx);
                gAssignedNodes   = llDeleteSubList(gAssignedNodes, idx, idx);
                gAssignedAvatars = llDeleteSubList(gAssignedAvatars, idx, idx);
                if (gPendingCount > 0)
                {
                    gPendingCount--;
                }

                if (llListFindList(gSkippedAvatars, [lostAvatar]) == -1)
                {
                    gRetryQueue     += [lostAvatar];
                    gSkippedAvatars += [lostAvatar];

                    if (DEBUG >= 2)
                    {
                        llOwnerSay("[Coord] Node " + (string)nodeLink
                            + " re-registered. Queuing retry: " + (string)lostAvatar);
                    }
                }
                else
                {
                    if (DEBUG >= 2)
                    {
                        llOwnerSay("[Coord] Node " + (string)nodeLink
                            + " re-registered again. Skipping: " + (string)lostAvatar);
                    }
                }

                gReadyNodes += [nodeLink];
                dispatch_to_ready_nodes();
                check_scan_complete();
            }
            else if (gScanActive && (llGetListLength(gRetryQueue) > 0 || gQueueIndex < llGetListLength(gAvatarQueue)))
            {
                if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                {
                    gReadyNodes += [nodeLink];
                }
                dispatch_to_ready_nodes();
            }
            else
            {
                if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                {
                    gReadyNodes += [nodeLink];
                }

                if (DEBUG >= 2)
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
                if (num == MSG_NODE_DONE)
                {
                    key scannedAv = llList2Key(gAssignedAvatars, idx);
                    integer existIdx = llListFindList(gScannedAvatars, [scannedAv]);
                    if (existIdx == -1)
                    {
                        gScannedAvatars += [scannedAv];
                        gScannedTimes   += [llGetUnixTime()];
                    }
                    else
                    {
                        gScannedTimes = llListReplaceList(gScannedTimes, [llGetUnixTime()], existIdx, existIdx);
                    }
                }
                gAssignedNodes   = llDeleteSubList(gAssignedNodes, idx, idx);
                gAssignedAvatars = llDeleteSubList(gAssignedAvatars, idx, idx);
            }
            if (gPendingCount > 0)
            {
                gPendingCount--;
            }

            if (DEBUG >= 1)
            {
                string label = "DONE";
                if (num == MSG_NODE_ERROR) { label = "ERROR"; }
                llOwnerSay("[Coord] Node " + (string)nodeLink + " " + label
                    + " | Pending: " + (string)gPendingCount
                    + " | Queue: " + (string)gQueueIndex + "/" + (string)llGetListLength(gAvatarQueue));
            }

            if (gScanActive)
            {
                gReadyNodes += [nodeLink];
                dispatch_to_ready_nodes();
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

    on_rez(integer start_param)
    {
        llMessageLinked(LINK_ALL_OTHERS, MSG_ABORT_SCAN, "", NULL_KEY);
        llResetScript();
    }

    changed(integer change)
    {
        if (change & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START))
        {
            llMessageLinked(LINK_ALL_OTHERS, MSG_ABORT_SCAN, "", NULL_KEY);
            llResetScript();
        }
        else if (change & CHANGED_LINK)
        {
            // Link numbers may have shifted — re-collect all nodes
            // Cooldown history (gScannedAvatars/gScannedTimes) is preserved
            llSetTimerEvent(0.0);
            gAvatarQueue     = [];
            gQueueIndex      = 0;
            gPendingCount    = 0;
            gReadyNodes      = [];
            gAssignedNodes   = [];
            gAssignedAvatars = [];
            gRetryQueue      = [];
            gSkippedAvatars  = [];
            gScanActive      = FALSE;
            gWaitingToRescan = FALSE;
            gCollectingNodes = TRUE;
            llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
            llSetTimerEvent(NODE_WAIT_DELAY);
            if (DEBUG >= 1) llOwnerSay("[Coord] Linkset changed. Re-collecting nodes...");
        }
    }
}
