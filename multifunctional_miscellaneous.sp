/*
 * 文件名: l4d2_start_config_zisha.sp
 * 简介: L4D2 SourceMod 插件；开局应用服务器配置，玩家加入 30 秒后刷新幸存者轮廓，并支持聊天命令 !zisha 自杀。
 * 使用方法:
 *   1. 将本文件编译为 .smx。
 *   2. 把生成的 .smx 放入 left4dead2/addons/sourcemod/plugins/。
 *   3. 服务器内玩家在聊天框输入 !zisha，即可杀死自己。
 *   4. 玩家加入服务器后，插件会等待 30 秒，然后执行一次幸存者轮廓刷新：先设置 sv_disable_glow_survivors 1，再短延迟设置为 0。
 *   5. 管理员/控制台仍可使用 sm_startcfg 重新执行开局配置。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name = "L4D2 Start Config",
    author = "me",
    description = "Apply start-of-map server settings, refresh survivor glow 30 seconds after human join, allow sm_startcfg, and let players use !zisha to kill themselves.",
    version = "1.5",
    url = ""
};

#define SHOVE_PENALTY_NEAR_INFINITE 99999
#define GLOW_REFRESH_STAGE2_DELAY 0.2
#define CLIENT_JOIN_GLOW_REFRESH_DELAY 30.0

ConVar g_hFFEasy;
ConVar g_hFFNormal;
ConVar g_hFFHard;
ConVar g_hFFExpert;
ConVar g_hDisableGlowSurvivors;
ConVar g_hRescueDisabled;
ConVar g_hAmmoShotgunMax;
ConVar g_hAmmoAutoshotgunMax;
ConVar g_hAmmoSmgMax;
ConVar g_hAmmoAssaultRifleMax;
ConVar g_hAmmoHuntingRifleMax;
ConVar g_hAmmoSniperRifleMax;
ConVar g_hAmmoGrenadeLauncherMax;
ConVar g_hAmmoM60Max;
ConVar g_hGunSwingCoopMinPenalty;
ConVar g_hGunSwingCoopMaxPenalty;
ConVar g_hGunSwingVsMinPenalty;
ConVar g_hGunSwingVsMaxPenalty;

Handle g_hStartConfigStage2Timer;
Handle g_hLateJoinGlowStage2Timer;
Handle g_hClientJoinGlowTimers[MAXPLAYERS + 1];

public void OnPluginStart()
{
    g_hFFEasy   = FindConVar("survivor_friendly_fire_factor_easy");
    g_hFFNormal = FindConVar("survivor_friendly_fire_factor_normal");
    g_hFFHard   = FindConVar("survivor_friendly_fire_factor_hard");
    g_hFFExpert = FindConVar("survivor_friendly_fire_factor_expert");
    g_hDisableGlowSurvivors = FindConVar("sv_disable_glow_survivors");
    g_hRescueDisabled = FindConVar("sv_rescue_disabled");
    g_hAmmoShotgunMax = FindConVar("ammo_shotgun_max");
    g_hAmmoAutoshotgunMax = FindConVar("ammo_autoshotgun_max");
    g_hAmmoSmgMax = FindConVar("ammo_smg_max");
    g_hAmmoAssaultRifleMax = FindConVar("ammo_assaultrifle_max");
    g_hAmmoHuntingRifleMax = FindConVar("ammo_huntingrifle_max");
    g_hAmmoSniperRifleMax = FindConVar("ammo_sniperrifle_max");
    g_hAmmoGrenadeLauncherMax = FindConVar("ammo_grenadelauncher_max");
    g_hAmmoM60Max = FindConVar("ammo_m60_max");
    g_hGunSwingCoopMinPenalty = FindConVar("z_gun_swing_coop_min_penalty");
    g_hGunSwingCoopMaxPenalty = FindConVar("z_gun_swing_coop_max_penalty");
    g_hGunSwingVsMinPenalty = FindConVar("z_gun_swing_vs_min_penalty");
    g_hGunSwingVsMaxPenalty = FindConVar("z_gun_swing_vs_max_penalty");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    RegConsoleCmd("sm_startcfg", Command_StartCfg, "Reapply the start config settings.");
    RegConsoleCmd("sm_zisha", Command_ZiSha, "Kill yourself from chat with !zisha.");

    DisableFriendlyFire();
    ApplyShoveSettings();
}

public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client))
    {
        return;
    }

    QueueClientJoinGlowRefresh(client);
}

public void OnClientDisconnect(int client)
{
    delete g_hClientJoinGlowTimers[client];
    g_hClientJoinGlowTimers[client] = null;
}

public void OnMapEnd()
{
    delete g_hStartConfigStage2Timer;
    g_hStartConfigStage2Timer = null;

    delete g_hLateJoinGlowStage2Timer;
    g_hLateJoinGlowStage2Timer = null;

    for (int client = 1; client <= MaxClients; client++)
    {
        delete g_hClientJoinGlowTimers[client];
        g_hClientJoinGlowTimers[client] = null;
    }
}

public void OnMapStart()
{
    ApplyStartConfig();
}

public void OnConfigsExecuted()
{
    ApplyAmmoSettings();
    ApplyShoveSettings();
    DisableFriendlyFire();

    CreateTimer(1.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(5.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    DisableFriendlyFire();

    CreateTimer(1.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DisableFriendlyFire(Handle timer)
{
    DisableFriendlyFire();
    return Plugin_Stop;
}

public Action Command_StartCfg(int client, int args)
{
    ApplyStartConfig();

    if (client > 0 && client <= MaxClients)
    {
        ReplyToCommand(client, "[StartCfg] 已重新执行 l4d2_startconfig 的配置。");
    }
    else
    {
        PrintToServer("[StartCfg] 已重新执行 l4d2_startconfig 的配置。");
    }

    return Plugin_Handled;
}

public Action Command_ZiSha(int client, int args)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (!IsPlayerAlive(client))
    {
        ReplyToCommand(client, "[ZiSha] 你当前不是存活状态，无法自杀。");
        return Plugin_Handled;
    }

    ForcePlayerSuicide(client);
    return Plugin_Handled;
}

public Action Timer_RunMapStartCommandsStage2(Handle timer)
{
    if (timer == g_hStartConfigStage2Timer)
    {
        g_hStartConfigStage2Timer = null;
    }

    SetCvarIntSafe(g_hDisableGlowSurvivors, 0);
    SetCvarIntSafe(g_hRescueDisabled, 0);
    return Plugin_Stop;
}

public Action Timer_RunLateJoinGlowStage2(Handle timer)
{
    if (timer == g_hLateJoinGlowStage2Timer)
    {
        g_hLateJoinGlowStage2Timer = null;
    }

    SetCvarIntSafe(g_hDisableGlowSurvivors, 0);
    return Plugin_Stop;
}

public Action Timer_RefreshGlowAfterClientJoin(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (client > 0 && client <= MaxClients && timer == g_hClientJoinGlowTimers[client])
    {
        g_hClientJoinGlowTimers[client] = null;
    }

    if (!IsHumanClientInGame(client))
    {
        return Plugin_Stop;
    }

    RefreshSurvivorGlowForLateJoiner();
    return Plugin_Stop;
}

void ApplyStartConfig()
{
    RunMapStartCommands();
    ApplyAmmoSettings();
    ApplyShoveSettings();
    DisableFriendlyFire();

    CreateTimer(1.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(5.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
}

void RunMapStartCommands()
{
    SetCvarIntSafe(g_hDisableGlowSurvivors, 1);
    SetCvarIntSafe(g_hRescueDisabled, 1);

    delete g_hStartConfigStage2Timer;
    g_hStartConfigStage2Timer = CreateTimer(GLOW_REFRESH_STAGE2_DELAY, Timer_RunMapStartCommandsStage2, _, TIMER_FLAG_NO_MAPCHANGE);
}

void RefreshSurvivorGlowForLateJoiner()
{
    SetCvarIntSafe(g_hDisableGlowSurvivors, 1);

    delete g_hLateJoinGlowStage2Timer;
    g_hLateJoinGlowStage2Timer = CreateTimer(GLOW_REFRESH_STAGE2_DELAY, Timer_RunLateJoinGlowStage2, _, TIMER_FLAG_NO_MAPCHANGE);
}

void QueueClientJoinGlowRefresh(int client)
{
    if (!IsHumanClientInGame(client))
    {
        return;
    }

    delete g_hClientJoinGlowTimers[client];
    g_hClientJoinGlowTimers[client] = CreateTimer(CLIENT_JOIN_GLOW_REFRESH_DELAY, Timer_RefreshGlowAfterClientJoin, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

void DisableFriendlyFire()
{
    SetCvarFloatSafe(g_hFFEasy,   0.0);
    SetCvarFloatSafe(g_hFFNormal, 0.0);
    SetCvarFloatSafe(g_hFFHard,   0.0);
    SetCvarFloatSafe(g_hFFExpert, 0.0);
}

void ApplyAmmoSettings()
{
    SetCvarIntSafe(g_hAmmoShotgunMax, -2);
    SetCvarIntSafe(g_hAmmoAutoshotgunMax, -2);
    SetCvarIntSafe(g_hAmmoSmgMax, -2);
    SetCvarIntSafe(g_hAmmoAssaultRifleMax, -2);
    SetCvarIntSafe(g_hAmmoHuntingRifleMax, -2);
    SetCvarIntSafe(g_hAmmoSniperRifleMax, -2);
    SetCvarIntSafe(g_hAmmoGrenadeLauncherMax, -2);
    SetCvarIntSafe(g_hAmmoM60Max, -2);
}

void ApplyShoveSettings()
{
    SetCvarIntSafe(g_hGunSwingCoopMinPenalty, SHOVE_PENALTY_NEAR_INFINITE);
    SetCvarIntSafe(g_hGunSwingCoopMaxPenalty, SHOVE_PENALTY_NEAR_INFINITE);
    SetCvarIntSafe(g_hGunSwingVsMinPenalty, SHOVE_PENALTY_NEAR_INFINITE);
    SetCvarIntSafe(g_hGunSwingVsMaxPenalty, SHOVE_PENALTY_NEAR_INFINITE);
}

void SetCvarFloatSafe(ConVar cvar, float value)
{
    if (cvar == null)
    {
        return;
    }

    cvar.SetFloat(value, true, false);
}

void SetCvarIntSafe(ConVar cvar, int value)
{
    if (cvar == null)
    {
        return;
    }

    cvar.SetInt(value, true, false);
}

bool IsHumanClientInGame(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client);
}
