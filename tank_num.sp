/*
This plugin is intended to increase Tank spawn intensity in Left 4 Dead 2: whenever the map/Director spawns a Tank,
the plugin automatically spawns one additional Tank near that Tank.

It uses an event-driven design rather than polling, combined with delayed confirmation, failure retries, and multiple
candidate spawn offsets to maximize success rate and avoid recursive triggering.

Overall, the design aims to produce a stable, controllable, and visually reasonable multi-Tank spawn effect without
meaningfully increasing CPU cost.
*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

public Plugin myinfo =
{
    name        = "L4D2 Tank Mirror Spawner (Anchor Tank + Retry)",
    author      = "me",
    description = "When a Tank spawns, spawn one extra Tank near that Tank. Event-driven with retries and multi-position attempts.",
    version     = "1.5.0",
    url         = ""
};

ConVar g_cvEnable;
ConVar g_cvDebug;

ConVar g_cvDelay;            // Delay before the first attempt after an external Tank spawns
ConVar g_cvRetryCount;       // Maximum retry count after the first attempt
ConVar g_cvRetryInterval;    // Interval between retries
ConVar g_cvMaxExtraPerMap;   // Maximum extra Tanks spawned by this plugin per map
ConVar g_cvMaxTotalTanks;    // Maximum total alive Tanks allowed (including extras)

// State
int   g_iExtraSpawnedThisMap = 0;

// Anti-recursion: Tanks spawned by this plugin also trigger player_spawn and must be ignored
int   g_iIgnoreNextTankSpawns = 0;
float g_fLastManualSpawnTime  = 0.0;

// De-dup: the same Tank may trigger repeated spawn chains within a short time window
float g_fLastHandledTime[MAXPLAYERS + 1];

// Candidate offset positions (around the anchor Tank)
static const float g_Offsets[][3] =
{
    { 260.0,  160.0, 0.0 },
    { 260.0, -160.0, 0.0 },
    {-260.0,  160.0, 0.0 },
    {-260.0, -160.0, 0.0 },
    { 360.0,    0.0, 0.0 },
    {-360.0,    0.0, 0.0 },
    {   0.0,  360.0, 0.0 },
    {   0.0, -360.0, 0.0 }
};

public void OnPluginStart()
{
    g_cvEnable         = CreateConVar("sm_tank_mirror_enable", "1", "Enable tank mirror spawner.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDebug          = CreateConVar("sm_tank_mirror_debug", "0", "Debug output (1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvDelay          = CreateConVar("sm_tank_mirror_delay", "0.50", "Delay seconds after external Tank spawn before first attempt.", FCVAR_NOTIFY, true, 0.0, true, 3.0);
    g_cvRetryCount     = CreateConVar("sm_tank_mirror_retry_count", "3", "Max retries after the first attempt.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvRetryInterval  = CreateConVar("sm_tank_mirror_retry_interval", "0.60", "Seconds between retries.", FCVAR_NOTIFY, true, 0.1, true, 5.0);

    g_cvMaxExtraPerMap = CreateConVar("sm_tank_mirror_max_extra_per_map", "8", "Max extra tanks spawned by this plugin per map.", FCVAR_NOTIFY, true, 0.0, true, 64.0);
    g_cvMaxTotalTanks  = CreateConVar("sm_tank_mirror_max_total_tanks", "4", "Max total alive tanks allowed (including extra).", FCVAR_NOTIFY, true, 1.0, true, 32.0);

    HookEvent("round_start", Event_Reset, EventHookMode_PostNoCopy);
    HookEvent("mission_lost", Event_Reset, EventHookMode_PostNoCopy);
    HookEvent("finale_win", Event_Reset, EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_Reset, EventHookMode_PostNoCopy);

    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

    ResetState();
    DebugLog("Plugin started.");
}

public void OnMapStart() { ResetState(); }
public void OnMapEnd()   { ResetState(); }

public Action Event_Reset(Event event, const char[] name, bool dontBroadcast)
{
    ResetState();
    return Plugin_Continue;
}

void ResetState()
{
    g_iExtraSpawnedThisMap = 0;
    g_iIgnoreNextTankSpawns = 0;
    g_fLastManualSpawnTime = 0.0;

    for (int i = 1; i <= MaxClients; i++)
        g_fLastHandledTime[i] = 0.0;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients)
        return Plugin_Continue;

    if (!IsClientInGame(client))
        return Plugin_Continue;

    if (GetClientTeam(client) != 3) // Infected
        return Plugin_Continue;

    if (!IsClientTank(client))
        return Plugin_Continue;

    float now = GetEngineTime();

    // De-bounce: avoid duplicate spawn-chain triggers for the same Tank
    if (now - g_fLastHandledTime[client] < 0.30)
    {
        DebugLog("Debounce tank spawn: client=%d", client);
        return Plugin_Continue;
    }
    g_fLastHandledTime[client] = now;

    // Anti-recursion: ignore Tanks spawned by this plugin itself
    if (g_iIgnoreNextTankSpawns > 0 && (now - g_fLastManualSpawnTime) < 2.0)
    {
        g_iIgnoreNextTankSpawns--;
        DebugLog("Ignore manual-spawn tank spawn: client=%d ignore_left=%d", client, g_iIgnoreNextTankSpawns);
        return Plugin_Continue;
    }

    // Limit check: per-map extra spawn cap
    if (g_iExtraSpawnedThisMap >= g_cvMaxExtraPerMap.IntValue)
    {
        DebugLog("Stop: extra_per_map limit reached (%d).", g_cvMaxExtraPerMap.IntValue);
        return Plugin_Continue;
    }

    // Limit check: total alive Tank cap
    int aliveTanks = CountAliveTanks();
    if (aliveTanks >= g_cvMaxTotalTanks.IntValue)
    {
        DebugLog("Stop: total tank limit reached (alive=%d limit=%d).", aliveTanks, g_cvMaxTotalTanks.IntValue);
        return Plugin_Continue;
    }

    DebugLog("External Tank detected: client=%d userid=%d aliveTanks=%d schedule mirror task.", client, userid, aliveTanks);

    // Create mirror task: retriesUsed=0, offsetIndex=0, anchorUserId=userid
    DataPack dp = new DataPack();
    dp.WriteCell(0);       // retriesUsed
    dp.WriteCell(0);       // offsetIndex
    dp.WriteCell(userid);  // anchorUserId (external Tank)

    CreateTimer(g_cvDelay.FloatValue, Timer_MirrorTask, dp, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

public Action L4D_OnStagger(int target, int source)
{
    // target: entity being staggered (usually a player)
    // source: the stagger source (may be a client, an entity, or even -1)

    if (!GetConVarBool(g_hEnable))
        return Plugin_Continue;

    if (target < 1 || target > MaxClients || !IsClientInGame(target) || !IsPlayerAlive(target))
        return Plugin_Continue;

    if (GetClientTeam(target) != TEAM_SURVIVOR)
        return Plugin_Continue;

    // Only handle "rock-caused stagger"
    if (source <= MaxClients || !IsValidEntity(source))
        return Plugin_Continue;

    char cls[64];
    GetEntityClassname(source, cls, sizeof cls);
    if (!StrEqual(cls, "tank_rock", false))
        return Plugin_Continue;

    // Reuse your block check: must be within the swing window + within the forward cone
    if (CanBlockRockNow(target, source))
    {
        // Key point: directly cancel stagger (stun)
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public Action Timer_MirrorTask(Handle timer, DataPack dp)
{
    dp.Reset();
    int retriesUsed  = dp.ReadCell();
    int offsetIndex  = dp.ReadCell();
    int anchorUserId = dp.ReadCell();

    if (!g_cvEnable.BoolValue)
    {
        delete dp;
        return Plugin_Stop;
    }

    // Re-check limits
    if (g_iExtraSpawnedThisMap >= g_cvMaxExtraPerMap.IntValue)
    {
        DebugLog("MirrorTask stop: extra_per_map limit reached.");
        delete dp;
        return Plugin_Stop;
    }

    int aliveTanks = CountAliveTanks();
    if (aliveTanks >= g_cvMaxTotalTanks.IntValue)
    {
        DebugLog("MirrorTask stop: total tank limit reached.");
        delete dp;
        return Plugin_Stop;
    }

    // Prefer using the external Tank's current position as anchor; if invalid, fallback to any alive survivor
    float anchorPos[3], anchorAng[3];
    bool hasAnchor = GetAnchorTankPos(anchorUserId, anchorPos, anchorAng);
    if (!hasAnchor)
    {
        if (!GetAnyAliveSurvivorPos(anchorPos, anchorAng))
        {
            DebugLog("MirrorTask abort: no valid anchor (tank gone, no survivor).");
            delete dp;
            return Plugin_Stop;
        }
        DebugLog("MirrorTask: tank anchor missing -> fallback survivor anchor.");
    }

    int offsetsCount = sizeof(g_Offsets);

    if (offsetIndex >= offsetsCount)
    {
        int maxRetries = g_cvRetryCount.IntValue;
        if (retriesUsed >= maxRetries)
        {
            DebugLog("MirrorTask failed: retries exhausted (%d).", maxRetries);
            delete dp;
            return Plugin_Stop;
        }

        retriesUsed++;
        offsetIndex = 0;

        DebugLog("MirrorTask retry round: retriesUsed=%d / %d", retriesUsed, maxRetries);

        dp.Reset();
        dp.WriteCell(retriesUsed);
        dp.WriteCell(offsetIndex);
        dp.WriteCell(anchorUserId);

        CreateTimer(g_cvRetryInterval.FloatValue, Timer_MirrorTask, dp, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    float pos[3], ang[3];
    ang = anchorAng;

    pos[0] = anchorPos[0] + g_Offsets[offsetIndex][0];
    pos[1] = anchorPos[1] + g_Offsets[offsetIndex][1];
    pos[2] = anchorPos[2] + g_Offsets[offsetIndex][2];

    // Pre-register ignore: the next Tank spawn event is likely from the one we are about to spawn
    g_iIgnoreNextTankSpawns++;
    g_fLastManualSpawnTime = GetEngineTime();

    int ent = L4D2_SpawnTank(pos, ang);
    if (ent > 0)
    {
        g_iExtraSpawnedThisMap++;
        DebugLog("MirrorTask spawn OK: ent=%d extra_this_map=%d (offsetIndex=%d)", ent, g_iExtraSpawnedThisMap, offsetIndex);
        delete dp;
        return Plugin_Stop;
    }

    // Failed: rollback ignore counter to avoid suppressing a real external Tank later
    if (g_iIgnoreNextTankSpawns > 0)
        g_iIgnoreNextTankSpawns--;

    DebugLog("MirrorTask spawn FAIL at offsetIndex=%d (try next).", offsetIndex);

    offsetIndex++;

    dp.Reset();
    dp.WriteCell(retriesUsed);
    dp.WriteCell(offsetIndex);
    dp.WriteCell(anchorUserId);

    // Advance attempts quickly within the same retry round
    CreateTimer(0.08, Timer_MirrorTask, dp, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

bool GetAnchorTankPos(int anchorUserId, float pos[3], float ang[3])
{
    int client = GetClientOfUserId(anchorUserId);
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (GetClientTeam(client) != 3) return false;
    if (!IsPlayerAlive(client)) return false;
    if (!IsClientTank(client)) return false;

    // Use the "current" position (after delays/retries, script teleport/init is usually completed)
    GetClientAbsOrigin(client, pos);
    GetClientAbsAngles(client, ang);
    return true;
}

bool IsClientTank(int client)
{
    int zclass = GetEntProp(client, Prop_Send, "m_zombieClass");
    return (zclass == 8);
}

int CountAliveTanks()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (GetClientTeam(i) != 3) continue;
        if (!IsPlayerAlive(i)) continue;
        if (!IsClientTank(i)) continue;
        count++;
    }
    return count;
}

bool GetAnyAliveSurvivorPos(float pos[3], float ang[3])
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (GetClientTeam(i) != 2) continue;
        if (!IsPlayerAlive(i)) continue;

        GetClientAbsOrigin(i, pos);
        GetClientAbsAngles(i, ang);
        return true;
    }
    return false;
}

void DebugLog(const char[] fmt, any ...)
{
    if (!g_cvDebug.BoolValue)
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);

    PrintToServer("[TankMirror] %s", buffer);
    LogMessage("[TankMirror] %s", buffer);
}
