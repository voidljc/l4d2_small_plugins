/* 
 * L4D2 Headshot Reward System (Shot-Window Validation Version)
 *
 * Rules:
 * 1) Shot record phase (weapon_fire):
 *    - When the player triggers the weapon_fire event, record:
 *      a) The timestamp of this shot
 *      b) The current active weapon entity
 *    - Also reset the "reward already granted for this shot" flag
 *    - If the plugin is disabled, the client is invalid, or (when configured) the player is not a Survivor,
 *      do not record any state
 *
 * 2) Damage entry point (player_hurt / infected_hurt):
 *    - Only handle damage events caused by a valid player attacker
 *    - If configured as Survivors-only, filter the attacker team first
 *
 * 3) Shot-window validation:
 *    - Compare current time with the most recent weapon_fire timestamp
 *    - If the time delta exceeds the configured shot window (HS_SHOT_WINDOW):
 *      -> treat as an invalid shot and do not enter reward logic
 *    - If this shot has already been rewarded:
 *      -> terminate immediately to prevent duplicate rewards for a single shot
 *
 * 4) Weapon consistency validation:
 *    - Read the attacker's current active weapon
 *    - If the current weapon does not match the weapon recorded at weapon_fire:
 *      -> terminate to prevent incorrect rewards caused by weapon switching or async events
 *
 * 5) Hitgroup decision order:
 *    - Always use the event field hitgroup as the source of truth
 *    - Only when hitgroup == HEAD is the hit considered a valid headshot
 *    - Any non-head hit never triggers rewards
 *
 * 6) Target-type branching:
 *    a) player_hurt:
 *       - Only reward when the victim team is Infected (TEAM_INFECTED)
 *       - Whether to enable Special Infected / Tank rewards is controlled by config
 *    b) infected_hurt:
 *       - Use the entity classname to distinguish target types
 *       - Common infected (infected) and Witch (witch / witch_bride)
 *         are independently controlled by config switches
 *
 * 7) Reward execution and re-entry restriction:
 *    - Each valid headshot may grant the reward only once
 *    - Reward contents may include:
 *      a) Clip ammo refund (not exceeding maximum clip cap)
 *      b) Real-health heal (not exceeding the configured maximum real health)
 *    - After rewarding, mark the shot as "rewarded" immediately to block repeats
 *
 * 8) Edge cases and safety requirements:
 *    - If at any stage the client/entity/weapon is invalid:
 *      -> abort the current validation immediately
 *    - Do not apply ammo rewards to weapons without a clip or invalid weapon entities
 *    - On map start or client join, all shot/reward state must be reset
 *
 * Dependencies:
 * - SourceMod
 * - SDKTools
 */

#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

// =======================
// Configuration (you mainly edit here)
// =======================

// Master plugin toggle: 1 = on, 0 = off
#define HS_ENABLE_PLUGIN        1

// Shot window (seconds): maximum allowed delay from weapon_fire to hurt event
#define HS_SHOT_WINDOW          0.25

// Reward Survivors only (team 2)
#define HS_ONLY_SURVIVORS       1

// Enable headshot rewards for common infected
#define HS_ENABLE_COMMON        1

// Enable headshot rewards for Special Infected / Tank (player_hurt + victim team 3)
#define HS_ENABLE_SPECIAL       1
#define HS_ENABLE_TANK          1   // Shares team 3 with specials; this is a semantic toggle

// Enable headshot rewards for Witch
#define HS_ENABLE_WITCH         1

// Reward: refund ammo
#define HS_REWARD_AMMO          1

// Reward: heal (real health)
#define HS_REWARD_HEALTH        1

// Health gained per headshot
#define HS_HEAL_AMOUNT          1

// Maximum real health cap
#define HS_MAX_HEALTH           99

// Maximum clip cap
#define HS_MAX_CLIP             255

// Debug output
#define HS_DEBUG                0

// Hitgroup: head
#define HITGROUP_HEAD           1

// Team constants
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

// =======================
// Variables
// =======================

float g_LastShotTime[MAXPLAYERS + 1];
int   g_LastShotWep [MAXPLAYERS + 1];
bool  g_ShotRewarded[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "L4D2 Headshot Reward",
    author      = "me",
    description = "Headshot reward: ammo / heal",
    version     = "1.1",
    url         = ""
};

public void OnPluginStart()
{
    HookEvent("weapon_fire",   E_WeaponFire,  EventHookMode_Post);
    HookEvent("player_hurt",   E_AnyHurt,     EventHookMode_Post);
    HookEvent("infected_hurt", E_AnyHurt,     EventHookMode_Post);
}

public void OnClientPutInServer(int client)
{
    g_LastShotTime[client] = 0.0;
    g_LastShotWep[client]  = -1;
    g_ShotRewarded[client] = false;
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_LastShotTime[i] = 0.0;
        g_LastShotWep[i]  = -1;
        g_ShotRewarded[i] = false;
    }
}

// =======================
// Utility helpers
// =======================

int GetClientRealHealthSafe(int client)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return 0;
    return GetEntProp(client, Prop_Send, "m_iHealth");
}

void SetClientRealHealthSafe(int client, int value)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    if (value < 0) value = 0;
    SetEntProp(client, Prop_Send, "m_iHealth", value);
}

void RewardHealth(int attacker)
{
#if HS_REWARD_HEALTH == 0
    return;
#endif

    int hp = GetClientRealHealthSafe(attacker);
    if (hp >= HS_MAX_HEALTH) return;

    hp += HS_HEAL_AMOUNT;
    if (hp > HS_MAX_HEALTH) hp = HS_MAX_HEALTH;

    SetClientRealHealthSafe(attacker, hp);

#if HS_DEBUG == 1
    PrintToChat(attacker, "[HSReward] HP +%d (Now: %d)", HS_HEAL_AMOUNT, hp);
#endif
}

void RewardAmmo(int attacker, int weapon)
{
#if HS_REWARD_AMMO == 0
    return;
#endif

    if (weapon <= MaxClients || !IsValidEdict(weapon)) return;

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip < 0) return; // No clip / clipless weapon

    int newClip = clip + 1;
    if (newClip > HS_MAX_CLIP) newClip = HS_MAX_CLIP;

    SetEntProp(weapon, Prop_Send, "m_iClip1", newClip);

#if HS_DEBUG == 1
    PrintToChat(attacker, "[HSReward] Ammo +1 (Clip: %d -> %d)", clip, newClip);
#endif
}

void DoReward(int attacker, int weapon)
{
    if (g_ShotRewarded[attacker]) return;

    RewardAmmo(attacker, weapon);
    RewardHealth(attacker);

    g_ShotRewarded[attacker] = true;
}

// =======================
// weapon_fire: record shot
// =======================

public Action E_WeaponFire(Event e, const char[] name, bool dontBroadcast)
{
#if HS_ENABLE_PLUGIN == 0
    return Plugin_Continue;
#endif

    int client = GetClientOfUserId(e.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Continue;

#if HS_ONLY_SURVIVORS == 1
    if (GetClientTeam(client) != TEAM_SURVIVOR)
        return Plugin_Continue;
#endif

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (wep <= MaxClients || !IsValidEdict(wep))
        return Plugin_Continue;

    g_LastShotTime[client] = GetGameTime();
    g_LastShotWep[client]  = wep;
    g_ShotRewarded[client] = false;

    return Plugin_Continue;
}

// =======================
// player_hurt + infected_hurt: validate headshot and reward
// =======================

public Action E_AnyHurt(Event event, const char[] name, bool dontBroadcast)
{
#if HS_ENABLE_PLUGIN == 0
    return Plugin_Continue;
#endif

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker <= 0 || !IsClientInGame(attacker))
        return Plugin_Continue;

#if HS_ONLY_SURVIVORS == 1
    if (GetClientTeam(attacker) != TEAM_SURVIVOR)
        return Plugin_Continue;
#endif

    // Must be within the shot window
    float now = GetGameTime();
    if (now - g_LastShotTime[attacker] > HS_SHOT_WINDOW)
        return Plugin_Continue;

    if (g_ShotRewarded[attacker])
        return Plugin_Continue;

    int wep = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
    if (wep <= MaxClients || !IsValidEdict(wep))
        return Plugin_Continue;

    if (wep != g_LastShotWep[attacker])
        return Plugin_Continue;

    // ---- Key rule: use hitgroup directly as the headshot source of truth ----
    int hitgroup = event.GetInt("hitgroup");
    if (hitgroup != HITGROUP_HEAD)
        return Plugin_Continue;

    // ---------------------
    // player_hurt -> Special Infected / Tank
    // ---------------------
    if (StrEqual(name, "player_hurt", false))
    {
        int victim = GetClientOfUserId(event.GetInt("userid"));
        if (victim <= 0 || !IsClientInGame(victim))
            return Plugin_Continue;

        int vteam = GetClientTeam(victim);

#if (HS_ENABLE_SPECIAL == 0) && (HS_ENABLE_TANK == 0)
        return Plugin_Continue;
#else
        if (vteam == TEAM_INFECTED)
        {
            DoReward(attacker, wep);
            return Plugin_Continue;
        }
#endif
    }

    // ---------------------
    // infected_hurt -> Common infected / Witch
    // ---------------------
    if (StrEqual(name, "infected_hurt", false))
    {
        int ent = event.GetInt("entityid");
        if (ent <= 0 || !IsValidEntity(ent))
            return Plugin_Continue;

        char classname[64];
        GetEntityClassname(ent, classname, sizeof(classname));

#if HS_ENABLE_COMMON
        if (StrEqual(classname, "infected", false))
        {
            DoReward(attacker, wep);
            return Plugin_Continue;
        }
#endif

#if HS_ENABLE_WITCH
        if (StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false))
        {
            DoReward(attacker, wep);
            return Plugin_Continue;
        }
#endif
    }

    return Plugin_Continue;
}
