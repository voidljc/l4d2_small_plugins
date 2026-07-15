/*
 * 文件名: multifunctional_miscellaneous_cheat_bridge.sp
 * 简介: L4D2 SourceMod 初始化插件。
 *
 * 重要说明:
 *   L4D2 会拒绝在通过普通“开始战役/大厅”创建的当前会话里启用真实 sv_cheats，
 *   并显示：Can't use cheats now...。插件不能可靠地把这种会话变成由主菜单
 *   “map mapname”创建的作弊监听服。
 *
 *   本版本因此不再修改 sv_cheats，也没有任何 sv_cheats 监控器。
 *   本版本会在插件运行期间移除服务器作弊命令的 FCVAR_CHEAT 标志，并通过
 *   全局命令监听器只允许本地主机、root 管理员或服务器控制台执行。
 *   因此主机可以直接使用：
 *
 *       god
 *       noclip
 *       give rifle_m60
 *       z_spawn tank
 *
 *   对需要作弊标志的 ConVar，使用：sm_dev <CVar> <值>。
 *   本插件卸载或桥接关闭时会恢复所有被修改的命令标志。
 *
 * 安全:
 *   - 服务器控制台始终可以使用 sm_dev。
 *   - 非专用监听服仅允许客户端 1（本地主机）或 root 管理员使用。
 *   - 专用服务器仅允许 root 管理员使用。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name = "L4D2 Start Config + Cheat Bridge",
    author = "me",
    description = "Applies campaign settings and runs cheat-flagged commands without forcing sv_cheats.",
    version = "2.5-cheat-bridge",
    url = ""
};

#define SHOVE_PENALTY_NEAR_INFINITE 99999
#define GLOW_REFRESH_STAGE2_DELAY 0.2
#define CLIENT_JOIN_GLOW_REFRESH_DELAY 30.0
#define MOUNTED_GUN_NEAR_INFINITE_TIME 999999.0
#define DEV_COMMAND_BUFFER 512
#define DEV_VALUE_BUFFER 384

ConVar g_hCheatBridge;
ConVar g_hSvCheats;
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
ConVar g_hDirectorNoDeathCheck;
ConVar g_hMinigunOverheatTime;
ConVar g_hMinigunCooldownTime;
ConVar g_hMountedGunOverheatTime;
ConVar g_hMountedGunCooldownTime;
ConVar g_hMountedGunOverheatPenaltyTime;

Handle g_hStartConfigStage2Timer;
Handle g_hLateJoinGlowStage2Timer;
Handle g_hClientJoinGlowTimers[MAXPLAYERS + 1];

StringMap g_smUnlockedCheatCommands;
ArrayList g_alUnlockedCheatCommands;

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        SetFailState("This plugin only supports Left 4 Dead 2.");
        return;
    }

    g_smUnlockedCheatCommands = new StringMap();
    g_alUnlockedCheatCommands = new ArrayList(ByteCountToCells(128));

    g_hCheatBridge = CreateConVar(
        "sm_startcfg_cheat_bridge",
        "1",
        "Unlock cheat-flagged server commands for the local host/root admins. 1=enable, 0=disable.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_hCheatBridge.AddChangeHook(ConVar_CheatBridgeChanged);

    // 只用于状态显示，绝不修改、监听或复制 sv_cheats。
    g_hSvCheats = FindConVar("sv_cheats");

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
    g_hDirectorNoDeathCheck = FindConVar("director_no_death_check");
    g_hMinigunOverheatTime = FindConVar("z_minigun_overheat_time");
    g_hMinigunCooldownTime = FindConVar("z_minigun_cooldown_time");
    g_hMountedGunOverheatTime = FindConVar("mounted_gun_overheat_time");
    g_hMountedGunCooldownTime = FindConVar("mounted_gun_cooldown_time");
    g_hMountedGunOverheatPenaltyTime = FindConVar("mounted_gun_overheat_penalty_time");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    AddCommandListener(Listener_CheatCommandGate);

    RegConsoleCmd("sm_startcfg", Command_StartCfg, "Reapply all start configuration settings.");
    RegConsoleCmd("sm_cheatstatus", Command_CheatStatus, "Show cheat bridge and real sv_cheats status.");
    RegConsoleCmd("sm_zisha", Command_ZiSha, "Kill yourself from chat with !zisha.");
    RegConsoleCmd("sm_dev", Command_Dev, "Run one cheat-flagged command or set/query one ConVar.");
    RegConsoleCmd("sm_cheat", Command_Dev, "Alias of sm_dev.");

    AutoExecConfig(true, "l4d2_start_config_cheat_bridge");

    UnlockAllCheatCommands();
    ApplyStartConfig();
    PrintToServer("[StartCfg] Cheat bridge loaded. Real sv_cheats is not forced; host cheat commands are unlocked.");
}

public void OnAllPluginsLoaded()
{
    UnlockAllCheatCommands();
}

public void OnMapStart()
{
    UnlockAllCheatCommands();
    ApplyStartConfig();
}

public void OnPluginEnd()
{
    RestoreAllCheatCommands();
}

public void OnConfigsExecuted()
{
    // server.cfg、模式配置等可能覆盖地图开始时的值，因此配置完成后再次应用。
    ApplyAmmoSettings();
    ApplyShoveSettings();
    ApplyMountedGunSettings();
    DisableFriendlyFire();
    SetCvarIntSafe(g_hDirectorNoDeathCheck, 1);

    CreateTimer(1.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(5.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnServerExitHibernation()
{
    ApplyStartConfig();
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

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    DisableFriendlyFire();
    SetCvarIntSafe(g_hDirectorNoDeathCheck, 1);
    CreateTimer(1.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Command_StartCfg(int client, int args)
{
    ApplyStartConfig();

    int currentValue = (g_hSvCheats != null) ? g_hSvCheats.IntValue : -1;
    ReplyToCommand(
        client,
        "[StartCfg] 配置已重新执行。cheat_bridge=%d，真实 sv_cheats=%d（本插件不会修改它）。",
        IsCheatBridgeEnabled() ? 1 : 0,
        currentValue
    );

    return Plugin_Handled;
}

public Action Command_CheatStatus(int client, int args)
{
    int currentValue = (g_hSvCheats != null) ? g_hSvCheats.IntValue : -1;

    ReplyToCommand(
        client,
        "[StartCfg] cheat_bridge=%d, access=%d, unlocked_commands=%d, real sv_cheats=%d。",
        IsCheatBridgeEnabled() ? 1 : 0,
        HasDevAccess(client) ? 1 : 0,
        (g_alUnlockedCheatCommands != null) ? g_alUnlockedCheatCommands.Length : 0,
        currentValue
    );

    return Plugin_Handled;
}

public Action Command_Dev(int client, int args)
{
    if (!IsCheatBridgeEnabled())
    {
        ReplyToCommand(client, "[Dev] 作弊桥接已关闭。设置 sm_startcfg_cheat_bridge 1 后再试。");
        return Plugin_Handled;
    }

    if (!HasDevAccess(client))
    {
        ReplyToCommand(client, "[Dev] 仅本地监听服主机、root 管理员或服务器控制台可以使用。");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Dev] 用法: sm_dev <命令/CVar> [参数或值]");
        ReplyToCommand(client, "[Dev] 示例: sm_dev god | sm_dev noclip | sm_dev give rifle_m60 | sm_dev z_spawn tank");
        return Plugin_Handled;
    }

    char name[128];
    GetCmdArg(1, name, sizeof(name));

    if (StrEqual(name, "sv_cheats", false))
    {
        ReplyToCommand(
            client,
            "[Dev] 本插件不会修改 sv_cheats。当前大厅战役会被 L4D2 引擎拒绝；请直接使用 sm_dev <作弊命令>。"
        );
        return Plugin_Handled;
    }

    char raw[DEV_COMMAND_BUFFER];
    GetCmdArgString(raw, sizeof(raw));
    TrimString(raw);

    // 只执行一个命令，禁止通过分号或换行拼接第二条命令。
    if (StrContains(raw, ";", false) != -1
        || StrContains(raw, "\n", false) != -1
        || StrContains(raw, "\r", false) != -1)
    {
        ReplyToCommand(client, "[Dev] 一次只能执行一条命令，不能包含分号或换行。");
        return Plugin_Handled;
    }

    ConVar cvar = FindConVar(name);
    if (cvar != null)
    {
        return HandleDevConVar(client, cvar, name, args);
    }

    int currentFlags = GetCommandFlags(name);
    if (currentFlags == INVALID_FCVAR_FLAGS)
    {
        ReplyToCommand(client, "[Dev] 找不到命令或 ConVar: %s", name);
        return Plugin_Handled;
    }

    if ((currentFlags & FCVAR_CHEAT) != 0 && !UnlockCheatCommand(name, currentFlags))
    {
        ReplyToCommand(client, "[Dev] 无法解除命令的作弊标志: %s", name);
        return Plugin_Handled;
    }

    if (client > 0)
    {
        FakeClientCommand(client, "%s", raw);
    }
    else
    {
        ServerCommand("%s", raw);
        ServerExecute();
    }

    ReplyToCommand(client, "[Dev] 已执行: %s", raw);
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

public void ConVar_CheatBridgeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (StringToInt(newValue) != 0)
    {
        UnlockAllCheatCommands();
    }
    else
    {
        RestoreAllCheatCommands();
    }
}

public Action Listener_CheatCommandGate(int client, const char[] command, int argc)
{
    if (!IsCheatBridgeEnabled() || g_smUnlockedCheatCommands == null)
    {
        return Plugin_Continue;
    }

    int originalFlags;
    if (!g_smUnlockedCheatCommands.GetValue(command, originalFlags))
    {
        return Plugin_Continue;
    }

    if (HasDevAccess(client))
    {
        return Plugin_Continue;
    }

    if (client > 0 && client <= MaxClients)
    {
        ReplyToCommand(client, "[Dev] 该作弊命令仅允许本地主机或 root 管理员使用。");
    }

    return Plugin_Handled;
}

void UnlockAllCheatCommands()
{
    if (!IsCheatBridgeEnabled() || g_smUnlockedCheatCommands == null || g_alUnlockedCheatCommands == null)
    {
        return;
    }

    char name[128];
    bool isCommand;
    int flags;

    Handle iterator = FindFirstConCommand(name, sizeof(name), isCommand, flags);
    if (iterator == INVALID_HANDLE)
    {
        LogError("[StartCfg] Unable to enumerate console commands.");
        return;
    }

    do
    {
        if (isCommand && (flags & FCVAR_CHEAT) != 0)
        {
            UnlockCheatCommand(name, flags);
        }
    }
    while (FindNextConCommand(iterator, name, sizeof(name), isCommand, flags));

    delete iterator;
}

bool UnlockCheatCommand(const char[] name, int currentFlags)
{
    int storedFlags;
    if (g_smUnlockedCheatCommands.GetValue(name, storedFlags))
    {
        return true;
    }

    if ((currentFlags & FCVAR_CHEAT) == 0)
    {
        return true;
    }

    if (!SetCommandFlags(name, currentFlags & ~FCVAR_CHEAT))
    {
        return false;
    }

    g_smUnlockedCheatCommands.SetValue(name, currentFlags);
    g_alUnlockedCheatCommands.PushString(name);
    return true;
}

void RestoreAllCheatCommands()
{
    if (g_smUnlockedCheatCommands == null || g_alUnlockedCheatCommands == null)
    {
        return;
    }

    char name[128];
    int originalFlags;

    for (int i = 0; i < g_alUnlockedCheatCommands.Length; i++)
    {
        g_alUnlockedCheatCommands.GetString(i, name, sizeof(name));

        if (g_smUnlockedCheatCommands.GetValue(name, originalFlags))
        {
            SetCommandFlags(name, originalFlags);
        }
    }

    g_smUnlockedCheatCommands.Clear();
    g_alUnlockedCheatCommands.Clear();
}

Action HandleDevConVar(int client, ConVar cvar, const char[] name, int args)
{
    char value[DEV_VALUE_BUFFER];

    if (args == 1)
    {
        cvar.GetString(value, sizeof(value));
        ReplyToCommand(client, "[Dev] %s = %s", name, value);
        return Plugin_Handled;
    }

    BuildArguments(2, args, value, sizeof(value));
    cvar.SetString(value, true, false);

    char actual[DEV_VALUE_BUFFER];
    cvar.GetString(actual, sizeof(actual));
    ReplyToCommand(client, "[Dev] 已设置 %s = %s", name, actual);
    return Plugin_Handled;
}

void BuildArguments(int firstArg, int lastArg, char[] output, int maxlen)
{
    output[0] = '\0';

    char piece[192];
    for (int i = firstArg; i <= lastArg; i++)
    {
        GetCmdArg(i, piece, sizeof(piece));

        if (i > firstArg)
        {
            StrCat(output, maxlen, " ");
        }

        StrCat(output, maxlen, piece);
    }
}

bool HasDevAccess(int client)
{
    if (client == 0)
    {
        return true;
    }

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    // 监听服主机固定为客户端槽位 1；root 管理员也始终允许。
    if (!IsDedicatedServer() && client == 1)
    {
        return true;
    }

    return CheckCommandAccess(client, "sm_dev", ADMFLAG_ROOT, true);
}

bool IsCheatBridgeEnabled()
{
    return g_hCheatBridge != null && g_hCheatBridge.BoolValue;
}

public Action Timer_DisableFriendlyFire(Handle timer)
{
    DisableFriendlyFire();
    return Plugin_Stop;
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
    ApplyMountedGunSettings();
    DisableFriendlyFire();

    SetCvarIntSafe(g_hDirectorNoDeathCheck, 1);

    CreateTimer(1.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(5.0, Timer_DisableFriendlyFire, _, TIMER_FLAG_NO_MAPCHANGE);
}

void RunMapStartCommands()
{
    SetCvarIntSafe(g_hDisableGlowSurvivors, 1);
    SetCvarIntSafe(g_hRescueDisabled, 1);
    SetCvarIntSafe(g_hDirectorNoDeathCheck, 1);
    ApplyMountedGunSettings();

    delete g_hStartConfigStage2Timer;
    g_hStartConfigStage2Timer = CreateTimer(
        GLOW_REFRESH_STAGE2_DELAY,
        Timer_RunMapStartCommandsStage2,
        _,
        TIMER_FLAG_NO_MAPCHANGE
    );
}

void RefreshSurvivorGlowForLateJoiner()
{
    SetCvarIntSafe(g_hDisableGlowSurvivors, 1);

    delete g_hLateJoinGlowStage2Timer;
    g_hLateJoinGlowStage2Timer = CreateTimer(
        GLOW_REFRESH_STAGE2_DELAY,
        Timer_RunLateJoinGlowStage2,
        _,
        TIMER_FLAG_NO_MAPCHANGE
    );
}

void QueueClientJoinGlowRefresh(int client)
{
    if (!IsHumanClientInGame(client))
    {
        return;
    }

    delete g_hClientJoinGlowTimers[client];
    g_hClientJoinGlowTimers[client] = CreateTimer(
        CLIENT_JOIN_GLOW_REFRESH_DELAY,
        Timer_RefreshGlowAfterClientJoin,
        GetClientUserId(client),
        TIMER_FLAG_NO_MAPCHANGE
    );
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

void ApplyMountedGunSettings()
{
    SetCvarFloatSafe(g_hMinigunOverheatTime, MOUNTED_GUN_NEAR_INFINITE_TIME);
    SetCvarFloatSafe(g_hMountedGunOverheatTime, MOUNTED_GUN_NEAR_INFINITE_TIME);

    SetCvarFloatSafe(g_hMinigunCooldownTime, 0.0);
    SetCvarFloatSafe(g_hMountedGunCooldownTime, 0.0);
    SetCvarFloatSafe(g_hMountedGunOverheatPenaltyTime, 0.0);
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
