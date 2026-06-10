/**
 * =====================================================================
 * 文件说明：l4d2_unpin_qskill_killreduce_cpu_optimized.sp
 * ---------------------------------------------------------------------
 * 插件名称：L4D2 - Q键解除控制技能（击杀特感减冷却版，CPU保守优化版）
 *
 * 使用方法：
 * 1) 编译本文件为 .smx 后放入：left4dead2/addons/sourcemod/plugins/
 * 2) 需要安装并加载 Left4DHooks；SDKHooks 通常随 SourceMod 提供。
 * 3) 推荐绑定：bind q "sm_unpin_q" 或 bind q "+unpin_q"
 * 4) 配置文件会自动生成/读取：cfg/sourcemod/l4d2_unpin_qskill.cfg
 *
 * 功能概述：
 * 1) 玩家按下 Q（绑定到 sm_unpin_q 或 +unpin_q）时，会先检查技能冷却状态。
 * 2) 若冷却完成：
 *    - 立即进入触发期（持续时间可调）。
 *    - 触发期内若玩家被 Smoker / Hunter / Jockey / Charger 控制，
 *      插件会自动检测控制者并立刻杀死该特感。
 *    - 触发期内可选开启安全无敌（m_takedamage = 0）。
 * 3) 若仍在冷却：
 *    - 不会触发技能。
 *    - 仅向当前按键玩家本人发送提示，显示“冷却中，剩余多少秒”。
 * 4) 每次按 Q 都会给当前玩家一个私有状态提示：
 *    - 冷却完毕：提示已启动技能。
 *    - 冷却中：提示剩余冷却秒数。
 * 5) 玩家每击杀 1 个特感，当前技能剩余冷却减少 1 秒（可通过 ConVar 调整）。
 * 6) Q 技能持续时间内可选免受 stagger / stumble（如爆炸硬直、Tank 拳/石头造成的僵直）。
 *    - 只减少“当前冷却剩余时间”，不会把额外减免存到下一轮。
 *    - 若原本已冷却完毕，则不会继续累计为负冷却。
 *    - 默认也会仅向击杀者本人输出一条私有提示。
 *
 * 本 CPU 保守优化版不改变功能语义：
 * - 不把每帧检测改成低频 Timer。
 * - 不删除 Left4DHooks 控制检测。
 * - 不删除 netprop 兜底检测。
 * - 不改变默认冷却、持续时间、击杀减冷却、无敌、免僵直逻辑。
 *
 * 本版相对前版的内部优化：
 * - 缓存 ConVar 值，避免 OnGameFrame / 事件转发中频繁读取 ConVar。
 * - OnGameFrame 先判断 active 玩家数，空闲时只做极少量判断。
 * - 维护 active 玩家列表，只遍历正在触发 Q 技能的玩家，不再每帧扫描所有 MaxClients。
 * - 缓存常用 netprop 是否存在，减少触发期内重复 HasEntProp 查询。
 * - 保守减少同一帧内重复的玩家合法性检查。
 * - 当总开关被关闭时，立即结束所有触发期并恢复 m_takedamage，避免残留无敌。
 *
 * 仅自己可见的消息实现：
 * - 使用 PrintToChat(client, ...)，只向触发命令或击杀触发的那个玩家输出。
 * - 其他玩家不会看到该提示。
 *
 * 性能说明：
 * - 平时无人处于触发期时，OnGameFrame() 立即 return，开销极低。
 * - “击杀特感减冷却”走 player_death 事件，不轮询，也不需要定时器。
 * - 本插件主要性能消耗仍在“触发期每帧检查是否被控”，但现在只遍历 active 玩家。
 * - 免僵直走 Left4DHooks 前置转发，不需要额外计时器或额外扫描循环。
 *
 * 依赖：
 * - Left4DHooks（必须）：L4D2_GetSpecialInfectedDominatingMe
 * - SDKHooks（建议）：用于兜底伤害击杀
 *
 * ConVars：
 *   sm_unpin_q_enable            1/0 总开关
 *   sm_unpin_q_duration          触发期时长（秒，默认 3.0）
 *   sm_unpin_q_cooldown          冷却时间（秒，默认 120.0）
 *   sm_unpin_q_kill_interval     杀控制者节流（秒，默认 0.20）
 *   sm_unpin_q_kill_reduce       每击杀 1 个特感减少多少秒冷却（默认 1.0）
 *   sm_unpin_q_godmode           触发期内无敌（默认 1）
 *   sm_unpin_q_god_block_incap   倒地/挂边撤销无敌（默认 1）
 *   sm_unpin_q_block_stagger     触发期内免僵直/免硬直（默认 1）
 * =====================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

public Plugin myinfo =
{
    name        = "L4D2 Unpin Q Skill (Kill Reduce Cooldown, CPU Optimized)",
    author      = "me",
    description = "Press Q to activate unpin window; killing special infected reduces cooldown.",
    version     = "10.1.0",
    url         = ""
};

// ----------------------
// ConVars
// ----------------------
ConVar gC_Enable;
ConVar gC_Duration;
ConVar gC_Cooldown;
ConVar gC_KillInterval;
ConVar gC_KillReduce;

ConVar gC_Godmode;
ConVar gC_GodBlockIncap;
ConVar gC_BlockStagger;

// ConVar cache: avoid high-frequency methodmap reads in frame/forward paths.
bool  gB_Enable;
bool  gB_Godmode;
bool  gB_GodBlockIncap;
bool  gB_BlockStagger;
float gF_Duration;
float gF_Cooldown;
float gF_KillInterval;
float gF_KillReduce;

// ----------------------
// Per-player state
// ----------------------
bool  gActive[MAXPLAYERS + 1];
float gActiveUntil[MAXPLAYERS + 1];
float gNextReadyAt[MAXPLAYERS + 1];

// 杀控制者节流：避免状态未刷新时反复调用导致性能/日志/边缘 bug
float gNextKillTryAt[MAXPLAYERS + 1];

// Active list: only active players are scanned in OnGameFrame().
int   gActiveClients[MAXPLAYERS + 1];
int   gActiveIndex[MAXPLAYERS + 1];
int   gActiveCount = 0;

// Godmode: restore m_takedamage
bool  gGodOn[MAXPLAYERS + 1];
int   gOldTakeDamage[MAXPLAYERS + 1];

// Netprop availability cache. These props are stable for L4D2 players.
bool gPropCacheReady = false;
bool gHasTakeDamage = false;
bool gHasIncap = false;
bool gHasLedge = false;
bool gHasTongueOwner = false;
bool gHasPounceAttacker = false;
bool gHasJockeyAttacker = false;
bool gHasCarryAttacker = false;
bool gHasPummelAttacker = false;

// ----------------------
// ConVar cache helpers
// ----------------------
static void RefreshConVarCache()
{
    gB_Enable        = (gC_Enable.IntValue != 0);
    gB_Godmode       = (gC_Godmode.IntValue != 0);
    gB_GodBlockIncap = (gC_GodBlockIncap.IntValue != 0);
    gB_BlockStagger  = (gC_BlockStagger.IntValue != 0);

    gF_Duration      = gC_Duration.FloatValue;
    gF_Cooldown      = gC_Cooldown.FloatValue;
    gF_KillInterval  = gC_KillInterval.FloatValue;
    gF_KillReduce    = gC_KillReduce.FloatValue;
}

static void HookConVarCaches()
{
    HookConVarChange(gC_Enable,        Event_ConVarChanged);
    HookConVarChange(gC_Duration,      Event_ConVarChanged);
    HookConVarChange(gC_Cooldown,      Event_ConVarChanged);
    HookConVarChange(gC_KillInterval,  Event_ConVarChanged);
    HookConVarChange(gC_KillReduce,    Event_ConVarChanged);
    HookConVarChange(gC_Godmode,       Event_ConVarChanged);
    HookConVarChange(gC_GodBlockIncap, Event_ConVarChanged);
    HookConVarChange(gC_BlockStagger,  Event_ConVarChanged);
}

// ----------------------
// Utilities
// ----------------------
static bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

static bool IsSurvivorAliveHuman(int client)
{
    return IsValidClient(client) && !IsFakeClient(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client);
}

static bool IsInfectedClient(int client)
{
    return IsValidClient(client) && GetClientTeam(client) == 3;
}

static bool IsInfectedAlive(int client)
{
    return IsInfectedClient(client) && IsPlayerAlive(client);
}

static void RefreshPlayerPropCache(int client)
{
    if (!IsValidClient(client))
        return;

    gHasTakeDamage     = HasEntProp(client, Prop_Data, "m_takedamage");

    gHasIncap          = (FindSendPropInfo("CTerrorPlayer", "m_isIncapacitated") != -1);
    gHasLedge          = (FindSendPropInfo("CTerrorPlayer", "m_isHangingFromLedge") != -1);
    gHasTongueOwner    = (FindSendPropInfo("CTerrorPlayer", "m_tongueOwner") != -1);
    gHasPounceAttacker = (FindSendPropInfo("CTerrorPlayer", "m_pounceAttacker") != -1);
    gHasJockeyAttacker = (FindSendPropInfo("CTerrorPlayer", "m_jockeyAttacker") != -1);
    gHasCarryAttacker  = (FindSendPropInfo("CTerrorPlayer", "m_carryAttacker") != -1);
    gHasPummelAttacker = (FindSendPropInfo("CTerrorPlayer", "m_pummelAttacker") != -1);

    gPropCacheReady = true;
}

static void EnsurePlayerPropCache(int client)
{
    if (!gPropCacheReady)
        RefreshPlayerPropCache(client);
}

static bool IsIncapOrLedge(int client)
{
    if (!IsValidClient(client))
        return false;

    EnsurePlayerPropCache(client);

    if (gHasIncap && GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0)
        return true;

    if (gHasLedge && GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
        return true;

    return false;
}

static void PrintPrivateStatus(int client, const char[] message, any ...)
{
    if (!IsValidClient(client))
        return;

    char buffer[192];
    VFormat(buffer, sizeof(buffer), message, 3);
    PrintToChat(client, "\x04[Q技能]\x01 %s", buffer);
}

static float GetRemainingCooldown(int client, float now)
{
    float remain = gNextReadyAt[client] - now;
    if (remain < 0.0)
        remain = 0.0;
    return remain;
}

static void RemoveActiveAtIndex(int index)
{
    if (index < 0 || index >= gActiveCount)
        return;

    int client = gActiveClients[index];
    int lastIndex = gActiveCount - 1;
    int lastClient = gActiveClients[lastIndex];

    gActiveClients[index] = lastClient;
    if (lastClient > 0 && lastClient <= MaxClients)
        gActiveIndex[lastClient] = index;

    gActiveClients[lastIndex] = 0;
    gActiveCount--;

    if (client > 0 && client <= MaxClients)
        gActiveIndex[client] = -1;
}

static void RemoveActiveFromList(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    int index = gActiveIndex[client];
    if (index < 0 || index >= gActiveCount || gActiveClients[index] != client)
    {
        index = -1;
        for (int i = 0; i < gActiveCount; i++)
        {
            if (gActiveClients[i] == client)
            {
                index = i;
                break;
            }
        }
    }

    if (index != -1)
        RemoveActiveAtIndex(index);
    else
        gActiveIndex[client] = -1;
}

static void RebuildActiveList()
{
    gActiveCount = 0;

    for (int i = 0; i <= MAXPLAYERS; i++)
        gActiveClients[i] = 0;

    for (int client = 0; client <= MAXPLAYERS; client++)
        gActiveIndex[client] = -1;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!gActive[client])
            continue;

        if (gActiveCount >= MaxClients)
            break;

        gActiveClients[gActiveCount] = client;
        gActiveIndex[client] = gActiveCount;
        gActiveCount++;
    }
}

static void StartActive(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (gActive[client])
        return;

    if (gActiveCount >= MaxClients)
        RebuildActiveList();

    if (gActiveCount >= MaxClients)
        return;

    gActive[client] = true;
    gActiveClients[gActiveCount] = client;
    gActiveIndex[client] = gActiveCount;
    gActiveCount++;
}

static void DisableGodmode(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (!gGodOn[client])
        return;

    if (!gPropCacheReady && client > 0 && client <= MaxClients && IsClientInGame(client))
        RefreshPlayerPropCache(client);

    if (gHasTakeDamage && IsValidEntity(client))
    {
        int restore = gOldTakeDamage[client];
        if (restore < 0)
            restore = 2; // 常规可受伤
        SetEntProp(client, Prop_Data, "m_takedamage", restore);
    }

    gGodOn[client] = false;
    gOldTakeDamage[client] = 2;
}

static void EnableGodmodeChecked(int client)
{
    EnsurePlayerPropCache(client);
    if (!gHasTakeDamage)
        return;

    if (!gGodOn[client])
    {
        gOldTakeDamage[client] = GetEntProp(client, Prop_Data, "m_takedamage");
        gGodOn[client] = true;
    }

    SetEntProp(client, Prop_Data, "m_takedamage", 0);
}

static void EnableGodmode(int client)
{
    if (!IsSurvivorAliveHuman(client))
        return;

    EnableGodmodeChecked(client);
}

static void UpdateGodmodeDuringActiveChecked(int client)
{
    if (!gB_Godmode)
    {
        DisableGodmode(client);
        return;
    }

    if (!gActive[client])
    {
        DisableGodmode(client);
        return;
    }

    // 关键：倒地/挂边时撤销无敌，避免血量体系出现不一致
    if (gB_GodBlockIncap && IsIncapOrLedge(client))
    {
        DisableGodmode(client);
        return;
    }

    EnableGodmodeChecked(client);
}

static void UpdateGodmodeDuringActive(int client)
{
    if (!gActive[client] || !IsSurvivorAliveHuman(client))
    {
        DisableGodmode(client);
        return;
    }

    UpdateGodmodeDuringActiveChecked(client);
}

static bool IsActiveNow(int client, float now)
{
    return gActive[client] && now < gActiveUntil[client] && IsSurvivorAliveHuman(client);
}

static void EndActive(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (gActive[client])
    {
        gActive[client] = false;
        RemoveActiveFromList(client);
    }

    gActiveUntil[client] = 0.0;
    gNextKillTryAt[client] = 0.0;

    DisableGodmode(client);
}

static void ClearAllActiveWindows()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (gActive[client] || gGodOn[client])
            EndActive(client);
        else
        {
            gActiveUntil[client] = 0.0;
            gNextKillTryAt[client] = 0.0;
        }
    }

    RebuildActiveList();
}

static void ResetClientState(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    EndActive(client);

    gNextReadyAt[client] = 0.0;
    gNextKillTryAt[client] = 0.0;

    DisableGodmode(client);
}

static void ReduceCooldownFromSpecialKill(int client, float reduceSec)
{
    if (!IsSurvivorAliveHuman(client))
        return;

    if (reduceSec <= 0.0)
        return;

    float now = GetGameTime();
    float remain = GetRemainingCooldown(client, now);

    // 已经转好，不累计为“下次额外减冷却”
    if (remain <= 0.0)
        return;

    gNextReadyAt[client] -= reduceSec;
    if (gNextReadyAt[client] < now)
        gNextReadyAt[client] = now;

    float newRemain = GetRemainingCooldown(client, now);
    float actualReduce = remain - newRemain;
    if (actualReduce < 0.0)
        actualReduce = 0.0;

    if (newRemain > 0.0)
    {
        PrintPrivateStatus(client, "击杀特感，冷却减少 %.1f 秒，当前剩余 %.1f 秒。", actualReduce, newRemain);
    }
    else
    {
        PrintPrivateStatus(client, "击杀特感，冷却减少 %.1f 秒，当前已冷却完毕。", actualReduce);
    }
}

// dominator native 偶发返回 0 时，用 netprop 兜底找控制者
static int GetPinAttackerByProps(int victim)
{
    EnsurePlayerPropCache(victim);

    int attacker;

    if (gHasTongueOwner)
    {
        attacker = GetEntPropEnt(victim, Prop_Send, "m_tongueOwner");
        if (IsInfectedAlive(attacker))
            return attacker;
    }

    if (gHasPounceAttacker)
    {
        attacker = GetEntPropEnt(victim, Prop_Send, "m_pounceAttacker");
        if (IsInfectedAlive(attacker))
            return attacker;
    }

    if (gHasJockeyAttacker)
    {
        attacker = GetEntPropEnt(victim, Prop_Send, "m_jockeyAttacker");
        if (IsInfectedAlive(attacker))
            return attacker;
    }

    if (gHasCarryAttacker)
    {
        attacker = GetEntPropEnt(victim, Prop_Send, "m_carryAttacker");
        if (IsInfectedAlive(attacker))
            return attacker;
    }

    if (gHasPummelAttacker)
    {
        attacker = GetEntPropEnt(victim, Prop_Send, "m_pummelAttacker");
        if (IsInfectedAlive(attacker))
            return attacker;
    }

    return 0;
}

/**
 * 杀死控制者：优先 ForcePlayerSuicide（最直接，通常能触发官方释放链）
 * 若被某些插件/状态阻止，再用 TakeDamage 兜底。
 */
static void KillDominator(int victim, int attacker)
{
    if (!IsSurvivorAliveHuman(victim))
        return;

    if (!IsInfectedAlive(attacker))
        return;

    // 尝试直接自杀（对特感 / 特感 bot 一般都有效）
    ForcePlayerSuicide(attacker);

    // 若仍存活，用超高伤害兜底
    if (IsInfectedAlive(attacker))
    {
        // 若目标被设为不可受伤，先强制恢复 takedamage（只在兜底分支做，避免副作用扩大）
        if (!gPropCacheReady)
            RefreshPlayerPropCache(victim);

        if (gHasTakeDamage)
        {
            int td = GetEntProp(attacker, Prop_Data, "m_takedamage");
            if (td == 0)
                SetEntProp(attacker, Prop_Data, "m_takedamage", 2);
        }

        SDKHooks_TakeDamage(attacker, victim, victim, 100000.0, DMG_GENERIC | DMG_BLAST);
    }
}

// ----------------------
// Command: Q trigger
// ----------------------
public Action Cmd_TriggerQ(int client, int args)
{
    // 监听服 client=0 映射真人玩家（按原逻辑保留）
    if (client <= 0)
    {
        if (IsDedicatedServer())
            return Plugin_Handled;

        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                client = i;
                break;
            }
        }
        if (client <= 0)
            return Plugin_Handled;
    }

    if (!gB_Enable)
    {
        PrintPrivateStatus(client, "功能当前已关闭。");
        return Plugin_Handled;
    }

    if (!IsSurvivorAliveHuman(client))
        return Plugin_Handled;

    EnsurePlayerPropCache(client);

    float now = GetGameTime();

    // 冷却检查：每次按 Q 都提示当前状态，仅本人可见
    if (now < gNextReadyAt[client])
    {
        PrintPrivateStatus(client, "冷却中，剩余 %.1f 秒。", GetRemainingCooldown(client, now));
        return Plugin_Handled;
    }

    StartActive(client);

    gActiveUntil[client]   = now + gF_Duration;
    gNextReadyAt[client]   = now + gF_Cooldown;
    gNextKillTryAt[client] = 0.0; // 允许立即尝试

    // 立即更新一次无敌（不等下一帧）
    UpdateGodmodeDuringActiveChecked(client);

    if (gB_BlockStagger)
        PrintPrivateStatus(client, "冷却完毕，技能已启动：持续 %.1f 秒，冷却 %.1f 秒，期间免僵直。", gF_Duration, gF_Cooldown);
    else
        PrintPrivateStatus(client, "冷却完毕，技能已启动：持续 %.1f 秒，冷却 %.1f 秒。", gF_Duration, gF_Cooldown);

    return Plugin_Handled;
}

public Action Cmd_DummyRelease(int client, int args)
{
    return Plugin_Handled;
}

// ----------------------
// Event: kill special infected -> reduce cooldown
// ----------------------
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!gB_Enable)
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsInfectedClient(victim))
        return;

    if (!IsSurvivorAliveHuman(attacker))
        return;

    ReduceCooldownFromSpecialKill(attacker, gF_KillReduce);
}

// ----------------------
// Left4DHooks: block stagger during active window
// ----------------------
public Action L4D2_OnStagger(int target, int source)
{
    if (!gB_Enable)
        return Plugin_Continue;

    if (!gB_BlockStagger)
        return Plugin_Continue;

    if (!IsValidClient(target))
        return Plugin_Continue;

    float now = GetGameTime();
    if (!IsActiveNow(target, now))
        return Plugin_Continue;

    return Plugin_Handled;
}

// ----------------------
// Frame loop: only when active
// ----------------------
public void OnGameFrame()
{
    // Most frames should exit here. This avoids even reading the enable ConVar/cache path when idle.
    if (gActiveCount <= 0)
        return;

    if (!gB_Enable)
        return;

    float now = GetGameTime();
    int index = 0;

    while (index < gActiveCount)
    {
        int client = gActiveClients[index];

        // Corruption guard: remove invalid list slot without advancing, because the last entry is swapped in.
        if (client <= 0 || client > MaxClients || !gActive[client])
        {
            RemoveActiveAtIndex(index);
            continue;
        }

        // 失效 / 死亡：结束触发期，避免残留
        if (!IsSurvivorAliveHuman(client))
        {
            EndActive(client);
            continue;
        }

        // 触发期结束
        if (now >= gActiveUntil[client])
        {
            EndActive(client);
            continue;
        }

        EnsurePlayerPropCache(client);

        // 每帧更新无敌（含倒地 / 挂边撤销）。保持原语义，不降频。
        UpdateGodmodeDuringActiveChecked(client);

        // 每帧检测是否被控。保持原语义，不改成 Timer。
        int attacker = L4D2_GetSpecialInfectedDominatingMe(client);
        if (!IsInfectedAlive(attacker))
            attacker = GetPinAttackerByProps(client);

        // 被控：杀控制者（节流）
        if (IsInfectedAlive(attacker) && now >= gNextKillTryAt[client])
        {
            KillDominator(client, attacker);
            gNextKillTryAt[client] = now + gF_KillInterval;
        }

        index++;
    }
}

// ----------------------
// Lifecycle
// ----------------------
public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin is for Left 4 Dead 2 only.");

    if (GetFeatureStatus(FeatureType_Native, "L4D2_GetSpecialInfectedDominatingMe") != FeatureStatus_Available)
        SetFailState("Missing native: L4D2_GetSpecialInfectedDominatingMe (Left4DHooks required).");

    gC_Enable        = CreateConVar("sm_unpin_q_enable",          "1",     "总开关：1启用，0关闭", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gC_Duration      = CreateConVar("sm_unpin_q_duration",        "3.0",   "触发期时长（秒）",     FCVAR_NOTIFY, true, 0.1, true, 30.0);
    gC_Cooldown      = CreateConVar("sm_unpin_q_cooldown",        "120.0", "冷却时间（秒）",       FCVAR_NOTIFY, true, 0.0, true, 99999.0);
    gC_KillInterval  = CreateConVar("sm_unpin_q_kill_interval",   "0.20",  "杀控制者节流间隔（秒）", FCVAR_NOTIFY, true, 0.05, true, 2.0);
    gC_KillReduce    = CreateConVar("sm_unpin_q_kill_reduce",     "1.0",   "每击杀 1 个特感减少多少秒冷却", FCVAR_NOTIFY, true, 0.0, true, 60.0);

    gC_Godmode       = CreateConVar("sm_unpin_q_godmode",         "1",     "触发期内是否无敌（m_takedamage=0）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gC_GodBlockIncap = CreateConVar("sm_unpin_q_god_block_incap", "1",     "倒地/挂边时撤销无敌以避免血量异常", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gC_BlockStagger  = CreateConVar("sm_unpin_q_block_stagger",   "1",     "触发期内是否免僵直/免硬直（stagger）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarCaches();
    RefreshConVarCache();

    AutoExecConfig(true, "l4d2_unpin_qskill");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    RegConsoleCmd("sm_unpin_q", Cmd_TriggerQ, "Press Q: during duration, if pinned then kill dominator; private cooldown status.");
    RegConsoleCmd("+unpin_q",   Cmd_TriggerQ, "Bind key to +unpin_q.");
    RegConsoleCmd("-unpin_q",   Cmd_DummyRelease, "Dummy release for +unpin_q.");

    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        gActiveClients[i] = 0;
        gActiveIndex[i] = -1;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        gGodOn[i] = false;
        gOldTakeDamage[i] = 2;
        ResetClientState(i);
    }

    gActiveCount = 0;
    gPropCacheReady = false;
}

public void OnConfigsExecuted()
{
    RefreshConVarCache();

    if (!gB_Enable)
        ClearAllActiveWindows();
}

public void Event_ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    bool wasEnabled = gB_Enable;

    RefreshConVarCache();

    if (convar == gC_Enable && wasEnabled && !gB_Enable)
        ClearAllActiveWindows();

    if (convar == gC_Godmode && !gB_Godmode)
    {
        for (int client = 1; client <= MaxClients; client++)
            DisableGodmode(client);
    }
}

public void OnMapStart()
{
    gPropCacheReady = false;

    for (int i = 1; i <= MaxClients; i++)
        ResetClientState(i);

    RebuildActiveList();
}

public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    ResetClientState(client);

    if (!gPropCacheReady)
        RefreshPlayerPropCache(client);
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    ResetClientState(client);
}

public void OnPluginEnd()
{
    // 卸载时尽量恢复 m_takedamage，避免残留无敌
    for (int i = 1; i <= MaxClients; i++)
    {
        if (gGodOn[i])
            DisableGodmode(i);
    }
}
