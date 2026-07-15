#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "5.0.0"
#define M60_CLASSNAME  "weapon_rifle_m60"

/*
 * M60 may already have one shot queued when attack input is released.
 * Start blocking at 2 rounds so a queued shot can reduce the clip to 1,
 * but should not allow it to reach 0 and trigger the built-in discard.
 */
#define M60_GUARD_CLIP 2

public Plugin myinfo =
{
    name        = "[L4D2] M60 Native Reload Guard - Ultra Low",
    author      = "me",
    description = "Prevents empty M60 discard, preserves native reload and enables fast draw with no idle per-tick checks.",
    version     = PLUGIN_VERSION,
    url         = ""
};

int  g_iActiveM60Ref[MAXPLAYERS + 1];
bool g_bClientHooksInstalled[MAXPLAYERS + 1];
bool g_bM60PreThinkHooked[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errorMax)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, errorMax, "This plugin supports Left 4 Dead 2 only.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

    for (int client = 1; client <= MaxClients; client++)
    {
        ResetClientState(client);

        if (IsClientInGame(client))
        {
            InstallClientHooks(client);
            RefreshActiveWeapon(client);
        }
    }
}

public void OnPluginEnd()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        DisableM60PreThink(client);
    }
}

public void OnMapStart()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        DisableM60PreThink(client);
        g_iActiveM60Ref[client] = INVALID_ENT_REFERENCE;

        if (IsClientInGame(client))
        {
            InstallClientHooks(client);
            RefreshActiveWeapon(client);
        }
    }
}

public void OnMapEnd()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        DisableM60PreThink(client);
        g_iActiveM60Ref[client] = INVALID_ENT_REFERENCE;
    }
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
    InstallClientHooks(client);
}

public void OnClientDisconnect(int client)
{
    DisableM60PreThink(client);
    g_iActiveM60Ref[client] = INVALID_ENT_REFERENCE;
    g_bClientHooksInstalled[client] = false;
}

void InstallClientHooks(int client)
{
    if (!IsValidClient(client) || g_bClientHooksInstalled[client])
    {
        return;
    }

    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
    SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
    SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDropPost);

    g_bClientHooksInstalled[client] = true;
}

public void OnWeaponEquipPost(int client, int weapon)
{
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
    {
        DisableM60Guard(client);
        return;
    }

    if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == weapon)
    {
        SetActiveWeapon(client, weapon, false);
    }
}

public void OnWeaponSwitchPost(int client, int weapon)
{
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
    {
        DisableM60Guard(client);
        return;
    }

    SetActiveWeapon(client, weapon, true);
}

public void OnWeaponDropPost(int client, int weapon)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    int guardedWeapon = EntRefToEntIndex(g_iActiveM60Ref[client]);
    if (guardedWeapon == weapon)
    {
        DisableM60Guard(client);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client >= 1 && client <= MaxClients)
    {
        DisableM60Guard(client);
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (event.GetInt("team") != 2)
    {
        DisableM60Guard(client);
    }
}

void RefreshActiveWeapon(int client)
{
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
    {
        DisableM60Guard(client);
        return;
    }

    SetActiveWeapon(
        client,
        GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon"),
        false
    );
}

void SetActiveWeapon(int client, int weapon, bool fastDraw)
{
    if (!IsM60(weapon))
    {
        DisableM60Guard(client);
        return;
    }

    g_iActiveM60Ref[client] = EntIndexToEntRef(weapon);

    /* Recover an M60 that was already at an invalid empty state. */
    if (GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0)
    {
        SetEntProp(weapon, Prop_Send, "m_iClip1", 1);
    }

    EnableM60PreThink(client);

    if (fastDraw)
    {
        RequestFrame(Frame_EnableM60FireImmediately, GetClientUserId(client));
    }
}

void EnableM60PreThink(int client)
{
    if (client < 1 || client > MaxClients || g_bM60PreThinkHooked[client])
    {
        return;
    }

    SDKHook(client, SDKHook_PreThink, OnM60PreThink);
    g_bM60PreThinkHooked[client] = true;
}

void DisableM60PreThink(int client)
{
    if (client < 1 || client > MaxClients || !g_bM60PreThinkHooked[client])
    {
        return;
    }

    SDKUnhook(client, SDKHook_PreThink, OnM60PreThink);
    g_bM60PreThinkHooked[client] = false;
}

void DisableM60Guard(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    DisableM60PreThink(client);
    g_iActiveM60Ref[client] = INVALID_ENT_REFERENCE;
}

public void OnM60PreThink(int client)
{
    int weapon = EntRefToEntIndex(g_iActiveM60Ref[client]);

    if (
        weapon == INVALID_ENT_REFERENCE ||
        !IsValidSurvivor(client) ||
        !IsPlayerAlive(client) ||
        GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != weapon ||
        !IsM60(weapon)
    )
    {
        DisableM60Guard(client);
        return;
    }

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

    if (clip <= 0)
    {
        SetEntProp(weapon, Prop_Send, "m_iClip1", 1);
        clip = 1;
    }

    if (clip > M60_GUARD_CLIP)
    {
        return;
    }

    int buttons = GetClientButtons(client);
    if ((buttons & IN_ATTACK) == 0)
    {
        return;
    }

    /*
     * Remove only primary attack input. IN_RELOAD is left untouched, so the
     * game's original M60 reload speed, animation and ammo transfer remain.
     */
    ClearAttackInput(client);
}

public void Frame_EnableM60FireImmediately(any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
    {
        return;
    }

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsM60(weapon))
    {
        return;
    }

    float now = GetGameTime();

    if (HasEntProp(weapon, Prop_Send, "m_flNextPrimaryAttack"))
    {
        float nextPrimary = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
        if (nextPrimary > now)
        {
            SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", now);
        }
    }

    if (HasEntProp(client, Prop_Send, "m_flNextAttack"))
    {
        float nextAttack = GetEntPropFloat(client, Prop_Send, "m_flNextAttack");
        if (nextAttack > now)
        {
            SetEntPropFloat(client, Prop_Send, "m_flNextAttack", now);
        }
    }
}

void ClearAttackInput(int client)
{
    ClearButtonBit(client, "m_nButtons", IN_ATTACK);
    ClearButtonBit(client, "m_afButtonPressed", IN_ATTACK);
    ClearButtonBit(client, "m_afButtonLast", IN_ATTACK);
}

void ClearButtonBit(int client, const char[] prop, int bit)
{
    if (!HasEntProp(client, Prop_Data, prop))
    {
        return;
    }

    int value = GetEntProp(client, Prop_Data, prop);
    if ((value & bit) != 0)
    {
        SetEntProp(client, Prop_Data, prop, value & ~bit);
    }
}

void ResetClientState(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_iActiveM60Ref[client] = INVALID_ENT_REFERENCE;
    g_bM60PreThinkHooked[client] = false;
}

bool IsM60(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return false;
    }

    char classname[32];
    GetEntityClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, M60_CLASSNAME, false);
}

bool IsValidClient(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client);
}

bool IsValidSurvivor(int client)
{
    return IsValidClient(client) && GetClientTeam(client) == 2;
}
