/*
 * 插件说明：
 * - L4D2 SourceMod 插件。
 * - 用 sm_moretegan 控制是否自动补特感。
 * - 当前存活普通特感不足目标数量时，在存活幸存者附近寻找合法位置补怪。
 * - 补怪顺序循环：hunter -> charger -> jockey -> smoker -> spitter -> boomer。
 * - Tank alive: this plugin pauses spawning specials only.
 * - Other mods and the Director are not blocked.
 *
 * 控制台用法：
 * - sm_moretegan 0              关闭，默认关闭
 * - sm_moretegan 1              开启
 * - sm_moretegan_target 24      设置目标特感数量
 * - sm_moretegan_interval 10.0  设置检测间隔
 * - sm_moretegan_attempts 30    设置找出生点尝试次数
 * - sm_moretegan_debug 0        关闭调试输出
 * - sm_moretegan_pause_tank 1   Tank alive pauses this plugin only
 *
 * 聊天框用法：
 * - 在控制台指令前面加 ! 即可。
 * - !sm_moretegan 1
 * - !sm_moretegan 0
 * - !sm_moretegan_target 24
 * - !sm_moretegan_interval 10.0
 * - !sm_moretegan_attempts 30
 * - !sm_moretegan_debug 1
 * - !sm_moretegan_pause_tank 1
 *
 * 编译要求：
 * - 需要安装 Left 4 DHooks。
 * - 确保存在：
 *   addons/sourcemod/scripting/include/left4dhooks.inc
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3

#define L4D2_ZC_SMOKER  1
#define L4D2_ZC_BOOMER  2
#define L4D2_ZC_HUNTER  3
#define L4D2_ZC_SPITTER 4
#define L4D2_ZC_JOCKEY  5
#define L4D2_ZC_CHARGER 6
#define L4D2_ZC_TANK    8

public Plugin myinfo =
{
    name = "L4D2 More Tegan",
    author = "me",
    description = "Chat and console controlled special infected auto-fill up to target count. Pauses while Tank exists.",
    version = "1.3.0",
    url = ""
};

ConVar g_hEnable;
ConVar g_hTarget;
ConVar g_hInterval;
ConVar g_hAttempts;
ConVar g_hDebug;
ConVar g_hPauseTank;

Handle g_hCheckTimer = null;

int g_iSpawnOrder[6] =
{
    L4D2_ZC_HUNTER,
    L4D2_ZC_CHARGER,
    L4D2_ZC_JOCKEY,
    L4D2_ZC_SMOKER,
    L4D2_ZC_SPITTER,
    L4D2_ZC_BOOMER
};

int g_iNextSpawnIndex = 0;
bool g_bMapStarted = false;

public void OnPluginStart()
{
    char game[32];
    GetGameFolderName(game, sizeof(game));

    if (!StrEqual(game, "left4dead2", false))
    {
        SetFailState("This plugin only supports Left 4 Dead 2.");
    }

    g_hEnable = CreateConVar(
        "sm_moretegan",
        "0",
        "Enable more special infected auto-fill. 0 = off, 1 = on.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_hTarget = CreateConVar(
        "sm_moretegan_target",
        "16",
        "Target number of alive special infected.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        64.0
    );

    g_hInterval = CreateConVar(
        "sm_moretegan_interval",
        "10.0",
        "Check interval in seconds after sm_moretegan is enabled.",
        FCVAR_NOTIFY,
        true,
        1.0,
        true,
        120.0
    );

    g_hAttempts = CreateConVar(
        "sm_moretegan_attempts",
        "30",
        "Spawn position search attempts per survivor.",
        FCVAR_NOTIFY,
        true,
        1.0,
        true,
        200.0
    );

    g_hDebug = CreateConVar(
        "sm_moretegan_debug",
        "0",
        "Print debug logs. 0 = off, 1 = on.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_hPauseTank = CreateConVar(
        "sm_moretegan_pause_tank",
        "1",
        "Pause this plugin's special infected spawning while any alive Tank exists. 0 = off, 1 = on.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    HookConVarChange(g_hEnable, OnEnableChanged);
    HookConVarChange(g_hInterval, OnIntervalChanged);

    AddCommandListener(Command_Say, "say");
    AddCommandListener(Command_Say, "say_team");

    AutoExecConfig(true, "l4d2_moretegan");
}

public void OnMapStart()
{
    g_bMapStarted = true;
    g_iNextSpawnIndex = 0;

    if (g_hEnable != null && g_hEnable.BoolValue)
    {
        StartCheckTimer(true);
    }
}

public void OnMapEnd()
{
    g_bMapStarted = false;
    StopCheckTimer();
}

public void OnConfigsExecuted()
{
    if (g_bMapStarted && g_hEnable.BoolValue)
    {
        StartCheckTimer(true);
    }
}

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar.BoolValue)
    {
        StartCheckTimer(true);
        PrintToServer("[MoreTegan] sm_moretegan enabled.");
    }
    else
    {
        StopCheckTimer();
        PrintToServer("[MoreTegan] sm_moretegan disabled.");
    }
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_hEnable.BoolValue)
    {
        StartCheckTimer(false);
    }
}

public Action Command_Say(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Continue;
    }

    char text[256];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);

    if (text[0] != '!')
    {
        return Plugin_Continue;
    }

    char input[256];
    CopyStringWithoutFirstChar(text, input, sizeof(input));
    TrimString(input);

    if (input[0] == '\0')
    {
        return Plugin_Continue;
    }

    char cmd[64];
    char value[64];

    int next = BreakString(input, cmd, sizeof(cmd));

    if (next == -1)
    {
        value[0] = '\0';
    }
    else
    {
        strcopy(value, sizeof(value), input[next]);
        TrimString(value);
        StripQuotes(value);
    }

    if (HandleChatCvar(client, cmd, value))
    {
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

bool HandleChatCvar(int client, const char[] cmd, const char[] value)
{
    if (StrEqual(cmd, "sm_moretegan", false))
    {
        return SetBoolCvarFromChat(client, g_hEnable, "sm_moretegan", value);
    }

    if (StrEqual(cmd, "sm_moretegan_target", false))
    {
        return SetIntCvarFromChat(client, g_hTarget, "sm_moretegan_target", value, 0, 64);
    }

    if (StrEqual(cmd, "sm_moretegan_interval", false))
    {
        return SetFloatCvarFromChat(client, g_hInterval, "sm_moretegan_interval", value, 1.0, 120.0);
    }

    if (StrEqual(cmd, "sm_moretegan_attempts", false))
    {
        return SetIntCvarFromChat(client, g_hAttempts, "sm_moretegan_attempts", value, 1, 200);
    }

    if (StrEqual(cmd, "sm_moretegan_debug", false))
    {
        return SetBoolCvarFromChat(client, g_hDebug, "sm_moretegan_debug", value);
    }

    if (StrEqual(cmd, "sm_moretegan_pause_tank", false))
    {
        return SetBoolCvarFromChat(client, g_hPauseTank, "sm_moretegan_pause_tank", value);
    }

    return false;
}

bool SetBoolCvarFromChat(int client, ConVar cvar, const char[] name, const char[] value)
{
    if (value[0] == '\0')
    {
        PrintToChat(client, "\x04[MoreTegan]\x01 %s = %d", name, cvar.IntValue);
        return true;
    }

    int number = StringToInt(value);

    if (number != 0 && number != 1)
    {
        PrintToChat(client, "\x04[MoreTegan]\x01 Usage: !%s 0/1", name);
        return true;
    }

    cvar.SetInt(number, true, false);
    PrintToChat(client, "\x04[MoreTegan]\x01 %s set to %d", name, number);
    return true;
}

bool SetIntCvarFromChat(int client, ConVar cvar, const char[] name, const char[] value, int minValue, int maxValue)
{
    if (value[0] == '\0')
    {
        PrintToChat(client, "\x04[MoreTegan]\x01 %s = %d", name, cvar.IntValue);
        return true;
    }

    int number = StringToInt(value);

    if (number < minValue)
    {
        number = minValue;
    }

    if (number > maxValue)
    {
        number = maxValue;
    }

    cvar.SetInt(number, true, false);
    PrintToChat(client, "\x04[MoreTegan]\x01 %s set to %d", name, number);
    return true;
}

bool SetFloatCvarFromChat(int client, ConVar cvar, const char[] name, const char[] value, float minValue, float maxValue)
{
    if (value[0] == '\0')
    {
        PrintToChat(client, "\x04[MoreTegan]\x01 %s = %.2f", name, cvar.FloatValue);
        return true;
    }

    float number = StringToFloat(value);

    if (number < minValue)
    {
        number = minValue;
    }

    if (number > maxValue)
    {
        number = maxValue;
    }

    cvar.SetFloat(number, true, false);
    PrintToChat(client, "\x04[MoreTegan]\x01 %s set to %.2f", name, number);
    return true;
}

void CopyStringWithoutFirstChar(const char[] source, char[] dest, int maxlen)
{
    int i = 1;
    int j = 0;

    while (source[i] != '\0' && j < maxlen - 1)
    {
        dest[j] = source[i];
        i++;
        j++;
    }

    dest[j] = '\0';
}

void StartCheckTimer(bool runNow)
{
    StopCheckTimer();

    if (!g_bMapStarted)
    {
        return;
    }

    if (!g_hEnable.BoolValue)
    {
        return;
    }

    float interval = g_hInterval.FloatValue;

    g_hCheckTimer = CreateTimer(
        interval,
        Timer_CheckSpecials,
        _,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );

    if (runNow)
    {
        CreateTimer(0.1, Timer_CheckSpecialsOnce, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

void StopCheckTimer()
{
    if (g_hCheckTimer != null)
    {
        KillTimer(g_hCheckTimer);
        g_hCheckTimer = null;
    }
}

public Action Timer_CheckSpecialsOnce(Handle timer)
{
    if (!g_hEnable.BoolValue)
    {
        return Plugin_Stop;
    }

    CheckAndFillSpecials();
    return Plugin_Stop;
}

public Action Timer_CheckSpecials(Handle timer)
{
    if (!g_hEnable.BoolValue)
    {
        g_hCheckTimer = null;
        return Plugin_Stop;
    }

    CheckAndFillSpecials();
    return Plugin_Continue;
}

void CheckAndFillSpecials()
{
    if (!g_bMapStarted)
    {
        return;
    }

    if (g_hPauseTank.BoolValue && HasAliveTank())
    {
        DebugLog("Alive Tank detected. Skip this plugin's special infected spawn.");
        return;
    }

    if (!HasAliveSurvivor())
    {
        DebugLog("No alive survivor. Skip.");
        return;
    }

    int target = g_hTarget.IntValue;
    int current = CountAliveSpecials();

    if (current >= target)
    {
        DebugLog("Current specials: %d / %d. No need to spawn.", current, target);
        return;
    }

    int need = target - current;

    DebugLog("Current specials: %d / %d. Need spawn: %d.", current, target, need);

    for (int i = 0; i < need; i++)
    {
        if (g_hPauseTank.BoolValue && HasAliveTank())
        {
            DebugLog("Alive Tank detected during spawn loop. Stop this plugin's spawn loop.");
            break;
        }

        int zclass = g_iSpawnOrder[g_iNextSpawnIndex];

        if (!TrySpawnSpecialNearSurvivor(zclass))
        {
            char name[32];
            GetZombieClassName(zclass, name, sizeof(name));

            DebugLog("Failed to find legal spawn position for %s.", name);
            break;
        }

        char spawnedName[32];
        GetZombieClassName(zclass, spawnedName, sizeof(spawnedName));

        DebugLog("Spawned %s.", spawnedName);

        g_iNextSpawnIndex++;

        if (g_iNextSpawnIndex >= sizeof(g_iSpawnOrder))
        {
            g_iNextSpawnIndex = 0;
        }
    }
}

int CountAliveSpecials()
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_INFECTED)
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            continue;
        }

        int zclass = GetEntProp(client, Prop_Send, "m_zombieClass");

        if (IsNormalSpecialClass(zclass))
        {
            count++;
        }
    }

    return count;
}

bool HasAliveTank()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_INFECTED)
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            continue;
        }

        int zclass = GetEntProp(client, Prop_Send, "m_zombieClass");

        if (zclass == L4D2_ZC_TANK)
        {
            return true;
        }
    }

    return false;
}


bool IsNormalSpecialClass(int zclass)
{
    if (zclass == L4D2_ZC_SMOKER)
    {
        return true;
    }

    if (zclass == L4D2_ZC_BOOMER)
    {
        return true;
    }

    if (zclass == L4D2_ZC_HUNTER)
    {
        return true;
    }

    if (zclass == L4D2_ZC_SPITTER)
    {
        return true;
    }

    if (zclass == L4D2_ZC_JOCKEY)
    {
        return true;
    }

    if (zclass == L4D2_ZC_CHARGER)
    {
        return true;
    }

    return false;
}

bool TrySpawnSpecialNearSurvivor(int zclass)
{
    int survivors[MAXPLAYERS + 1];
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_SURVIVOR)
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            continue;
        }

        survivors[count] = client;
        count++;
    }

    if (count <= 0)
    {
        return false;
    }

    ShuffleIntArray(survivors, count);

    int attempts = g_hAttempts.IntValue;

    float pos[3];
    float ang[3];

    for (int i = 0; i < count; i++)
    {
        int survivor = survivors[i];

        if (!IsClientInGame(survivor))
        {
            continue;
        }

        if (!IsPlayerAlive(survivor))
        {
            continue;
        }

        if (!L4D_GetRandomPZSpawnPosition(survivor, zclass, attempts, pos))
        {
            continue;
        }

        ang[0] = 0.0;
        ang[1] = GetRandomFloat(0.0, 360.0);
        ang[2] = 0.0;

        L4D2_SpawnSpecial(zclass, pos, ang);
        return true;
    }

    return false;
}

void ShuffleIntArray(int[] array, int count)
{
    for (int i = 0; i < count; i++)
    {
        int j = GetRandomInt(i, count - 1);

        int temp = array[i];
        array[i] = array[j];
        array[j] = temp;
    }
}

bool HasAliveSurvivor()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_SURVIVOR)
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            continue;
        }

        return true;
    }

    return false;
}

void GetZombieClassName(int zclass, char[] buffer, int maxlen)
{
    if (zclass == L4D2_ZC_SMOKER)
    {
        strcopy(buffer, maxlen, "smoker");
        return;
    }

    if (zclass == L4D2_ZC_BOOMER)
    {
        strcopy(buffer, maxlen, "boomer");
        return;
    }

    if (zclass == L4D2_ZC_HUNTER)
    {
        strcopy(buffer, maxlen, "hunter");
        return;
    }

    if (zclass == L4D2_ZC_SPITTER)
    {
        strcopy(buffer, maxlen, "spitter");
        return;
    }

    if (zclass == L4D2_ZC_JOCKEY)
    {
        strcopy(buffer, maxlen, "jockey");
        return;
    }

    if (zclass == L4D2_ZC_CHARGER)
    {
        strcopy(buffer, maxlen, "charger");
        return;
    }

    strcopy(buffer, maxlen, "unknown");
}

void DebugLog(const char[] format, any ...)
{
    if (!g_hDebug.BoolValue)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);

    PrintToServer("[MoreTegan] %s", buffer);
}
