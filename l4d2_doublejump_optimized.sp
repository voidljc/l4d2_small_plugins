/*
 * File: l4d2_doublejump_optimized.sp
 * Plugin: L4D2 Double Jump - Optimized Cache Version
 *
 * 简介：
 *   这是一个 Left 4 Dead 2 的 SourceMod 二段跳插件。
 *   玩家每次离地期间只允许使用一次空中跳跃；落地后重置次数。
 *   本版本在不改变原功能逻辑的前提下，缓存 ConVar 值和玩家基础允许状态，
 *   减少 OnPlayerRunCmd 每 tick 的重复 ConVar 读取和基础状态检查。
 *
 * 使用方法：
 *   1. 将本文件放到：addons/sourcemod/scripting/l4d2_doublejump_optimized.sp
 *   2. 使用 SourceMod 编译器编译：
 *        spcomp l4d2_doublejump_optimized.sp
 *   3. 将生成的 l4d2_doublejump_optimized.smx 放到：
 *        addons/sourcemod/plugins/
 *   4. 启动服务器或切图后，会自动生成配置文件：
 *        cfg/sourcemod/l4d2_doublejump.cfg
 *
 * 主要参数：
 *   sm_djump_enable    "1"      // 是否启用二段跳，1=启用，0=关闭
 *   sm_djump_force     "280.0"  // 二段跳向上的速度增量
 *   sm_djump_team      "2"      // 允许队伍：0=全部，2=生还者，3=感染者
 *   sm_djump_noladder  "1"      // 是否禁止梯子上二段跳
 *   sm_djump_nowater   "1"      // 是否禁止深水中二段跳，waterlevel >= 2 时禁止
 *
 * 优化说明：
 *   - 保留 OnPlayerRunCmd 逐 tick 输入检测，避免漏掉短按跳跃键。
 *   - 只缓存 ConVar 和玩家基础状态：是否在游戏、是否存活、队伍是否允许。
 *   - 不缓存地面、梯子、水位状态，因为这些属于快速变化状态，缓存会改变功能表现。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#if !defined FL_ONGROUND
#define FL_ONGROUND (1 << 0)
#endif

ConVar g_cvEnable;
ConVar g_cvForce;
ConVar g_cvTeam;
ConVar g_cvNoLadder;
ConVar g_cvNoWater;

// ConVar 缓存：避免 OnPlayerRunCmd 每 tick 反复读取 ConVar。
bool  g_bEnable;
float g_fForce;
int   g_iTeam;
bool  g_bNoLadder;
bool  g_bNoWater;

// 玩家基础允许状态缓存：只缓存慢变化条件。
bool g_bBaseAllowed[MAXPLAYERS + 1];

// 二段跳状态机。保留原逻辑，不改输入检测频率。
bool g_JumpHeld[MAXPLAYERS + 1];
int  g_JumpCount[MAXPLAYERS + 1];      // 0=地面/未计数, 1=本次离地仍可空中跳一次, 2=二段已用
bool g_WasOnGround[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "L4D2 Double Jump",
    author      = "you / optimized by ChatGPT",
    description = "Allow exactly one mid-air jump per airtime with low-risk cache optimization.",
    version     = "1.2.0",
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnable   = CreateConVar("sm_djump_enable",   "1",     "Enable double jump (1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvForce    = CreateConVar("sm_djump_force",    "280.0", "Upward Z velocity added on mid-air jump", FCVAR_NOTIFY);
    g_cvTeam     = CreateConVar("sm_djump_team",     "2",     "Which team can double jump: 0=all, 2=Survivors, 3=Infected", FCVAR_NOTIFY);
    g_cvNoLadder = CreateConVar("sm_djump_noladder", "1",     "Block while on ladders", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvNoWater  = CreateConVar("sm_djump_nowater",  "1",     "Block in deep water (waterlevel>=2)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(g_cvEnable,   OnDJumpConVarChanged);
    HookConVarChange(g_cvForce,    OnDJumpConVarChanged);
    HookConVarChange(g_cvTeam,     OnDJumpConVarChanged);
    HookConVarChange(g_cvNoLadder, OnDJumpConVarChanged);
    HookConVarChange(g_cvNoWater,  OnDJumpConVarChanged);

    CacheConVars();

    AutoExecConfig(true, "l4d2_doublejump");

    HookEvent("player_spawn", Event_PlayerSpawnOrDeath, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerSpawnOrDeath, EventHookMode_Post);
    HookEvent("player_team",  Event_PlayerTeam,         EventHookMode_Post);

    ResetAllClients();
    RefreshAllBaseAllowed();
}

public void OnConfigsExecuted()
{
    // AutoExecConfig 的配置执行完成后，再同步一次缓存，保证 cfg 里的值生效。
    CacheConVars();
    RefreshAllBaseAllowed();
}

public void OnClientPutInServer(int client)
{
    ResetClient(client);
    UpdateClientBaseAllowed(client);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client);

    if (IsValidClientIndex(client))
    {
        g_bBaseAllowed[client] = false;
    }
}

public void OnDJumpConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CacheConVars();

    // sm_djump_team 改变会影响玩家基础允许状态。
    // 这里统一刷新全部玩家，开销极低，并且避免判断遗漏。
    RefreshAllBaseAllowed();
}

public Action Event_PlayerSpawnOrDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClientIndex(client))
    {
        ResetClient(client);
        UpdateClientBaseAllowed(client);
    }

    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClientIndex(client))
    {
        UpdateClientBaseAllowed(client);
    }

    return Plugin_Continue;
}

void CacheConVars()
{
    g_bEnable   = g_cvEnable.BoolValue;
    g_fForce    = g_cvForce.FloatValue;
    g_iTeam     = g_cvTeam.IntValue;
    g_bNoLadder = g_cvNoLadder.BoolValue;
    g_bNoWater  = g_cvNoWater.BoolValue;
}

void ResetAllClients()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ResetClient(client);
    }
}

void RefreshAllBaseAllowed()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        UpdateClientBaseAllowed(client);
    }
}

void ResetClient(int client)
{
    if (!IsValidClientIndex(client))
    {
        return;
    }

    g_JumpHeld[client]    = false;
    g_JumpCount[client]   = 0;
    g_WasOnGround[client] = true;
}

void UpdateClientBaseAllowed(int client)
{
    if (!IsValidClientIndex(client))
    {
        return;
    }

    g_bBaseAllowed[client] = false;

    if (!IsClientInGame(client))
    {
        return;
    }

    if (!IsPlayerAlive(client))
    {
        return;
    }

    int team = GetClientTeam(client);

    if (g_iTeam == 2 && team != 2)
    {
        return;
    }

    if (g_iTeam == 3 && team != 3)
    {
        return;
    }

    g_bBaseAllowed[client] = true;
}

bool IsValidClientIndex(int client)
{
    return client >= 1 && client <= MaxClients;
}

bool IsOnGround(int client)
{
    return (GetEntityFlags(client) & FL_ONGROUND) != 0;
}

bool PassesRuntimeFilters(int client)
{
    if (!g_bBaseAllowed[client])
    {
        return false;
    }

    // 不缓存梯子状态：移动状态变化快，缓存会改变边界手感。
    if (g_bNoLadder && GetEntityMoveType(client) == MOVETYPE_LADDER)
    {
        return false;
    }

    // 不缓存水位状态：水位变化快，缓存可能导致刚入水/刚出水时判定错误。
    if (g_bNoWater)
    {
        int water = GetEntProp(client, Prop_Send, "m_nWaterLevel"); // 0..3
        if (water >= 2)
        {
            return false;
        }
    }

    return true;
}

// 每次离地期间允许一次：
// - 地面 -> 空中：把计数置为 1，表示本次离地期间还可用一次空中跳。
// - 空中按下跳键 且 计数 == 1：施加上升速度，置为 2，消费掉名额。
// - 回到地面：计数清零。
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3],
                             float angles[3], int &weapon, int &subtype, int &cmdnum,
                             int &tickcount, int &seed, int mouse[2])
{
    if (!IsValidClientIndex(client))
    {
        return Plugin_Continue;
    }

    if (!g_bEnable || !PassesRuntimeFilters(client))
    {
        return Plugin_Continue;
    }

    bool pressed = (buttons & IN_JUMP) != 0;
    bool rising  = pressed && !g_JumpHeld[client]; // 按键上升沿
    g_JumpHeld[client] = pressed;

    bool onGround = IsOnGround(client);

    // 处理地面/空中状态切换。
    if (onGround)
    {
        // 回到地面：重置。
        g_JumpCount[client]   = 0;
        g_WasOnGround[client] = true;

        // 玩家在地面按下第一次跳，这里不做任何限制，正常起跳由游戏处理。
        return Plugin_Continue;
    }

    // 从地面刚刚离开，不论是起跳还是走下台阶，都授予一次空中跳机会。
    if (g_WasOnGround[client])
    {
        g_JumpCount[client]   = 1;
        g_WasOnGround[client] = false;
    }

    // 空中二段跳：只要还在空中且这次离地还没用过，就允许一次。
    if (rising && g_JumpCount[client] == 1)
    {
        float velocity[3];
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);

        // 保留原手感：若正在下坠，则先消除下坠速度再加向上速度。
        if (velocity[2] < 0.0)
        {
            velocity[2] = 0.0;
        }

        velocity[2] += g_fForce;

        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);

        g_JumpCount[client] = 2;
    }

    return Plugin_Continue;
}
