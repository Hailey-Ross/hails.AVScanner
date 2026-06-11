integer MSG_NODE_READY  = 3101520;
integer MSG_ASSIGN      = 5676979;
integer MSG_NODE_DONE   = 2195870;
integer MSG_NODE_ERROR  = 8190093;
integer MSG_RESET_NODES = 1210977;
integer MSG_ABORT_SCAN  = 2798014;
integer MSG_SET_DEBUG   = 4927361;
integer MSG_SET_PACING  = 6602143;
integer MSG_WIPE_NODES  = 7245013;

integer MSG_COORD_REQUEST = 9341782;
integer MSG_COORD_ASSIGN  = 4862305;
integer MSG_COORD_DONE    = 6183947;
integer MSG_COORD_ERROR   = 3729516;
integer MSG_SCAN_STARTED  = 5094821;

integer DEPLOY_PIN = 84150193;  // must match all scripts

// Must match Coordinator A and Node: NUM_COORDINATORS = 2, NODE_START_LINK = 2
integer NUM_COORDINATORS = 2;
integer NODE_START_LINK  = 2;
integer COORD_A_LINK     = 1;

integer DEBUG              = 0;  // 0 = off  1 = standard  2 = verbose
integer MAX_ACTIVE_WORKERS = 10;

integer gMyLinkNumber    = 0;
list    gReadyNodes      = [];
list    gAssignedNodes   = [];
list    gAssignedAvatars = [];
integer gPendingCount    = 0;
list    gRetryQueue      = [];
list    gSkippedAvatars  = [];

reset_b_state()
{
    gReadyNodes      = [];
    gAssignedNodes   = [];
    gAssignedAvatars = [];
    gPendingCount    = 0;
    gRetryQueue      = [];
    gSkippedAvatars  = [];
}

dispatch_to_ready_nodes()
{
    while (llGetListLength(gReadyNodes) > 0
           && gPendingCount < MAX_ACTIVE_WORKERS
           && llGetListLength(gRetryQueue) > 0)
    {
        integer nodeLink = llList2Integer(gReadyNodes, 0);
        gReadyNodes = llDeleteSubList(gReadyNodes, 0, 0);
        key avatarId    = llList2Key(gRetryQueue, 0);
        gRetryQueue = llDeleteSubList(gRetryQueue, 0, 0);
        gPendingCount++;
        gAssignedNodes   += [nodeLink];
        gAssignedAvatars += [avatarId];
        llMessageLinked(nodeLink, MSG_ASSIGN, (string)avatarId, avatarId);
        if (DEBUG >= 2)
            llOwnerSay("[Coord B] -> Node " + (string)nodeLink + " (retry) | " + (string)avatarId);
    }
}

request_work_for_ready_nodes()
{
    integer capacity = MAX_ACTIVE_WORKERS - gPendingCount;
    integer ready    = llGetListLength(gReadyNodes);
    integer count;
    if (ready < capacity) count = ready;
    else count = capacity;
    integer i;
    for (i = 0; i < count; i++)
        llMessageLinked(COORD_A_LINK, MSG_COORD_REQUEST, "", NULL_KEY);
}

wake_idle_nodes()
{
    integer primCount = llGetObjectPrimCount(llGetKey());
    if (primCount <= 0) primCount = llGetNumberOfPrims();
    integer link;
    for (link = NODE_START_LINK + 1; link <= primCount; link += NUM_COORDINATORS)
    {
        if (link != gMyLinkNumber)
            llMessageLinked(link, MSG_RESET_NODES, "", NULL_KEY);
    }
}

default
{
    state_entry()
    {
        llSetRemoteScriptAccessPin(DEPLOY_PIN);
        gMyLinkNumber = llGetLinkNumber();
        reset_b_state();
        if (DEBUG >= 1) llOwnerSay("[Coord B] Ready at link " + (string)gMyLinkNumber + ".");
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (sender_num == COORD_A_LINK)
        {
            if (num == MSG_SET_DEBUG)
            {
                DEBUG = (integer)str;
                return;
            }
            if (num == MSG_RESET_NODES)
            {
                reset_b_state();
                if (DEBUG >= 1) llOwnerSay("[Coord B] Reset.");
                return;
            }
            if (num == MSG_ABORT_SCAN)
            {
                reset_b_state();
                if (DEBUG >= 1) llOwnerSay("[Coord B] Abort.");
                return;
            }
            if (num == MSG_SCAN_STARTED)
            {
                if (llGetListLength(gReadyNodes) > 0)
                    request_work_for_ready_nodes();
                else
                    wake_idle_nodes();
                return;
            }
            if (num == MSG_COORD_ASSIGN)
            {
                key avatarId = (key)str;
                if (llGetListLength(gReadyNodes) == 0)
                {
                    gRetryQueue += [avatarId];
                    if (DEBUG >= 2)
                        llOwnerSay("[Coord B] No ready node for " + str + "; queued.");
                    return;
                }
                integer nodeLink = llList2Integer(gReadyNodes, 0);
                gReadyNodes = llDeleteSubList(gReadyNodes, 0, 0);
                gPendingCount++;
                gAssignedNodes   += [nodeLink];
                gAssignedAvatars += [avatarId];
                llMessageLinked(nodeLink, MSG_ASSIGN, str, avatarId);
                if (DEBUG >= 2)
                    llOwnerSay("[Coord B] -> Node " + (string)nodeLink + " | " + str);
                return;
            }
            return;
        }

        if (sender_num < NODE_START_LINK
            || (sender_num - NODE_START_LINK) % NUM_COORDINATORS != 1)
            return;

        if (num == MSG_NODE_READY)
        {
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
                        llOwnerSay("[Coord B] Node " + (string)nodeLink + " re-registered. Retry: " + (string)lostAvatar);
                }
                else
                {
                    llMessageLinked(COORD_A_LINK, MSG_COORD_ERROR, (string)lostAvatar, lostAvatar);
                    if (DEBUG >= 2)
                        llOwnerSay("[Coord B] Node " + (string)nodeLink + " re-registered again. Skipping: " + (string)lostAvatar);
                }
            }
            if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                gReadyNodes += [nodeLink];
            dispatch_to_ready_nodes();
            if (llGetListLength(gRetryQueue) == 0 && gPendingCount < MAX_ACTIVE_WORKERS)
                llMessageLinked(COORD_A_LINK, MSG_COORD_REQUEST, "", NULL_KEY);
            return;
        }

        if (num == MSG_NODE_DONE || num == MSG_NODE_ERROR)
        {
            integer nodeLink = sender_num;
            integer idx = llListFindList(gAssignedNodes, [nodeLink]);
            string completedAvatar = "";
            if (idx != -1)
            {
                completedAvatar  = (string)llList2Key(gAssignedAvatars, idx);
                gAssignedNodes   = llDeleteSubList(gAssignedNodes, idx, idx);
                gAssignedAvatars = llDeleteSubList(gAssignedAvatars, idx, idx);
            }
            if (gPendingCount > 0) gPendingCount--;
            if (DEBUG >= 1)
            {
                string label = "DONE";
                if (num != MSG_NODE_DONE) label = "ERROR";
                llOwnerSay("[Coord B] Node " + (string)nodeLink + " " + label
                    + " | Pending: " + (string)gPendingCount);
            }
            if (num == MSG_NODE_DONE)
                llMessageLinked(COORD_A_LINK, MSG_COORD_DONE, completedAvatar, (key)completedAvatar);
            else
                llMessageLinked(COORD_A_LINK, MSG_COORD_ERROR, completedAvatar, (key)completedAvatar);
            if (llListFindList(gReadyNodes, [nodeLink]) == -1)
                gReadyNodes += [nodeLink];
            dispatch_to_ready_nodes();
            if (llGetListLength(gRetryQueue) == 0 && gPendingCount < MAX_ACTIVE_WORKERS)
                llMessageLinked(COORD_A_LINK, MSG_COORD_REQUEST, "", NULL_KEY);
            return;
        }
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
        {
            gMyLinkNumber = llGetLinkNumber();
            reset_b_state();
            if (DEBUG >= 1) llOwnerSay("[Coord B] Linkset changed. State reset.");
        }
    }
}
