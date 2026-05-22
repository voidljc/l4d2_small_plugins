/*
Speeds up attack-related actions while the player is ducking by reducing remaining cooldown timers
(attacks, shoves, and melee), with a minimum melee cooldown safeguard.
*/

/*
Dependencies:
SourceMod 1.12+
SDKHooks (included with SourceMod)SDKHooks（包含在SourceMod中）
*/

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo =   公共插件myinfo =
{
    name        = "FastRate (duck Booster)",name = "FastRate（鸭子助推器）"；
    author      = "me",
    description = "Speed up actions while crouching by clamping future timers; melee safe-guard",description =“通过夹紧未来计时器来加速蹲伏时的动作；近战安全”,
    version     = "1.3_0",版本= "1.3_0"，
    url         = ""Url = “”
};

/* ========================= CVARS ========================= */
ConVar g_cvEnable;        // Master enable switch
ConVar g_cvScale;         // Speed scale: remaining time multiplied by scale (0~1)
ConVar g_cvTeam;          // Affected team (2 = Survivors)
ConVar g_cvSlotMode;      // 0 = slot0 weapon, 1 = active weapon
ConVar g_cvNeedDuck;      // Require IN_DUCK input
ConVar g_cvUseFLDuck;     // Use FL_DUCKING state for detection

ConVar g_cvAffectFire;    // Affect firing / throwing
ConVar g_cvAffectReload;  // Affect reload
ConVar g_cvAffectShove;   // Affect shove

ConVar g_cvMeleeMinRem;   // Minimum remaining melee cooldown (seconds)
ConVar g_cvWhitelist;     // Weapon whitelist (empty = all)

ArrayList g_Whitelist;

/* New: toggle "boost mode" using Shift */
bool g_bBoost[MAXPLAYERS + 1];        // Whether boost is currently enabled for the player
int  g_iPrevButtons[MAXPLAYERS + 1];  // Previous frame button state, used to detect edge-triggered Shift presses

/* Accelerate after crouching for 3 seconds */
float g_fDuckHoldStart[MAXPLAYERS + 1]; // Timestamp when the player started holding crouch (0 = not timing)
bool  g_bDuckHoldReady[MAXPLAYERS + 1]; // Whether the player has crouched continuously for 3 seconds


/* ========================= UTILITIES ========================= */

// Only shortens future timestamps: target = max(rem * scale, minRemain)
// If target >= rem (would extend or do nothing), do not write back
stock void ClampFutureTimeNonExtend(int ent, const char[] prop, float now, float scale, float minRemain = 0.0)void ClampFutureTimeNonExtend（int int, const char[] prop, float now, float scale, float minRemain = 0.0）
{
    float t = GetEntPropFloat(ent, Prop_Send, prop);浮动t = GetEntPropFloat(ent, Prop_Send, prop)；
    if (t <= now) return;If (t <= now) return；

    float rem    = t - now;Float rem = t - now；
    float target = rem * scale;浮动目标= rem *缩放；
    if (target < minRemain) target = minRemain;if (target < minRemain) target = minRemain；

    // Avoid extending or jittering (only write back if clearly shorter)
    if (target >= rem - 0.001) return;如果（目标>= rem - 0.001）返回；

    SetEntPropFloat(ent, Prop_Send, prop, now + target);
}

stock bool SplitStringEx(const char[] src, const char[] delim, char[] outToken, int outMax, int &start)
{
    int len = strlen(src);
    if (start >= len) return false;
    int dlen = strlen(delim), i = start, j = 0;
    while (i < len)
    {
        if (dlen && strncmp(src[i], delim, dlen) == 0) break;
        if (j < outMax - 1) outToken[j++] = src[i];
        i++;
    }
    outToken[j] = '\0';
    start = (i < len) ? i + dlen : len;
    return true;
}

void RebuildWhitelist()
{
    if (g_Whitelist == null) g_Whitelist = new ArrayList(ByteCountToCells(64));
    g_Whitelist.Clear();

    char buf[512];
    g_cvWhitelist.GetString(buf, sizeof(buf));
    if (!buf[0]) return;

    char token[64]; int pos = 0;
    while (SplitStringEx(buf, ",", token, sizeof(token), pos))
    {
        TrimString(token);
        if (token[0]) g_Whitelist.PushString(token);
    }
}

public void OnWhitelistChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RebuildWhitelist();
}

bool IsWeaponWhitelisted(int wep)
{
    if (g_Whitelist == null || g_Whitelist.Length == 0) return true;
    char cls[64];
    if (!GetEntityClassname(wep, cls, sizeof(cls))) return false;
    for (int i = 0; i < g_Whitelist.Length; i++)
    {
        char w[64]; g_Whitelist.GetString(i, w, sizeof(w));
        if (StrEqual(cls, w, false)) return true;
    }
    return false;
}

stock bool GetWeaponClassName(int wep, char[] cls, int maxlen)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;
    return GetEntityClassname(wep, cls, maxlen);
}

/* Update the "crouched for 3 seconds" state every frame */
void UpdateDuckHold3s(int client)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        g_fDuckHoldStart[client] = 0.0;
        g_bDuckHoldReady[client] = false;
        return;
    }

    float now = GetGameTime();

    if (IsDuckHeld(client))
    {
        // First time entering crouch
        if (g_fDuckHoldStart[client] <= 0.0)
        {
            g_fDuckHoldStart[client] = now;
        }
        else if (!g_bDuckHoldReady[client] && (now - g_fDuckHoldStart[client] >= 3.0))
        {
            // Crouched continuously for 3 seconds
            g_bDuckHoldReady[client] = true;
        }
    }
    else
    {
        // Crouch interrupted -> reset immediately
        g_fDuckHoldStart[client] = 0.0;
        g_bDuckHoldReady[client] = false;
    }
}

public Action Timer_UpdateDuckHold3s(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        UpdateDuckHold3s(client);
    }

    return Plugin_Continue;
}

/* ========================= INITIALIZATION ========================= */

public void OnPluginStart()
{
    g_cvEnable     = CreateConVar("sm_crouchboost_enable", "1",   "Enable plugin (1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvScale      = CreateConVar("sm_crouchboost_scale",  "0.25","Remaining time scale while crouching (0~1)", FCVAR_NOTIFY, true, 0.05, true, 1.0);
    g_cvTeam       = CreateConVar("sm_crouchboost_team",   "2",   "Team to affect (2=Survivors)", FCVAR_NOTIFY, true, 0.0, true, 3.0);
    g_cvSlotMode   = CreateConVar("sm_crouchboost_slot",   "1",   "Weapon target: 0=slot0, 1=active", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvNeedDuck   = CreateConVar("sm_crouchboost_needduck","1",  "Require IN_DUCK pressed (ignored if FL_DUCKING mode)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvUseFLDuck  = CreateConVar("sm_crouchboost_flduck", "0",   "Use FL_DUCKING instead of IN_DUCK", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvAffectFire   = CreateConVar("sm_crouchboost_fire",   "1", "Affect fire/throw timers", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAffectReload = CreateConVar("sm_crouchboost_reload", "1", "Affect reload timers",    FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAffectShove  = CreateConVar("sm_crouchboost_shove",  "1", "Affect shove cooldown",   FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvMeleeMinRem  = CreateConVar("sm_crouchboost_melee_minrem", "0.22", "Melee minimum remaining cooldown (seconds)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWhitelist    = CreateConVar("sm_crouchboost_weapons","",    "Comma separated weapon class whitelist (empty=all)", FCVAR_NOTIFY);

    AutoExecConfig(true, "plugin_crouchboost");

    HookConVarChange(g_cvWhitelist, OnWhitelistChanged);
    RebuildWhitelist();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_PostThinkPost, PostThinkClamp);
            g_bBoost[i] = false;
            g_iPrevButtons[i] = 0;

            g_fDuckHoldStart[i] = 0.0;
            g_bDuckHoldReady[i] = false;
        }
    }
    CreateTimer(1.0, Timer_UpdateDuckHold3s, _, TIMER_REPEAT);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_PostThinkPost, PostThinkClamp);
    g_bBoost[client] = false;
    g_iPrevButtons[client] = 0;

    g_fDuckHoldStart[client] = 0.0;
    g_bDuckHoldReady[client] = false;
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_PostThinkPost, PostThinkClamp);
    g_bBoost[client] = false;
    g_iPrevButtons[client] = 0;

    g_fDuckHoldStart[client] = 0.0;
    g_bDuckHoldReady[client] = false;
}

/* ========================= CHECKS & HELPERS ========================= */

bool IsClientEligible(int client)
{
    if (!g_cvEnable.BoolValue) return false;
    if (!IsClientInGame(client) || !IsPlayerAlive(client)) return false;
    if (GetClientTeam(client) != g_cvTeam.IntValue) return false;
    return true;
}

/**
 * Returns true if the player is holding crouch (IN_DUCK)
 * or the player entity is currently crouching (FL_DUCKING).
 * Does not check movement, jumping, or reload input.
 */
bool IsDuckHeld(int client)
{
    int buttons = GetClientButtons(client);
    int flags   = GetEntityFlags(client);

    if (buttons & IN_DUCK) return true;
    if (flags   & FL_DUCKING) return true;

    return false;
}

/**
 * Legacy strict logic:
 * - Must be crouching (IN_DUCK or FL_DUCKING)
 * - No movement (forward/back/left/right)
 * - No jumping
 * - No manual reload (R key)
 */
bool IsPureDuck(int client)
{
    int buttons = GetClientButtons(client);
    int flags   = GetEntityFlags(client);

    if (g_cvUseFLDuck.BoolValue)
    {
        if ((flags & FL_DUCKING) == 0)
            return false;
    }
    else if (g_cvNeedDuck.BoolValue)
    {
        if ((buttons & IN_DUCK) == 0)
            return false;
    }

    // Disallow movement / jumping
    if ((buttons & (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_JUMP)) != 0)
        return false;

    // Disallow manual reload
    if (buttons & IN_RELOAD)
        return false;

    return true;
}


/* New: toggle g_bBoost using Shift (IN_SPEED) */
void UpdateShiftToggle(int client)
{
    int buttons = GetClientButtons(client);
    int changed = buttons ^ g_iPrevButtons[client]; // Which buttons changed state

    // If IN_SPEED state changed
    if (changed & IN_SPEED)
    {
        // And it was just pressed (0 -> 1), toggle boost state
        if (buttons & IN_SPEED)
        {
            g_bBoost[client] = !g_bBoost[client];
            // Uncomment to show a hint:
            // PrintHintText(client, g_bBoost[client] ? "Boost: ON" : "Boost: OFF");
        }
    }

    g_iPrevButtons[client] = buttons;
}

int GetTargetWeapon(int client)
{
    int wep = (g_cvSlotMode.IntValue == 0)
        ? GetPlayerWeaponSlot(client, 0)
        : GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (wep > MaxClients && IsValidEdict(wep)) return wep;
    return -1;
}

bool IsReloading(int wep)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;

    int offs = GetEntSendPropOffs(wep, "m_bInReload");
    if (offs != -1 && view_as<bool>(GetEntData(wep, offs, 1)))
        return true;

    int st_offs = GetEntSendPropOffs(wep, "m_reloadState"); // Per-shell reload (shotguns)
    if (st_offs != -1 && GetEntData(wep, st_offs, 4) != 0)
        return true;

    return false;
}

bool IsMelee(int wep)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;
    char wcls[64];
    if (!GetWeaponClassName(wep, wcls, sizeof(wcls))) return false;
    return StrEqual(wcls, "weapon_melee", false);
}

void ClampPlayerLevel(int client, float now, float scale, bool isMelee)
{
    if (!(g_cvAffectFire.BoolValue || g_cvAffectReload.BoolValue)) return;

    float minRemP = isMelee ? g_cvMeleeMinRem.FloatValue : 0.0;
    ClampFutureTimeNonExtend(client, "m_flNextAttack", now, scale, minRemP);
}

void ClampWeaponLevel(int wep, float now, float scale, bool isMelee)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return;
    if (!IsWeaponWhitelisted(wep)) return;
    if (!(g_cvAffectFire.BoolValue || g_cvAffectReload.BoolValue)) return;

    float minRemW = isMelee ? g_cvMeleeMinRem.FloatValue : 0.0;
    ClampFutureTimeNonExtend(wep, "m_flNextPrimaryAttack",   now, scale, minRemW);
    ClampFutureTimeNonExtend(wep, "m_flNextSecondaryAttack", now, scale, minRemW);
}

void ClampShove(int client, float now, float scale)
{
    if (!g_cvAffectShove.BoolValue) return;
    ClampFutureTimeNonExtend(client, "m_flNextShoveTime", now, scale, 0.0);
}

void ProcessClient(int client)
{
    // Always update the "crouched for 3 seconds" state first
    UpdateDuckHold3s(client);

    if (!IsClientEligible(client))
        return;

    // ======= Original logic: crouching alone triggers acceleration =======
    if (!IsDuckHeld(client))
        return;

    float now = GetGameTime();

    // Base acceleration scale from CVAR
    float baseScale = g_cvScale.FloatValue;
    float scale     = baseScale;

    // ======= New logic: additional boost after 3 seconds of continuous crouch =======
    //
    // Plugin semantics:
    // remaining CD = remaining CD * scale
    // smaller scale => faster actions
    // To double the speed again, multiply scale by 0.5
    if (g_bDuckHoldReady[client])
    {
        scale *= 0.5;   // "0.5" means another 2x acceleration on top of the base scale
    }

    int wep = GetTargetWeapon(client);
    bool hasWeapon = (wep != -1);

    // Do not accelerate while reloading (legacy behavior)
    if (hasWeapon && IsReloading(wep))
        return;

    bool isMelee = hasWeapon ? IsMelee(wep) : false;

    // 1) Player-level: attack / reload gate (includes melee)
    ClampPlayerLevel(client, now, scale, isMelee);

    // 2) Shove cooldown
    ClampShove(client, now, scale);

    // 3) Weapon-level: primary / secondary attacks (fire, throw, melee)
    if (hasWeapon)
        ClampWeaponLevel(wep, now, scale, isMelee);
}

/* ========================= MAIN HOOK ========================= */

public void PostThinkClamp(int client)
{
    ProcessClient(client);
}
