// ── Message protocol constants (must match Node script) ──
integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;
integer MSG_SET_PACING  = 6602143;
integer MSG_WIPE_NODES  = 7245013;

// ── Deployment (must match Node script) ──
// Node scripts set this PIN on their prim via llSetRemoteScriptAccessPin,
// which lets do_deploy() push script updates with llRemoteLoadScriptPin.
// Order is always deploy -> verify registrations -> cleanup; never wipe
// before deploying (PIN persistence after a full wipe is undocumented).
integer DEPLOY_PIN         = 84150193;
string  NODE_SCRIPT_PREFIX = "hails.AVScanner_Node";

// ── Config ──
// DEBUG levels: 0 = silent, 1 = standard, 2 = verbose
// Toggle with '/2 hailsAV debug' (standard) or '/2 hailsAV debug verbose'
integer DEBUG           = 0;
float   RESCAN_DELAY    = 30.0;
integer SCAN_COOLDOWN   = 180;    // seconds before an avatar is eligible for rescan
// Max avatars assigned at once. The object-wide HTTP cap (25 req/20s) fixes
// total scan time regardless of parallelism, so extra concurrency only adds
// burst load on the backend (HTTP 499s) and per-avatar latency.
integer MAX_ACTIVE_WORKERS = 10;

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
integer gDisabled        = FALSE;
integer gListenHandle    = 0;
integer gWipeArmedUntil  = 0;   // unix time; wipe executes only if re-confirmed before this
integer gPacedWorkers    = 1;   // worker count last broadcast via MSG_SET_PACING; ramps up mid-scan
integer gDeployReport    = FALSE; // verify-registrations timer pending after a deploy
integer gDeployTargets   = 0;   // prim count of the last deploy, for the verify report
integer gAutoCleanup     = FALSE; // redeploy: run cleanup automatically if every prim registered
integer gAwaitingCleanup = FALSE; // deploy done but cleanup pending; scanning stays paused

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

abort_scan_state()
{
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
    gPacedWorkers    = 1;
    gDeployReport    = FALSE;
    gAutoCleanup     = FALSE;
    gAwaitingCleanup = FALSE;
}

// Returns the single node script in the root prim's inventory, or "" after
// telling the owner why (none found, or ambiguous)
string find_node_script()
{
    string  found   = "";
    integer matches = 0;
    integer i;
    for (i = 0; i < llGetInventoryNumber(INVENTORY_SCRIPT); i++)
    {
        string itemName = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (llSubStringIndex(itemName, NODE_SCRIPT_PREFIX) == 0)
        {
            found = itemName;
            matches++;
        }
    }
    if (matches == 0)
    {
        llOwnerSay("[Coord] No script starting with '" + NODE_SCRIPT_PREFIX
            + "' found in the root prim. Drop the node script in and try again.");
        return "";
    }
    if (matches > 1)
    {
        llOwnerSay("[Coord] Found " + (string)matches + " scripts starting with '"
            + NODE_SCRIPT_PREFIX + "' in the root prim. Keep exactly one and try again.");
        return "";
    }
    return found;
}

do_wipe()
{
    abort_scan_state();
    llMessageLinked(LINK_ALL_OTHERS, MSG_WIPE_NODES, "", NULL_KEY);
    llOwnerSay("[Coord] Wipe broadcast sent. Node scripts are deleting themselves.");
}

do_deploy(string scriptName)
{
    abort_scan_state();

    // Pause scanning fully: stop in-flight node work too, so nothing scans
    // or POSTs while scripts are being replaced under it. Scanning stays
    // paused until cleanup (see the gAwaitingCleanup guard in start_scan)
    llMessageLinked(LINK_ALL_OTHERS, MSG_ABORT_SCAN, "", NULL_KEY);

    // llGetObjectPrimCount excludes seated avatars but returns 0 when the
    // object is an attachment; fall back to llGetNumberOfPrims there (nobody
    // can sit on an attachment, so it is exact in that case)
    integer primCount = llGetObjectPrimCount(llGetKey());
    if (primCount <= 0)
    {
        primCount = llGetNumberOfPrims();
    }
    integer targets = primCount - 1;
    if (targets < 1)
    {
        llOwnerSay("[Coord] No child prims found to deploy to.");
        return;
    }
    llOwnerSay("[Coord] Deploying '" + scriptName + "' to " + (string)targets
        + " prims. llRemoteLoadScriptPin sleeps 3s per prim; expect ~"
        + (string)(targets * 3) + "s.");

    integer link;
    for (link = 2; link <= primCount; link++)
    {
        llRemoteLoadScriptPin(llGetLinkKey(link), scriptName, DEPLOY_PIN, TRUE, 0);
        if ((link - 1) % 10 == 0 && link < primCount)
        {
            llOwnerSay("[Coord] Pushed to " + (string)(link - 1) + "/" + (string)targets + " prims...");
        }
    }

    // Destroy NOTHING yet. Loaded scripts announce themselves as they start;
    // the verify timer reports how many actually registered before any
    // cleanup happens. (A failed llRemoteLoadScriptPin only shouts on
    // DEBUG_CHANNEL, so registrations are the only reliable success signal.)
    gDeployTargets   = targets;
    gDeployReport    = TRUE;
    gAwaitingCleanup = TRUE;
    llSetTimerEvent(10.0);
    llOwnerSay("[Coord] Push finished. Scanning is paused until cleanup. Verifying registrations for 10s...");
}

do_cleanup()
{
    string scriptName = find_node_script();
    if (scriptName == "")
    {
        return;
    }

    // Nodes delete every other node-script version in their prim, keeping
    // only scriptName; then the staged root copy is removed
    llMessageLinked(LINK_ALL_OTHERS, MSG_WIPE_NODES, scriptName, NULL_KEY);
    llRemoveInventory(scriptName);
    gAwaitingCleanup = FALSE;
    llOwnerSay("[Coord] Cleanup done: prims keep only '" + scriptName
        + "', staged copy removed from the root prim. Starting scan.");
    start_scan();
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
        {
            llOwnerSay("[Coord] -> Node " + (string)nodeLink + " | " + (string)avatarId);
        }
    }

    // Ramp pacing up as workers actually join (nodes register dynamically;
    // scans no longer wait for a collection window). Broadcast only on
    // increase to keep link traffic down; gPendingCount is capped at
    // MAX_ACTIVE_WORKERS by the loop above.
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

    if (gAwaitingCleanup)
    {
        llOwnerSay("[Coord] Deploy is awaiting cleanup; scanning stays paused."
            + " Say 'hailsAV cleanup' to finish the upgrade and resume.");
        return;
    }

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

    // Tell nodes how many of them will be sending HTTP concurrently so they
    // can pace against the object-wide throttle (25 requests/20s for the
    // whole linkset). Concurrency = min(ready nodes, queued avatars,
    // MAX_ACTIVE_WORKERS); counting idle nodes would make the send gap
    // needlessly long.
    integer workerCount = llGetListLength(gReadyNodes);
    if (agentCount < workerCount) workerCount = agentCount;
    if (workerCount > MAX_ACTIVE_WORKERS) workerCount = MAX_ACTIVE_WORKERS;
    if (workerCount < 1) workerCount = 1;
    gPacedWorkers = workerCount;
    llMessageLinked(LINK_ALL_OTHERS, MSG_SET_PACING, (string)workerCount, NULL_KEY);

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
        abort_scan_state();
        gDisabled       = FALSE;
        gScannedAvatars = [];
        gScannedTimes   = [];

        gListenHandle = llListen(2, "", llGetOwner(), "");

        if (DEBUG >= 1)
            llOwnerSay("[Coord] Ready. Scanning starts now; nodes join as they register.");

        // No collection window: start with whatever nodes are ready (possibly
        // none) and dispatch to the rest as their MSG_NODE_READY arrives
        llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
        start_scan();
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
            if (!gScanActive)
            {
                start_scan();
            }
        }
        else if (message == "hailsAV wipenodes")
        {
            integer now = llGetUnixTime();
            if (now <= gWipeArmedUntil)
            {
                gWipeArmedUntil = 0;
                do_wipe();
            }
            else
            {
                gWipeArmedUntil = now + 30;
                llOwnerSay("[Coord] This deletes ALL node scripts from the child prims."
                    + " Say 'hailsAV wipenodes' again within 30s to confirm.");
            }
        }
        else if (message == "hailsAV deploy")
        {
            string scriptName = find_node_script();
            if (scriptName != "")
            {
                gAutoCleanup = FALSE;
                do_deploy(scriptName);
            }
        }
        else if (message == "hailsAV redeploy")
        {
            // Deploy FIRST (same-named scripts are silently replaced in the
            // prims), clean up old versions after registrations confirm the
            // loads worked. Never wipe before deploying: a wiped prim has
            // nothing left to recover with if the loads fail.
            string scriptName = find_node_script();
            if (scriptName != "")
            {
                gAutoCleanup = TRUE;
                do_deploy(scriptName);
            }
        }
        else if (message == "hailsAV cleanup")
        {
            do_cleanup();
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

        if (gDeployReport)
        {
            gDeployReport = FALSE;
            integer registered = llGetListLength(gReadyNodes);
            llOwnerSay("[Coord] Deploy check: " + (string)registered + "/"
                + (string)gDeployTargets + " nodes registered.");

            if (gAutoCleanup && registered >= gDeployTargets)
            {
                gAutoCleanup = FALSE;
                do_cleanup();
                return;
            }
            gAutoCleanup = FALSE;

            if (registered == 0)
            {
                llOwnerSay("[Coord] Nothing registered: the remote loads likely failed"
                    + " (check for shouted DEBUG_CHANNEL errors). The staged copy is"
                    + " still in the root prim; nothing was deleted.");
            }
            else
            {
                llOwnerSay("[Coord] Stragglers re-register via heartbeat (up to 10 min)."
                    + " When satisfied, say 'hailsAV cleanup' to purge old versions,"
                    + " remove the staged root copy, and start scanning.");
            }
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
            // Link numbers may have shifted — reset all nodes and restart.
            // Cooldown history (gScannedAvatars/gScannedTimes) is preserved
            abort_scan_state();
            llMessageLinked(LINK_ALL_OTHERS, MSG_RESET_NODES, "", NULL_KEY);
            if (DEBUG >= 1) llOwnerSay("[Coord] Linkset changed. Restarting scan; nodes rejoin as they register.");
            start_scan();
        }
    }
}
