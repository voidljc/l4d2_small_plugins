/*
 * L4D2 Tank Spawn HP x2 (Auto-Detect Version)
 *
 * Features:
 * - Listen for Tank spawns (tank_spawn / player_spawn as a double-safety net)
 * - Once a Tank is detected, multiply both its current HP and max HP by 2
 * - Applies only to Infected Tanks (m_zombieClass == Tank)
 *
 * Key design notes (stability first):
 * 1) Does not rely on any "spawn function return value": in L4D2, Tank spawning happens inside the engine/Director,
 *    and plugins can only observe the completed spawn via events.
 * 2) Uses a 0.1s delayed timer before writing HP to avoid same-frame / immediate-follow-up game logic overwriting HP,
 *    which would make the write fail.
 * 3) Updates both m_iHealth and m_iMaxHealth to avoid incorrect health bar max display or later logic inconsistencies.
 * 4) Uses userid -> client mapping to ensure the event source is reliable, and performs full validation:
 *    InGame / Alive / Team / Class.
 *
 * Dependencies: SourceMod 1.12+, sdktools (optional: sdkhooks)
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define ZOMBIECLASS_TANK 8

public Plugin myinfo =
{
    name        = "Tank HP x2 on Spawn",
    author      = "me",
    description = "Detect tank spawn and double its health",
    version     = "1.0",
    url         = ""
};

public void OnPluginStart()
{
    // Event: Tank spawn (most direct)
    HookEvent("tank_spawn", Event_TankSpawn, EventHookMode_PostNoCopy);

    // Fallback: player spawn (more reliable than tank_spawn in some cases)
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidTankClient(client)) return;

    // Delay slightly to avoid HP being overwritten by game logic
    CreateTimer(0.1, Timer_DoubleTankHP, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidTankClient(client)) return;

    CreateTimer(0.1, Timer_DoubleTankHP, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DoubleTankHP(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidTankClient(client)) return Plugin_Stop;

    int hp    = GetEntProp(client, Prop_Data, "m_iHealth");
    int maxhp = GetEntProp(client, Prop_Data, "m_iMaxHealth");

    // Failsafe: sometimes maxhp may be 0; use current hp as the baseline
    if (maxhp <= 0) maxhp = hp;
    if (hp <= 0 || maxhp <= 0) return Plugin_Stop;

    int newMax = maxhp * 2;
    int newHP  = hp * 2;

    SetEntProp(client, Prop_Data, "m_iMaxHealth", newMax);
    SetEntProp(client, Prop_Data, "m_iHealth", newHP);

    // In some HUD/network-sync cases, writing Prop_Send is more reliable (optional)
    if (HasEntProp(client, Prop_Send, "m_iHealth"))
        SetEntProp(client, Prop_Send, "m_iHealth", newHP);

    return Plugin_Stop;
}

static bool IsValidTankClient(int client)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (GetClientTeam(client) != 3) return false; // 3 = Infected
    if (!IsPlayerAlive(client)) return false;

    int zclass = GetEntProp(client, Prop_Send, "m_zombieClass");
    return (zclass == ZOMBIECLASS_TANK);
}
