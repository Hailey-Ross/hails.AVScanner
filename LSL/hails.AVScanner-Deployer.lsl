integer MSG_ABORT_SCAN = 2798014;
integer MSG_WIPE_NODES = 7245013;
integer MSG_NODE_READY = 3101520;

integer DEPLOY_PIN         = 84150193;  // must match all scripts
string  NODE_SCRIPT_PREFIX = "hails.AVScanner_Node";
string  COORD_A_PREFIX     = "hails.AVScanner_Coordinator-A";
string  COORD_B_PREFIX     = "hails.AVScanner_Coordinator-B";

// Set to the link number of the Coordinator B prim in dual-coordinator mode.
// Leave as 0 for single-coordinator mode.
integer COORD_B_LINK = 5;
integer DEBUG        = 0;  // 0 = off  1 = standard  2 = verbose

// Commands (say on channel 2):
//   hailsAV deploy       — push node script to all node prims
//   hailsAV redeploy     — deploy then auto-cleanup on full success
//   hailsAV deploy-coord — push coordinator scripts to their prims
//   hailsAV cleanup      — remove staged root copy; nodes keep deployed version
//   hailsAV wipenodes    — delete all node scripts (two-step confirm)

integer gDeployReport    = FALSE;
integer gDeployTargets   = 0;
integer gRegisteredCount = 0;
integer gAutoCleanup     = FALSE;
integer gWipeArmedUntil  = 0;
integer gListenHandle    = 0;

string find_script(string prefix)
{
    string  found   = "";
    integer matches = 0;
    integer i;
    for (i = 0; i < llGetInventoryNumber(INVENTORY_SCRIPT); i++)
    {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (llSubStringIndex(name, prefix) == 0)
        {
            found = name;
            matches++;
        }
    }
    if (matches == 0)
    {
        llOwnerSay("[Deploy] No script starting with '" + prefix + "' found in root prim.");
        return "";
    }
    if (matches > 1)
    {
        llOwnerSay("[Deploy] Found " + (string)matches + " scripts starting with '" + prefix + "'. Keep exactly one.");
        return "";
    }
    return found;
}

do_deploy_nodes(string scriptName, integer autoCleanup)
{
    llMessageLinked(LINK_ALL_OTHERS, MSG_ABORT_SCAN, "", NULL_KEY);

    integer primCount = llGetObjectPrimCount(llGetKey());
    if (primCount <= 0) primCount = llGetNumberOfPrims();

    integer targets = 0;
    integer link;
    for (link = 2; link <= primCount; link++)
    {
        if (COORD_B_LINK > 0 && link == COORD_B_LINK)
            jump count_skip;
        targets++;
@count_skip;
    }

    if (targets < 1)
    {
        llOwnerSay("[Deploy] No node prims found.");
        return;
    }

    llOwnerSay("[Deploy] Deploying '" + scriptName + "' to " + (string)targets
        + " prims. Expect ~" + (string)(targets * 3) + "s.");

    integer pushed = 0;
    for (link = 2; link <= primCount; link++)
    {
        if (COORD_B_LINK > 0 && link == COORD_B_LINK)
            jump deploy_skip;
        llRemoteLoadScriptPin(llGetLinkKey(link), scriptName, DEPLOY_PIN, TRUE, 0);
        pushed++;
        if (pushed % 10 == 0 && link < primCount)
            llOwnerSay("[Deploy] Pushed to " + (string)pushed + "/" + (string)targets + " prims...");
@deploy_skip;
    }

    gDeployTargets   = targets;
    gDeployReport    = TRUE;
    gRegisteredCount = 0;
    gAutoCleanup     = autoCleanup;
    llSetTimerEvent(10.0);
    llOwnerSay("[Deploy] Push finished. Verifying registrations for 10s...");
}

do_deploy_coordinators()
{
    string coordA = find_script(COORD_A_PREFIX);
    if (coordA == "") return;

    llMessageLinked(LINK_ALL_OTHERS, MSG_ABORT_SCAN, "", NULL_KEY);

    integer primCount = llGetObjectPrimCount(llGetKey());
    if (primCount <= 0) primCount = llGetNumberOfPrims();

    llOwnerSay("[Deploy] Pushing '" + coordA + "' to link 1...");
    llRemoteLoadScriptPin(llGetLinkKey(1), coordA, DEPLOY_PIN, TRUE, 0);

    if (COORD_B_LINK > 0 && COORD_B_LINK <= primCount)
    {
        string coordB = find_script(COORD_B_PREFIX);
        if (coordB != "")
        {
            llOwnerSay("[Deploy] Pushing '" + coordB + "' to link " + (string)COORD_B_LINK + "...");
            llRemoteLoadScriptPin(llGetLinkKey(COORD_B_LINK), coordB, DEPLOY_PIN, TRUE, 0);
        }
    }

    llOwnerSay("[Deploy] Coordinator push done. Scanning resumes when coordinators restart.");
}

do_cleanup()
{
    string nodeScript = find_script(NODE_SCRIPT_PREFIX);
    if (nodeScript == "") return;
    llMessageLinked(LINK_ALL_OTHERS, MSG_WIPE_NODES, nodeScript, NULL_KEY);
    llRemoveInventory(nodeScript);
    llOwnerSay("[Deploy] Cleanup done. Staged copy removed from root prim.");
}

do_wipe()
{
    llMessageLinked(LINK_ALL_OTHERS, MSG_WIPE_NODES, "", NULL_KEY);
    llOwnerSay("[Deploy] Wipe broadcast sent. Node scripts are deleting themselves.");
}

default
{
    state_entry()
    {
        llSetRemoteScriptAccessPin(DEPLOY_PIN);
        gListenHandle = llListen(2, "", llGetOwner(), "");
        if (DEBUG >= 1) llOwnerSay("[Deploy] Ready.");
    }

    listen(integer channel, string name, key id, string message)
    {
        if (id != llGetOwner()) return;
        if (message == "hailsAV deploy")
        {
            string s = find_script(NODE_SCRIPT_PREFIX);
            if (s != "") do_deploy_nodes(s, FALSE);
        }
        else if (message == "hailsAV redeploy")
        {
            string s = find_script(NODE_SCRIPT_PREFIX);
            if (s != "") do_deploy_nodes(s, TRUE);
        }
        else if (message == "hailsAV deploy-coord")
        {
            do_deploy_coordinators();
        }
        else if (message == "hailsAV cleanup")
        {
            do_cleanup();
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
                llOwnerSay("[Deploy] This deletes ALL node scripts. Say 'hailsAV wipenodes' again within 30s to confirm.");
            }
        }
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (gDeployReport && num == MSG_NODE_READY)
            gRegisteredCount++;
    }

    timer()
    {
        llSetTimerEvent(0.0);
        if (gDeployReport)
        {
            gDeployReport = FALSE;
            llOwnerSay("[Deploy] Verify: " + (string)gRegisteredCount + "/" + (string)gDeployTargets + " nodes registered.");
            if (gAutoCleanup && gRegisteredCount >= gDeployTargets)
            {
                gAutoCleanup = FALSE;
                do_cleanup();
                return;
            }
            gAutoCleanup = FALSE;
            if (gRegisteredCount == 0)
                llOwnerSay("[Deploy] No registrations — remote loads may have failed. Staged copy retained.");
            else
                llOwnerSay("[Deploy] Say 'hailsAV cleanup' when satisfied to purge old versions.");
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
    }
}
