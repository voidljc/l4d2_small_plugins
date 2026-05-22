/*
This plugin listens to primary-weapon firing events and provides a "shot accumulation reward" mechanic
that converts standard bullets into upgraded bullets for specific whitelisted weapons.

- Rifles, SMGs, and snipers: after every 3 shots, reward 1 upgraded bullet (incendiary or explosive).
- Shotguns: use an alternating reward threshold: 2 shots for 1 reward, then 1 shot for 1 reward, then 2, and so on.

The reward does NOT increase total magazine capacity. Instead, it converts one normal round currently
in the magazine into an upgraded round. The upgrade type is chosen with a 50% incendiary / 50% explosive
probability, providing a sustained but controlled damage boost without breaking the ammo structure.
*/

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name        = "Weapon Special Bullet Whitelist",
    author      = "me",
    description = "Whitelist weapons: rifles/smgs/snipers grant 1 upgraded bullet every 3 shots; shotguns alternate thresholds 2 and 1 (2<->1) per reward. Explosive/Incendiary 50/50.",
    version     = "1.1.0",
    url         = ""
};

// Common L4D2 m_upgradeBitVec bits: 1 = Incendiary, 2 = Explosive
#define UPGRADE_INCENDIARY (1)
#define UPGRADE_EXPLOSIVE  (2)

ConVar g_cvEnable;

// Group A: reward 1 upgraded bullet every 3 shots
static const char g_Group3Weapons[][] =
{
    "weapon_hunting_rifle",
    "weapon_rifle",
    "weapon_rifle_ak47",
    "weapon_rifle_desert",
    "weapon_rifle_m60",
    "weapon_rifle_sg552",

    "weapon_smg",
    "weapon_smg_mp5",
    "weapon_smg_silenced",

    "weapon_sniper_awp",
    "weapon_sniper_military",
    "weapon_sniper_scout"
};

// Group B: four shotguns (alternating threshold: 2 then 1 then 2 ...)
static const char g_ShotgunWeapons[][] =
{
    "weapon_autoshotgun",
    "weapon_pumpshotgun",
    "weapon_shotgun_spas",
    "weapon_shotgun_chrome"
};

// Per-player: shot counter and the "primary weapon entity bound to the current counter"
int  g_ShotCount[MAXPLAYERS + 1];
int  g_LastPrimaryEnt[MAXPLAYERS + 1];

// Shotgun alternating phase: false = next reward uses threshold 2, true = next reward uses threshold 1
bool g_ShotgunPhase[MAXPLAYERS + 1];

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("wsbw_enable", "1", "Enable plugin (0/1).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    AutoExecConfig(true, "weapon_special_bullet_whitelist");

    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClient(i);
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        ResetClient(client);
    }
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        ResetClient(client);
    }
}

void ResetClient(int client)
{
    g_ShotCount[client] = 0;
    g_LastPrimaryEnt[client] = -1;
    g_ShotgunPhase[client] = false; // Start with "2 shots -> 1 reward"
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients)
    {
        return;
    }
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return;
    }

    // Active weapon
    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (active <= MaxClients || !IsValidEntity(active))
    {
        return;
    }

    // Primary weapon (slot 0)
    int primary = GetPlayerWeaponSlot(client, 0);
    if (primary <= MaxClients || !IsValidEntity(primary))
    {
        return;
    }

    // Only allow primary-weapon fire events to trigger (avoid pistols/melee)
    if (active != primary)
    {
        return;
    }

    // Check whitelist membership and compute the threshold for this shot
    bool isShotgun = false;
    int threshold = GetThresholdForWeapon(primary, client, isShotgun);
    if (threshold == 0)
    {
        return;
    }

    // Weapon changed: reset counters; also reset shotgun phase to avoid inheriting the "1-shot reward" state across weapons
    if (g_LastPrimaryEnt[client] != primary)
    {
        g_LastPrimaryEnt[client] = primary;
        g_ShotCount[client] = 0;
        if (isShotgun)
        {
            g_ShotgunPhase[client] = false; // New shotgun starts at threshold 2
        }
    }

    // Defensive checks to avoid spam if GetEntProp is invalid for some reason
    if (!HasEntProp(primary, Prop_Send, "m_iClip1") ||
        !HasEntProp(primary, Prop_Send, "m_upgradeBitVec") ||
        !HasEntProp(primary, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
    {
        return;
    }

    g_ShotCount[client]++;

    if (g_ShotCount[client] < threshold)
    {
        return;
    }

    // Threshold reached: reset and reward
    g_ShotCount[client] = 0;

    int upgradeFlag = (GetURandomFloat() < 0.5) ? UPGRADE_EXPLOSIVE : UPGRADE_INCENDIARY;
    GiveOneUpgradedBullet_AddToClip(primary, upgradeFlag);

    // Shotguns: toggle phase after each reward to implement 2<->1 alternation
    if (isShotgun)
    {
        g_ShotgunPhase[client] = !g_ShotgunPhase[client];
    }
}

int GetThresholdForWeapon(int weaponEnt, int client, bool &isShotgun)
{
    isShotgun = false;

    char cls[64];
    GetEntityClassname(weaponEnt, cls, sizeof(cls));

    // Shotguns: alternating threshold (2 then 1 then 2 ...)
    for (int i = 0; i < sizeof(g_ShotgunWeapons); i++)
    {
        if (StrEqual(cls, g_ShotgunWeapons[i], false))
        {
            isShotgun = true;
            return g_ShotgunPhase[client] ? 1 : 2;
        }
    }

    // Others: every 3 shots
    for (int j = 0; j < sizeof(g_Group3Weapons); j++)
    {
        if (StrEqual(cls, g_Group3Weapons[j], false))
        {
            return 3;
        }
    }

    return 0;
}

// Your "add bullet logic":
// - Reward 1 upgraded bullet without increasing total magazine size.
// - Implementation: do not change m_iClip1; only increase m_nUpgradedPrimaryAmmoLoaded
//   (equivalent to converting 1 normal round currently in the magazine into an upgraded round).
void GiveOneUpgradedBullet_AddToClip(int weapon, int upgradeFlag)
{
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return;
    }

    if (!HasEntProp(weapon, Prop_Send, "m_iClip1") ||
        !HasEntProp(weapon, Prop_Send, "m_upgradeBitVec") ||
        !HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
    {
        return;
    }

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip <= 0)
    {
        return; // Magazine empty: no bullets available to convert
    }

    int upLoaded = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
    if (upLoaded < 0) upLoaded = 0;

    // Key constraint: upgraded rounds must not exceed total rounds in the magazine, or logic becomes inconsistent
    if (upLoaded >= clip)
    {
        return;
    }

    int bitvec = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
    bitvec |= upgradeFlag;
    SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", bitvec);

    upLoaded++;
    if (upLoaded > 255) upLoaded = 255;

    SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", upLoaded);

    // Note: m_iClip1 is NOT modified.
    // Net effect is equivalent to "+1 then -1": total magazine count stays the same, but the upgraded-round share increases by 1.
}
