/*
 * ========================= ConVar Parameter Reference =========================
 *
 * l4d2_deflectrock_enable (0/1)
 *  - Master plugin toggle.
 *  - 0: Disable all functionality.
 *  - 1: Enable the rock deflect/block logic.
 *
 *
 * l4d2_deflectrock_air (0/1)
 *  - Whether to allow "mid-air cut / early deflect".
 *  - 0: No active scanning; you can only block when the rock is very close or on contact (closer to vanilla).
 *  - 1: Enable active scanning (timer). During the swing window, the rock can be blocked before it touches the player.
 *
 *  Notes:
 *   Enabling this option is required to achieve "mid-air cut".
 *   Scan frequency is 0.1 seconds and it runs only during the melee swing timing window.
 *
 *
 * l4d2_deflectrock_window (seconds)
 *  - The effective "block timing window" after a melee swing.
 *  - Rock block checks are allowed only within this window.
 *
 *  Common values:
 *   0.12 - 0.18: Strict timing, closer to an action-game parry.
 *   0.18 - 0.25: Balanced feel and forgiveness (recommended).
 *   0.30 - 1.00: Very lenient; swinging is effectively a short-duration shield.
 *
 *
 * l4d2_deflectrock_fov (degrees, full angle)
 *  - Facing direction constraint: the rock must be inside the forward sector in front of the player.
 *
 *  Examples:
 *   45: Front-only, strict.
 *   60: Natural feel, commonly used.
 *   80: Allows more side blocks, more lenient.
 *
 *
 * l4d2_deflectrock_reach (units)
 *  - Length of the forward block volume.
 *  - Determines how far in front of the player a rock can be blocked.
 *
 *  Common values:
 *   70 - 90 : Must be close to block.
 *   100-130 : Natural, with reasonable forgiveness.
 *   150+   : Noticeable "block at a distance", more shield-like.
 *
 *
 * l4d2_deflectrock_thickness (units)
 *  - Side-to-side thickness of the block volume (lateral tolerance).
 *
 *  Common values:
 *   25 - 35: Requires precise alignment.
 *   40 - 60: Matches typical melee coverage.
 *   80+    : Very wide; may cause accidental blocks.
 *
 *
 * l4d2_deflectrock_speed (units/sec)
 *  - Base deflect speed applied to the rock on a successful block.
 *
 *  Common values:
 *   450 - 650 : Heavier feel, closer to a realistic shove.
 *   700 - 900 : Snappy, strong action feel.
 *   1000+     : Very exaggerated and may affect balance.
 *
 *
 * l4d2_deflectrock_upboost (float)
 *  - Additional Z-axis component added to the deflect direction.
 *  - Helps prevent the rock from immediately hitting the ground or re-colliding at close range.
 *
 *  Common values:
 *   0.15 - 0.40: Natural lift.
 *   0.60+      : Strong upward pop, more exaggerated.
 *
 *
 * l4d2_deflectrock_carry (0.0 - 1.0)
 *  - Fraction of the rock's original velocity preserved on deflect (inertia).
 *
 *  Meaning:
 *   0.0       : Fully determined by player direction (hard block).
 *   0.1 - 0.3 : Preserve a small amount of inertia (recommended).
 *   0.6+      : Mostly keeps the original trajectory; only slightly redirected.
 *
 *
 * l4d2_deflectrock_nudge (units)
 *  - Small forward teleport applied to the rock on a successful block.
 *  - Prevents immediate re-touch causing jitter or repeated triggers.
 *
 *  Common values:
 *   8  - 20: Safe and not visually obvious.
 *   30+    : More noticeable "snap" in position.
 *
 *
 * ========================= Tuning Suggestions =========================
 *
 * - To enable "mid-air cut", you must set l4d2_deflectrock_air = 1.
 * - window / fov / reach / thickness determine "whether it blocks and where it blocks".
 * - speed / upboost / carry / nudge only affect the physics/visual result after a successful block.
 * - Tune the detection parameters first, then tune the deflect visuals.
 *
 */


/**
 * L4D2 - Melee Deflect Tank Rock (SM 1.12)
 * - Deflects tank_rock when a survivor swings a melee within a short timing window,
 *   inside a forward "hit box" (reach + thickness) and within facing FOV.
 * - Also blocks damage in OnTakeDamage as a safety net (prevents knockdown/damage).
 *
 * Compile with: SourceMod 1.12, sdkhooks, sdktools
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <left4dhooks>

#define TEAM_SURVIVOR 2

ConVar g_hEnable;
ConVar g_hWindow;          // seconds
ConVar g_hFovDeg;          // degrees (full cone)
ConVar g_hReach;           // units, forward length
ConVar g_hThickness;       // units, perpendicular radius
ConVar g_hDeflectSpeed;    // units/sec
ConVar g_hUpBoost;         // additive Z direction (0..1-ish)
ConVar g_hCarry;           // 0..1, how much old velocity to keep
ConVar g_hNudge;           // units, teleport a bit forward to avoid re-touch loop
ConVar g_hAirDeflect;    // 0 = disable air scan, 1 = enable air scan

float g_fLastMeleeSwing[MAXPLAYERS + 1];
Handle g_hScanTimer[MAXPLAYERS + 1];
bool g_bNeedCancelStagger[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "L4D2 Melee Deflect Tank Rock",
    author      = "me",
    description = "Deflects Tank rocks with melee swing (Touch + Damage interception).",
    version     = "1.0.0",
    url         = ""
};

public void OnPluginStart()
{
    g_hEnable       = CreateConVar("l4d2_deflectrock_enable", "1", "Enable rock deflect plugin (0/1).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hWindow       = CreateConVar("l4d2_deflectrock_window", "0.18", "Block window after melee swing (seconds).", FCVAR_NOTIFY, true, 0.01, true, 1.0);
    g_hFovDeg       = CreateConVar("l4d2_deflectrock_fov", "60", "Facing cone (degrees, full angle).", FCVAR_NOTIFY, true, 1.0, true, 180.0);
    g_hReach        = CreateConVar("l4d2_deflectrock_reach", "105", "Forward reach (units).", FCVAR_NOTIFY, true, 1.0, true, 500.0);
    g_hThickness    = CreateConVar("l4d2_deflectrock_thickness", "45", "Perpendicular thickness radius (units).", FCVAR_NOTIFY, true, 1.0, true, 200.0);
    g_hDeflectSpeed = CreateConVar("l4d2_deflectrock_speed", "750", "Deflect speed (units/sec).", FCVAR_NOTIFY, true, 0.0, true, 3000.0);
    g_hUpBoost      = CreateConVar("l4d2_deflectrock_upboost", "0.30", "Additive upward component to deflect dir (0..1).", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_hCarry        = CreateConVar("l4d2_deflectrock_carry", "0.20", "Carry factor of old rock velocity (0..1).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hNudge        = CreateConVar("l4d2_deflectrock_nudge", "12", "Teleport rock forward by this many units on deflect to avoid instant re-touch.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    
    g_hAirDeflect   = CreateConVar(
        "l4d2_deflectrock_air",
        "1",
        "Allow deflecting tank rock in air by active scanning (0=off, 1=on).",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );


    AutoExecConfig(true, "l4d2_deflect_tankrock");

    // Hook damage for clients
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }

}

public void OnClientPutInServer(int client)
{
    g_fLastMeleeSwing[client] = 0.0;

    if (g_hScanTimer[client] != null)
    {
        CloseHandle(g_hScanTimer[client]);
        g_hScanTimer[client] = null;
    }

    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage_Client);
}

public void OnClientDisconnect(int client)
{
    if (g_hScanTimer[client] != null)
    {
        KillTimer(g_hScanTimer[client]);
        g_hScanTimer[client] = null;
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!GetConVarBool(g_hEnable))
        return;

    // Tank rock entity
    if (StrEqual(classname, "tank_rock", false))
    {
        SDKHook(entity, SDKHook_StartTouch, OnRockStartTouch);
    }
}

void StartRockScanTimer(int client)
{
    // If a scan timer is already running, do not create another one; updating LastSwingTime is enough to extend validity
    if (g_hScanTimer[client] != null)
        return;

    // Once per 0.1s to satisfy your CPU budget constraint
    g_hScanTimer[client] = CreateTimer(0.1, Timer_ScanRocks, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void Frame_CancelStagger(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    L4D_CancelStagger(client);

    // Optional: clear impulse only for this frame to further remove the "tiny hitch"
    float v[3] = {0.0, 0.0, 0.0};
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, v);
}

public Action L4D_OnStagger(int target, int source)
{
    if (!GetConVarBool(g_hEnable))
        return Plugin_Continue;

    if (target < 1 || target > MaxClients || !IsClientInGame(target) || !IsPlayerAlive(target))
        return Plugin_Continue;

    if (GetClientTeam(target) != TEAM_SURVIVOR)
        return Plugin_Continue;

    if (source <= MaxClients || !IsValidEntity(source))
        return Plugin_Continue;

    char cls[64];
    GetEntityClassname(source, cls, sizeof cls);
    if (!StrEqual(cls, "tank_rock", false))
        return Plugin_Continue;

    if (CanBlockRockNow(target, source))
        return Plugin_Handled;   // Key: cancel the stagger at the source

    return Plugin_Continue;
}

public Action Timer_ScanRocks(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);

    if (!GetConVarBool(g_hAirDeflect))
        return StopClientScanTimer(client, timer);

    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return StopClientScanTimer(client, timer);

    if (!GetConVarBool(g_hEnable) || GetClientTeam(client) != TEAM_SURVIVOR)
        return StopClientScanTimer(client, timer);

    float now = GetGameTime();
    float window = GetConVarFloat(g_hWindow);

    // Stop once out of the timing window (your window=1 would continue for 1 second here)
    if (now - g_fLastMeleeSwing[client] > window)
        return StopClientScanTimer(client, timer);

    // Iterate all tank_rock entities (usually very few)
    int rock = -1;
    while ((rock = FindEntityByClassname(rock, "tank_rock")) != -1)
    {
        if (!IsValidEntity(rock))
            continue;

        // Reuse the same predicate: time window + FOV + reach + thickness
        if (CanBlockRockNow(client, rock))
        {
            DeflectRock(client, rock);

            // Optional policy:
            // 1) Keep scanning: allow blocking multiple rocks in one swing window (usually unnecessary)
            // 2) Stop scanning immediately: more "realistic", one swing blocks once (usually better)
            //
            // This implementation chooses "stop scanning" to avoid repeatedly re-applying velocity to the same rock every 0.1s.
            return StopClientScanTimer(client, timer);
        }
    }

    return Plugin_Continue;
}

Action StopClientScanTimer(int client, Handle timer)
{
    if (client >= 1 && client <= MaxClients)
    {
        if (g_hScanTimer[client] == timer)
            g_hScanTimer[client] = null;
    }

    // Key: do NOT CloseHandle(timer) inside the timer callback
    return Plugin_Stop;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (!GetConVarBool(g_hEnable))
        return Plugin_Continue;

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;

    if (!IsPlayerAlive(client))
        return Plugin_Continue;

    if (GetClientTeam(client) != TEAM_SURVIVOR)
        return Plugin_Continue;

    if (buttons & IN_ATTACK)
    {
        int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        if (wep > MaxClients && IsValidEntity(wep))
        {
            char wcls[64];
            GetEntityClassname(wep, wcls, sizeof(wcls));
            if (StrEqual(wcls, "weapon_melee", false))
            {
                g_fLastMeleeSwing[client] = GetGameTime();

                if (GetConVarBool(g_hAirDeflect))
                {
                    StartRockScanTimer(client);
                }

            }
        }
    }

    return Plugin_Continue;
}

/**
 * Touch handler: rock is about to touch something.
 * We use this as the main "deflect" moment to nudge velocity and create the visible effect.
 */
public Action OnRockStartTouch(int rock, int other)
{
    if (!GetConVarBool(g_hEnable))
        return Plugin_Continue;

    if (!IsValidEntity(rock))
        return Plugin_Continue;

    // Only care if touching a survivor client
    if (other < 1 || other > MaxClients)
        return Plugin_Continue;

    int client = other;

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    if (GetClientTeam(client) != TEAM_SURVIVOR)
        return Plugin_Continue;

    if (!CanBlockRockNow(client, rock))
        return Plugin_Continue;

    DeflectRock(client, rock);

    // We do not block engine touch; we just change velocity & position.
    // Damage interception happens in OnTakeDamage as a safety net.
    return Plugin_Continue;
}

/**
 * Damage hook: prevents damage/knockdown before engine applies it.
 */
public Action OnTakeDamage_Client(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!GetConVarBool(g_hEnable))
        return Plugin_Continue;

    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
        return Plugin_Continue;

    if (!IsPlayerAlive(victim))
        return Plugin_Continue;

    if (GetClientTeam(victim) != TEAM_SURVIVOR)
        return Plugin_Continue;

    if (inflictor <= MaxClients || !IsValidEntity(inflictor))
        return Plugin_Continue;

    char cls[64];
    GetEntityClassname(inflictor, cls, sizeof(cls));
    if (!StrEqual(cls, "tank_rock", false))
        return Plugin_Continue;

    // If within block conditions, nullify damage (prevents knockdown/damage).
    if (CanBlockRockNow(victim, inflictor))
    {
        damage = 0.0;
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

/**
 * Core block predicate:
 * - within time window after melee swing
 * - facing within cone (FOV)
 * - rock inside forward "hit box": 0<=proj<=reach and perpDist<=thickness
 */
bool CanBlockRockNow(int client, int rock)
{
    float now = GetGameTime();
    float window = GetConVarFloat(g_hWindow);

    if (now - g_fLastMeleeSwing[client] > window)
        return false;

    float reach = GetConVarFloat(g_hReach);
    float thick = GetConVarFloat(g_hThickness);

    float pEye[3], rPos[3];
    GetClientEyePosition(client, pEye);
    GetEntPropVector(rock, Prop_Data, "m_vecAbsOrigin", rPos);

    float toRock[3];
    MakeVectorFromPoints(pEye, rPos, toRock);

    // Forward vector from view angles
    float ang[3], fwd[3];
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);

    // Facing FOV check using dot(dir, fwd) >= cos(fov/2)
    float dir[3];
    dir = toRock;
    if (!NormalizeVectorSafe(dir))
        return false;

    float fov = GetConVarFloat(g_hFovDeg);
    float cosThresh = Cosine(DegToRad(fov * 0.5));
    float dFacing = GetVectorDotProduct(fwd, dir);
    if (dFacing < cosThresh)
        return false;

    // Forward hit box:
    // proj = dot(toRock, fwd)
    float proj = GetVectorDotProduct(toRock, fwd);
    if (proj < 0.0 || proj > reach)
        return false;

    // perp = toRock - fwd * proj
    float perp[3];
    perp[0] = toRock[0] - fwd[0] * proj;
    perp[1] = toRock[1] - fwd[1] * proj;
    perp[2] = toRock[2] - fwd[2] * proj;

    float perpDist = GetVectorLength(perp);
    if (perpDist > thick)
        return false;

    return true;
}

void DeflectRock(int client, int rock)
{
    float ang[3], fwd[3];
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);

    float upBoost = GetConVarFloat(g_hUpBoost);
    fwd[2] += upBoost;
    NormalizeVector(fwd, fwd);

    float speed = GetConVarFloat(g_hDeflectSpeed);
    float carry = GetConVarFloat(g_hCarry);

    float oldVel[3];
    GetEntPropVector(rock, Prop_Data, "m_vecVelocity", oldVel);

    float newVel[3];
    newVel[0] = fwd[0] * speed + oldVel[0] * carry;
    newVel[1] = fwd[1] * speed + oldVel[1] * carry;
    newVel[2] = fwd[2] * speed + oldVel[2] * carry;

    // Nudge rock position slightly forward to reduce immediate re-touch loops
    float nudge = GetConVarFloat(g_hNudge);

    float rPos[3];
    GetEntPropVector(rock, Prop_Data, "m_vecAbsOrigin", rPos);

    float newPos[3];
    newPos[0] = rPos[0] + fwd[0] * nudge;
    newPos[1] = rPos[1] + fwd[1] * nudge;
    newPos[2] = rPos[2] + fwd[2] * nudge;

    TeleportEntity(rock, newPos, NULL_VECTOR, newVel);

    g_bNeedCancelStagger[client] = true;
    RequestFrame(Frame_CancelStagger, GetClientUserId(client));

    // Optional: add a small effect/sound here if you want (kept minimal to avoid dependencies).
}

/** Safe normalize: returns false if vector too small */
bool NormalizeVectorSafe(float vec[3])
{
    float len = GetVectorLength(vec);
    if (len < 0.0001)
        return false;

    vec[0] /= len;
    vec[1] /= len;
    vec[2] /= len;
    return true;
}
