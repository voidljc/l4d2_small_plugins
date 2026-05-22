/**
 * =============================================================================
 * 文件：l4d2_self_rescue_wasd_optimized.sp
 * 使用方法：
 *   1. 将本文件放入 addons/sourcemod/scripting/ 目录。
 *   2. 使用 SourceMod 编译器 spcomp 编译本文件，生成 .smx。
 *   3. 将生成的 .smx 放入 addons/sourcemod/plugins/ 目录。
 *   4. 启动游戏/换图后会自动生成配置文件：
 *      cfg/sourcemod/l4d2_self_rescue_wasd.cfg
 *
 * 简介：
 *   这是一个 L4D2 倒地 WASD 自救插件。该版本在不改变功能路线的前提下，
 *   对高频 OnPlayerRunCmd 路径做保守 CPU 优化：
 *     - 每 tick 优先使用 g_bMonitorIncap[client] 做轻量状态门控。
 *     - 只有正在监听倒地自救的玩家，才继续执行真人幸存者和倒地状态判断。
 *     - OnPlayerRunCmd 内部使用快速倒地检测，避免重复 HasEntProp / IsHumanSurvivor。
 *     - 保留原来的事件、冷却、击杀减冷却、give health、自救失败退冷却逻辑。
 *
 * 功能如下：
 *
 *   1. 真人幸存者倒地后，监听该玩家按键输入。
 *   2. 同时按住 W + A + S + D 时，触发一次自救。
 *   3. 自救有冷却时间，默认 30 秒，可在 cfg 中调整。
 *   4. 冷却期间再次按下组合键，只给自己显示剩余冷却秒数。
 *   5. 每击杀 1 个特感，当前自救冷却减少 1 秒，可在 cfg 中调整。
 *   6. 即使正在被队友扶，也允许自己强制触发自救。
 *   7. 真人幸存者地面倒地时，只给本人提示 WASD 自救是否冷却完成。
 *      - 冷却完成：提示同时按住 W+A+S+D 可以自己起来。
 *      - 冷却中：提示还差多少秒可以按 W+A+S+D 自救。
 *
 * 设计目标：
 *   - 尽量降低算力占用：
 *       * 不开重复定时器
 *       * 不做全图扫描
 *       * 不做全局高频逻辑
 *       * 自救冷却减少仅通过 player_death 事件处理
 *   - 尽量降低句柄/内存风险：
 *       * 只用固定数组
 *       * 不使用重复 Timer
 *       * 不使用 DataPack / ArrayList / StringMap
 *
 * 配置文件：
 *   首次加载插件后会自动生成：
 *   cfg/sourcemod/l4d2_self_rescue_wasd.cfg
 *
 * 可调参数：
 *   l4d2_selfrescue_enable        是否启用插件
 *   l4d2_selfrescue_cooldown        倒地自起冷却时间（秒）
 *   l4d2_selfrescue_death_cooldown  死亡复活冷却时间（秒）
 *   l4d2_selfrescue_kill_reduce     每击杀 1 个特感减少多少秒倒地自起冷却
 *
 * 注意：
 *   - 本插件只处理“地面倒地”，不处理挂边。
 *   - 本插件只处理真人幸存者，不处理 bot。
 *   - 自救内部仍使用 give health 路线，再在下一帧修正为普通扶起血量。
 * =============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_hooks>

native void L4D_RespawnPlayer(int client, bool reset = true);

// 可选：由修改版双主武器插件提供，用于读取/写回“隐藏的另一把主武器”。
native bool DP_HasStoredWeapon(int client);
native bool DP_GetStoredWeapon(int client, char[] classname, int maxlen, int &clip, int &reserveAmmo, int &upgradeBits, int &upgradedAmmo);
native bool DP_SetStoredWeapon(int client, const char[] classname, int clip, int reserveAmmo, int upgradeBits, int upgradedAmmo);
native bool DP_ClearStoredWeapon(int client);

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define DEATH_MODEL_CLEAN_RADIUS 1200.0

public Plugin myinfo =
{
    name        = "L4D2 Self Rescue WASD",
    author      = "me",
    description = "Self rescue by holding W+A+S+D while incapacitated or dead, with configurable cooldown and SI-kill cooldown reduction.",
    version     = "1.4.2-restorefix-dualprimary",
    url         = ""
};

#if !defined IN_FORWARD
    #define IN_FORWARD      (1 << 3)
#endif
#if !defined IN_BACK
    #define IN_BACK         (1 << 4)
#endif
#if !defined IN_MOVELEFT
    #define IN_MOVELEFT     (1 << 9)
#endif
#if !defined IN_MOVERIGHT
    #define IN_MOVERIGHT    (1 << 10)
#endif

static const int REQUIRED_KEYS = IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT;

#define TRACKED_LOADOUT_SLOTS 5
#define MAX_STORED_NAME_LEN 64
#define LOADOUT_SNAPSHOT_INTERVAL 0.50
#define LOADOUT_RESTORE_PASSES 4
#define LOADOUT_RESTORE_INTERVAL 0.25
#define DOUBLE_PRIMARY_LIBRARY "double_primary_restore_api"

bool  g_bMonitorIncap[MAXPLAYERS + 1];
bool  g_bMonitorDeath[MAXPLAYERS + 1];
bool  g_bComboLatched[MAXPLAYERS + 1];
bool  g_bPendingRespawn[MAXPLAYERS + 1];
bool  g_bHasStoredLoadout[MAXPLAYERS + 1];
bool  g_bStoredDualPistols[MAXPLAYERS + 1];
bool  g_bStoredSecondaryHasClip[MAXPLAYERS + 1];
bool  g_bHasStoredHiddenPrimary[MAXPLAYERS + 1];
bool  g_bDoublePrimaryApiAvailable = false;
bool  g_bHasLastDeathOrigin[MAXPLAYERS + 1];
float g_fNextIncapSelfRescueAt[MAXPLAYERS + 1];
float g_fNextDeathRescueAt[MAXPLAYERS + 1];
float g_fPendingRespawnPos[MAXPLAYERS + 1][3];
float g_fLastDeathOrigin[MAXPLAYERS + 1][3];
float g_fLastDeathTime[MAXPLAYERS + 1];
char  g_sStoredLoadout[MAXPLAYERS + 1][TRACKED_LOADOUT_SLOTS][MAX_STORED_NAME_LEN];
char  g_sStoredMeleeName[MAXPLAYERS + 1][MAX_STORED_NAME_LEN];
char  g_sStoredHiddenPrimary[MAXPLAYERS + 1][MAX_STORED_NAME_LEN];
int   g_iStoredPrimaryClip[MAXPLAYERS + 1];
int   g_iStoredPrimaryReserveAmmo[MAXPLAYERS + 1];
int   g_iStoredPrimaryUpgradeBits[MAXPLAYERS + 1];
int   g_iStoredPrimaryUpgradedAmmo[MAXPLAYERS + 1];
int   g_iStoredHiddenPrimaryClip[MAXPLAYERS + 1];
int   g_iStoredHiddenPrimaryReserveAmmo[MAXPLAYERS + 1];
int   g_iStoredHiddenPrimaryUpgradeBits[MAXPLAYERS + 1];
int   g_iStoredHiddenPrimaryUpgradedAmmo[MAXPLAYERS + 1];
int   g_iStoredSecondaryClip[MAXPLAYERS + 1];
int   g_iLoadoutRestorePasses[MAXPLAYERS + 1];
int   g_iLastDeathCharacter[MAXPLAYERS + 1];
int   g_iAmmoOffset = -1;

// 插件 ConVar
ConVar g_hCvarEnable = null;
ConVar g_hCvarIncapCooldown = null;
ConVar g_hCvarDeathCooldown = null;
ConVar g_hCvarKillReduce = null;
ConVar g_hCvarRespawnHealth = null;

// 缓存值：运行时直接读缓存，不频繁读 ConVar
bool  g_bEnable = true;
float g_fIncapCooldown = 30.0;
float g_fDeathCooldown = 180.0;
float g_fKillReduce = 1.0;
int   g_iRespawnHealth = 50;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("L4D_RespawnPlayer");
    MarkNativeAsOptional("DP_HasStoredWeapon");
    MarkNativeAsOptional("DP_GetStoredWeapon");
    MarkNativeAsOptional("DP_SetStoredWeapon");
    MarkNativeAsOptional("DP_ClearStoredWeapon");
    return APLRes_Success;
}

public void OnPluginStart()
{
    // 创建插件参数
    g_hCvarEnable = CreateConVar(
        "l4d2_selfrescue_enable",
        "1",
        "Enable or disable the self rescue plugin. 0 = off, 1 = on.",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_hCvarIncapCooldown = CreateConVar(
        "l4d2_selfrescue_cooldown",
        "30.0",
        "Cooldown time in seconds after each incapacitated self rescue.",
        FCVAR_NOTIFY,
        true, 0.0
    );

    g_hCvarDeathCooldown = CreateConVar(
        "l4d2_selfrescue_death_cooldown",
        "180.0",
        "Cooldown time in seconds after each death respawn by W+A+S+D.",
        FCVAR_NOTIFY,
        true, 0.0
    );

    g_hCvarKillReduce = CreateConVar(
        "l4d2_selfrescue_kill_reduce",
        "1.0",
        "How many seconds of current self rescue cooldown are reduced per special infected kill.",
        FCVAR_NOTIFY,
        true, 0.0
    );

    g_hCvarRespawnHealth = CreateConVar(
        "l4d2_selfrescue_respawn_health",
        "50",
        "Real health set after self rescue or death respawn by W+A+S+D.",
        FCVAR_NOTIFY,
        true, 1.0,
        true, 100.0
    );

    AutoExecConfig(true, "l4d2_self_rescue_wasd");

    HookConVarChange(g_hCvarEnable, OnPluginCvarChanged);
    HookConVarChange(g_hCvarIncapCooldown, OnPluginCvarChanged);
    HookConVarChange(g_hCvarDeathCooldown, OnPluginCvarChanged);
    HookConVarChange(g_hCvarKillReduce, OnPluginCvarChanged);
    HookConVarChange(g_hCvarRespawnHealth, OnPluginCvarChanged);

    HookEvent("player_incapacitated", Event_PlayerIncapacitated);
    HookEvent("revive_success",       Event_ReviveSuccess);
    HookEvent("player_spawn",         Event_PlayerSpawn);
    HookEvent("player_death",         Event_PlayerDeathPre, EventHookMode_Pre);
    HookEvent("player_death",         Event_PlayerDeath);
    HookEvent("round_start",          Event_ResetAll, EventHookMode_PostNoCopy);
    HookEvent("round_end",            Event_ResetAll, EventHookMode_PostNoCopy);
    HookEvent("map_transition",       Event_ResetAll, EventHookMode_PostNoCopy);
    HookEvent("mission_lost",         Event_ResetAll, EventHookMode_PostNoCopy);

    // 死亡时再读武器槽不可靠：L4D2 可能已经剥离/掉落/转移玩家物品。
    // 所以用低频定时器保存“最后一次活着时”的装备快照。
    CreateTimer(LOADOUT_SNAPSHOT_INTERVAL, Timer_UpdateAliveLoadouts, _, TIMER_REPEAT);

    g_iAmmoOffset = FindSendPropInfo("CTerrorPlayer", "m_iAmmo");
    RefreshDoublePrimaryApiStatus();

    UpdateCachedCvars();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            FullResetClient(client);
            g_bMonitorIncap[client] = IsGroundIncapacitated(client);
            g_bMonitorDeath[client] = IsDeadHumanSurvivor(client);
        }
    }
}

public void OnAllPluginsLoaded()
{
    RefreshDoublePrimaryApiStatus();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, DOUBLE_PRIMARY_LIBRARY, false))
    {
        RefreshDoublePrimaryApiStatus();
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, DOUBLE_PRIMARY_LIBRARY, false))
    {
        g_bDoublePrimaryApiAvailable = false;
    }
}

public void OnConfigsExecuted()
{
    UpdateCachedCvars();
}

public void OnPluginCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    UpdateCachedCvars();
}

public void OnClientPutInServer(int client)
{
    FullResetClient(client);
}

public void OnClientDisconnect(int client)
{
    FullResetClient(client);
}

public Action OnPlayerRunCmd(
    int client,
    int &buttons,
    int &impulse,
    float vel[3],
    float angles[3],
    int &weapon,
    int &subtype,
    int &cmdnum,
    int &tickcount,
    int &seed,
    int mouse[2]
)
{
    if (!g_bEnable)
    {
        return Plugin_Continue;
    }

    // 高频路径第一层：先做固定数组状态门控。
    // 大多数 tick 玩家并未倒地，此处可以避免反复执行 IsClientInGame / IsFakeClient / GetClientTeam。
    if (client <= 0 || client > MaxClients)
    {
        return Plugin_Continue;
    }

    if (!g_bMonitorIncap[client] && !g_bMonitorDeath[client])
    {
        return Plugin_Continue;
    }

    // 高频路径第二层：只有被标记为倒地监听的玩家，才做真人幸存者校验。
    // 若玩家已经换队、断开、变为 bot 或其他异常状态，直接清理监听状态。
    if (!IsHumanSurvivor(client))
    {
        ClearMonitorState(client);
        return Plugin_Continue;
    }

    // 高频路径第三层：此处已经确认是真人幸存者，因此使用快速倒地检测，
    // 避免重复调用 IsHumanSurvivor 和低必要性的 HasEntProp。
    bool isGroundIncap = false;
    bool isDeathRescue = false;

    if (g_bMonitorIncap[client] && IsGroundIncapacitatedFast(client))
    {
        isGroundIncap = true;
    }
    else if (g_bMonitorDeath[client] && !IsPlayerAlive(client))
    {
        isDeathRescue = true;
    }
    else
    {
        ClearMonitorState(client);
        return Plugin_Continue;
    }

    bool comboPressed = ((buttons & REQUIRED_KEYS) == REQUIRED_KEYS);

    if (!comboPressed)
    {
        g_bComboLatched[client] = false;
        return Plugin_Continue;
    }

    // 边沿触发：只在本次刚按下组合键时处理一次
    if (g_bComboLatched[client])
    {
        return Plugin_Continue;
    }
    g_bComboLatched[client] = true;

    float now = GetGameTime();
    float remain = isDeathRescue
        ? (g_fNextDeathRescueAt[client] - now)
        : (g_fNextIncapSelfRescueAt[client] - now);

    if (remain > 0.0)
    {
        if (isDeathRescue)
        {
            PrintToChat(client, "\x04[自救]\x01 死亡复活冷却中，还需 \x03%d\x01 秒。", RoundToCeil(remain));
        }
        else
        {
            PrintToChat(client, "\x04[自救]\x01 冷却中，还需 \x03%d\x01 秒可再次自救。", RoundToCeil(remain));
        }
        return Plugin_Continue;
    }

    if (isGroundIncap)
    {
        g_fNextIncapSelfRescueAt[client] = now + g_fIncapCooldown;
        RequestFrame(Frame_DoSelfRescue, GetClientUserId(client));
        PrintToChat(client, "\x04[自救]\x01 已触发自救，进入 \x03%d\x01 秒冷却。", RoundToCeil(g_fIncapCooldown));
        return Plugin_Continue;
    }

    g_fNextDeathRescueAt[client] = now + g_fDeathCooldown;

    int observerTarget = GetRespawnAnchor(client);
    if (observerTarget <= 0)
    {
        RefundDeathCooldown(client);
        PrintToChat(client, "\x04[自救]\x01 复活失败：当前观战目标无效，需要观战一个未挂边的幸存者。");
        return Plugin_Continue;
    }

    GetClientAbsOrigin(observerTarget, g_fPendingRespawnPos[client]);
    g_fPendingRespawnPos[client][2] += 12.0;
    g_bPendingRespawn[client] = true;

    if (!StartRespawn(client))
    {
        g_bPendingRespawn[client] = false;
        RefundDeathCooldown(client);
        PrintToChat(client, "\x04[自救]\x01 复活失败：没有可用的 L4D_RespawnPlayer native 或 respawn 指令。");
        return Plugin_Continue;
    }

    CreateTimer(0.15, Timer_FinishRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    PrintToChat(
        client,
        "\x04[自救]\x01 已触发死亡复活，将在 \x03%N\x01 当前位置复活，进入 \x03%d\x01 秒冷却。",
        observerTarget,
        RoundToCeil(g_fDeathCooldown)
    );

    return Plugin_Continue;
}

public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bEnable)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHumanSurvivor(client))
    {
        return;
    }

    // 只处理地面倒地，不处理挂边
    if (HasEntProp(client, Prop_Send, "m_isHangingFromLedge") &&
        GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
    {
        return;
    }

    g_bMonitorIncap[client] = true;
    g_bMonitorDeath[client] = false;
    g_bComboLatched[client] = false;

    PrintIncapSelfRescueHint(client);
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject > 0)
    {
        ClearMonitorState(subject);
    }

    int userid = GetClientOfUserId(event.GetInt("userid"));
    if (userid > 0)
    {
        ClearMonitorState(userid);
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
    {
        g_bMonitorIncap[client] = false;
        g_bComboLatched[client] = false;

        if (!g_bPendingRespawn[client])
        {
            g_bMonitorDeath[client] = false;
        }
    }
}

public void Event_PlayerDeathPre(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (IsHumanSurvivor(victim))
    {
        // 不在这里覆盖装备快照。此时游戏可能已经开始处理死亡，
        // GetPlayerWeaponSlot 可能读到空槽或残缺槽位，覆盖掉真正的生前装备。
        StoreLastDeathInfo(victim);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (victim > 0)
    {
        g_bPendingRespawn[victim] = false;

        if (g_bEnable && IsDeadHumanSurvivor(victim))
        {
            g_bMonitorIncap[victim] = false;
            g_bMonitorDeath[victim] = true;
            g_bComboLatched[victim] = false;
            PrintDeathSelfRescueHint(victim);
        }
        else
        {
            ClearMonitorState(victim);
        }
    }

    if (!g_bEnable)
    {
        return;
    }

    if (!IsHumanSurvivor(attacker))
    {
        return;
    }

    if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim))
    {
        return;
    }

    // 只统计感染者队伍中的特感/Tank 玩家实体
    if (GetClientTeam(victim) != TEAM_INFECTED)
    {
        return;
    }

    ReduceIncapSelfRescueCooldown(attacker, g_fKillReduce);
}

public void Event_ResetAll(Event event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        FullResetClient(client);
    }
}

public void Frame_DoSelfRescue(any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsGroundIncapacitated(client))
    {
        return;
    }

    if (!CommandExists("give"))
    {
        RefundIncapCooldown(client);
        PrintToChat(client, "\x04[自救]\x01 失败：服务器不存在 give 指令。");
        return;
    }

    int oldFlags = GetCommandFlags("give");
    SetCommandFlags("give", oldFlags & ~FCVAR_CHEAT);
    FakeClientCommand(client, "give health");
    SetCommandFlags("give", oldFlags);

    RequestFrame(Frame_FixupSelfRescue, userid);
}

public void Frame_FixupSelfRescue(any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsHumanSurvivor(client) || !IsPlayerAlive(client))
    {
        return;
    }

    // 如果仍处于地面倒地，说明本次自救失败，退回冷却
    if (IsGroundIncapacitated(client))
    {
        RefundIncapCooldown(client);
        g_bComboLatched[client] = false;
        PrintToChat(client, "\x04[自救]\x01 本次自救未成功，请松开按键后再试。");
        return;
    }

    // 修正 give health 的结果，使之更接近普通扶起后的血量形态
    SetEntityHealth(client, g_iRespawnHealth);

    if (HasEntProp(client, Prop_Send, "m_healthBuffer"))
    {
        SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
    }

    if (HasEntProp(client, Prop_Send, "m_healthBufferTime"))
    {
        SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
    }

    ClearMonitorState(client);
}

public Action Timer_FinishRespawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients)
    {
        return Plugin_Stop;
    }

    if (!g_bPendingRespawn[client])
    {
        return Plugin_Stop;
    }

    g_bPendingRespawn[client] = false;

    if (!IsHumanSurvivor(client) || !IsPlayerAlive(client))
    {
        RefundDeathCooldown(client);

        if (IsDeadHumanSurvivor(client))
        {
            g_bMonitorDeath[client] = true;
        }

        if (IsClientInGame(client))
        {
            PrintToChat(client, "\x04[自救]\x01 死亡复活失败，已退还冷却。请确认服务器可用 Left4DHooks 或 respawn 指令。");
        }
        return Plugin_Stop;
    }

    FixupRespawnedSurvivor(client);
    TeleportEntity(client, g_fPendingRespawnPos[client], NULL_VECTOR, NULL_VECTOR);
    g_iLoadoutRestorePasses[client] = LOADOUT_RESTORE_PASSES;
    CreateTimer(0.10, Timer_RestoreDeathLoadout, userid, TIMER_FLAG_NO_MAPCHANGE);
    RemoveClientDeathModels(client);
    CreateTimer(0.50, Timer_CleanupDeathModelLate, userid, TIMER_FLAG_NO_MAPCHANGE);
    ClearMonitorState(client);

    PrintToChat(client, "\x04[自救]\x01 死亡复活完成，进入 \x03%d\x01 秒冷却。", RoundToCeil(g_fDeathCooldown));
    return Plugin_Stop;
}

public Action Timer_RestoreDeathLoadout(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsHumanSurvivor(client) || !IsPlayerAlive(client))
    {
        return Plugin_Stop;
    }

    bool clearExisting = (g_iLoadoutRestorePasses[client] == LOADOUT_RESTORE_PASSES);
    RestorePlayerLoadout(client, clearExisting);

    if (g_iLoadoutRestorePasses[client] > 1)
    {
        g_iLoadoutRestorePasses[client]--;
        CreateTimer(LOADOUT_RESTORE_INTERVAL, Timer_RestoreDeathLoadout, userid, TIMER_FLAG_NO_MAPCHANGE);
    }
    else
    {
        g_iLoadoutRestorePasses[client] = 0;
        // 不清除快照：如果复活后极短时间内再次死亡，仍有上一份可恢复装备。
        // 正常情况下，活人装备快照定时器会在下一次扫描时刷新为当前装备。
    }

    return Plugin_Stop;
}

public Action Timer_CleanupDeathModelLate(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Stop;
    }

    if (IsPlayerAlive(client))
    {
        RemoveClientDeathModels(client);
        g_bHasLastDeathOrigin[client] = false;
        g_fLastDeathTime[client] = 0.0;
        g_iLastDeathCharacter[client] = -1;
    }

    return Plugin_Stop;
}


public Action Timer_UpdateAliveLoadouts(Handle timer, any data)
{
    if (!g_bEnable)
    {
        return Plugin_Continue;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsHumanSurvivor(client) || !IsPlayerAlive(client))
        {
            continue;
        }

        // 复活流程中会短暂出现游戏默认装备；不要用默认装备覆盖死亡前快照。
        if (g_bPendingRespawn[client] || g_iLoadoutRestorePasses[client] > 0)
        {
            continue;
        }

        if (PlayerHasAnyTrackedLoadoutWeapon(client))
        {
            SnapshotPlayerLoadout(client);
        }
    }

    return Plugin_Continue;
}

static void PrintIncapSelfRescueHint(int client)
{
    if (!IsHumanSurvivor(client))
    {
        return;
    }

    float remain = g_fNextIncapSelfRescueAt[client] - GetGameTime();

    if (remain > 0.0)
    {
        PrintToChat(
            client,
            "\x04[自救]\x01 WASD 自救：\x03冷却中\x01，还差 \x03%d\x01 秒可以按 \x03W+A+S+D\x01 自救。",
            RoundToCeil(remain)
        );
        return;
    }

    PrintToChat(
        client,
        "\x04[自救]\x01 WASD 自救：\x03已冷却好\x01，同时按住 \x03W+A+S+D\x01 能自己起来。"
    );
}

static void PrintDeathSelfRescueHint(int client)
{
    if (!IsDeadHumanSurvivor(client))
    {
        return;
    }

    float remain = g_fNextDeathRescueAt[client] - GetGameTime();

    if (remain > 0.0)
    {
        PrintToChat(
            client,
            "\x04[自救]\x01 WASD 复活：\x03冷却中\x01，还差 \x03%d\x01 秒。观战未挂边幸存者后按 \x03W+A+S+D\x01 复活。",
            RoundToCeil(remain)
        );
        return;
    }

    PrintToChat(
        client,
        "\x04[自救]\x01 WASD 复活：\x03已冷却好\x01，观战一个未挂边的幸存者并按 \x03W+A+S+D\x01 可在其位置复活。"
    );
}

static void UpdateCachedCvars()
{
    g_bEnable = (g_hCvarEnable != null && g_hCvarEnable.BoolValue);
    g_fIncapCooldown = (g_hCvarIncapCooldown != null) ? g_hCvarIncapCooldown.FloatValue : 30.0;
    g_fDeathCooldown = (g_hCvarDeathCooldown != null) ? g_hCvarDeathCooldown.FloatValue : 180.0;
    g_fKillReduce = (g_hCvarKillReduce != null) ? g_hCvarKillReduce.FloatValue : 1.0;
    g_iRespawnHealth = (g_hCvarRespawnHealth != null) ? g_hCvarRespawnHealth.IntValue : 50;

    if (g_fIncapCooldown < 0.0)
    {
        g_fIncapCooldown = 0.0;
    }

    if (g_fDeathCooldown < 0.0)
    {
        g_fDeathCooldown = 0.0;
    }

    if (g_fKillReduce < 0.0)
    {
        g_fKillReduce = 0.0;
    }

    if (g_iRespawnHealth < 1)
    {
        g_iRespawnHealth = 1;
    }
    else if (g_iRespawnHealth > 100)
    {
        g_iRespawnHealth = 100;
    }
}

static bool PlayerHasAnyTrackedLoadoutWeapon(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    for (int slot = 0; slot < TRACKED_LOADOUT_SLOTS; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (IsValidTrackedWeapon(weapon))
        {
            return true;
        }
    }

    return false;
}

static bool IsHumanSurvivor(int client)
{
    return (client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && GetClientTeam(client) == TEAM_SURVIVOR);
}

static bool IsDeadHumanSurvivor(int client)
{
    return (IsHumanSurvivor(client) && !IsPlayerAlive(client));
}

static bool IsGroundIncapacitated(int client)
{
    if (!IsHumanSurvivor(client))
    {
        return false;
    }

    if (!HasEntProp(client, Prop_Send, "m_isIncapacitated"))
    {
        return false;
    }

    return IsGroundIncapacitatedFast(client);
}

static bool IsGroundIncapacitatedFast(int client)
{
    if (!IsPlayerAlive(client))
    {
        return false;
    }

    if (GetEntProp(client, Prop_Send, "m_isIncapacitated") == 0)
    {
        return false;
    }

    if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
    {
        return false;
    }

    // 故意不检查 m_reviveOwner
    // 即使队友正在扶，也允许自己自救
    return true;
}

static void SnapshotPlayerLoadout(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    ClearStoredLoadout(client);
    g_bHasStoredLoadout[client] = true;

    for (int slot = 0; slot < TRACKED_LOADOUT_SLOTS; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (!IsValidTrackedWeapon(weapon))
        {
            continue;
        }

        GetEdictClassname(weapon, g_sStoredLoadout[client][slot], MAX_STORED_NAME_LEN);

        if (slot == 0)
        {
            StorePrimaryWeaponState(client, weapon);
        }
        if (slot == 1)
        {
            g_bStoredDualPistols[client] = IsDualPistolWeapon(weapon);
            g_bStoredSecondaryHasClip[client] = WeaponHasClip(weapon);
            g_iStoredSecondaryClip[client] = g_bStoredSecondaryHasClip[client]
                ? GetEntProp(weapon, Prop_Send, "m_iClip1")
                : 0;

            if (StrEqual(g_sStoredLoadout[client][slot], "weapon_melee", false))
            {
                GetMeleeScriptName(weapon, g_sStoredMeleeName[client], MAX_STORED_NAME_LEN);
            }
        }
    }

    SnapshotHiddenDoublePrimary(client);
}

static void RestorePlayerLoadout(int client, bool clearExisting)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !g_bHasStoredLoadout[client])
    {
        return;
    }

    if (clearExisting)
    {
        RemoveTrackedLoadout(client);
    }

    EnsureStoredPrimary(client);
    EnsureStoredSecondary(client);
    EnsureStoredWeapon(client, 2);
    EnsureStoredWeapon(client, 3);
    EnsureStoredWeapon(client, 4);
    RestoreHiddenDoublePrimary(client);
}

static void RemoveTrackedLoadout(int client)
{
    for (int slot = 0; slot < TRACKED_LOADOUT_SLOTS; slot++)
    {
        RemoveWeaponInSlot(client, slot);
    }
}

static void EnsureStoredPrimary(int client)
{
    if (g_sStoredLoadout[client][0][0] == '\0')
    {
        return;
    }

    int weapon = GetPlayerWeaponSlot(client, 0);
    if (!PrimaryWeaponMatchesStored(client, weapon))
    {
        RemoveWeaponInSlot(client, 0);
        GiveStoredClassnameByCommand(client, g_sStoredLoadout[client][0]);
        weapon = GetPlayerWeaponSlot(client, 0);
    }

    if (IsValidTrackedWeapon(weapon))
    {
        ApplyStoredPrimaryWeaponState(client, weapon);
    }
}

static void EnsureStoredSecondary(int client)
{
    if (g_sStoredLoadout[client][1][0] == '\0')
    {
        return;
    }

    int weapon = GetPlayerWeaponSlot(client, 1);
    if (!SecondaryWeaponMatchesStored(client, weapon))
    {
        RemoveWeaponInSlot(client, 1);

        if (StrEqual(g_sStoredLoadout[client][1], "weapon_melee", false))
        {
            if (g_sStoredMeleeName[client][0] != '\0')
            {
                GivePlayerMelee(client, g_sStoredMeleeName[client]);
            }
        }
        else
        {
            GiveStoredClassnameByCommand(client, g_sStoredLoadout[client][1]);

            if (StrEqual(g_sStoredLoadout[client][1], "weapon_pistol", false) && g_bStoredDualPistols[client])
            {
                GiveStoredClassnameByCommand(client, "weapon_pistol");
            }
        }

        weapon = GetPlayerWeaponSlot(client, 1);
    }

    if (IsValidTrackedWeapon(weapon) && g_bStoredSecondaryHasClip[client] && WeaponHasClip(weapon))
    {
        SetEntProp(weapon, Prop_Send, "m_iClip1", g_iStoredSecondaryClip[client]);
    }
}

static void EnsureStoredWeapon(int client, int slot)
{
    if (slot < 2 || slot >= TRACKED_LOADOUT_SLOTS || g_sStoredLoadout[client][slot][0] == '\0')
    {
        return;
    }

    int weapon = GetPlayerWeaponSlot(client, slot);
    if (StoredWeaponMatchesClass(client, slot, weapon))
    {
        return;
    }

    RemoveWeaponInSlot(client, slot);
    GiveStoredClassnameByCommand(client, g_sStoredLoadout[client][slot]);
}

static void StorePrimaryWeaponState(int client, int weapon)
{
    g_iStoredPrimaryClip[client] = WeaponHasClip(weapon)
        ? GetEntProp(weapon, Prop_Send, "m_iClip1")
        : 0;
    g_iStoredPrimaryReserveAmmo[client] = GetWeaponReserveAmmo(client, weapon);
    g_iStoredPrimaryUpgradeBits[client] = HasEntProp(weapon, Prop_Send, "m_upgradeBitVec")
        ? GetEntProp(weapon, Prop_Send, "m_upgradeBitVec")
        : 0;
    g_iStoredPrimaryUpgradedAmmo[client] = HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded")
        ? GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded")
        : 0;
}

static void ApplyStoredPrimaryWeaponState(int client, int weapon)
{
    if (WeaponHasClip(weapon))
    {
        SetEntProp(weapon, Prop_Send, "m_iClip1", g_iStoredPrimaryClip[client]);
    }

    SetWeaponReserveAmmo(client, weapon, g_iStoredPrimaryReserveAmmo[client]);

    if (HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
    {
        SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", g_iStoredPrimaryUpgradeBits[client]);
    }

    if (HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
    {
        SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", g_iStoredPrimaryUpgradedAmmo[client]);
    }
}

static void RemoveWeaponInSlot(int client, int slot)
{
    int weapon = GetPlayerWeaponSlot(client, slot);
    while (IsValidTrackedWeapon(weapon))
    {
        RemovePlayerItem(client, weapon);
        AcceptEntityInput(weapon, "Kill");

        int nextWeapon = GetPlayerWeaponSlot(client, slot);
        if (nextWeapon == weapon)
        {
            break;
        }

        weapon = nextWeapon;
    }
}

static bool StoredWeaponMatchesClass(int client, int slot, int weapon)
{
    if (g_sStoredLoadout[client][slot][0] == '\0')
    {
        return !IsValidTrackedWeapon(weapon);
    }

    if (!IsValidTrackedWeapon(weapon))
    {
        return false;
    }

    char classname[MAX_STORED_NAME_LEN];
    GetEdictClassname(weapon, classname, sizeof(classname));
    return StrEqual(classname, g_sStoredLoadout[client][slot], false);
}

static bool PrimaryWeaponMatchesStored(int client, int weapon)
{
    return StoredWeaponMatchesClass(client, 0, weapon);
}

static bool SecondaryWeaponMatchesStored(int client, int weapon)
{
    if (!StoredWeaponMatchesClass(client, 1, weapon))
    {
        return false;
    }

    if (!IsValidTrackedWeapon(weapon))
    {
        return false;
    }

    if (StrEqual(g_sStoredLoadout[client][1], "weapon_melee", false))
    {
        char meleeName[MAX_STORED_NAME_LEN];
        GetMeleeScriptName(weapon, meleeName, sizeof(meleeName));
        return StrEqual(meleeName, g_sStoredMeleeName[client], false);
    }

    if (StrEqual(g_sStoredLoadout[client][1], "weapon_pistol", false))
    {
        return (IsDualPistolWeapon(weapon) == g_bStoredDualPistols[client]);
    }

    return true;
}

static void SnapshotHiddenDoublePrimary(int client)
{
    ClearStoredHiddenPrimary(client);

    if (!g_bDoublePrimaryApiAvailable || client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    if (!DP_HasStoredWeapon(client))
    {
        return;
    }

    char classname[MAX_STORED_NAME_LEN];
    int clip = 0;
    int reserveAmmo = 0;
    int upgradeBits = 0;
    int upgradedAmmo = 0;

    if (!DP_GetStoredWeapon(client, classname, sizeof(classname), clip, reserveAmmo, upgradeBits, upgradedAmmo))
    {
        return;
    }

    if (classname[0] == '\0' || StrEqual(classname, "weapon_none", false))
    {
        return;
    }

    strcopy(g_sStoredHiddenPrimary[client], MAX_STORED_NAME_LEN, classname);
    g_iStoredHiddenPrimaryClip[client] = clip;
    g_iStoredHiddenPrimaryReserveAmmo[client] = reserveAmmo;
    g_iStoredHiddenPrimaryUpgradeBits[client] = upgradeBits;
    g_iStoredHiddenPrimaryUpgradedAmmo[client] = upgradedAmmo;
    g_bHasStoredHiddenPrimary[client] = true;
}

static void RestoreHiddenDoublePrimary(int client)
{
    if (!g_bHasStoredHiddenPrimary[client] || !g_bDoublePrimaryApiAvailable)
    {
        return;
    }

    DP_SetStoredWeapon(
        client,
        g_sStoredHiddenPrimary[client],
        g_iStoredHiddenPrimaryClip[client],
        g_iStoredHiddenPrimaryReserveAmmo[client],
        g_iStoredHiddenPrimaryUpgradeBits[client],
        g_iStoredHiddenPrimaryUpgradedAmmo[client]
    );
}

static void RefreshDoublePrimaryApiStatus()
{
    g_bDoublePrimaryApiAvailable = LibraryExists(DOUBLE_PRIMARY_LIBRARY)
        && GetFeatureStatus(FeatureType_Native, "DP_HasStoredWeapon") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "DP_GetStoredWeapon") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "DP_SetStoredWeapon") == FeatureStatus_Available;
}

static void ClearStoredHiddenPrimary(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bHasStoredHiddenPrimary[client] = false;
    g_sStoredHiddenPrimary[client][0] = '\0';
    g_iStoredHiddenPrimaryClip[client] = 0;
    g_iStoredHiddenPrimaryReserveAmmo[client] = 0;
    g_iStoredHiddenPrimaryUpgradeBits[client] = 0;
    g_iStoredHiddenPrimaryUpgradedAmmo[client] = 0;
}

static void GivePlayerMelee(int client, const char[] meleeName)
{
    if (meleeName[0] == '\0')
    {
        return;
    }

    int weapon = CreateEntityByName("weapon_melee");
    if (weapon == -1)
    {
        return;
    }

    DispatchKeyValue(weapon, "melee_script_name", meleeName);
    DispatchSpawn(weapon);
    EquipPlayerWeapon(client, weapon);
}

static bool GiveStoredClassnameByCommand(int client, const char[] classname)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || classname[0] == '\0')
    {
        return false;
    }

    // 优先使用 SourceMod 的 GivePlayerItem：它接受完整 classname，
    // 比 FakeClientCommand("give xxx") 更少受作弊指令、别名和时序影响。
    int weapon = GivePlayerItem(client, classname);
    if (IsValidTrackedWeapon(weapon))
    {
        EquipPlayerWeapon(client, weapon);
        return true;
    }

    // 兜底：少数 L4D2 物品在某些环境中只能通过 give 参数生成。
    char giveArg[MAX_STORED_NAME_LEN];
    strcopy(giveArg, sizeof(giveArg), classname);
    ReplaceString(giveArg, sizeof(giveArg), "weapon_", "", false);

    RunCheatClientCommand(client, "give", giveArg);
    return true;
}

static void GetMeleeScriptName(int weapon, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!IsValidTrackedWeapon(weapon))
    {
        return;
    }

    if (HasEntProp(weapon, Prop_Data, "m_strMapSetScriptName"))
    {
        GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", buffer, maxlen);
    }

    if (buffer[0] == '\0' && HasEntProp(weapon, Prop_Send, "m_strMapSetScriptName"))
    {
        GetEntPropString(weapon, Prop_Send, "m_strMapSetScriptName", buffer, maxlen);
    }
}

static bool WeaponHasClip(int weapon)
{
    return (IsValidTrackedWeapon(weapon) && HasEntProp(weapon, Prop_Send, "m_iClip1"));
}

static int GetWeaponPrimaryAmmoType(int weapon)
{
    if (!IsValidTrackedWeapon(weapon))
    {
        return -1;
    }

    if (HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"))
    {
        return GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
    }

    if (HasEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType"))
    {
        return GetEntProp(weapon, Prop_Data, "m_iPrimaryAmmoType");
    }

    return -1;
}

static int GetWeaponReserveAmmo(int client, int weapon)
{
    if (client <= 0 || client > MaxClients || g_iAmmoOffset < 0)
    {
        return 0;
    }

    int ammoType = GetWeaponPrimaryAmmoType(weapon);
    if (ammoType < 0)
    {
        return 0;
    }

    return GetEntData(client, g_iAmmoOffset + ammoType * 4, 4);
}

static void SetWeaponReserveAmmo(int client, int weapon, int ammo)
{
    if (client <= 0 || client > MaxClients || g_iAmmoOffset < 0)
    {
        return;
    }

    int ammoType = GetWeaponPrimaryAmmoType(weapon);
    if (ammoType < 0)
    {
        return;
    }

    SetEntData(client, g_iAmmoOffset + ammoType * 4, ammo, 4, true);
}

static void StoreLastDeathInfo(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    GetClientAbsOrigin(client, g_fLastDeathOrigin[client]);
    g_bHasLastDeathOrigin[client] = true;
    g_fLastDeathTime[client] = GetGameTime();
    g_iLastDeathCharacter[client] = GetSurvivorCharacter(client);
}

static int RemoveClientDeathModels(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return 0;
    }

    int removed = 0;
    int entity = -1;

    while ((entity = FindEntityByClassname(entity, "survivor_death_model")) != -1)
    {
        if (!IsDeathModelEntity(entity))
        {
            continue;
        }

        if (!DeathModelMatchesClient(client, entity))
        {
            continue;
        }

        KillEntitySafely(entity);
        removed++;
    }

    return removed;
}

static bool DeathModelMatchesClient(int client, int entity)
{
    int clientChar = g_iLastDeathCharacter[client];
    int deathModelChar = GetDeathModelCharacter(entity);

    if (clientChar != -1 && deathModelChar != -1 && clientChar != deathModelChar)
    {
        return false;
    }

    if (g_bHasLastDeathOrigin[client])
    {
        float deathModelOrigin[3];
        if (GetEntityOrigin(entity, deathModelOrigin))
        {
            float maxDistanceSq = DEATH_MODEL_CLEAN_RADIUS * DEATH_MODEL_CLEAN_RADIUS;
            return (GetVectorDistanceSquared(deathModelOrigin, g_fLastDeathOrigin[client]) <= maxDistanceSq);
        }
    }

    return (clientChar != -1 && deathModelChar != -1 && clientChar == deathModelChar);
}

static int GetSurvivorCharacter(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return -1;
    }

    if (HasEntProp(client, Prop_Send, "m_survivorCharacter"))
    {
        return GetEntProp(client, Prop_Send, "m_survivorCharacter");
    }

    return -1;
}

static int GetDeathModelCharacter(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return -1;
    }

    if (HasEntProp(entity, Prop_Send, "m_survivorCharacter"))
    {
        return GetEntProp(entity, Prop_Send, "m_survivorCharacter");
    }

    if (HasEntProp(entity, Prop_Send, "m_nCharacterType"))
    {
        return GetEntProp(entity, Prop_Send, "m_nCharacterType");
    }

    return -1;
}

static bool GetEntityOrigin(int entity, float origin[3])
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return false;
    }

    if (HasEntProp(entity, Prop_Send, "m_vecOrigin"))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
        return true;
    }

    if (HasEntProp(entity, Prop_Data, "m_vecAbsOrigin"))
    {
        GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);
        return true;
    }

    if (HasEntProp(entity, Prop_Data, "m_vecOrigin"))
    {
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
        return true;
    }

    return false;
}

static float GetVectorDistanceSquared(const float a[3], const float b[3])
{
    float dx = a[0] - b[0];
    float dy = a[1] - b[1];
    float dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

static bool IsDeathModelEntity(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return false;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, "survivor_death_model", false);
}

static void KillEntitySafely(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return;
    }

    AcceptEntityInput(entity, "Kill");
}

static bool IsDualPistolWeapon(int weapon)
{
    if (!IsValidTrackedWeapon(weapon))
    {
        return false;
    }

    if (HasEntProp(weapon, Prop_Send, "m_hasDualWeapons"))
    {
        return (GetEntProp(weapon, Prop_Send, "m_hasDualWeapons") != 0);
    }

    if (HasEntProp(weapon, Prop_Send, "m_isDualWielding"))
    {
        return (GetEntProp(weapon, Prop_Send, "m_isDualWielding") != 0);
    }

    if (HasEntProp(weapon, Prop_Data, "m_hasDualWeapons"))
    {
        return (GetEntProp(weapon, Prop_Data, "m_hasDualWeapons") != 0);
    }

    if (HasEntProp(weapon, Prop_Data, "m_isDualWielding"))
    {
        return (GetEntProp(weapon, Prop_Data, "m_isDualWielding") != 0);
    }

    return false;
}

static bool IsValidTrackedWeapon(int weapon)
{
    return (weapon > MaxClients && IsValidEdict(weapon));
}

static void ClearStoredLoadout(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bHasStoredLoadout[client] = false;
    g_bStoredDualPistols[client] = false;
    g_bStoredSecondaryHasClip[client] = false;
    ClearStoredHiddenPrimary(client);
    g_sStoredMeleeName[client][0] = '\0';
    g_iStoredPrimaryClip[client] = 0;
    g_iStoredPrimaryReserveAmmo[client] = 0;
    g_iStoredPrimaryUpgradeBits[client] = 0;
    g_iStoredPrimaryUpgradedAmmo[client] = 0;
    g_iStoredSecondaryClip[client] = 0;
    g_iLoadoutRestorePasses[client] = 0;

    for (int slot = 0; slot < TRACKED_LOADOUT_SLOTS; slot++)
    {
        g_sStoredLoadout[client][slot][0] = '\0';
    }
}

static int GetRespawnAnchor(int client)
{
    int observerTarget = GetObserverTargetClient(client);
    if (IsValidRespawnAnchor(observerTarget))
    {
        return observerTarget;
    }

    return 0;
}

static int GetObserverTargetClient(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return 0;
    }

    if (!HasEntProp(client, Prop_Send, "m_hObserverTarget"))
    {
        return 0;
    }

    int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
    if (target > 0 && target <= MaxClients && IsClientInGame(target))
    {
        return target;
    }

    return 0;
}

static bool IsValidRespawnAnchor(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
    {
        return false;
    }

    if (HasEntProp(client, Prop_Send, "m_isHangingFromLedge") &&
        GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
    {
        return false;
    }

    return true;
}

static bool StartRespawn(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "L4D_RespawnPlayer") == FeatureStatus_Available)
    {
        L4D_RespawnPlayer(client);
        return true;
    }

    if (CommandExists("respawn"))
    {
        RunCheatClientCommand(client, "respawn");
        return true;
    }

    return false;
}

static void RunCheatClientCommand(int client, const char[] command, const char[] args = "")
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    int userFlags = GetUserFlagBits(client);
    SetUserFlagBits(client, ADMFLAG_ROOT);

    int oldFlags = GetCommandFlags(command);
    if (oldFlags != INVALID_FCVAR_FLAGS)
    {
        SetCommandFlags(command, oldFlags & ~FCVAR_CHEAT);
    }

    if (args[0] == '\0')
    {
        FakeClientCommand(client, "%s", command);
    }
    else
    {
        FakeClientCommand(client, "%s %s", command, args);
    }

    if (oldFlags != INVALID_FCVAR_FLAGS)
    {
        SetCommandFlags(command, oldFlags);
    }

    SetUserFlagBits(client, userFlags);
}

static void FixupRespawnedSurvivor(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return;
    }

    SetEntityHealth(client, g_iRespawnHealth);

    if (HasEntProp(client, Prop_Send, "m_healthBuffer"))
    {
        SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
    }

    if (HasEntProp(client, Prop_Send, "m_healthBufferTime"))
    {
        SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
    }

    if (HasEntProp(client, Prop_Send, "m_isIncapacitated"))
    {
        SetEntProp(client, Prop_Send, "m_isIncapacitated", 0);
    }

    if (HasEntProp(client, Prop_Send, "m_isHangingFromLedge"))
    {
        SetEntProp(client, Prop_Send, "m_isHangingFromLedge", 0);
    }

    if (HasEntProp(client, Prop_Send, "m_isGoingToDie"))
    {
        SetEntProp(client, Prop_Send, "m_isGoingToDie", 0);
    }

    if (HasEntProp(client, Prop_Send, "m_currentReviveCount"))
    {
        SetEntProp(client, Prop_Send, "m_currentReviveCount", 0);
    }

    if (HasEntProp(client, Prop_Send, "m_bIsOnThirdStrike"))
    {
        SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", 0);
    }

    StopSound(client, SNDCHAN_STATIC, "player/heartbeatloop.wav");
}

static void ReduceIncapSelfRescueCooldown(int client, float seconds)
{
    if (client <= 0 || client > MaxClients || seconds <= 0.0)
    {
        return;
    }

    float now = GetGameTime();

    // 只减少当前正在进行中的冷却，不做预存
    if (g_fNextIncapSelfRescueAt[client] <= now)
    {
        return;
    }

    g_fNextIncapSelfRescueAt[client] -= seconds;

    if (g_fNextIncapSelfRescueAt[client] < now)
    {
        g_fNextIncapSelfRescueAt[client] = now;
    }
}

static void ClearMonitorState(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bMonitorIncap[client] = false;
    g_bMonitorDeath[client] = false;
    g_bComboLatched[client] = false;
}

static void FullResetClient(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bMonitorIncap[client] = false;
    g_bMonitorDeath[client] = false;
    g_bComboLatched[client] = false;
    g_bPendingRespawn[client] = false;
    g_bHasStoredLoadout[client] = false;
    g_bStoredDualPistols[client] = false;
    g_bStoredSecondaryHasClip[client] = false;
    ClearStoredHiddenPrimary(client);
    g_bHasLastDeathOrigin[client] = false;
    g_fNextIncapSelfRescueAt[client] = 0.0;
    g_fNextDeathRescueAt[client] = 0.0;
    g_fPendingRespawnPos[client][0] = 0.0;
    g_fPendingRespawnPos[client][1] = 0.0;
    g_fPendingRespawnPos[client][2] = 0.0;
    g_fLastDeathOrigin[client][0] = 0.0;
    g_fLastDeathOrigin[client][1] = 0.0;
    g_fLastDeathOrigin[client][2] = 0.0;
    g_fLastDeathTime[client] = 0.0;
    g_sStoredMeleeName[client][0] = '\0';
    g_iStoredPrimaryClip[client] = 0;
    g_iStoredPrimaryReserveAmmo[client] = 0;
    g_iStoredPrimaryUpgradeBits[client] = 0;
    g_iStoredPrimaryUpgradedAmmo[client] = 0;
    g_iStoredSecondaryClip[client] = 0;
    g_iLoadoutRestorePasses[client] = 0;
    g_iLastDeathCharacter[client] = -1;
    for (int slot = 0; slot < TRACKED_LOADOUT_SLOTS; slot++)
    {
        g_sStoredLoadout[client][slot][0] = '\0';
    }
}

static void RefundIncapCooldown(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_fNextIncapSelfRescueAt[client] = GetGameTime();
}

static void RefundDeathCooldown(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_fNextDeathRescueAt[client] = GetGameTime();
}
