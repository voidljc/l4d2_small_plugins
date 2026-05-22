/***************************************************************
 * L4D2 SCAR -> SG552 Safe Swap (chat trigger, two-step delay)
 * Trigger: type !swapscar or /swapscar in chat
 *
 * Rules:
 * 1) Player enters the command:
 *    - First check whether the plugin is enabled
 *    - Then validate the client (in-game, not a bot)
 *    - If passed, defer the swap flow to the next tick to avoid modifying weapons directly inside the say hook (race conditions)
 *
 * 2) Stage 1 (begin swap on the next tick):
 *    - Verify the player is alive and the active-weapon entity is valid
 *    - Read the active weapon classname:
 *      a) If it is NOT SCAR (weapon_rifle_desert): terminate immediately, no changes
 *      b) If it IS SCAR: proceed
 *    - Before removal, record the old weapon's reserve ammo as the baseline for later restore
 *    - Remove SCAR from the player and kill the entity to prevent leftovers or duplicate ownership
 *
 * 3) Stage 2 (defer again, then give the new weapon):
 *    - Give SG552 (weapon_rifle_sg552) and attempt to equip immediately
 *    - If giving fails or the entity is invalid, execute a fallback:
 *      - Give back a SCAR and attempt to equip, preventing the player from ending up with no primary weapon
 *
 * 4) Reserve ammo restore and boundary fallback:
 *    - If the new weapon's ammo type is writable, restore reserve ammo to the recorded value
 *    - If the recorded reserve is 0 or unusable: write a fallback value to avoid abnormal reserve ammo after swapping
 *
 * 5) Mid-flow cancellation conditions:
 *    - If at any stage we detect: player left the game, died, entity invalid, or a critical operation failed
 *      -> terminate immediately and do not continue further modifications
 *
 * 6) Re-entrancy and consistency:
 *    - On every trigger, re-check whether the current active weapon is SCAR
 *    - If conditions are not met, the flow naturally terminates with no side effects
 *    - No forced cooldown: relies on staged execution and state re-validation to avoid repeated swaps causing desync
 *
 * 7) Resource and state cleanup:
 *    - After killing the old weapon entity, never access its handle again
 *    - Data passed between stages must be freed after use
 *    - All failure branches must ensure the player ends up holding a usable primary weapon
 *
 * Dependencies: SourceMod, SDKTools
 ***************************************************************/

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name        = "L4D2 Swap SCAR -> SG552 (Safe Swap)",
    author      = "me",
    description = "Say !swapscar to swap SCAR to SG552 safely (two-step); fixes reserve ammo.",
    version     = "1.2.0",
    url         = ""
};

ConVar g_cvEnable;
ConVar g_cvDebug;

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("sm_swapscar_enable", "1", "Enable swapscar say trigger.", FCVAR_NOTIFY);
    g_cvDebug  = CreateConVar("sm_swapscar_debug",  "1", "Debug output (1=on, 0=off).", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_swapscar_safe");
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    char text[192];
    strcopy(text, sizeof(text), sArgs);
    StripQuotes(text);
    TrimString(text);

    if (!StrEqual(text, "!swapscar", false) && !StrEqual(text, "/swapscar", false))
        return Plugin_Continue;

    // Process on next tick to avoid touching weapons inside the say hook (race condition)
    CreateTimer(0.0, Timer_BeginSwap, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled; // swallow the command
}

public Action Timer_BeginSwap(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        return Plugin_Stop;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0 || !IsValidEntity(weapon))
    {
        if (g_cvDebug.BoolValue) PrintToChat(client, "[Swap] No valid active weapon.");
        return Plugin_Stop;
    }

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));

    if (g_cvDebug.BoolValue)
        PrintToChat(client, "[Swap] Active weapon: %s", classname);

    if (!StrEqual(classname, "weapon_rifle_desert", false))
    {
        if (g_cvDebug.BoolValue) PrintToChat(client, "[Swap] Not SCAR. No action.");
        return Plugin_Stop;
    }

    // Record old weapon reserve ammo
    int oldReserve = 0;
    if (HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType") && HasEntProp(client, Prop_Send, "m_iAmmo"))
    {
        int oldAmmoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
        if (oldAmmoType >= 0 && oldAmmoType < 32)
            oldReserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, oldAmmoType);
    }

    // Remove SCAR first
    RemovePlayerItem(client, weapon);
    AcceptEntityInput(weapon, "Kill");

    // Give the SG552 on the next tick (key stability fix)
    DataPack pack = new DataPack();
    pack.WriteCell(userid);
    pack.WriteCell(oldReserve);
    CreateTimer(0.0, Timer_GiveSG552, pack, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Stop;
}

public Action Timer_GiveSG552(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int oldReserve = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        return Plugin_Stop;

    int newWep = GivePlayerItem(client, "weapon_rifle_sg552");
    if (g_cvDebug.BoolValue)
        PrintToChat(client, "[Swap] GivePlayerItem returned entity=%d", newWep);

    if (newWep <= 0 || !IsValidEntity(newWep))
    {
        if (g_cvDebug.BoolValue) PrintToChat(client, "[Swap] Give SG552 failed. (entity invalid)");
        // Fallback: give back a SCAR to avoid leaving the player without a primary weapon
        int back = GivePlayerItem(client, "weapon_rifle_desert");
        if (back > 0 && IsValidEntity(back))
            EquipPlayerWeapon(client, back);
        return Plugin_Stop;
    }

    EquipPlayerWeapon(client, newWep);

    // Restore SG552 reserve ammo (if old value is 0, use a fallback)
    if (HasEntProp(newWep, Prop_Send, "m_iPrimaryAmmoType") && HasEntProp(client, Prop_Send, "m_iAmmo"))
    {
        int newAmmoType = GetEntProp(newWep, Prop_Send, "m_iPrimaryAmmoType");
        if (newAmmoType >= 0 && newAmmoType < 32)
        {
            int reserveToSet = (oldReserve > 0) ? oldReserve : 360;
            SetEntProp(client, Prop_Send, "m_iAmmo", reserveToSet, _, newAmmoType);
        }
    }

    if (g_cvDebug.BoolValue) PrintToChat(client, "[Swap] SCAR -> SG552 done.");
    return Plugin_Stop;
}
