/**
 * 文件名: l4d2_clear_near_weapons.sp
 *
 * 功能简介:
 *   在 Left 4 Dead 2 中，通过控制台命令主动删除玩家周围一定半径内的地面枪械和近战武器。
 *   默认会删除 weapon_*_spawn / weapon_spawn / weapon_melee_spawn 这类地图武器刷点，
 *   因此能处理地图上原本摆放的枪械和近战武器。
 *
 * 使用方法:
 *   1. 将本文件放入:
 *      left4dead2/addons/sourcemod/scripting/l4d2_clear_near_weapons.sp
 *
 *   2. 用 SourceMod 自带 spcomp 编译，得到:
 *      l4d2_clear_near_weapons.smx
 *
 *   3. 将 .smx 放入:
 *      left4dead2/addons/sourcemod/plugins/
 *
 *   4. 进游戏后控制台执行:
 *      sm plugins load l4d2_clear_near_weapons
 *
 *   5. 控制台命令:
 *      sm_cw
 *      sm_cw 300
 *      sm_cw 300 all
 *
 * 命令说明:
 *   sm_cw
 *      删除命令执行者周围默认半径内的武器。
 *
 *   sm_cw 300
 *      删除命令执行者周围 300 Source units 半径内的武器。
 *
 *   sm_cw 300 all
 *      删除所有生还者周围 300 半径内的武器。
 *
 * CVar:
 *   l4d2_cw_default_radius 250.0
 *      默认删除半径。
 *
 *   l4d2_cw_include_spawns 1
 *      1 = 删除地图武器刷点，例如 weapon_spawn / weapon_rifle_spawn / weapon_melee_spawn。
 *      0 = 只删除已经掉在地上的实际 weapon_* 实体，尽量不动地图刷点。
 *
 * 注意:
 *   - 本版本用 RegConsoleCmd 注册，适合你本地单人/Listen 服测试。
 *   - 如果以后开公网服务器，建议改成 RegAdminCmd，避免普通玩家乱删武器。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name = "L4D2 Clear Nearby Weapons",
    author = "me",
    description = "Clear nearby gun/melee weapon entities by console command.",
    version = "1.0",
    url = ""
};

ConVar g_hDefaultRadius;
ConVar g_hIncludeSpawns;

public void OnPluginStart()
{
    RegConsoleCmd("sm_cw", Cmd_ClearWeapons, "Clear nearby L4D2 weapon entities.");
    RegConsoleCmd("sm_clearweapons", Cmd_ClearWeapons, "Clear nearby L4D2 weapon entities.");

    g_hDefaultRadius = CreateConVar(
        "l4d2_cw_default_radius",
        "250.0",
        "Default radius for sm_cw."
    );

    g_hIncludeSpawns = CreateConVar(
        "l4d2_cw_include_spawns",
        "1",
        "Whether to remove weapon spawn entities. 1=yes, 0=no.",
        _, true, 0.0, true, 1.0
    );
}

public Action Cmd_ClearWeapons(int client, int args)
{
    float radius = g_hDefaultRadius.FloatValue;
    bool allPlayers = false;

    for (int i = 1; i <= args; i++)
    {
        char arg[32];
        GetCmdArg(i, arg, sizeof(arg));

        if (StrEqual(arg, "all", false))
        {
            allPlayers = true;
        }
        else
        {
            float parsedRadius = StringToFloat(arg);
            if (parsedRadius > 0.0)
            {
                radius = parsedRadius;
            }
        }
    }

    if (client == 0)
    {
        allPlayers = true;
    }

    if (radius < 1.0)
    {
        radius = 1.0;
    }

    float centers[MAXPLAYERS + 1][3];
    int centerCount = 0;

    if (allPlayers)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i))
            {
                continue;
            }

            if (!IsPlayerAlive(i))
            {
                continue;
            }

            // L4D2: 2 = Survivors
            if (GetClientTeam(i) != 2)
            {
                continue;
            }

            GetClientAbsOrigin(i, centers[centerCount]);
            centerCount++;
        }
    }
    else
    {
        if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
        {
            ReplyToCommand(client, "[CW] self 模式只能由活着的玩家执行。服务器控制台请用: sm_cw <radius> all");
            return Plugin_Handled;
        }

        GetClientAbsOrigin(client, centers[0]);
        centerCount = 1;
    }

    if (centerCount <= 0)
    {
        ReplyToCommand(client, "[CW] 没有找到可作为中心点的生还者。");
        return Plugin_Handled;
    }

    int removed = ClearWeaponEntitiesAroundCenters(centers, centerCount, radius);

    ReplyToCommand(
        client,
        "[CW] 已删除 %d 个附近武器实体。radius=%.1f, include_spawns=%d",
        removed,
        radius,
        g_hIncludeSpawns.BoolValue ? 1 : 0
    );

    return Plugin_Handled;
}

int ClearWeaponEntitiesAroundCenters(float centers[][3], int centerCount, float radius)
{
    int removed = 0;
    int maxEnts = GetMaxEntities();

    for (int ent = MaxClients + 1; ent < maxEnts; ent++)
    {
        if (!IsValidEntity(ent))
        {
            continue;
        }

        char classname[64];
        if (!GetEntityClassname(ent, classname, sizeof(classname)))
        {
            continue;
        }

        if (!IsClearableWeaponClass(classname))
        {
            continue;
        }

        // 防止误删玩家手上正在持有的武器。
        if (IsOwnedByPlayer(ent))
        {
            continue;
        }

        float entOrigin[3];
        if (!GetEntityOriginSafe(ent, entOrigin))
        {
            continue;
        }

        if (!IsNearAnyCenter(entOrigin, centers, centerCount, radius))
        {
            continue;
        }

        if (RemoveEntitySafe(ent))
        {
            removed++;
        }
    }

    return removed;
}

bool IsClearableWeaponClass(const char[] classname)
{
    bool includeSpawns = g_hIncludeSpawns.BoolValue;

    bool isSpawnEntity = false;

    if (StrEqual(classname, "weapon_spawn", false))
    {
        isSpawnEntity = true;
    }
    else if (StrContains(classname, "_spawn", false) != -1)
    {
        isSpawnEntity = true;
    }

    if (isSpawnEntity && !includeSpawns)
    {
        return false;
    }

    // 通用非近战武器刷点。
    if (StrEqual(classname, "weapon_spawn", false))
    {
        return true;
    }

    static const char prefixes[][] =
    {
        "weapon_pistol",
        "weapon_smg",
        "weapon_pumpshotgun",
        "weapon_shotgun",
        "weapon_autoshotgun",
        "weapon_rifle",
        "weapon_hunting_rifle",
        "weapon_sniper",
        "weapon_grenade_launcher",
        "weapon_chainsaw",
        "weapon_melee"
    };

    for (int i = 0; i < sizeof(prefixes); i++)
    {
        if (StrContains(classname, prefixes[i], false) == 0)
        {
            return true;
        }
    }

    return false;
}

bool IsOwnedByPlayer(int ent)
{
    int owner = -1;

    if (HasEntProp(ent, Prop_Send, "m_hOwnerEntity"))
    {
        owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
        if (owner >= 1 && owner <= MaxClients)
        {
            return true;
        }
    }

    if (HasEntProp(ent, Prop_Data, "m_hOwnerEntity"))
    {
        owner = GetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity");
        if (owner >= 1 && owner <= MaxClients)
        {
            return true;
        }
    }

    if (HasEntProp(ent, Prop_Send, "m_hOwner"))
    {
        owner = GetEntPropEnt(ent, Prop_Send, "m_hOwner");
        if (owner >= 1 && owner <= MaxClients)
        {
            return true;
        }
    }

    return false;
}

bool GetEntityOriginSafe(int ent, float origin[3])
{
    if (HasEntProp(ent, Prop_Send, "m_vecOrigin"))
    {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
        return true;
    }

    if (HasEntProp(ent, Prop_Data, "m_vecOrigin"))
    {
        GetEntPropVector(ent, Prop_Data, "m_vecOrigin", origin);
        return true;
    }

    return false;
}

bool IsNearAnyCenter(const float entOrigin[3], float centers[][3], int centerCount, float radius)
{
    for (int i = 0; i < centerCount; i++)
    {
        if (GetVectorDistance(entOrigin, centers[i]) <= radius)
        {
            return true;
        }
    }

    return false;
}

bool RemoveEntitySafe(int ent)
{
    if (!IsValidEntity(ent))
    {
        return false;
    }

    if (AcceptEntityInput(ent, "Kill"))
    {
        return true;
    }

    if (IsValidEdict(ent))
    {
        RemoveEdict(ent);
        return true;
    }

    return false;
}