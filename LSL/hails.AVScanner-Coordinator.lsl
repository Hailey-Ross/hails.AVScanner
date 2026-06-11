integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;
integer MSG_SET_PACING  = 6602143;
integer MSG_WIPE_NODES  = 7245013;

// Dual-coordinator mode: set COORD_B_LINK to the link number of the Coordinator B prim.
// Must match Node and Deployer constants.
integer NUM_COORDINATORS = 2;
integer NODE_START_LINK  = 2;
integer COORD_B_LINK     = 5;

integer MSG_COORD_REQUEST = 9341782;
integer MSG_COORD_ASSIGN  = 4862305;
integer MSG_COORD_DONE    = 6183947;
integer MSG_COORD_ERROR   = 3729516;
integer MSG_SCAN_STARTED  = 5094821;

integer DEBUG              = 0;  // 0 = off  1 = standard  2 = verbose
float   RESCAN_DELAY       = 30.0;
integer SCAN_COOLDOWN      = 180;
integer MAX_ACTIVE_WORKERS = 10;
integer ARRIVAL_GRACE      = 8;
float   ARRIVAL_POLL       = 3.0;

list    gAvatarQueue       = [];
integer gQueueIndex        = 0;
integer gPendingCount      = 0;
list    gReadyNodes        = [];
list    gAssignedNodes     = [];
list    gAssignedAvatars   = [];
list    gRetryQueue        = [];
list    gSkippedAvatars    = [];
list    gScannedAvatars    = [];
list    gScannedTimes      = [];
integer gScanActive        = FALSE;
integer gWaitingToRescan   = FALSE;
integer gDisabled          = FALSE;
integer gListenHandle      = 0;
integer gPacedWorkers      = 1;
list    gLastRegionAvatars = [];
list    gPendingArrivals   = [];
integer gRescanDueAt       = 0;
integer gPendingCoordB     = 0;

integer is_agent_list_error(list agents)
{
    if (llGetListLength(agents) == 1)
    {
        if (llGetListEntryType(agents, 0) == TYPE_STRING)
            return TRUE;
    }
    return FALSE;
}

abort_scan_state()
{
    llSetTimerEvent(0.0);
    gAvatarQueue       = [];
    gQueueIndex        = 0;
    gPendingCount      = 0;
    gReadyNodes        = [];
    gAssignedNodes     = [];
    gAssignedAvatars   = [];
    gRetryQueue        = [];
    gSkippedAvatars    = [];
    gScanActive        = FALSE;
    gWaitingToRescan   = FALSE;
    gPacedWorkers      = 1;
    gLastRegionAvatars = [];
    gPendingArrivals   = [];
    gRescanDueAt       = 0;
    gPendingCoordB     = 0;
}

dispatch_to_ready_nodes()
{
    integer queueLen = llGetListLength(gAvatarQueue);
    while (llGetListLength(gReadyNodes) > 0
           && gPendingCount < MAX_ACTIVE_WORKERS
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
            llOwnerSay("[Coord] -> Node " + (string)nodeLink + " | " + (string)avatarId);
    }

    if (gScanActive && gPendingCount > gPacedWorkers)
    {
        gPacedWorkers = gPendingCount;
        llMessageLinked(LINK_ALL_OTHERS, MSG_SET_PACING, (string)gPacedWorkers, NULL_KEY);
    }
}

check_scan_complete()
{
    if (gPendingCount <= 0
        && gQueueIndex >= llGetListLength(gAvatarQueue)
        && llGetListLength(gRetryQueue) == 0)
        finish_scan();
}

finish_scan()
{
    if (DEBUG >= 1)
        llOwnerSay("[Coord] Scan complete. Free memory: " + (string)llGetFreeMemory());

    gAvatarQueue     = [];
    gQueueIndex      = 0;
    gPendingCount    = 0;
    gAssignedNodes   = [];
    gAssignedAvatars = [];
    gRetryQueue      = [];
    gSkippedAvatars  = [];
    gScanActive      = FALSE;
    gPendingCoordB   = 0;

    if (gDisabled)
    {
        if (DEBUG >= 1) llOwnerSay("[Coord] Scanning paused.");
        return;
    }

    gLastRegionAvatars = llGetAgentList(AGENT_LIST_REGION, []);
    gPendingArrivals   = [];
    gRescanDueAt       = llGetUnixTime() + (integer)RESCAN_DELAY;
    gWaitingToRescan   = TRUE;
    llSetTimerEvent(ARRIVAL_POLL);
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
            llOwnerSay("[Coord] llGetAgentList error: " + llList2String(gAvatarQueue, 0));
        gAvatarQueue     = [];
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }
    if (llGetListLength(gAvatarQueue) == 0)
    {
        if (DEBUG >= 2)
            llOwnerSay("[Coord] No avatars. Rescanning in " + (string)((integer)RESCAN_DELAY) + "s.");
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    integer now = llGetUnixTime();
    integer i;
    for (i = llGetListLength(gScannedAvatars) - 1; i >= 0; i--)
    {
        if (now - llList2Integer(gScannedTimes, i) >= SCAN_COOLDOWN)
        {
            gScannedAvatars = llDeleteSubList(gScannedAvatars, i, i);
            gScannedTimes   = llDeleteSubList(gScannedTimes, i, i);
        }
    }
    for (i = llGetListLength(gAvatarQueue) - 1; i >= 0; i--)
    {
        if (llListFindList(gScannedAvatars, [llList2Key(gAvatarQueue, i)]) != -1)
            gAvatarQueue = llDeleteSubList(gAvatarQueue, i, i);
    }
    if (llGetListLength(gAvatarQueue) == 0)
    {
        if (DEBUG >= 1) llOwnerSay("[Coord] All on cooldown. Rechecking in " + (string)((integer)RESCAN_DELAY) + "s.");
        gWaitingToRescan = TRUE;
        llSetTimerEvent(RESCAN_DELAY);
        return;
    }

    integer agentCount = llGetListLength(gAvatarQueue);

    integer workerCount = llGetListLength(gReadyNodes);
    if (agentCount < workerCount)      workerCount = agentCount;
    if (workerCount > MAX_ACTIVE_WORKERS) workerCount = MAX_ACTIVE_WORKERS;
    if (workerCount < 1)               workerCount = 1;
    if (workerCount != gPacedWorkers)
    {
        gPacedWorkers = workerCount;
        llMessageLinked(LINK_ALL_OTHERS, MSG_SET_PACING, (string)workerCount, NULL_KEY);
    }

    gQueueIndex      = 0;
    gPendingCount    = 0;
    gAssignedNodes   = [];
    gAssignedAvatars = [];
    gRetryQueue      = [];
    gSkippedAvatars  = [];
    gScanActive      = TRUE;

    if (DEBUG >= 1)
        llOwnerSay("[Coord] Scan started. Avatars: " + (string)agentCount
            + " | Ready nodes: " + (string)llGetListLength(gReadyNodes)
            + " | Free memory: " + (string)llGetFreeMemory());

    if (NUM_COORDINATORS > 1)
        llMessageLinked(COORD_B_LINK, MSG_SCAN_STARTED, "", NULL_KEY);

    dispatch_to_ready_nodes();
}

default
{
    state_entry()
    {
        abort_scan_state();
        gDisabled       = FALSE;
        gScannedAvatars = [];
        gScannedTimes   = [];
        gListenHandle   = llListen(2, "", llGetOwner(), "");
        if (DEBUG >= 1)
            llOwnerSay("[Coord] Ready.");
        llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
        start_scan();
    }

    listen(integer channel, string name, key id, string message)
    {
        if (id != llGetOwner()) return;
        list labels = ["OFF", "ON", "VERBOSE"];
        if (message == "hailsAV debug verbose")
        {
            if (DEBUG == 2) DEBUG = 0; else DEBUG = 2;
            llMessageLinked(LINK_ALL_OTHERS, MSG_SET_DEBUG, (string)DEBUG, NULL_KEY);
            llOwnerSay("[Coord] Debug " + llList2String(labels, DEBUG) + ".");
        }
        else if (message == "hailsAV debug")
        {
            if (DEBUG > 0) DEBUG = 0; else DEBUG = 1;
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
            if (!gScanActive) start_scan();
        }
    }

    touch_start(integer total_number)
    {
        if (llDetectedKey(0) != llGetOwner()) return;
        if (gDisabled)
        {
            llOwnerSay("[Coord] Paused. Say 'hailsAV enable' on ch2 to resume.");
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
            if (sender_num < NODE_START_LINK
                || (sender_num - NODE_START_LINK) % NUM_COORDINATORS != 0)
                return;
            integer nodeLink = sender_num;
            integer idx = llListFindList(gAssignedNodes, [nodeLink]);
            if (idx != -1)
            {
                key lostAvatar = llList2Key(gAssignedAvatars, idx);
                gAssignedNodes   = llDeleteSubList(gAssignedNodes, idx, idx);
                gAssignedAvatars = llDeleteSubList(gAssignedAvatars, idx, idx);
                if (gPendingCount > 0) gPendingCount--;
                if (llListFindList(gSkippedAvatars, [lostAvatar]) == -1)
                {
                    gRetryQueue     += [lostAvatar];
                    gSkippedAvatars += [lostAvatar];
                    if (DEBUG >= 2)
                        llOwnerSay("[Coord] Node " + (string)nodeLink + " re-registered. Retry: " + (string)lostAvatar);
                }
                else
                {
                    if (DEBUG >= 2)
                        llOwnerSay("[Coord] Node " + (string)nodeLink + " re-registered again. Skipping: " + (string)lostAvatar);
                }
                gReadyNodes += [nodeLink];
                dispatch_to_ready_nodes();
                check_scan_complete();
            }
            else if (gScanActive && (llGetListLength(gRetryQueue) > 0 || gQueueIndex < llGetListLength(gAvatarQueue)))
            {
                if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                    gReadyNodes += [nodeLink];
                dispatch_to_ready_nodes();
            }
            else
            {
                if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                    gReadyNodes += [nodeLink];
                if (DEBUG >= 2)
                    llOwnerSay("[Coord] Node " + (string)nodeLink + " registered. Ready: " + (string)llGetListLength(gReadyNodes));
                if (gScanActive) check_scan_complete();
            }
        }
        else if (num == MSG_NODE_DONE || num == MSG_NODE_ERROR)
        {
            if (sender_num < NODE_START_LINK
                || (sender_num - NODE_START_LINK) % NUM_COORDINATORS != 0)
                return;
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
            if (gPendingCount > 0) gPendingCount--;
            if (DEBUG >= 1)
            {
                string label = "DONE";
                if (num != MSG_NODE_DONE) label = "ERROR";
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
        else if (num == MSG_COORD_REQUEST && NUM_COORDINATORS > 1 && sender_num == COORD_B_LINK)
        {
            if (!gScanActive) return;
            if (gQueueIndex >= llGetListLength(gAvatarQueue) && llGetListLength(gRetryQueue) == 0) return;
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
            gPendingCoordB++;
            llMessageLinked(COORD_B_LINK, MSG_COORD_ASSIGN, (string)avatarId, avatarId);
            if (DEBUG >= 2)
                llOwnerSay("[Coord A] -> Coord B | " + (string)avatarId);
        }
        else if (NUM_COORDINATORS > 1 && sender_num == COORD_B_LINK
                 && (num == MSG_COORD_DONE || num == MSG_COORD_ERROR))
        {
            if (num == MSG_COORD_DONE && str != "")
            {
                key scannedAv = (key)str;
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
            if (gPendingCount > 0) gPendingCount--;
            if (gPendingCoordB > 0) gPendingCoordB--;
            if (DEBUG >= 1)
            {
                string label = "DONE";
                if (num != MSG_COORD_DONE) label = "ERROR";
                llOwnerSay("[Coord A] Coord B " + label
                    + " | Pending: " + (string)gPendingCount
                    + " | Queue: " + (string)gQueueIndex + "/" + (string)llGetListLength(gAvatarQueue));
            }
            if (gScanActive) check_scan_complete();
        }
    }

    timer()
    {
        llSetTimerEvent(0.0);
        if (gWaitingToRescan)
        {
            integer now = llGetUnixTime();
            list current = llGetAgentList(AGENT_LIST_REGION, []);
            integer i;
            for (i = 0; i < llGetListLength(current); i++)
            {
                key av = llList2Key(current, i);
                if (llListFindList(gLastRegionAvatars, [av]) == -1
                    && llListFindList(gPendingArrivals,   [av]) == -1
                    && llListFindList(gScannedAvatars,    [av]) == -1)
                {
                    gPendingArrivals += [av, now];
                    if (DEBUG >= 2)
                        llOwnerSay("[Coord] Arrival: " + (string)av);
                }
            }
            gLastRegionAvatars = current;

            integer hasReady = FALSE;
            for (i = 0; i < llGetListLength(gPendingArrivals) && !hasReady; i += 2)
            {
                if (now - llList2Integer(gPendingArrivals, i + 1) >= ARRIVAL_GRACE)
                    hasReady = TRUE;
            }
            if (hasReady && llGetListLength(gReadyNodes) > 0)
            {
                if (DEBUG >= 1) llOwnerSay("[Coord] Early scan: new arrivals past grace.");
                gWaitingToRescan = FALSE;
                gPendingArrivals = [];
                start_scan();
                return;
            }
            if (now >= gRescanDueAt)
            {
                gWaitingToRescan = FALSE;
                gPendingArrivals = [];
                start_scan();
                return;
            }
            llSetTimerEvent(ARRIVAL_POLL);
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
            abort_scan_state();
            llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
            if (DEBUG >= 1) llOwnerSay("[Coord] Linkset changed. Restarting.");
            start_scan();
        }
    }
}
