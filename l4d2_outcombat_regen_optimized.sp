/*
 * L4D2 Out-of-Combat Regeneration Optimized
 *
 * 简单说明：
 * - 生还者实血低于 50 后，若 5 秒内没有继续掉实血，则开始自动回血。
 * - 回血速度为每 0.3 秒 +1 实血。
 * - 回到 50 实血后停止回血。
 * - 只处理实血，不处理虚血/临时血量。
 * - 倒地、挂边、死亡、非生还者不会回血。
 *
 * 使用方法：
 * 1. 保存为：addons/sourcemod/scripting/l4d2_outcombat_regen_optimized.sp
 * 2. 使用 SourceMod 的 spcomp 编译。
 * 3. 把生成的 .smx 放到：addons/sourcemod/plugins/
 * 4. 重启服务器或换图生效。
 *
 * 优化点：
 * - 不再为每个玩家创建 0.1 秒循环 Timer。
 * - 用 player_hurt 事件记录受伤时间。
 * - 用 1 个全局低频扫描 Timer 兜底。
 * - 用 1 个全局 0.3 秒回血 Timer 处理所有正在回血的玩家。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name        = "L4D2 Out-of-Combat Regen Optimized",
    author      = "me",
    description = "Low-CPU real HP out-of-combat regeneration for L4D2 survivors.",
    version     = "2.0.0",
    url         = ""
};

#define TEAM_SURVIVOR 2

static const int   HP_THRESHOLD        = 50;
static const float SCAN_INTERVAL       = 1.0;
static const float REGEN_DELAY         = 5.0;
static const float REGEN_INTERVAL      = 0.3;
static const int   REGEN_AMOUNT        = 1;

Handle g_hScanTimer  = null;
Handle g_hWakeTimer  = null;
Handle g_hRegenTimer = null;

bool  g_bTracked[MAXPLAYERS + 1];
bool  g_bRegenerating[MAXPLAYERS + 1];
float g_fNextRegenTime[MAXPLAYERS + 1];
int   g_iLastRealHP[MAXPLAYERS + 1];

public void OnPluginStart()
{
    HookEvent("player_hurt",          Event_PlayerHurt,          EventHookMode_Post);
    HookEvent("player_spawn",         Event_PlayerRefresh,       EventHookMode_Post);
    HookEvent("player_death",         Event_PlayerStop,          EventHookMode_Post);
    HookEvent("player_team",          Event_PlayerStop,          EventHookMode_Post);
    HookEvent("player_incapacitated", Event_PlayerStop,          EventHookMode_Post);
    HookEvent("revive_success",       Event_ReviveSuccess,       EventHookMode_Post);
    HookEvent("heal_success",         Event_HealSuccess,         EventHookMode_Post);
    HookEvent("round_start",          Event_RoundReset,          EventHookMode_Post);
    HookEvent("round_end",            Event_RoundReset,          EventHookMode_Post);
    HookEvent("mission_lost",         Event_RoundReset,          EventHookMode_Post);
    HookEvent("map_transition",       Event_RoundReset,          EventHookMode_Post);

    StartScanTimer();

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientVars(i);
    }
}

public void OnMapStart()
{
    ResetAllClients();
    StartScanTimer();
}

public void OnMapEnd()
{
    StopAllTimers();
    ResetAllClients();
}

public void OnPluginEnd()
{
    StopAllTimers();
}

public void OnClientPutInServer(int client)
{
    ResetClientVars(client);
}

public void OnClientDisconnect(int client)
{
    ResetClientVars(client);
}

static void StartScanTimer()
{
    if (g_hScanTimer == null)
    {
        g_hScanTimer = CreateTimer(SCAN_INTERVAL, Timer_Scan, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

static void StopScanTimer()
{
    if (g_hScanTimer != null)
    {
        KillTimer(g_hScanTimer);
        g_hScanTimer = null;
    }
}

static void StopWakeTimer()
{
    if (g_hWakeTimer != null)
    {
        KillTimer(g_hWakeTimer);
        g_hWakeTimer = null;
    }
}

static void StopRegenTimer()
{
    if (g_hRegenTimer != null)
    {
        KillTimer(g_hRegenTimer);
        g_hRegenTimer = null;
    }
}

static void StopAllTimers()
{
    StopScanTimer();
    StopWakeTimer();
    StopRegenTimer();
}

static void ResetAllClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientVars(i);
    }
}

static void ResetClientVars(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bTracked[client]       = false;
    g_bRegenerating[client]  = false;
    g_fNextRegenTime[client] = 0.0;
    g_iLastRealHP[client]    = 0;
}

static bool IsEligibleSurvivor(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return false;
    }

    if (!IsClientInGame(client))
    {
        return false;
    }

    if (GetClientTeam(client) != TEAM_SURVIVOR)
    {
        return false;
    }

    if (!IsPlayerAlive(client))
    {
        return false;
    }

    if (GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0)
    {
        return false;
    }

    if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
    {
        return false;
    }

    return true;
}

static int GetRealHP(int client)
{
    int hp = GetClientHealth(client);

    if (hp < 0)
    {
        hp = 0;
    }

    return hp;
}

static int GetMaxRealHP(int client)
{
    int maxhp = GetEntProp(client, Prop_Data, "m_iMaxHealth");

    if (maxhp <= 0)
    {
        maxhp = 100;
    }

    return maxhp;
}

static int GetRegenTargetHP(int client)
{
    int maxhp = GetMaxRealHP(client);

    if (maxhp < HP_THRESHOLD)
    {
        return maxhp;
    }

    return HP_THRESHOLD;
}

static void StartWaiting(int client, int hp, float now)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bTracked[client]       = true;
    g_bRegenerating[client]  = false;
    g_fNextRegenTime[client] = now + REGEN_DELAY;
    g_iLastRealHP[client]    = hp;

    ScheduleWakeTimer();
}

static void StopTracking(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bTracked[client]       = false;
    g_bRegenerating[client]  = false;
    g_fNextRegenTime[client] = 0.0;
    g_iLastRealHP[client]    = 0;
}

static bool HasTrackedClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bTracked[i])
        {
            return true;
        }
    }

    return false;
}

static bool HasRegeneratingClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bTracked[i] && g_bRegenerating[i])
        {
            return true;
        }
    }

    return false;
}

static void EnsureRegenTimer()
{
    StopWakeTimer();

    if (g_hRegenTimer == null)
    {
        g_hRegenTimer = CreateTimer(REGEN_INTERVAL, Timer_Regen, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}

static void ScheduleWakeTimer()
{
    if (g_hRegenTimer != null)
    {
        StopWakeTimer();
        return;
    }

    StopWakeTimer();

    float now = GetGameTime();
    float earliest = 0.0;
    bool found = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bTracked[i])
        {
            continue;
        }

        if (g_bRegenerating[i])
        {
            continue;
        }

        if (!found || g_fNextRegenTime[i] < earliest)
        {
            earliest = g_fNextRegenTime[i];
            found = true;
        }
    }

    if (!found)
    {
        return;
    }

    float delay = earliest - now;

    if (delay < 0.1)
    {
        delay = 0.1;
    }

    g_hWakeTimer = CreateTimer(delay, Timer_Wake, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void EvaluateClient(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (!IsEligibleSurvivor(client))
    {
        StopTracking(client);
        return;
    }

    int hp = GetRealHP(client);

    if (hp >= HP_THRESHOLD)
    {
        StopTracking(client);
        return;
    }

    float now = GetGameTime();

    if (!g_bTracked[client])
    {
        StartWaiting(client, hp, now);
        return;
    }

    if (hp < g_iLastRealHP[client])
    {
        StartWaiting(client, hp, now);
        return;
    }

    g_iLastRealHP[client] = hp;
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client <= 0)
    {
        return;
    }

    if (!IsEligibleSurvivor(client))
    {
        StopTracking(client);
        return;
    }

    int hp = GetRealHP(client);

    if (hp >= HP_THRESHOLD)
    {
        StopTracking(client);
        return;
    }

    StartWaiting(client, hp, GetGameTime());
}

public void Event_PlayerRefresh(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client <= 0)
    {
        return;
    }

    EvaluateClient(client);
}

public void Event_PlayerStop(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client <= 0)
    {
        return;
    }

    StopTracking(client);
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));

    if (subject > 0)
    {
        EvaluateClient(subject);
    }
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));

    if (subject > 0)
    {
        EvaluateClient(subject);
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client > 0)
    {
        EvaluateClient(client);
    }
}

public void Event_RoundReset(Event event, const char[] name, bool dontBroadcast)
{
    StopWakeTimer();
    StopRegenTimer();
    ResetAllClients();
}

public Action Timer_Scan(Handle timer)
{
    g_hScanTimer = timer;

    float now = GetGameTime();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (!IsEligibleSurvivor(i))
        {
            if (g_bTracked[i])
            {
                StopTracking(i);
            }

            continue;
        }

        int hp = GetRealHP(i);

        if (hp >= HP_THRESHOLD)
        {
            if (g_bTracked[i])
            {
                StopTracking(i);
            }

            continue;
        }

        if (!g_bTracked[i])
        {
            StartWaiting(i, hp, now);
            continue;
        }

        if (hp < g_iLastRealHP[i])
        {
            StartWaiting(i, hp, now);
            continue;
        }

        g_iLastRealHP[i] = hp;
    }

    return Plugin_Continue;
}

public Action Timer_Wake(Handle timer)
{
    g_hWakeTimer = null;

    float now = GetGameTime();
    bool anyActive = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bTracked[i])
        {
            continue;
        }

        if (!IsEligibleSurvivor(i))
        {
            StopTracking(i);
            continue;
        }

        int hp = GetRealHP(i);

        if (hp >= HP_THRESHOLD)
        {
            StopTracking(i);
            continue;
        }

        if (hp < g_iLastRealHP[i])
        {
            StartWaiting(i, hp, now);
            continue;
        }

        g_iLastRealHP[i] = hp;

        if (now >= g_fNextRegenTime[i])
        {
            g_bRegenerating[i] = true;
            anyActive = true;
        }
    }

    if (anyActive)
    {
        EnsureRegenTimer();
    }
    else
    {
        ScheduleWakeTimer();
    }

    return Plugin_Stop;
}

public Action Timer_Regen(Handle timer)
{
    g_hRegenTimer = timer;

    float now = GetGameTime();
    bool anyActive = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bTracked[i])
        {
            continue;
        }

        if (!IsEligibleSurvivor(i))
        {
            StopTracking(i);
            continue;
        }

        int hp = GetRealHP(i);

        if (hp >= HP_THRESHOLD)
        {
            StopTracking(i);
            continue;
        }

        if (hp < g_iLastRealHP[i])
        {
            StartWaiting(i, hp, now);
            continue;
        }

        g_iLastRealHP[i] = hp;

        if (!g_bRegenerating[i])
        {
            if (now >= g_fNextRegenTime[i])
            {
                g_bRegenerating[i] = true;
            }
            else
            {
                continue;
            }
        }

        int targetHp = GetRegenTargetHP(i);

        if (targetHp <= 0)
        {
            StopTracking(i);
            continue;
        }

        if (hp >= targetHp)
        {
            StopTracking(i);
            continue;
        }

        hp += REGEN_AMOUNT;

        if (hp > targetHp)
        {
            hp = targetHp;
        }

        SetEntityHealth(i, hp);
        g_iLastRealHP[i] = hp;

        if (hp >= targetHp)
        {
            StopTracking(i);
            continue;
        }

        anyActive = true;
    }

    if (!anyActive)
    {
        g_hRegenTimer = null;

        if (HasTrackedClients())
        {
            ScheduleWakeTimer();
        }
        else
        {
            StopWakeTimer();
        }

        return Plugin_Stop;
    }

    return Plugin_Continue;
}
