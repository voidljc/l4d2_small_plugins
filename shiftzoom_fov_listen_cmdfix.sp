/**
 * =============================================================================
 * 本文件：L4D2 自定义按键望远缩放
 * -----------------------------------------------------------------------------
 * 文档说明：
 *   本插件为 L4D2 提供一个“自定义按键触发的纯 FOV 缩放”功能，仅改变视野，
 *   不修改武器散布、后坐力、弹道或任何伤害逻辑。
 *
 *   解决的问题：
 *   1) 在 dedicated server 中，玩家使用 bind c "+shiftzoom" 之类的自定义命令，
 *      SourceMod 一般会把命令正常回调到对应玩家 client。
 *   2) 但在 listen server（单人/本地开房、房主自己同时也是服务器）中，
 *      房主通过按键触发的自定义命令，插件收到的 client 可能是 0，而不是正常的
 *      玩家索引。
 *   3) 如果代码里直接把 client<=0 视为无效并返回，那么房主按键就会“看起来绑定了，
 *      实际完全没触发”。
 *   4) 当命令来源为 listen server 的 client=0 时，
 *      将其映射到一个真人玩家（优先生还者），从而让房主也能正确触发功能。
 *
 *   功能特性：
 *   - 玩家可自行绑定任意按键：bind c +shiftzoom
 *   - 支持两种模式：按住放大 / 切换放大
 *   - 仅对白名单武器生效
 *   - 死亡、换队、切到非白名单武器、插件禁用时自动恢复 FOV
 *   - 不依赖 OnPlayerRunCmd 逐 tick 读某个固定键位，性能开销较低
 *
 *   默认推荐绑定：
 *     bind c +shiftzoom
 *
 *   可用命令：
 *     +shiftzoom / -shiftzoom
 *     sm_zoomhelp
 *     sm_zoommode
 *     sm_zoomhold
 *     sm_zoomtoggle
 *
 *   ConVars：
 *     sm_shiftzoom_enable        1/0 启用
 *     sm_shiftzoom_fov           放大时 FOV（越小放大越明显）
 *     sm_shiftzoom_default_mode  0=按住 1=切换
 * =============================================================================
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo =
{
    name        = "L4D2 Custom Key Zoom",
    author      = "me",
    description = "Custom bind FOV zoom with hold/toggle modes for whitelisted weapons. Listen server host compatible.",
    version     = "2.1.1",
    url         = ""
};

ConVar gC_Enable;
ConVar gC_ZoomFov;
ConVar gC_DefaultMode; // 0=hold, 1=toggle

enum ZoomMode
{
    ZOOMMODE_HOLD = 0,
    ZOOMMODE_TOGGLE = 1
};

int  gPlayerMode[MAXPLAYERS + 1];
bool gZoomOn[MAXPLAYERS + 1];
bool gBindHeld[MAXPLAYERS + 1];
int  gSavedFov[MAXPLAYERS + 1];

static const char gWeaponWhitelist[][] =
{
    //"weapon_pistol",
    //"weapon_pistol_magnum",
    //"weapon_rifle",
    //"weapon_rifle_ak47",
    //"weapon_rifle_desert",
    "weapon_rifle_sg552",
    //"weapon_rifle_m60",
    //"weapon_smg",
    //"weapon_smg_mp5",
    "weapon_smg_silenced",
    "weapon_hunting_rifle",
    "weapon_sniper_awp",
    "weapon_sniper_military",
    "weapon_sniper_scout",

};

public void OnPluginStart()
{
    gC_Enable      = CreateConVar("sm_shiftzoom_enable", "1", "Enable custom key zoom (1/0).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gC_ZoomFov     = CreateConVar("sm_shiftzoom_fov", "40", "Zoom FOV when active (smaller = more zoom).", FCVAR_NOTIFY, true, 10.0, true, 90.0);
    gC_DefaultMode = CreateConVar("sm_shiftzoom_default_mode", "0", "Default mode: 0=hold, 1=toggle.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    RegConsoleCmd("+shiftzoom",  Cmd_PlusShiftZoom,  "Press custom zoom bind.");
    RegConsoleCmd("-shiftzoom",  Cmd_MinusShiftZoom, "Release custom zoom bind.");

    RegConsoleCmd("sm_zoommode",   Cmd_ZoomModeToggle,  "Toggle zoom control mode (hold/toggle).");
    RegConsoleCmd("sm_zoomhold",   Cmd_ZoomModeHold,    "Set zoom mode to HOLD.");
    RegConsoleCmd("sm_zoomtoggle", Cmd_ZoomModeToggle2, "Set zoom mode to TOGGLE.");
    RegConsoleCmd("sm_zoomhelp",   Cmd_ZoomHelp,        "Show zoom bind help.");

    HookConVarChange(gC_Enable, OnEnableChanged);

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_team",  Event_PlayerTeam,  EventHookMode_Post);

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClientState(i);

        if (IsClientInGame(i))
            SDKHook(i, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
    }
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
    SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
}

public void OnClientDisconnect(int client)
{
    ForceRestore(client);
    ResetClientState(client);
}

void ResetClientState(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    gZoomOn[client]     = false;
    gBindHeld[client]   = false;
    gSavedFov[client]   = 0;
    gPlayerMode[client] = -1;
}

int FindAnyHumanClientPreferSurvivor()
{
    int fallback = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        if (GetClientTeam(i) == 2)
            return i;

        if (fallback == 0)
            fallback = i;
    }

    return fallback;
}

int ResolveCommandClient(int client)
{
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        return client;

    if (client == 0 && !IsDedicatedServer())
        return FindAnyHumanClientPreferSurvivor();

    return 0;
}

public Action Cmd_ZoomHelp(int client, int args)
{
    int realClient = ResolveCommandClient(client);

    if (realClient > 0)
    {
        ReplyToCommand(realClient, "[Zoom] 默认绑定：bind c +shiftzoom");
        ReplyToCommand(realClient, "[Zoom] 自定义绑定：bind <key> +shiftzoom  例如：bind v +shiftzoom");
        ReplyToCommand(realClient, "[Zoom] 解除绑定：unbind <key>");
        ReplyToCommand(realClient, "[Zoom] 模式指令：sm_zoomhold / sm_zoomtoggle / sm_zoommode");
    }
    else if (client <= 0)
    {
        PrintToServer("[Zoom] 绑定示例：bind c +shiftzoom");
        PrintToServer("[Zoom] 模式指令：sm_zoomhold / sm_zoomtoggle / sm_zoommode");
    }

    return Plugin_Handled;
}

public Action Cmd_ZoomModeToggle(int client, int args)
{
    client = ResolveCommandClient(client);
    if (client <= 0)
        return Plugin_Handled;

    ZoomMode cur  = GetClientZoomMode(client);
    ZoomMode next = (cur == ZOOMMODE_HOLD) ? ZOOMMODE_TOGGLE : ZOOMMODE_HOLD;

    SetClientZoomMode(client, next);
    ReplyToCommand(client, "[Zoom] 模式已切换为：%s", (next == ZOOMMODE_HOLD) ? "按住放大" : "切换放大");

    if (!CanClientZoom(client))
    {
        ForceRestore(client);
    }
    else if (next == ZOOMMODE_HOLD)
    {
        if (gBindHeld[client] && !gZoomOn[client])
            Zoom(client);
        else if (!gBindHeld[client] && gZoomOn[client])
            Restore(client);
    }

    return Plugin_Handled;
}

public Action Cmd_ZoomModeHold(int client, int args)
{
    client = ResolveCommandClient(client);
    if (client <= 0)
        return Plugin_Handled;

    SetClientZoomMode(client, ZOOMMODE_HOLD);
    ReplyToCommand(client, "[Zoom] 模式已设置为：按住放大");

    if (!CanClientZoom(client))
    {
        ForceRestore(client);
    }
    else
    {
        if (gBindHeld[client] && !gZoomOn[client])
            Zoom(client);
        else if (!gBindHeld[client] && gZoomOn[client])
            Restore(client);
    }

    return Plugin_Handled;
}

public Action Cmd_ZoomModeToggle2(int client, int args)
{
    client = ResolveCommandClient(client);
    if (client <= 0)
        return Plugin_Handled;

    SetClientZoomMode(client, ZOOMMODE_TOGGLE);
    ReplyToCommand(client, "[Zoom] 模式已设置为：切换放大");

    if (!CanClientZoom(client))
        ForceRestore(client);

    return Plugin_Handled;
}

public Action Cmd_PlusShiftZoom(int client, int args)
{
    client = ResolveCommandClient(client);
    if (client <= 0)
        return Plugin_Handled;

    gBindHeld[client] = true;

    if (!CanClientZoom(client))
    {
        if (gZoomOn[client])
            Restore(client);
        return Plugin_Handled;
    }

    ZoomMode mode = GetClientZoomMode(client);

    if (mode == ZOOMMODE_HOLD)
    {
        if (!gZoomOn[client])
            Zoom(client);
    }
    else
    {
        if (gZoomOn[client])
            Restore(client);
        else
            Zoom(client);
    }

    return Plugin_Handled;
}

public Action Cmd_MinusShiftZoom(int client, int args)
{
    client = ResolveCommandClient(client);
    if (client <= 0)
        return Plugin_Handled;

    gBindHeld[client] = false;

    if (GetClientZoomMode(client) == ZOOMMODE_HOLD && gZoomOn[client])
        Restore(client);

    return Plugin_Handled;
}

ZoomMode GetClientZoomMode(int client)
{
    int pm = gPlayerMode[client];
    if (pm == 0) return ZOOMMODE_HOLD;
    if (pm == 1) return ZOOMMODE_TOGGLE;
    return (gC_DefaultMode.IntValue == 1) ? ZOOMMODE_TOGGLE : ZOOMMODE_HOLD;
}

void SetClientZoomMode(int client, ZoomMode mode)
{
    gPlayerMode[client] = view_as<int>(mode);
}

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (StringToInt(newValue) != 0)
        return;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            ForceRestore(i);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
    {
        gBindHeld[client] = false;
        ForceRestore(client);
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0)
        return;

    if (GetClientTeam(client) <= 1)
    {
        gBindHeld[client] = false;
        ForceRestore(client);
    }
}

public void OnWeaponSwitchPost(int client, int weapon)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;

    if (!gC_Enable.BoolValue)
    {
        ForceRestore(client);
        return;
    }

    if (!IsPlayerAlive(client) || GetClientTeam(client) != 2)
    {
        ForceRestore(client);
        return;
    }

    bool whitelisted = IsWeaponWhitelistedEntity(weapon);

    if (!whitelisted)
    {
        if (gZoomOn[client])
            Restore(client);
        return;
    }

    if (GetClientZoomMode(client) == ZOOMMODE_HOLD && gBindHeld[client] && !gZoomOn[client])
        Zoom(client);
}

bool CanClientZoom(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return false;

    if (!gC_Enable.BoolValue)
        return false;

    if (!IsPlayerAlive(client))
        return false;

    if (GetClientTeam(client) != 2)
        return false;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEdict(weapon))
        return false;

    return IsWeaponWhitelistedEntity(weapon);
}

bool IsWeaponWhitelistedEntity(int weapon)
{
    if (weapon <= MaxClients || !IsValidEdict(weapon))
        return false;

    char cls[64];
    GetEdictClassname(weapon, cls, sizeof(cls));

    for (int i = 0; i < sizeof(gWeaponWhitelist); i++)
    {
        if (StrEqual(cls, gWeaponWhitelist[i], false))
            return true;
    }

    return false;
}

void Zoom(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;

    int curFov = GetEntProp(client, Prop_Send, "m_iFOV");
    if (curFov <= 0)
        curFov = 90;

    if (!gZoomOn[client])
        gSavedFov[client] = curFov;

    int targetFov = gC_ZoomFov.IntValue;
    if (targetFov < 10) targetFov = 10;
    if (targetFov > 90) targetFov = 90;

    SetEntProp(client, Prop_Send, "m_iFOV", targetFov);
    gZoomOn[client] = true;
}

void Restore(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;

    int restoreFov = gSavedFov[client];
    if (restoreFov <= 0)
        restoreFov = 90;

    SetEntProp(client, Prop_Send, "m_iFOV", restoreFov);
    gZoomOn[client] = false;
}

void ForceRestore(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (IsClientInGame(client))
    {
        int restoreFov = gSavedFov[client];
        if (restoreFov <= 0)
            restoreFov = 90;

        SetEntProp(client, Prop_Send, "m_iFOV", restoreFov);
    }

    gZoomOn[client]   = false;
    gSavedFov[client] = 0;
}
