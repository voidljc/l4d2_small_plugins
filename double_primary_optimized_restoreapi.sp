/*
 * 文件名: double_primary_optimized.sp
 * 插件用途: Left 4 Dead / Left 4 Dead 2 双主武器切换插件。
 * 使用方法:
 *   1. 将本文件放入 addons/sourcemod/scripting/ 目录。
 *   2. 使用 SourceMod spcomp 编译: spcomp double_primary_optimized.sp
 *   3. 将生成的 double_primary_optimized.smx 放入 addons/sourcemod/plugins/ 目录。
 *   4. 进入游戏后，生还者玩家同时按住 E(IN_USE) + 右键(IN_ATTACK2) 切换保存的主武器。
 *
 * 优化说明:
 *   - 保留原始功能、按键、冷却、武器保存/恢复、弹夹/备弹/升级弹保存逻辑。
 *   - 只做保守 CPU 优化: OnPlayerRunCmd 入口先判断按键；缓存 z_gun_swing_interval；缓存 CTerrorPlayer::m_iAmmo 基址。
 *   - 不重写 m_iAmmo + 12/20/28/... 这类寻址偏移，避免破坏原插件的弹药寻址行为。
 *   - 新增 double_primary_restore_api，可让复活插件保存/恢复隐藏的另一把主武器。
 */

// 原始说明: 预加:增加游戏提示,修改buttons
#include <sourcemod>
#include <sdktools>

public Plugin:myinfo =
{
	name = "双主武器",
	author = "非本龟 / optimized",
	description = "双主武器 - 保守 CPU 优化版",
	version = "0.2.3-cpuopt-restoreapi",
	url = "",
};

new String:weapon_d[MAXPLAYERS + 1][64];
new danjia_d[MAXPLAYERS + 1];
new houbei_d[MAXPLAYERS + 1];
new txammo_d[MAXPLAYERS + 1];
new txanum_d[MAXPLAYERS + 1];
new bool:C_Timer[MAXPLAYERS + 1];
new String:game[64];

new bool:g_bIsL4D1 = false;
new bool:g_bIsL4D2 = false;
new bool:g_bMapTransition = false;
new Handle:g_hGunSwingInterval = INVALID_HANDLE;
new g_iAmmoOffset = -1;
new Handle:g_hSavedWeapons = INVALID_HANDLE;

#define DOUBLE_PRIMARY_RESTORE_API "double_primary_restore_api"

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	RegPluginLibrary(DOUBLE_PRIMARY_RESTORE_API);
	CreateNative("DP_HasStoredWeapon", Native_DP_HasStoredWeapon);
	CreateNative("DP_GetStoredWeapon", Native_DP_GetStoredWeapon);
	CreateNative("DP_SetStoredWeapon", Native_DP_SetStoredWeapon);
	CreateNative("DP_ClearStoredWeapon", Native_DP_ClearStoredWeapon);
	return APLRes_Success;
}

public OnPluginStart()
{
	HookEvent("finale_win", RoundEnd);
	HookEvent("map_transition", Event_MapTransition);
	HookEvent("mission_lost", RoundEnd);
	HookEvent("player_death", Player_Death);
	HookEvent("player_team", Player_Team);

	for (new i = 1; i <= MAXPLAYERS; i++)
	{
		ResetClientData(i);
	}

	GetGameFolderName(game, sizeof(game));
	g_bIsL4D1 = StrEqual(game, "left4dead");
	g_bIsL4D2 = StrEqual(game, "left4dead2");
	g_hSavedWeapons = CreateTrie();

	g_hGunSwingInterval = FindConVar("z_gun_swing_interval");
	g_iAmmoOffset = FindSendPropInfo("CTerrorPlayer", "m_iAmmo");
}

public OnMapStart()
{
	g_bMapTransition = false;
}

public OnMapEnd()
{
	g_bMapTransition = true;
}

public OnClientPostAdminCheck(client)
{
	LoadPersistentClientData(client);
}

public OnClientDisconnect(client)
{
	if (g_bMapTransition)
	{
		SavePersistentClientData(client);
	}
	else
	{
		ClearPersistentClientData(client);
	}

	ResetClientData(client);
}

public Action:RoundEnd(Handle:event, String:event_name[], bool:dontBroadcast)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		ClearPersistentClientData(i);
		ResetClientData(i);
	}

	if (g_hSavedWeapons != INVALID_HANDLE)
	{
		ClearTrie(g_hSavedWeapons);
	}
	return Plugin_Continue;
}

public Action:Event_MapTransition(Handle:event, String:event_name[], bool:dontBroadcast)
{
	g_bMapTransition = true;

	for (new i = 1; i <= MaxClients; i++)
	{
		SavePersistentClientData(i);
	}

	return Plugin_Continue;
}

public Action:Player_Death(Handle:event, String:event_name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	ClearPersistentClientData(client);
	ResetClientData(client);
	return Plugin_Continue;
}

public Action:Player_Team(Handle:event, String:event_name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new newteam = GetEventInt(event, "team");
	if (newteam == 3)
	{
		ClearPersistentClientData(client);
		ResetClientData(client);
	}
	return Plugin_Continue;
}

public Action:C_Timer_End(Handle:timer, any:client)
{
	if (client >= 1 && client <= MaxClients)
	{
		C_Timer[client] = false;
	}
	return Plugin_Stop;
}

stock ResetClientData(client)
{
	if (client < 1 || client > MaxClients)
	{
		return;
	}

	strcopy(weapon_d[client], sizeof(weapon_d[]), "weapon_none");
	danjia_d[client] = 0;
	houbei_d[client] = 0;
	txammo_d[client] = 0;
	txanum_d[client] = 0;
	C_Timer[client] = false;
}

stock bool:GetClientStorageKey(client, String:key[], maxlen)
{
	if (client < 1 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
	{
		return false;
	}

	if (!GetClientAuthId(client, AuthId_Steam2, key, maxlen, true))
	{
		return false;
	}

	return key[0] != '\0';
}

stock SavePersistentClientData(client)
{
	if (g_hSavedWeapons == INVALID_HANDLE)
	{
		return;
	}

	new String:key[64];
	if (!GetClientStorageKey(client, key, sizeof(key)))
	{
		return;
	}

	if (!HasStoredWeapon(client))
	{
		RemoveFromTrie(g_hSavedWeapons, key);
		return;
	}

	new String:data[192];
	Format(data, sizeof(data), "%s|%d|%d|%d|%d", weapon_d[client], danjia_d[client], houbei_d[client], txammo_d[client], txanum_d[client]);
	SetTrieString(g_hSavedWeapons, key, data, true);
}

stock LoadPersistentClientData(client)
{
	if (g_hSavedWeapons == INVALID_HANDLE)
	{
		return;
	}

	new String:key[64];
	if (!GetClientStorageKey(client, key, sizeof(key)))
	{
		return;
	}

	new String:data[192];
	if (!GetTrieString(g_hSavedWeapons, key, data, sizeof(data)))
	{
		return;
	}

	new String:pieces[5][64];
	if (ExplodeString(data, "|", pieces, sizeof(pieces), sizeof(pieces[])) != 5)
	{
		return;
	}

	strcopy(weapon_d[client], sizeof(weapon_d[]), pieces[0]);
	danjia_d[client] = StringToInt(pieces[1]);
	houbei_d[client] = StringToInt(pieces[2]);
	txammo_d[client] = StringToInt(pieces[3]);
	txanum_d[client] = StringToInt(pieces[4]);
}

stock ClearPersistentClientData(client)
{
	if (g_hSavedWeapons == INVALID_HANDLE)
	{
		return;
	}

	new String:key[64];
	if (!GetClientStorageKey(client, key, sizeof(key)))
	{
		return;
	}

	RemoveFromTrie(g_hSavedWeapons, key);
}

stock Float:GetSwitchInterval()
{
	if (g_hGunSwingInterval != INVALID_HANDLE)
	{
		return GetConVarFloat(g_hGunSwingInterval);
	}
	return 0.0;
}

stock bool:HasStoredWeapon(client)
{
	return !StrEqual(weapon_d[client], "weapon_none");
}

public Native_DP_HasStoredWeapon(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return false;
	}

	return HasStoredWeapon(client);
}

public Native_DP_GetStoredWeapon(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !HasStoredWeapon(client))
	{
		return false;
	}

	new maxlen = GetNativeCell(3);
	SetNativeString(2, weapon_d[client], maxlen, true);
	SetNativeCellRef(4, danjia_d[client]);
	SetNativeCellRef(5, houbei_d[client]);
	SetNativeCellRef(6, txammo_d[client]);
	SetNativeCellRef(7, txanum_d[client]);
	return true;
}

public Native_DP_SetStoredWeapon(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return false;
	}

	new String:classname[64];
	GetNativeString(2, classname, sizeof(classname));

	if (classname[0] == '\0' || StrEqual(classname, "weapon_none"))
	{
		ResetClientData(client);
		ClearPersistentClientData(client);
		return true;
	}

	strcopy(weapon_d[client], sizeof(weapon_d[]), classname);
	danjia_d[client] = GetNativeCell(3);
	houbei_d[client] = GetNativeCell(4);
	txammo_d[client] = GetNativeCell(5);
	txanum_d[client] = GetNativeCell(6);
	SavePersistentClientData(client);
	return true;
}

public Native_DP_ClearStoredWeapon(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return false;
	}

	ResetClientData(client);
	ClearPersistentClientData(client);
	return true;
}

stock CheatCommand(Client, const String:command[], const String:arguments[])
{
	if (!Client)
	{
		return;
	}

	new admindata = GetUserFlagBits(Client);
	SetUserFlagBits(Client, ADMFLAG_ROOT);

	new flags = GetCommandFlags(command);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);
	FakeClientCommand(Client, "%s %s", command, arguments);
	SetCommandFlags(command, flags);

	SetUserFlagBits(Client, admindata);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	// CPU 优化关键点: 绝大多数 tick 没有同时按 E + 右键，先直接返回。
	// 不改成“只检测按下瞬间”，避免改变原插件“按住等待冷却结束后可再次触发”的行为。
	if (!(buttons & IN_USE) || !(buttons & IN_ATTACK2))
	{
		return Plugin_Continue;
	}

	if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != 2)
	{
		return Plugin_Continue;
	}

	if (C_Timer[client])
	{
		return Plugin_Continue;
	}

	C_Timer[client] = true;
	SwitchDoublePrimary(client);
	CreateTimer(GetSwitchInterval(), C_Timer_End, client);

	return Plugin_Continue;
}

stock SwitchDoublePrimary(client)
{
	new ent = GetPlayerWeaponSlot(client, 0);

	if (ent != -1)
	{
		new String:weapon_f[64];
		new danjia_f = 0;
		new houbei_f = 0;
		new txammo_f = 0;
		new txanum_f = 0;

		GetEdictClassname(ent, weapon_f, sizeof(weapon_f));

		if (g_bIsL4D1)
		{
			GetClientWeaponInfo_l4d1(client, houbei_f, danjia_f);
		}
		else if (g_bIsL4D2)
		{
			GetClientWeaponInfo_l4d2(client, houbei_f, danjia_f);
		}

		txammo_f = GetEntProp(ent, Prop_Send, "m_upgradeBitVec");
		txanum_f = GetEntProp(ent, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");

		RemovePlayerItem(client, ent);

		if (HasStoredWeapon(client))
		{
			GiveStoredWeapon(client);
		}

		strcopy(weapon_d[client], sizeof(weapon_d[]), weapon_f);
		danjia_d[client] = danjia_f;
		houbei_d[client] = houbei_f;
		txammo_d[client] = txammo_f;
		txanum_d[client] = txanum_f;
		SavePersistentClientData(client);
	}
	else
	{
		if (HasStoredWeapon(client))
		{
			GiveStoredWeapon(client);
		}

		strcopy(weapon_d[client], sizeof(weapon_d[]), "weapon_none");
		danjia_d[client] = 0;
		houbei_d[client] = 0;
		txammo_d[client] = 0;
		txanum_d[client] = 0;
		ClearPersistentClientData(client);
	}
}

stock GiveStoredWeapon(client)
{
	CheatCommand(client, "give", weapon_d[client]);

	if (g_bIsL4D1)
	{
		SetClientWeaponInfo_l4d1(client, houbei_d[client], danjia_d[client]);
	}
	else if (g_bIsL4D2)
	{
		SetClientWeaponInfo_l4d2(client, houbei_d[client], danjia_d[client]);
	}

	new ent = GetPlayerWeaponSlot(client, 0);
	if (ent != -1)
	{
		SetEntProp(ent, Prop_Send, "m_upgradeBitVec", txammo_d[client]);
		SetEntProp(ent, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", txanum_d[client]);
	}
}

GetClientWeaponInfo_l4d2(client, &ammo, &clip)
{
	new slot = 0;
	new ent = GetPlayerWeaponSlot(client, slot);
	if (ent > 0)
	{
		new String:weapon[32];
		GetEdictClassname(ent, weapon, sizeof(weapon));

		if (g_iAmmoOffset < 0)
		{
			clip = GetEntProp(ent, Prop_Send, "m_iClip1");
			return;
		}

		new bool:set = false;
		if (slot == 0)
		{
			clip = GetEntProp(ent, Prop_Send, "m_iClip1");
			if (StrEqual(weapon, "weapon_rifle") || StrEqual(weapon, "weapon_rifle_sg552") || StrEqual(weapon, "weapon_rifle_desert") || StrEqual(weapon, "weapon_rifle_ak47"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 12);
				if (set) SetEntData(client, g_iAmmoOffset + 12, 0);
			}
			else if (StrEqual(weapon, "weapon_smg") || StrEqual(weapon, "weapon_smg_silenced") || StrEqual(weapon, "weapon_smg_mp5"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 20);
				if (set) SetEntData(client, g_iAmmoOffset + 20, 0);
			}
			else if (StrEqual(weapon, "weapon_pumpshotgun") || StrEqual(weapon, "weapon_shotgun_chrome"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 28);
				if (set) SetEntData(client, g_iAmmoOffset + 28, 0);
			}
			else if (StrEqual(weapon, "weapon_autoshotgun") || StrEqual(weapon, "weapon_shotgun_spas"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 32);
				if (set) SetEntData(client, g_iAmmoOffset + 32, 0);
			}
			else if (StrEqual(weapon, "weapon_hunting_rifle"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 36);
				if (set) SetEntData(client, g_iAmmoOffset + 36, 0);
			}
			else if (StrEqual(weapon, "weapon_sniper_scout") || StrEqual(weapon, "weapon_sniper_military") || StrEqual(weapon, "weapon_sniper_awp"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 40);
				if (set) SetEntData(client, g_iAmmoOffset + 40, 0);
			}
			else if (StrEqual(weapon, "weapon_grenade_launcher"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 68);
				if (set) SetEntData(client, g_iAmmoOffset + 68, 0);
			}
		}
	}
}

SetClientWeaponInfo_l4d2(client, ammo, clip)
{
	new slot = 0;
	new ent = GetPlayerWeaponSlot(client, slot);
	if (ent > 0)
	{
		new String:weapon[32];
		GetEdictClassname(ent, weapon, sizeof(weapon));

		SetEntProp(ent, Prop_Send, "m_iClip1", clip);

		if (g_iAmmoOffset < 0)
		{
			return;
		}

		new bool:set = true;
		if (StrEqual(weapon, "weapon_rifle") || StrEqual(weapon, "weapon_rifle_sg552") || StrEqual(weapon, "weapon_rifle_desert") || StrEqual(weapon, "weapon_rifle_ak47"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 12, ammo);
		}
		else if (StrEqual(weapon, "weapon_smg") || StrEqual(weapon, "weapon_smg_silenced") || StrEqual(weapon, "weapon_smg_mp5"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 20, ammo);
		}
		else if (StrEqual(weapon, "weapon_pumpshotgun") || StrEqual(weapon, "weapon_shotgun_chrome"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 28, ammo);
		}
		else if (StrEqual(weapon, "weapon_autoshotgun") || StrEqual(weapon, "weapon_shotgun_spas"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 32, ammo);
		}
		else if (StrEqual(weapon, "weapon_hunting_rifle"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 36, ammo);
		}
		else if (StrEqual(weapon, "weapon_sniper_scout") || StrEqual(weapon, "weapon_sniper_military") || StrEqual(weapon, "weapon_sniper_awp"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 40, ammo);
		}
		else if (StrEqual(weapon, "weapon_grenade_launcher"))
		{
			if (set) SetEntData(client, g_iAmmoOffset + 68, ammo);
		}
	}
}

GetClientWeaponInfo_l4d1(client, &ammo, &clip)
{
	new slot = 0;
	new ent = GetPlayerWeaponSlot(client, slot);
	if (ent > 0)
	{
		new String:weapon[32];
		GetEdictClassname(ent, weapon, sizeof(weapon));

		if (g_iAmmoOffset < 0)
		{
			clip = GetEntProp(ent, Prop_Send, "m_iClip1");
			return;
		}

		if (slot == 0)
		{
			clip = GetEntProp(ent, Prop_Send, "m_iClip1");

			if (StrEqual(weapon, "weapon_pumpshotgun") || StrEqual(weapon, "weapon_autoshotgun"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 24);
			}
			else if (StrEqual(weapon, "weapon_smg"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 20);
			}
			else if (StrEqual(weapon, "weapon_rifle"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 12);
			}
			else if (StrEqual(weapon, "weapon_hunting_rifle"))
			{
				ammo = GetEntData(client, g_iAmmoOffset + 8);
			}
		}
	}
}

SetClientWeaponInfo_l4d1(client, ammo, clip)
{
	new slot = 0;
	new ent = GetPlayerWeaponSlot(client, slot);
	if (ent > 0)
	{
		new String:weapon[32];
		GetEdictClassname(ent, weapon, sizeof(weapon));

		SetEntProp(ent, Prop_Send, "m_iClip1", clip);

		if (g_iAmmoOffset < 0)
		{
			return;
		}

		if (StrEqual(weapon, "weapon_pumpshotgun") || StrEqual(weapon, "weapon_autoshotgun"))
		{
			SetEntData(client, g_iAmmoOffset + 24, ammo);
		}
		else if (StrEqual(weapon, "weapon_smg"))
		{
			SetEntData(client, g_iAmmoOffset + 20, ammo);
		}
		else if (StrEqual(weapon, "weapon_rifle"))
		{
			SetEntData(client, g_iAmmoOffset + 12, ammo);
		}
		else if (StrEqual(weapon, "weapon_hunting_rifle"))
		{
			SetEntData(client, g_iAmmoOffset + 8, ammo);
		}
	}
}
