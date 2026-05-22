/*
 * L4D2 SI Unreachable Cleaner
 *
 * 简单说明：
 *   低算力清理插件。它不会每帧检查所有特感，而是按固定间隔轮询少量特感。
 *   插件通过距离、位移、是否接近幸存者、是否被幸存者看到、是否正在控人等条件，
 *   判断特感是否长期无法靠近幸存者，然后清除这些无效特感。
 *
 * 使用方法：
 *   1. 保存为 addons/sourcemod/scripting/l4d2_si_unreachable_cleaner.sp
 *   2. 用 spcomp 编译
 *   3. 把生成的 .smx 放到 addons/sourcemod/plugins/
 *   4. 重启服务器或换图
 *
 * 主要控制台变量：
 *   l4d2_si_stuck_enable        1      是否启用插件
 *   l4d2_si_stuck_interval      1.0    每次检测间隔，建议 1.0
 *   l4d2_si_stuck_checks        1      每次检测几只特感，建议 1 或 2
 *   l4d2_si_stuck_protect       10.0   特感生成后的保护时间
 *   l4d2_si_stuck_close         700.0  离幸存者小于该距离时绝不清除
 *   l4d2_si_stuck_far           1200.0 超过该距离才开始怀疑
 *   l4d2_si_stuck_veryfar       2200.0 超过该距离会更快增加怀疑分
 *   l4d2_si_stuck_visible       1800.0 在该距离内如果幸存者能直线看到它，则不清除
 *   l4d2_si_stuck_minmove       80.0   每次采样移动少于该值，认为可能卡住
 *   l4d2_si_stuck_minprogress   80.0   每次采样没有靠近这么多，认为没有有效接近
 *   l4d2_si_stuck_score         6      怀疑分达到多少开始确认
 *   l4d2_si_stuck_fails         2      连续确认失败多少次后清除
 *   l4d2_si_stuck_killdist      900.0  最终清除时必须仍然大于该距离
 *   l4d2_si_stuck_bots_only     1      只清理 AI 特感，建议保持 1
 *   l4d2_si_stuck_debug         0      调试输出
 *
 * 注意：
 *   这是无外部扩展版本，不能做真正的 NavMesh 路径连通性判断。
 *   它的目标是以很低 CPU 成本清除长期无效、无法接近幸存者的特感。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define ZC_SMOKER  1
#define ZC_BOOMER  2
#define ZC_HUNTER  3
#define ZC_SPITTER 4
#define ZC_JOCKEY  5
#define ZC_CHARGER 6
#define ZC_TANK    8

#define MAX_STUCK_SCORE 100

public Plugin myinfo =
{
    name = "L4D2 SI Unreachable Cleaner",
    author = "ChatGPT",
    description = "Low CPU cleanup for unreachable or useless special infected.",
    version = "1.0.0",
    url = ""
};

ConVar g_cvEnable;
ConVar g_cvInterval;
ConVar g_cvChecks;
ConVar g_cvBotsOnly;
ConVar g_cvProtectTime;
ConVar g_cvCloseDist;
ConVar g_cvFarDist;
ConVar g_cvVeryFarDist;
ConVar g_cvVisibleDist;
ConVar g_cvMinMove;
ConVar g_cvMinProgress;
ConVar g_cvScoreLimit;
ConVar g_cvFailLimit;
ConVar g_cvKillDist;
ConVar g_cvDebug;

Handle g_hTimer = null;
int g_iCursor = 1;

float g_fSpawnTime[MAXPLAYERS + 1];
bool g_bHaveSample[MAXPLAYERS + 1];
float g_fLastOrigin[MAXPLAYERS + 1][3];
float g_fLastDistance[MAXPLAYERS + 1];

int g_iStuckScore[MAXPLAYERS + 1];
int g_iFailCount[MAXPLAYERS + 1];

bool g_bHasTongueVictim;
bool g_bHasPounceVictim;
bool g_bHasJockeyVictim;
bool g_bHasPummelVictim;
bool g_bHasCarryVictim;

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        SetFailState("This plugin only supports Left 4 Dead 2.");
    }

    g_cvEnable = CreateConVar(
        "l4d2_si_stuck_enable",
        "1",
        "Enable SI unreachable cleaner.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvInterval = CreateConVar(
        "l4d2_si_stuck_interval",
        "1.0",
        "Timer interval in seconds. Recommended: 1.0",
        FCVAR_NOTIFY,
        true,
        0.2,
        true,
        10.0
    );

    g_cvChecks = CreateConVar(
        "l4d2_si_stuck_checks",
        "1",
        "How many SI clients to check per timer tick. Recommended: 1 or 2.",
        FCVAR_NOTIFY,
        true,
        1.0,
        true,
        8.0
    );

    g_cvBotsOnly = CreateConVar(
        "l4d2_si_stuck_bots_only",
        "1",
        "Only clean AI controlled infected. Recommended: 1.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvProtectTime = CreateConVar(
        "l4d2_si_stuck_protect",
        "10.0",
        "Spawn protection time. SI younger than this will not be cleaned.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        60.0
    );

    g_cvCloseDist = CreateConVar(
        "l4d2_si_stuck_close",
        "700.0",
        "If SI is closer than this to any survivor, it will not be cleaned.",
        FCVAR_NOTIFY,
        true,
        100.0,
        true,
        3000.0
    );

    g_cvFarDist = CreateConVar(
        "l4d2_si_stuck_far",
        "1200.0",
        "Distance above which SI starts to be considered suspicious.",
        FCVAR_NOTIFY,
        true,
        300.0,
        true,
        5000.0
    );

    g_cvVeryFarDist = CreateConVar(
        "l4d2_si_stuck_veryfar",
        "2200.0",
        "Very far distance. SI beyond this gains suspicion faster.",
        FCVAR_NOTIFY,
        true,
        500.0,
        true,
        8000.0
    );

    g_cvVisibleDist = CreateConVar(
        "l4d2_si_stuck_visible",
        "1800.0",
        "Within this distance, visible SI will not be cleaned.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        5000.0
    );

    g_cvMinMove = CreateConVar(
        "l4d2_si_stuck_minmove",
        "80.0",
        "If SI moves less than this between samples, it may be stuck.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1000.0
    );

    g_cvMinProgress = CreateConVar(
        "l4d2_si_stuck_minprogress",
        "80.0",
        "If SI does not get closer by this amount between samples, it may be useless.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1000.0
    );

    g_cvScoreLimit = CreateConVar(
        "l4d2_si_stuck_score",
        "6",
        "Suspicion score required before final confirmation begins.",
        FCVAR_NOTIFY,
        true,
        1.0,
        true,
        50.0
    );

    g_cvFailLimit = CreateConVar(
        "l4d2_si_stuck_fails",
        "2",
        "How many final failed confirmations are required before cleaning SI.",
        FCVAR_NOTIFY,
        true,
        1.0,
        true,
        10.0
    );

    g_cvKillDist = CreateConVar(
        "l4d2_si_stuck_killdist",
        "900.0",
        "SI must still be farther than this during final confirmation before being cleaned.",
        FCVAR_NOTIFY,
        true,
        100.0,
        true,
        5000.0
    );

    g_cvDebug = CreateConVar(
        "l4d2_si_stuck_debug",
        "0",
        "Enable debug logging.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvInterval.AddChangeHook(OnIntervalChanged);

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

    CacheVictimProps();

    AutoExecConfig(true, "l4d2_si_unreachable_cleaner");

    ResetAllClients();
    RestartTimer();
}

public void OnMapStart()
{
    ResetAllClients();
    RestartTimer();
}

public void OnMapEnd()
{
    delete g_hTimer;
}

public void OnClientDisconnect(int client)
{
    ResetClientData(client);
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RestartTimer();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    ResetAllClients();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (IsValidClient(client))
    {
        ResetClientData(client);

        if (IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED)
        {
            g_fSpawnTime[client] = GetGameTime();
        }
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (IsValidClient(client))
    {
        ResetClientData(client);
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (IsValidClient(client))
    {
        ResetClientData(client);
    }
}

void CacheVictimProps()
{
    g_bHasTongueVictim = FindSendPropInfo("CTerrorPlayer", "m_tongueVictim") > 0;
    g_bHasPounceVictim = FindSendPropInfo("CTerrorPlayer", "m_pounceVictim") > 0;
    g_bHasJockeyVictim = FindSendPropInfo("CTerrorPlayer", "m_jockeyVictim") > 0;
    g_bHasPummelVictim = FindSendPropInfo("CTerrorPlayer", "m_pummelVictim") > 0;
    g_bHasCarryVictim = FindSendPropInfo("CTerrorPlayer", "m_carryVictim") > 0;
}

void RestartTimer()
{
    delete g_hTimer;

    float interval = g_cvInterval.FloatValue;

    if (interval < 0.2)
    {
        interval = 0.2;
    }

    g_hTimer = CreateTimer(interval, Timer_CheckSpecials, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckSpecials(Handle timer)
{
    if (!g_cvEnable.BoolValue)
    {
        return Plugin_Continue;
    }

    bool processed[MAXPLAYERS + 1];

    int checks = g_cvChecks.IntValue;

    if (checks < 1)
    {
        checks = 1;
    }
    else if (checks > 8)
    {
        checks = 8;
    }

    for (int i = 0; i < checks; i++)
    {
        int client = FindNextSpecialInfected(processed);

        if (client <= 0)
        {
            break;
        }

        processed[client] = true;
        ProcessSpecialInfected(client);
    }

    return Plugin_Continue;
}

int FindNextSpecialInfected(bool processed[MAXPLAYERS + 1])
{
    for (int i = 0; i < MaxClients; i++)
    {
        int client = g_iCursor;

        g_iCursor++;

        if (g_iCursor > MaxClients)
        {
            g_iCursor = 1;
        }

        if (processed[client])
        {
            continue;
        }

        if (IsValidSpecialInfected(client))
        {
            return client;
        }
    }

    return 0;
}

void ProcessSpecialInfected(int client)
{
    if (!IsValidSpecialInfected(client))
    {
        ResetClientData(client);
        return;
    }

    if (g_fSpawnTime[client] <= 0.0)
    {
        g_fSpawnTime[client] = GetGameTime();
    }

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");

    if (IsPinningSurvivor(client, zombieClass))
    {
        DebugLog("Reset: %N is pinning survivor.", client);
        ReduceSuspicion(client, 4, true);
        StoreCurrentSample(client);
        return;
    }

    float aliveTime = GetGameTime() - g_fSpawnTime[client];

    if (aliveTime < g_cvProtectTime.FloatValue)
    {
        StoreCurrentSample(client);
        return;
    }

    float nearestDistance;
    int nearestSurvivor;

    if (!GetNearestSurvivorDistance(client, nearestDistance, nearestSurvivor))
    {
        ResetClientData(client);
        return;
    }

    if (nearestDistance <= g_cvCloseDist.FloatValue)
    {
        DebugLog("Reset: %N is close to survivor. Distance: %.1f", client, nearestDistance);
        ReduceSuspicion(client, 3, true);
        StoreCurrentSample(client);
        return;
    }

    if (IsVisibleToAnySurvivor(client))
    {
        DebugLog("Reset: %N is visible to survivor.", client);
        ReduceSuspicion(client, 3, true);
        StoreCurrentSample(client);
        return;
    }

    if (!g_bHaveSample[client])
    {
        StoreCurrentSample(client);
        return;
    }

    float origin[3];
    GetClientAbsOrigin(client, origin);

    float moved = GetVectorDistance(origin, g_fLastOrigin[client]);
    float progress = g_fLastDistance[client] - nearestDistance;

    int addScore = 0;

    if (nearestDistance >= g_cvFarDist.FloatValue)
    {
        if (moved < g_cvMinMove.FloatValue)
        {
            addScore++;
        }

        if (progress < g_cvMinProgress.FloatValue)
        {
            addScore++;
        }

        if (nearestDistance >= g_cvVeryFarDist.FloatValue)
        {
            addScore++;
        }
    }
    else
    {
        float strictMove = g_cvMinMove.FloatValue * 0.5;

        if (moved < strictMove && progress <= 0.0)
        {
            addScore++;
        }
    }

    if (addScore > 0)
    {
        g_iStuckScore[client] += addScore;

        if (g_iStuckScore[client] > MAX_STUCK_SCORE)
        {
            g_iStuckScore[client] = MAX_STUCK_SCORE;
        }

        DebugLog(
            "Suspicious: %N score=%d add=%d dist=%.1f moved=%.1f progress=%.1f",
            client,
            g_iStuckScore[client],
            addScore,
            nearestDistance,
            moved,
            progress
        );
    }
    else
    {
        ReduceSuspicion(client, 2, true);
        StoreCurrentSample(client);
        return;
    }

    if (g_iStuckScore[client] >= g_cvScoreLimit.IntValue)
    {
        if (FinalConfirmFailed(client, nearestDistance, moved, progress))
        {
            g_iFailCount[client]++;

            DebugLog(
                "Confirm fail: %N fail=%d score=%d dist=%.1f moved=%.1f progress=%.1f",
                client,
                g_iFailCount[client],
                g_iStuckScore[client],
                nearestDistance,
                moved,
                progress
            );
        }
        else
        {
            g_iFailCount[client] = 0;
            ReduceSuspicion(client, 2, false);
        }
    }

    if (g_iFailCount[client] >= g_cvFailLimit.IntValue)
    {
        CleanSpecialInfected(client, nearestDistance, moved, progress);
        return;
    }

    StoreCurrentSample(client);
}

bool FinalConfirmFailed(int client, float nearestDistance, float moved, float progress)
{
    if (!IsValidSpecialInfected(client))
    {
        return false;
    }

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");

    if (IsPinningSurvivor(client, zombieClass))
    {
        return false;
    }

    if (nearestDistance < g_cvKillDist.FloatValue)
    {
        return false;
    }

    if (IsVisibleToAnySurvivor(client))
    {
        return false;
    }

    if (moved >= g_cvMinMove.FloatValue)
    {
        return false;
    }

    if (progress >= g_cvMinProgress.FloatValue)
    {
        return false;
    }

    return true;
}

void CleanSpecialInfected(int client, float nearestDistance, float moved, float progress)
{
    if (!IsValidSpecialInfected(client))
    {
        ResetClientData(client);
        return;
    }

    DebugLog(
        "Cleaning SI: %N dist=%.1f moved=%.1f progress=%.1f score=%d fails=%d",
        client,
        nearestDistance,
        moved,
        progress,
        g_iStuckScore[client],
        g_iFailCount[client]
    );

    ForcePlayerSuicide(client);
    ResetClientData(client);
}

bool IsValidSpecialInfected(int client)
{
    if (!IsValidClient(client))
    {
        return false;
    }

    if (!IsClientInGame(client))
    {
        return false;
    }

    if (!IsPlayerAlive(client))
    {
        return false;
    }

    if (GetClientTeam(client) != TEAM_INFECTED)
    {
        return false;
    }

    if (g_cvBotsOnly.BoolValue && !IsFakeClient(client))
    {
        return false;
    }

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");

    if (zombieClass <= 0)
    {
        return false;
    }

    if (zombieClass == ZC_TANK)
    {
        return false;
    }

    if (GetEntProp(client, Prop_Send, "m_isGhost") != 0)
    {
        return false;
    }

    return true;
}

bool IsPinningSurvivor(int client, int zombieClass)
{
    int victim = -1;

    switch (zombieClass)
    {
        case ZC_SMOKER:
        {
            if (g_bHasTongueVictim)
            {
                victim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
            }
        }

        case ZC_HUNTER:
        {
            if (g_bHasPounceVictim)
            {
                victim = GetEntPropEnt(client, Prop_Send, "m_pounceVictim");
            }
        }

        case ZC_JOCKEY:
        {
            if (g_bHasJockeyVictim)
            {
                victim = GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");
            }
        }

        case ZC_CHARGER:
        {
            if (g_bHasPummelVictim)
            {
                victim = GetEntPropEnt(client, Prop_Send, "m_pummelVictim");

                if (IsValidSurvivor(victim))
                {
                    return true;
                }
            }

            if (g_bHasCarryVictim)
            {
                victim = GetEntPropEnt(client, Prop_Send, "m_carryVictim");
            }
        }
    }

    return IsValidSurvivor(victim);
}

bool GetNearestSurvivorDistance(int client, float &nearestDistance, int &nearestSurvivor)
{
    float siOrigin[3];
    GetClientAbsOrigin(client, siOrigin);

    nearestDistance = 999999.0;
    nearestSurvivor = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i))
        {
            continue;
        }

        float survivorOrigin[3];
        GetClientAbsOrigin(i, survivorOrigin);

        float distance = GetVectorDistance(siOrigin, survivorOrigin);

        if (distance < nearestDistance)
        {
            nearestDistance = distance;
            nearestSurvivor = i;
        }
    }

    return nearestSurvivor > 0;
}

bool IsVisibleToAnySurvivor(int client)
{
    float visibleDist = g_cvVisibleDist.FloatValue;

    if (visibleDist <= 0.0)
    {
        return false;
    }

    float siEye[3];
    GetClientEyePosition(client, siEye);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i))
        {
            continue;
        }

        float survivorEye[3];
        GetClientEyePosition(i, survivorEye);

        if (GetVectorDistance(siEye, survivorEye) > visibleDist)
        {
            continue;
        }

        if (HasClearLine(survivorEye, siEye))
        {
            return true;
        }
    }

    return false;
}

bool HasClearLine(const float start[3], const float end[3])
{
    Handle trace = TR_TraceRayFilterEx(
        start,
        end,
        MASK_OPAQUE,
        RayType_EndPoint,
        TraceFilter_IgnorePlayers
    );

    bool blocked = TR_DidHit(trace);
    delete trace;

    return !blocked;
}

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask)
{
    if (entity >= 1 && entity <= MaxClients)
    {
        return false;
    }

    return true;
}

void StoreCurrentSample(int client)
{
    if (!IsValidClient(client) || !IsClientInGame(client))
    {
        return;
    }

    float nearestDistance;
    int nearestSurvivor;

    if (!GetNearestSurvivorDistance(client, nearestDistance, nearestSurvivor))
    {
        return;
    }

    GetClientAbsOrigin(client, g_fLastOrigin[client]);
    g_fLastDistance[client] = nearestDistance;
    g_bHaveSample[client] = true;
}

void ReduceSuspicion(int client, int amount, bool clearFails)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_iStuckScore[client] -= amount;

    if (g_iStuckScore[client] < 0)
    {
        g_iStuckScore[client] = 0;
    }

    if (clearFails)
    {
        g_iFailCount[client] = 0;
    }
}

void ResetClientData(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_fSpawnTime[client] = 0.0;
    g_bHaveSample[client] = false;
    g_fLastDistance[client] = 0.0;
    g_iStuckScore[client] = 0;
    g_iFailCount[client] = 0;

    g_fLastOrigin[client][0] = 0.0;
    g_fLastOrigin[client][1] = 0.0;
    g_fLastOrigin[client][2] = 0.0;
}

void ResetAllClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientData(i);
    }

    g_iCursor = 1;
}

bool IsValidClient(int client)
{
    return client >= 1 && client <= MaxClients;
}

bool IsValidSurvivor(int client)
{
    if (!IsValidClient(client))
    {
        return false;
    }

    if (!IsClientInGame(client))
    {
        return false;
    }

    if (!IsPlayerAlive(client))
    {
        return false;
    }

    if (GetClientTeam(client) != TEAM_SURVIVOR)
    {
        return false;
    }

    return true;
}

void DebugLog(const char[] format, any ...)
{
    if (!g_cvDebug.BoolValue)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);

    PrintToServer("[SI-StuckCleaner] %s", buffer);
}