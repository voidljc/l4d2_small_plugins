/*
 * L4D2 Melee Boost (Z key) - Adrenaline-Priority Version (0.1s polling)
 * bind z "+melee_boost"
 *
 * Rules:
 * 1) When the player presses Z:
 *    - First check whether Adrenaline is active
 *      a) If yes: ignore cooldown, immediately enter "Adrenaline Mode" with continuous boosting
 *      b) If no: check cooldown; only trigger a 3-second boost if not on cooldown
 *
 * 2) Adrenaline Mode:
 *    - Poll every 0.1 seconds to see whether Adrenaline is still active
 *    - Once Adrenaline is detected as ended: stop boosting immediately and start a 10-second cooldown
 *
 * 3) Non-Adrenaline Mode:
 *    - Boost duration is fixed at 3 seconds
 *    - Cooldown starts at the moment of triggering (10 seconds)
 *
 * 4) Weapon switch cancels immediately:
 *    - In any mode, if the current weapon is not melee: stop the current boost immediately
 *
 * 5) Strict timer handle cleanup:
 *    - All Stop branches must set g_hBoostTimer[client] to null and clear state
 *
 * Dependencies: SourceMod 1.12+, SDKHooks (included with SourceMod)
 */

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name        = "L4D2 Melee Boost (Adren Priority)",
    author      = "me",
    description = "Z key melee acceleration: adrenaline ignores the cooldown, non-adrenaline is cooled down; gun cutting is canceled; 0.1 second detection",
    version     = "1.2.0",
    url         = ""
};

/* ========================= CVARS ========================= */
ConVar g_cvEnable;
ConVar g_cvTeam;
ConVar g_cvScale;
ConVar g_cvDuration;   // Non-adrenaline duration (default: 3)
ConVar g_cvCooldown;   // Cooldown (default: 10)
ConVar g_cvTick;       // Poll interval (default: 0.1)

/* ========================= STATE ========================= */
float  g_fBoostUntil[MAXPLAYERS + 1];  // Used for non-adrenaline mode
float  g_fNextReady[MAXPLAYERS + 1];   // Cooldown end time
bool   g_bAdrenMode[MAXPLAYERS + 1];   // Whether in adrenaline mode
Handle g_hBoostTimer[MAXPLAYERS + 1];  // 0.1s repeating timer

/* ========================= COMMON CHECKS ========================= */

bool IsEligible(int client)
{
    if (!g_cvEnable.BoolValue) return false;
    if (client <= 0) return false;
    if (!IsClientInGame(client) || !IsPlayerAlive(client)) return false;
    if (GetClientTeam(client) != g_cvTeam.IntValue) return false;
    return true;
}

bool IsMeleeWeapon(int wep)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;

    char cls[64];
    if (!GetEntityClassname(wep, cls, sizeof(cls))) return false;

    return StrEqual(cls, "weapon_melee", false);
}

/* Adrenaline state */
bool IsAdrenalineActive(int client)
{
    static int offs = -2; // -2 = uninitialized
    if (offs == -2)
        offs = GetEntSendPropOffs(client, "m_bAdrenalineActive");

    if (offs == -1) return false;
    return view_as<bool>(GetEntData(client, offs, 1));
}

/* Only shortens future timestamps */
stock void ClampFutureTimeNonExtend(int ent, const char[] prop, float now, float scale)
{
    float t = GetEntPropFloat(ent, Prop_Send, prop);
    if (t <= now) return;

    float rem = t - now;
    float target = rem * scale;

    if (target >= rem - 0.001) return;
    SetEntPropFloat(ent, Prop_Send, prop, now + target);
}

/* Unified stop: strict cleanup of handle and state */
void StopBoost(int client)
{
    if (g_hBoostTimer[client] != null)
    {
        delete g_hBoostTimer[client];
        g_hBoostTimer[client] = null;
    }
    g_bAdrenMode[client] = false;
    g_fBoostUntil[client] = 0.0;
}

/* ========================= TIMER: 0.1s POLLING ========================= */

public Action Timer_MeleeBoost(Handle timer, any client)
{
    if (!IsEligible(client))
    {
        g_hBoostTimer[client] = null;
        g_bAdrenMode[client] = false;
        return Plugin_Stop;
    }

    float now = GetGameTime();

    /* Cancel immediately on weapon switch (applies to all modes) */
    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsMeleeWeapon(wep))
    {
        g_hBoostTimer[client] = null;
        g_bAdrenMode[client] = false;
        return Plugin_Stop;
    }

    /* Adrenaline mode: once adrenaline is gone -> start cooldown and stop immediately */
    if (g_bAdrenMode[client])
    {
        if (!IsAdrenalineActive(client))
        {
            g_fNextReady[client] = now + g_cvCooldown.FloatValue; // ★ cooldown starts only when adrenaline ends
            g_hBoostTimer[client] = null;
            g_bAdrenMode[client] = false;
            return Plugin_Stop;
        }
    }
    else
    {
        /* Non-adrenaline mode: stop when time is up */
        if (now >= g_fBoostUntil[client])
        {
            g_hBoostTimer[client] = null;
            return Plugin_Stop;
        }
    }

    /* Apply melee boost clamp */
    float scale = g_cvScale.FloatValue;

    ClampFutureTimeNonExtend(client, "m_flNextAttack", now, scale);
    ClampFutureTimeNonExtend(wep,    "m_flNextPrimaryAttack",   now, scale);
    ClampFutureTimeNonExtend(wep,    "m_flNextSecondaryAttack", now, scale);

    return Plugin_Continue;
}

/* ========================= TRIGGER COMMAND (Z) ========================= */

public Action Cmd_MeleeBoost(int client, int args)
{
    // In listen servers, client=0 maps to the real player
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
        if (client <= 0) return Plugin_Handled;
    }

    if (!IsEligible(client))
        return Plugin_Handled;

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsMeleeWeapon(wep))
    {
        PrintToChat(client, "[Melee boost] Please switch to melee weapon first");
        return Plugin_Handled;
    }

    float now = GetGameTime();

    /* Trigger order: check adrenaline first */
    if (IsAdrenalineActive(client))
    {
        /* Adrenaline: ignore cooldown */
        g_bAdrenMode[client] = true;

        /* If a timer is already running, do not create another one */
        if (g_hBoostTimer[client] == null)
        {
            float tick = g_cvTick.FloatValue;
            if (tick < 0.01) tick = 0.01;

            g_hBoostTimer[client] = CreateTimer(tick, Timer_MeleeBoost, client, TIMER_REPEAT);
        }

        PrintToChat(client, "[Melee boost] Adrenaline activation: lasts until the effect ends (ignores cooldown)");
        return Plugin_Handled;
    }

    /* Non-adrenaline: check cooldown */
    if (now < g_fNextReady[client])
    {
        PrintToChat(client, "[Melee boost] Cooling down: %.1f seconds", g_fNextReady[client] - now);
        return Plugin_Handled;
    }

    /* Non-adrenaline: trigger 3 seconds, and start cooldown at trigger time */
    g_bAdrenMode[client] = false;
    g_fBoostUntil[client] = now + g_cvDuration.FloatValue;
    g_fNextReady[client]  = now + g_cvCooldown.FloatValue;

    if (g_hBoostTimer[client] == null)
    {
        float tick = g_cvTick.FloatValue;
        if (tick < 0.01) tick = 0.01;

        g_hBoostTimer[client] = CreateTimer(tick, Timer_MeleeBoost, client, TIMER_REPEAT);
    }

    PrintToChat(client, "[Melee boost] Triggered: Lasts %.1f seconds, cooldown %.1f seconds", g_cvDuration.FloatValue, g_cvCooldown.FloatValue);
    return Plugin_Handled;
}

/* ========================= LIFECYCLE ========================= */

public void OnPluginStart()
{
    g_cvEnable   = CreateConVar("sm_meleeboost_enable", "1", "Enable plugin (1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTeam     = CreateConVar("sm_meleeboost_team",   "2", "Affected team (2=Survivors)", FCVAR_NOTIFY, true, 0.0, true, 3.0);

    g_cvScale    = CreateConVar("sm_meleeboost_scale",  "0.25", "Cooldown scale (smaller = faster)", FCVAR_NOTIFY, true, 0.01, true, 1.0);
    g_cvDuration = CreateConVar("sm_meleeboost_duration", "3.0", "Non-adrenaline duration (seconds)", FCVAR_NOTIFY, true, 0.1, true, 60.0);
    g_cvCooldown = CreateConVar("sm_meleeboost_cooldown", "10.0", "Cooldown time (seconds)", FCVAR_NOTIFY, true, 0.1, true, 300.0);
    g_cvTick     = CreateConVar("sm_meleeboost_tick", "0.1", "Poll interval (seconds)", FCVAR_NOTIFY, true, 0.01, true, 1.0);

    AutoExecConfig(true, "plugin_meleeboost_adren_priority");

    RegConsoleCmd("sm_meleeboost", Cmd_MeleeBoost);
    RegConsoleCmd("+melee_boost",  Cmd_MeleeBoost);
}

public void OnClientPutInServer(int client)
{
    StopBoost(client);
    g_fNextReady[client] = 0.0;
}

public void OnClientDisconnect(int client)
{
    StopBoost(client);
    g_fNextReady[client] = 0.0;
}
