/**
 * 文件名: l4d2_shift_adrenaline_optimized_v1_4.sp
 * 简介:
 *   L4D2 SourceMod 插件。检测人类幸存者玩家是否按下 Shift。
 *   实际检测的是 IN_SPEED，也就是玩家当前是否执行 +speed 动作；默认键位通常是 Shift。
 *
 * 当前功能:
 *   1. 只在 IN_SPEED 从 0 变成 1 的瞬间触发，长按不会反复触发。
 *   2. 如果玩家 4 号槽有 weapon_adrenaline，并且当前没有肾上腺素状态：
 *      - 无视当前冷却，直接消耗肾上腺素针。
 *      - 给予服务器 adrenaline_duration 对应的原版肾上腺素持续时间。
 *      - 把 Shift 冷却刷新为 l4d2_shift_adrenaline_cooldown，默认 10 秒。
 *   3. 如果玩家 4 号槽有 weapon_pain_pills，并且当前没有肾上腺素状态：
 *      - 无视当前冷却，直接消耗止痛药。
 *      - 按 pain_pills_health_value 给予原版临时血量回血，并按临时血量上限封顶。
 *      - 额外给予 l4d2_shift_adrenaline_pills_duration 秒肾上腺素，默认 8 秒。
 *      - 把 Shift 冷却刷新为 l4d2_shift_adrenaline_cooldown，默认 10 秒。
 *   4. 如果没有可自动使用的针/药：
 *      - 冷却没好：只给该玩家提示剩余冷却。
 *      - 冷却好了但已有肾上腺素状态：不给 3 秒，也不刷新冷却。
 *      - 冷却好了且没有肾上腺素状态：给予 l4d2_shift_adrenaline_duration 秒肾上腺素，默认 3 秒，并刷新冷却。
 *
 * 使用方法:
 *   1. 将本文件保存为:
 *        addons/sourcemod/scripting/l4d2_shift_adrenaline_optimized_v1_4.sp
 *   2. 用 SourceMod 的 spcomp 编译:
 *        spcomp l4d2_shift_adrenaline_optimized_v1_4.sp
 *   3. 将生成的 .smx 放入:
 *        addons/sourcemod/plugins/
 *   4. 重启服务器或执行:
 *        sm plugins load l4d2_shift_adrenaline_optimized_v1_4
 *   5. 首次运行后会生成配置文件:
 *        cfg/sourcemod/l4d2_shift_adrenaline_optimized.cfg
 *
 * 主要参数:
 *   l4d2_shift_adrenaline_enable           "1"     // 是否启用插件
 *   l4d2_shift_adrenaline_owner_only       "1"     // 是否只允许本地房主/通常 client 1 使用
 *   l4d2_shift_adrenaline_cooldown         "10.0"  // 冷却时间；触发成功后刷新为该值
 *   l4d2_shift_adrenaline_duration         "3.0"   // 普通情况，无针无药时的肾上腺素时间
 *   l4d2_shift_adrenaline_pills_duration   "8.0"   // 自动吃止痛药后的肾上腺素时间
 *   l4d2_shift_adrenaline_consume_carried  "1"     // 是否自动消耗玩家身上的针/药
 *
 * 注意:
 *   - 默认 owner_only = 1，适合本地开房/单人模式给服务器主人使用。
 *   - listen server 里房主通常是 client 1；如果要让所有真人幸存者都能用，把 owner_only 改成 0。
 *   - 自动消耗针/药是直接删除物品并写玩家状态，不播放原版使用动画。
 *   - 止痛药回血写入 m_healthBuffer/m_healthBufferTime，使用 pain_pills_health_value，并按永久血量 + 临时血量 <= 最大血量封顶。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_hooks>

#define PLUGIN_VERSION "1.4.0"
#define TEAM_SURVIVOR 2
#define L4D2_SLOT_PILLS_ADRENALINE 4
#define FALLBACK_ORIGINAL_ADRENALINE_DURATION 15.0
#define FALLBACK_PILLS_HEALTH_VALUE 50.0
#define FALLBACK_PILLS_DECAY_RATE 0.27
#define FALLBACK_SURVIVOR_MAX_HEALTH 100

#if !defined IN_SPEED
    #define IN_SPEED (1 << 17)
#endif

enum CarriedItemType
{
    Item_None = 0,
    Item_Adrenaline,
    Item_Pills
};

ConVar g_cvEnable;
ConVar g_cvOwnerOnly;
ConVar g_cvCooldown;
ConVar g_cvShortDuration;
ConVar g_cvPillsAdrenalineDuration;
ConVar g_cvConsumeCarried;
ConVar g_cvGameAdrenalineDuration;
ConVar g_cvPainPillsHealthValue;
ConVar g_cvPainPillsDecayRate;

float g_fNextUseTime[MAXPLAYERS + 1];
bool g_bWasHoldingShift[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "[L4D2] Shift Adrenaline Optimized",
    author = "me",
    description = "Press Shift to auto-use adrenaline or pills, or get short adrenaline with cooldown.",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    char game[32];
    GetGameFolderName(game, sizeof(game));

    if (!StrEqual(game, "left4dead2", false))
    {
        strcopy(error, err_max, "This plugin only supports Left 4 Dead 2.");
        return APLRes_Failure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar(
        "l4d2_shift_adrenaline_version",
        PLUGIN_VERSION,
        "Plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    g_cvEnable = CreateConVar(
        "l4d2_shift_adrenaline_enable",
        "1",
        "Enable Shift adrenaline plugin. 1 = enable, 0 = disable.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvOwnerOnly = CreateConVar(
        "l4d2_shift_adrenaline_owner_only",
        "1",
        "Only allow local listen-server owner, usually client 1, to use this plugin. 1 = owner only, 0 = all human survivors.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvCooldown = CreateConVar(
        "l4d2_shift_adrenaline_cooldown",
        "10.0",
        "Cooldown in seconds. Successful trigger refreshes cooldown to now + this value.",
        FCVAR_NOTIFY,
        true,
        0.0
    );

    g_cvShortDuration = CreateConVar(
        "l4d2_shift_adrenaline_duration",
        "3.0",
        "Normal short adrenaline duration in seconds when the player has no carried adrenaline or pills.",
        FCVAR_NOTIFY,
        true,
        0.1
    );

    g_cvPillsAdrenalineDuration = CreateConVar(
        "l4d2_shift_adrenaline_pills_duration",
        "8.0",
        "Adrenaline duration in seconds after auto-consuming pain pills.",
        FCVAR_NOTIFY,
        true,
        0.1
    );

    g_cvConsumeCarried = CreateConVar(
        "l4d2_shift_adrenaline_consume_carried",
        "1",
        "If 1, pressing Shift will first consume carried weapon_adrenaline or weapon_pain_pills when the player is not already in adrenaline state.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvGameAdrenalineDuration = FindConVar("adrenaline_duration");
    g_cvPainPillsHealthValue = FindConVar("pain_pills_health_value");
    g_cvPainPillsDecayRate = FindConVar("pain_pills_decay_rate");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_team", Event_PlayerStateChanged, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerStateChanged, EventHookMode_Post);

    AutoExecConfig(true, "l4d2_shift_adrenaline_optimized");

    ResetAllPlayers();
}

public void OnMapStart()
{
    ResetAllPlayers();
}

public void OnClientPutInServer(int client)
{
    ResetClient(client);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    ResetAllPlayers();
}

public void Event_PlayerStateChanged(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    // 不重置冷却，只清掉按键边沿状态，避免死亡/换队/重生后继承“正在按住 Shift”的旧状态。
    g_bWasHoldingShift[client] = false;
}

public Action OnPlayerRunCmd(
    int client,
    int &buttons,
    int &impulse,
    float vel[3],
    float angles[3],
    int &weapon,
    int &subtype,
    int &cmdnum,
    int &tickcount,
    int &seed,
    int mouse[2]
)
{
    if (client <= 0 || client > MaxClients)
    {
        return Plugin_Continue;
    }

    if (!g_cvEnable.BoolValue)
    {
        g_bWasHoldingShift[client] = false;
        return Plugin_Continue;
    }

    // 本地房主/单人模式专用优化：非 client 1 直接返回。
    if (g_cvOwnerOnly.BoolValue && client != 1)
    {
        return Plugin_Continue;
    }

    bool shiftDown = ((buttons & IN_SPEED) != 0);

    // 最常见路径：没按 Shift。只清边沿状态，不做玩家/物品/状态检查。
    if (!shiftDown)
    {
        g_bWasHoldingShift[client] = false;
        return Plugin_Continue;
    }

    // 长按 Shift 的后续 tick，直接返回。
    if (g_bWasHoldingShift[client])
    {
        return Plugin_Continue;
    }

    // 到这里才代表“Shift 刚按下”。
    g_bWasHoldingShift[client] = true;

    if (!IsValidHumanSurvivor(client))
    {
        return Plugin_Continue;
    }

    TryUseShiftAdrenaline(client);
    return Plugin_Continue;
}

void TryUseShiftAdrenaline(int client)
{
    if (GetAdrenalineTimerOffset() < 0)
    {
        PrintToChat(client, "\x04[Shift肾上腺素]\x01 触发失败：无法找到肾上腺素状态属性。");
        LogError("[Shift Adrenaline] Could not find CTerrorPlayer::m_bAdrenalineActive.");
        return;
    }

    bool hasAdrenalineNow = HasAdrenalineActive(client);

    /*
     * 有针/药 + 当前没有肾上腺素状态时，无视冷却直接使用。
     * 成功后刷新冷却为：现在 + l4d2_shift_adrenaline_cooldown。
     */
    if (g_cvConsumeCarried.BoolValue && !hasAdrenalineNow)
    {
        int itemEntity = -1;
        CarriedItemType itemType = GetCarriedItemType(client, itemEntity);

        if (itemType == Item_Adrenaline)
        {
            float originalDuration = GetOriginalAdrenalineDuration();

            if (!ConsumeCarriedItem(client, itemEntity))
            {
                PrintToChat(client, "\x04[Shift肾上腺素]\x01 检测到肾上腺素针，但消耗失败。");
                return;
            }

            SetAdrenalineDuration(client, originalDuration);
            RefreshCooldown(client);

            PrintToChat(
                client,
                "\x04[Shift肾上腺素]\x01 已消耗肾上腺素针，获得原版 \x05%.1f\x01 秒效果；冷却刷新为 \x05%.0f\x01 秒。",
                originalDuration,
                g_cvCooldown.FloatValue
            );

            return;
        }

        if (itemType == Item_Pills)
        {
            if (!CanGainPainPillsHealth(client))
            {
                PrintToChat(client, "\x04[Shift肾上腺素]\x01 当前血量已接近上限，未自动消耗止痛药。");
                return;
            }

            if (!ConsumeCarriedItem(client, itemEntity))
            {
                PrintToChat(client, "\x04[Shift肾上腺素]\x01 检测到止痛药，但消耗失败。");
                return;
            }

            ApplyPainPillsHealth(client);

            float pillsDuration = g_cvPillsAdrenalineDuration.FloatValue;
            SetAdrenalineDuration(client, pillsDuration);
            RefreshCooldown(client);

            PrintToChat(
                client,
                "\x04[Shift肾上腺素]\x01 已自动吃止痛药，获得原版临时血量和 \x05%.1f\x01 秒肾上腺素；冷却刷新为 \x05%.0f\x01 秒。",
                pillsDuration,
                g_cvCooldown.FloatValue
            );

            return;
        }
    }

    // 不满足“可直接使用针/药”时，才按普通 Shift 技能冷却处理。
    float now = GetGameTime();
    float readyTime = g_fNextUseTime[client];

    if (readyTime > now)
    {
        int remain = RoundToCeil(readyTime - now);
        PrintToChat(client, "\x04[Shift肾上腺素]\x01 冷却中，还剩 \x05%d\x01 秒。", remain);
        return;
    }

    // 冷却好了，但已经处于肾上腺素状态，则不给普通 3 秒，也不刷新冷却。
    if (hasAdrenalineNow)
    {
        float remain = GetAdrenalineRemaining(client);
        PrintToChat(client, "\x04[Shift肾上腺素]\x01 你已经有肾上腺素效果，剩余约 \x05%.1f\x01 秒，不再给予普通 3 秒效果。", remain);
        return;
    }

    // 普通情况：没有针、没有药、没有肾上腺素状态、冷却已好。
    float shortDuration = g_cvShortDuration.FloatValue;
    SetAdrenalineDuration(client, shortDuration);
    RefreshCooldown(client);

    PrintToChat(client, "\x04[Shift肾上腺素]\x01 已触发普通效果，持续 \x05%.1f\x01 秒。", shortDuration);
}

bool IsValidHumanSurvivor(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return false;
    }

    if (!IsClientInGame(client))
    {
        return false;
    }

    if (IsFakeClient(client))
    {
        return false;
    }

    if (GetClientTeam(client) != TEAM_SURVIVOR)
    {
        return false;
    }

    if (!IsPlayerAlive(client))
    {
        return false;
    }

    return true;
}

void ResetClient(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_fNextUseTime[client] = 0.0;
    g_bWasHoldingShift[client] = false;
}

void ResetAllPlayers()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClient(i);
    }
}

void RefreshCooldown(int client)
{
    // 这是刷新/重设为固定倒计时，不是在旧冷却上叠加。
    g_fNextUseTime[client] = GetGameTime() + g_cvCooldown.FloatValue;
}

CarriedItemType GetCarriedItemType(int client, int &entity)
{
    entity = GetPlayerWeaponSlot(client, L4D2_SLOT_PILLS_ADRENALINE);
    if (entity == -1)
    {
        return Item_None;
    }

    if (!IsValidEntity(entity))
    {
        entity = -1;
        return Item_None;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (StrEqual(classname, "weapon_adrenaline", false))
    {
        return Item_Adrenaline;
    }

    if (StrEqual(classname, "weapon_pain_pills", false))
    {
        return Item_Pills;
    }

    entity = -1;
    return Item_None;
}

bool ConsumeCarriedItem(int client, int entity)
{
    if (entity == -1 || !IsValidEntity(entity))
    {
        return false;
    }

    if (!RemovePlayerItem(client, entity))
    {
        return false;
    }

    AcceptEntityInput(entity, "Kill");
    return true;
}

float GetOriginalAdrenalineDuration()
{
    if (g_cvGameAdrenalineDuration != null)
    {
        float value = g_cvGameAdrenalineDuration.FloatValue;
        if (value > 0.0)
        {
            return value;
        }
    }

    return FALLBACK_ORIGINAL_ADRENALINE_DURATION;
}

float GetPainPillsHealthValue()
{
    if (g_cvPainPillsHealthValue != null)
    {
        float value = g_cvPainPillsHealthValue.FloatValue;
        if (value > 0.0)
        {
            return value;
        }
    }

    return FALLBACK_PILLS_HEALTH_VALUE;
}

float GetPainPillsDecayRate()
{
    if (g_cvPainPillsDecayRate != null)
    {
        float value = g_cvPainPillsDecayRate.FloatValue;
        if (value >= 0.0)
        {
            return value;
        }
    }

    return FALLBACK_PILLS_DECAY_RATE;
}

int GetSurvivorMaxHealth(int client)
{
    static int s_iMaxHealthOffset = -2;

    if (s_iMaxHealthOffset == -2)
    {
        s_iMaxHealthOffset = FindSendPropInfo("CTerrorPlayer", "m_iMaxHealth");
    }

    if (s_iMaxHealthOffset >= 0)
    {
        int maxHealth = GetEntProp(client, Prop_Send, "m_iMaxHealth");
        if (maxHealth > 0)
        {
            return maxHealth;
        }
    }

    return FALLBACK_SURVIVOR_MAX_HEALTH;
}

float GetCurrentTempHealth(int client)
{
    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    if (buffer <= 0.0)
    {
        return 0.0;
    }

    float bufferTime = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float decayRate = GetPainPillsDecayRate();
    float temp = buffer - ((GetGameTime() - bufferTime) * decayRate);

    if (temp <= 0.0)
    {
        return 0.0;
    }

    return temp;
}

bool CanGainPainPillsHealth(int client)
{
    int permanentHealth = GetClientHealth(client);
    int maxHealth = GetSurvivorMaxHealth(client);

    float currentTemp = GetCurrentTempHealth(client);
    float maxAllowedTemp = float(maxHealth - permanentHealth);

    if (maxAllowedTemp <= 0.0)
    {
        return false;
    }

    return (currentTemp < maxAllowedTemp - 0.01);
}

void ApplyPainPillsHealth(int client)
{
    int permanentHealth = GetClientHealth(client);
    int maxHealth = GetSurvivorMaxHealth(client);

    float currentTemp = GetCurrentTempHealth(client);
    float addTemp = GetPainPillsHealthValue();
    float maxAllowedTemp = float(maxHealth - permanentHealth);

    if (maxAllowedTemp <= 0.0)
    {
        return;
    }

    float newTemp = currentTemp + addTemp;
    if (newTemp > maxAllowedTemp)
    {
        newTemp = maxAllowedTemp;
    }

    if (newTemp < 0.0)
    {
        newTemp = 0.0;
    }

    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", newTemp);
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}

bool HasAdrenalineActive(int client)
{
    if (GetEntProp(client, Prop_Send, "m_bAdrenalineActive") == 0)
    {
        return false;
    }

    if (GetAdrenalineRemaining(client) <= 0.0)
    {
        return false;
    }

    return true;
}

void SetAdrenalineDuration(int client, float duration)
{
    int timerOffset = GetAdrenalineTimerOffset();
    if (timerOffset < 0)
    {
        return;
    }

    SetEntDataFloat(client, timerOffset + 4, duration);
    SetEntDataFloat(client, timerOffset + 8, GetGameTime() + duration);
    SetEntProp(client, Prop_Send, "m_bAdrenalineActive", (duration > 0.0) ? 1 : 0, 1);
}

float GetAdrenalineRemaining(int client)
{
    int timerOffset = GetAdrenalineTimerOffset();
    if (timerOffset < 0)
    {
        return 0.0;
    }

    if (GetEntProp(client, Prop_Send, "m_bAdrenalineActive") == 0)
    {
        return 0.0;
    }

    float endTime = GetEntDataFloat(client, timerOffset + 8);
    float remain = endTime - GetGameTime();

    if (remain <= 0.0)
    {
        return 0.0;
    }

    return remain;
}

int GetAdrenalineTimerOffset()
{
    static int s_iTimerOffset = -2;

    if (s_iTimerOffset == -2)
    {
        int activeOffset = FindSendPropInfo("CTerrorPlayer", "m_bAdrenalineActive");

        if (activeOffset == -1)
        {
            s_iTimerOffset = -1;
        }
        else
        {
            s_iTimerOffset = activeOffset - 12;
        }
    }

    return s_iTimerOffset;
}
