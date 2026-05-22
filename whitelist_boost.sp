/*
 * 本文件：L4D2 白名单武器“子弹加速 + 无限子弹 + 击杀特感减冷却”（按键 X）
 *
 * 功能概述
 * - 按 X 开/关白名单武器加速与无限子弹。
 * - 支持两种模式：
 *   1) 全程加速模式（Continuous）：按一次 X 开启；再按一次 X 关闭；无持续时间/无冷却。
 *   2) 时间限制模式（Timed）：按一次 X 开启；持续 sm_wlboost_duration 秒；随后进入冷却 sm_wlboost_cooldown 秒。
 * - 永久监听玩家击杀特感事件：
 *   - 击杀 1 个普通特感（Smoker / Boomer / Hunter / Spitter / Jockey / Charger），减少自身冷却 0.5 秒
 *     （默认值可由 sm_wlboost_killreduce 调整）。
 *   - 击杀 Tank，立刻恢复自身冷却（直接可用）。
 *   - 该监听对本地多人房间/监听服中的所有玩家都生效；谁击杀，谁减自己的冷却。
 *
 * 模式切换
 * - 指令：sm_wlboost_mode [0/1]
 *   0 = 时间限制模式
 *   1 = 全程加速模式
 *   无参数 = 在 0/1 间切换
 *
 * 触发按键
 * - bind x "+wl_boost"
 *
 * 白名单读取（文件）
 * - 路径：addons/sourcemod/configs/wlboost_whitelist.txt
 * - 每行 1 个武器 classname（例如 weapon_smg）
 * - 允许写 weapon_smg.txt，会自动去掉 .txt
 * - 支持行内注释 //，以及整行注释 # 或 ;
 * - 若文件不存在或为空，则使用内置默认白名单
 *
 * 资源/安全
 * - 所有 CreateTimer 句柄按玩家维度保存，并在提前关闭/切换模式/断开连接/插件结束/插件禁用时显式 delete
 * - PostThink Hook 仅在“加速开启期间”存在；关闭/到期立即 Unhook
 * - 实体索引缓存使用 EntRef 校验；地图开始会清空缓存，避免索引复用导致误判
 * - 击杀减冷却后会重建冷却提示计时器，保证提示时间与实际剩余冷却一致
 *
 * 依赖
 * - SourceMod 1.12+
 * - SDKHooks
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo =
{
    name        = "L4D2 WL Boost + InfAmmo + KillReduceCD (Key X) - ToggleMode",
    author      = "me",
    description = "按 X 切换白名单加速(每帧clamp)+无限子弹；支持模式切换；击杀特感减冷却；支持文件白名单",
    version     = "3.1.0",
    url         = ""
};

/* ========================= CVAR 参数 ========================= */
ConVar g_cvEnable;         // 总开关
ConVar g_cvTeam;           // 生效队伍（2=生还者）

ConVar g_cvScale;          // 剩余时间缩放（越小越快）
ConVar g_cvDuration;       // 持续时间（秒）
ConVar g_cvCooldown;       // 冷却时间（秒）

ConVar g_cvRefundPerShot;  // 每次开火补弹匣几发（默认 1）
ConVar g_cvKillReduce;     // 击杀普通特感减少冷却秒数（默认 0.5）

/* ========================= 状态（玩家维度） ========================= */
bool   g_bModeContinuous[MAXPLAYERS + 1]; // true=全程加速；false=时间限制
bool   g_bBoostEnabled[MAXPLAYERS + 1];   // 当前是否处于“开启状态”（两种模式共享）

float  g_fBoostUntil[MAXPLAYERS + 1];     // 时间限制模式：结束时刻
float  g_fNextReady[MAXPLAYERS + 1];      // 时间限制模式：下次可用时刻

Handle g_hReadyTimer[MAXPLAYERS + 1];     // 冷却完成提示计时器
Handle g_hEndTimer[MAXPLAYERS + 1];       // 时间限制模式：到期自动关闭

bool   g_bThinkHooked[MAXPLAYERS + 1];    // 是否已 Hook PostThink

/* ========================= 白名单（StringMap） ========================= */
StringMap g_WeaponWL;

/* ========================= 武器实体缓存（EntRef 校验） ========================= */
#define MAX_EDICTS 2048
bool g_bWepCached[MAX_EDICTS + 1];
bool g_bWepAllowed[MAX_EDICTS + 1];
int  g_iWepEntRef[MAX_EDICTS + 1];

bool g_bReloadCached[MAX_EDICTS + 1];
int  g_iReloadEntRef[MAX_EDICTS + 1];
int  g_offInReloadEnt[MAX_EDICTS + 1];
int  g_offReloadStateEnt[MAX_EDICTS + 1];

/* ========================= 通用清理（防泄露/防残留） ========================= */

void KillClientTimers(int client)
{
    if (g_hReadyTimer[client] != null) { delete g_hReadyTimer[client]; g_hReadyTimer[client] = null; }
    if (g_hEndTimer[client] != null)   { delete g_hEndTimer[client];   g_hEndTimer[client]   = null; }
}

void UnhookClientThink(int client)
{
    if (g_bThinkHooked[client])
    {
        SDKUnhook(client, SDKHook_PostThinkPost, PostThinkClamp);
        g_bThinkHooked[client] = false;
    }
}

/* 只关闭“加速开启状态”，保留时间限制模式下的冷却（g_fNextReady）与冷却提示计时器（g_hReadyTimer） */
void StopBoostKeepCooldown(int client)
{
    if (client <= 0 || client > MaxClients) return;

    g_bBoostEnabled[client] = false;
    g_fBoostUntil[client]  = 0.0;

    if (g_hEndTimer[client] != null) { delete g_hEndTimer[client]; g_hEndTimer[client] = null; }

    UnhookClientThink(client);
}

/* 完整重置：关闭加速 + 清空冷却 + 杀死所有计时器 + 解除 Hook */
void ResetClientStateFull(int client)
{
    if (client <= 0 || client > MaxClients) return;

    g_bBoostEnabled[client] = false;
    g_fBoostUntil[client]   = 0.0;
    g_fNextReady[client]    = 0.0;

    KillClientTimers(client);
    UnhookClientThink(client);
}

void ResetAllClientsStateFull()
{
    for (int i = 1; i <= MaxClients; i++)
        ResetClientStateFull(i);
}

void ResetEntityCaches()
{
    for (int i = 0; i <= MAX_EDICTS; i++)
    {
        g_bWepCached[i] = false;
        g_bWepAllowed[i] = false;
        g_iWepEntRef[i] = 0;

        g_bReloadCached[i] = false;
        g_iReloadEntRef[i] = 0;
        g_offInReloadEnt[i] = 0;
        g_offReloadStateEnt[i] = 0;
    }
}

/* ========================= 通用判断 ========================= */

bool IsClientEligibleBase(int client)
{
    if (!g_cvEnable.BoolValue) return false;
    if (client <= 0) return false;
    if (!IsClientInGame(client) || !IsPlayerAlive(client)) return false;
    if (GetClientTeam(client) != g_cvTeam.IntValue) return false;
    return true;
}

bool IsBoostActive(int client, float now)
{
    if (!g_bBoostEnabled[client])
        return false;

    if (g_bModeContinuous[client])
        return true;

    if (now < g_fBoostUntil[client])
        return true;

    /* 自愈：极端情况下（例如计时器未触发/已被清理），过期后强制收敛状态 */
    StopBoostKeepCooldown(client);
    return false;
}

/* ========================= 冷却同步辅助（新增） ========================= */

void RefreshReadyTimer(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (g_hReadyTimer[client] != null)
    {
        delete g_hReadyTimer[client];
        g_hReadyTimer[client] = null;
    }

    if (g_bModeContinuous[client])
        return;

    float now = GetGameTime();
    float remain = g_fNextReady[client] - now;

    if (remain <= 0.0)
    {
        g_fNextReady[client] = 0.0;
        return;
    }

    g_hReadyTimer[client] = CreateTimer(remain, Timer_Ready, client);
}

void ReduceClientCooldown(int client, float seconds)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (!IsClientInGame(client))
        return;
    if (!g_cvEnable.BoolValue)
        return;
    if (g_bModeContinuous[client])
        return;

    float now = GetGameTime();
    if (g_fNextReady[client] <= now)
        return; // 当前没有冷却

    float oldRemain = g_fNextReady[client] - now;
    float newRemain = oldRemain - seconds;

    if (newRemain <= 0.0)
    {
        g_fNextReady[client] = 0.0;
        RefreshReadyTimer(client);
        PrintToChat(client, "[白名单加速] 击杀特感：冷却立即恢复");
        return;
    }

    g_fNextReady[client] = now + newRemain;
    RefreshReadyTimer(client);
    PrintToChat(client, "[白名单加速] 击杀特感：冷却减少 %.1f 秒（剩余 %.1f 秒）", seconds, newRemain);
}

void ResetClientCooldownImmediately(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (!IsClientInGame(client))
        return;
    if (!g_cvEnable.BoolValue)
        return;
    if (g_bModeContinuous[client])
        return;

    float now = GetGameTime();
    if (g_fNextReady[client] <= now)
        return; // 当前没有冷却，无需处理

    g_fNextReady[client] = 0.0;
    RefreshReadyTimer(client);
    PrintToChat(client, "[白名单加速] 击杀 Tank：冷却立即恢复");
}

/* ========================= 监听服映射真人玩家（修复用） ========================= */

int FindAnyHumanClientPreferSurvivor()
{
    int fallback = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        if (GetClientTeam(i) == 2) // 生还者优先
            return i;

        if (fallback == 0)
            fallback = i;
    }
    return fallback;
}

/* ========================= 白名单构建/加载（文件） ========================= */

void BuildWeaponWhitelistDefaults()
{
    if (g_WeaponWL == null)
        g_WeaponWL = new StringMap();
    else
        g_WeaponWL.Clear();

    g_WeaponWL.SetValue("weapon_autoshotgun", 1);
    g_WeaponWL.SetValue("weapon_hunting_rifle", 1);
    //g_WeaponWL.SetValue("weapon_pistol", 1);
    //g_WeaponWL.SetValue("weapon_pistol_magnum", 1);
    g_WeaponWL.SetValue("weapon_pumpshotgun", 1);
    g_WeaponWL.SetValue("weapon_rifle", 1);
    g_WeaponWL.SetValue("weapon_rifle_ak47", 1);
    g_WeaponWL.SetValue("weapon_rifle_desert", 1);
    g_WeaponWL.SetValue("weapon_rifle_m60", 1);
    g_WeaponWL.SetValue("weapon_rifle_sg552", 1);
    g_WeaponWL.SetValue("weapon_shotgun_chrome", 1);
    g_WeaponWL.SetValue("weapon_shotgun_spas", 1);
    g_WeaponWL.SetValue("weapon_smg", 1);
    g_WeaponWL.SetValue("weapon_smg_mp5", 1);
    g_WeaponWL.SetValue("weapon_smg_silenced", 1);
    g_WeaponWL.SetValue("weapon_sniper_awp", 1);
    g_WeaponWL.SetValue("weapon_sniper_military", 1);
    g_WeaponWL.SetValue("weapon_sniper_scout", 1);
}

void NormalizeWeaponName(char[] s, int maxlen)
{
    TrimString(s);
    if (s[0] == '\0') return;

    /* 兼容 weapon_xxx.txt 写法 */
    int len = strlen(s);
    if (len > 4
        && s[len - 4] == '.'
        && (s[len - 3] == 't' || s[len - 3] == 'T')
        && (s[len - 2] == 'x' || s[len - 2] == 'X')
        && (s[len - 1] == 't' || s[len - 1] == 'T'))
    {
        s[len - 4] = '\0';
        TrimString(s);
    }
}

bool LoadWeaponWhitelistFromFile()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/wlboost_whitelist.txt");

    File f = OpenFile(path, "r");
    if (f == null)
        return false;

    if (g_WeaponWL == null)
        g_WeaponWL = new StringMap();
    else
        g_WeaponWL.Clear();

    char line[256];
    int  count = 0;

    while (!f.EndOfFile() && f.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0')
            continue;

        /* 整行注释 */
        if (line[0] == '#' || line[0] == ';')
            continue;

        /* 行内注释 // */
        int cpos = StrContains(line, "//", false);
        if (cpos == 0)
            continue;
        else if (cpos > 0)
        {
            line[cpos] = '\0';
            TrimString(line);
            if (line[0] == '\0')
                continue;
        }

        NormalizeWeaponName(line, sizeof(line));
        if (line[0] == '\0')
            continue;

        g_WeaponWL.SetValue(line, 1);
        count++;
    }

    delete f;

    if (count <= 0)
        return false;

    return true;
}

void BuildWeaponWhitelist()
{
    bool ok = LoadWeaponWhitelistFromFile();
    if (!ok)
        BuildWeaponWhitelistDefaults();

    ResetEntityCaches();
}

/* 白名单查询（带实体缓存） */
bool IsWeaponWhitelistedCached(int wep)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;
    if (wep < 0 || wep > MAX_EDICTS) return false;

    int ref = EntIndexToEntRef(wep);

    if (g_bWepCached[wep] && g_iWepEntRef[wep] == ref)
        return g_bWepAllowed[wep];

    char cls[64];
    bool allowed = false;

    if (GetEntityClassname(wep, cls, sizeof(cls)) && g_WeaponWL != null)
    {
        int dummy;
        allowed = g_WeaponWL.GetValue(cls, dummy);
    }

    g_bWepCached[wep]  = true;
    g_iWepEntRef[wep]  = ref;
    g_bWepAllowed[wep] = allowed;

    return allowed;
}

/* 换弹判断（offset 惰性缓存） */
bool IsReloading(int wep)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;
    if (wep < 0 || wep > MAX_EDICTS) return false;

    int ref = EntIndexToEntRef(wep);

    if (!g_bReloadCached[wep] || g_iReloadEntRef[wep] != ref)
    {
        g_offInReloadEnt[wep]     = GetEntSendPropOffs(wep, "m_bInReload");
        g_offReloadStateEnt[wep]  = GetEntSendPropOffs(wep, "m_reloadState");

        g_bReloadCached[wep] = true;
        g_iReloadEntRef[wep] = ref;
    }

    int offIn = g_offInReloadEnt[wep];
    if (offIn != -1 && GetEntData(wep, offIn, 1) != 0)
        return true;

    int offState = g_offReloadStateEnt[wep];
    if (offState != -1 && GetEntData(wep, offState, 4) != 0)
        return true;

    return false;
}

/* 只缩短未来时间，不延长 */
stock void ClampFutureTimeNonExtend(int ent, const char[] prop, float now, float scale, float minRemain = 0.0)
{
    float t = GetEntPropFloat(ent, Prop_Send, prop);
    if (t <= now) return;

    float rem    = t - now;
    float target = rem * scale;

    if (target < minRemain) target = minRemain;
    if (target >= rem - 0.001) return;

    SetEntPropFloat(ent, Prop_Send, prop, now + target);
}

/* ========================= 冷却提示/到期结束 ========================= */

public Action Timer_Ready(Handle timer, any client)
{
    if (client <= 0 || client > MaxClients) return Plugin_Stop;
    g_hReadyTimer[client] = null;

    if (!IsClientInGame(client)) return Plugin_Stop;
    if (!g_cvEnable.BoolValue) return Plugin_Stop;

    float now = GetGameTime();
    if (now >= g_fNextReady[client])
        PrintToChat(client, "[白名单加速] 冷却完成");

    return Plugin_Stop;
}

public Action Timer_EndBoost(Handle timer, any client)
{
    if (client <= 0 || client > MaxClients) return Plugin_Stop;
    g_hEndTimer[client] = null;

    if (!IsClientInGame(client)) return Plugin_Stop;

    /* 时间限制模式到期：关闭加速，但保留冷却 */
    StopBoostKeepCooldown(client);
    return Plugin_Stop;
}

/* ========================= 模式切换指令 ========================= */

void PrintModeStatus(int client)
{
    if (client <= 0) return;

    if (g_bModeContinuous[client])
    {
        PrintToChat(client, "[白名单加速] 当前模式：全程加速（按 X 开/关；无倒计时/无冷却）");
    }
    else
    {
        PrintToChat(client, "[白名单加速] 当前模式：时间限制（持续 %.1f 秒，冷却 %.1f 秒；击杀特感可减冷却）",
            g_cvDuration.FloatValue, g_cvCooldown.FloatValue);
    }
}

public Action Cmd_WLBoostMode(int client, int args)
{
    if (client <= 0)
    {
        if (IsDedicatedServer())
        {
            PrintToServer("[白名单加速] sm_wlboost_mode 为玩家指令：0=时间限制, 1=全程加速");
            return Plugin_Handled;
        }

        int mapped = FindAnyHumanClientPreferSurvivor();
        if (mapped == 0)
            return Plugin_Handled;

        client = mapped;
    }

    if (!IsClientInGame(client))
        return Plugin_Handled;

    bool target;
    bool hasTarget = false;

    if (args >= 1)
    {
        char sArg[16];
        GetCmdArg(1, sArg, sizeof(sArg));
        target = (StringToInt(sArg) != 0);
        hasTarget = true;
    }

    bool newMode = hasTarget ? target : !g_bModeContinuous[client];

    if (newMode != g_bModeContinuous[client])
    {
        /* 切换模式时：强制清理玩家全部状态（含倒计时/冷却） */
        ResetClientStateFull(client);
        g_bModeContinuous[client] = newMode;
    }

    PrintModeStatus(client);
    return Plugin_Handled;
}

/* ========================= 触发命令（X，按键开/关） ========================= */

public Action Cmd_WLBoost(int client, int args)
{
    if (client <= 0)
    {
        if (IsDedicatedServer())
            return Plugin_Handled;

        int mapped = FindAnyHumanClientPreferSurvivor();
        if (mapped == 0)
            return Plugin_Handled;

        client = mapped;
    }

    if (!IsClientInGame(client)) return Plugin_Handled;
    if (!g_cvEnable.BoolValue)   return Plugin_Handled;

    /* 已开启时：全程模式允许关闭；时间限制模式不允许关闭 */
    if (g_bBoostEnabled[client])
    {
        if (g_bModeContinuous[client])
        {
            StopBoostKeepCooldown(client);
            PrintToChat(client, "[白名单加速] 已关闭");
        }
        else
        {
            float now = GetGameTime();
            float left = g_fBoostUntil[client] - now;
            if (left < 0.0) left = 0.0;
            PrintToChat(client, "[白名单加速] 时间限制模式进行中：剩余 %.1f 秒", left);
            /* 不关闭，不重置计时器，不进入冷却 */
        }
        return Plugin_Handled;
    }

    /* 尝试开启 */
    if (!IsPlayerAlive(client))
    {
        PrintToChat(client, "[白名单加速] 开启失败：你已死亡");
        return Plugin_Handled;
    }

    if (GetClientTeam(client) != g_cvTeam.IntValue)
    {
        PrintToChat(client, "[白名单加速] 开启失败：队伍不符合");
        return Plugin_Handled;
    }

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsWeaponWhitelistedCached(wep))
    {
        PrintToChat(client, "[白名单加速] 开启失败：当前武器不在白名单");
        return Plugin_Handled;
    }

    if (IsReloading(wep))
    {
        PrintToChat(client, "[白名单加速] 开启失败：换弹中无法开启");
        return Plugin_Handled;
    }

    float now = GetGameTime();

    if (!g_bModeContinuous[client])
    {
        /* 时间限制模式：检查冷却 */
        if (now < g_fNextReady[client])
        {
            PrintToChat(client, "[白名单加速] 冷却中：%.1f 秒", g_fNextReady[client] - now);
            return Plugin_Handled;
        }

        float duration = g_cvDuration.FloatValue;
        float cd       = g_cvCooldown.FloatValue;
        float scale    = g_cvScale.FloatValue;

        g_bBoostEnabled[client] = true;
        g_fBoostUntil[client]   = now + duration;
        g_fNextReady[client]    = now + cd;

        PrintToChat(client, "[白名单加速] 已开启：持续 %.1f 秒（scale=%.3f）+无限子弹；击杀特感可减冷却；冷却 %.1f 秒", duration, scale, cd);

        /* 冷却提示计时器 */
        RefreshReadyTimer(client);

        /* 到期自动关闭 */
        if (g_hEndTimer[client] != null) { delete g_hEndTimer[client]; g_hEndTimer[client] = null; }
        g_hEndTimer[client] = CreateTimer(duration, Timer_EndBoost, client);
    }
    else
    {
        /* 全程模式：不创建任何倒计时/冷却 */
        g_bBoostEnabled[client] = true;
        g_fBoostUntil[client]   = 0.0;
        g_fNextReady[client]    = 0.0;

        /* 全程模式下也确保没有倒计时残留 */
        KillClientTimers(client);

        PrintToChat(client, "[白名单加速] 已开启：全程模式（scale=%.3f）+无限子弹；按 X 关闭", g_cvScale.FloatValue);
    }

    /* 开启期间挂 PostThink（两种模式一致） */
    if (!g_bThinkHooked[client])
    {
        SDKHook(client, SDKHook_PostThinkPost, PostThinkClamp);
        g_bThinkHooked[client] = true;
    }

    return Plugin_Handled;
}

public Action Cmd_WLBoostStop(int client, int args)
{
    /* bind x "+wl_boost" 会在松开触发 -wl_boost；本插件使用“按下切换”，松开应当无动作 */
    return Plugin_Handled;
}

/* ========================= 每帧加速 ========================= */

public void PostThinkClamp(int client)
{
    if (!IsClientEligibleBase(client))
        return;

    float now = GetGameTime();

    if (!IsBoostActive(client, now))
    {
        /* 非激活状态：保险收敛 */
        UnhookClientThink(client);
        return;
    }

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsWeaponWhitelistedCached(wep))
        return;

    if (IsReloading(wep))
        return;

    float scale = g_cvScale.FloatValue;

    ClampFutureTimeNonExtend(client, "m_flNextAttack", now, scale, 0.0);
    ClampFutureTimeNonExtend(wep,    "m_flNextPrimaryAttack",   now, scale, 0.0);
    ClampFutureTimeNonExtend(wep,    "m_flNextSecondaryAttack", now, scale, 0.0);
}

/* ========================= 无限子弹：开火事件补弹匣 ========================= */

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsClientEligibleBase(client))
        return;

    float now = GetGameTime();
    if (!IsBoostActive(client, now))
        return;

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsWeaponWhitelistedCached(wep))
        return;

    if (IsReloading(wep))
        return;

    int add = g_cvRefundPerShot.IntValue;
    if (add <= 0)
        return;

    int clip = GetEntProp(wep, Prop_Send, "m_iClip1");
    if (clip < 0)
        return;

    SetEntProp(wep, Prop_Send, "m_iClip1", clip + add);
}

/* ========================= 击杀特感减冷却（新增） ========================= */

bool IsTrackedSpecialInfectedVictim(int victim, bool &isTank)
{
    isTank = false;

    if (victim <= 0 || victim > MaxClients)
        return false;
    if (!IsClientInGame(victim))
        return false;
    if (GetClientTeam(victim) != 3)
        return false;

    int zclass = GetEntProp(victim, Prop_Send, "m_zombieClass");

    switch (zclass)
    {
        case 1, 2, 3, 4, 5, 6:
        {
            return true; // smoker, boomer, hunter, spitter, jockey, charger
        }
        case 8:
        {
            isTank = true;
            return true;
        }
    }

    return false;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsClientEligibleBase(attacker))
        return;

    bool isTank = false;
    if (!IsTrackedSpecialInfectedVictim(victim, isTank))
        return;

    if (isTank)
    {
        ResetClientCooldownImmediately(attacker);
        return;
    }

    float reduce = g_cvKillReduce.FloatValue;
    if (reduce <= 0.0)
        return;

    ReduceClientCooldown(attacker, reduce);
}

/* ========================= 生命周期 ========================= */

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!convar.BoolValue)
    {
        ResetAllClientsStateFull();
    }
}

public void OnPluginStart()
{
    g_cvEnable        = CreateConVar("sm_wlboost_enable",     "1",    "是否启用插件(1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTeam          = CreateConVar("sm_wlboost_team",       "2",    "生效队伍(2=生还者)", FCVAR_NOTIFY, true, 0.0, true, 3.0);

    g_cvScale         = CreateConVar("sm_wlboost_scale",      "0.25", "剩余时间缩放(越小越快)", FCVAR_NOTIFY, true, 0.05, true, 1.0);
    g_cvDuration      = CreateConVar("sm_wlboost_duration",   "3.0",  "时间限制模式：持续时间(秒)", FCVAR_NOTIFY, true, 0.1, true, 60.0);
    g_cvCooldown      = CreateConVar("sm_wlboost_cooldown",   "10.0", "时间限制模式：冷却时间(秒)", FCVAR_NOTIFY, true, 0.1, true, 300.0);

    g_cvRefundPerShot = CreateConVar("sm_wlboost_refund",     "1",    "加速开启期间：每次开火补弹匣发数(clip1)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvKillReduce    = CreateConVar("sm_wlboost_killreduce", "0.5",  "击杀普通特感时减少的冷却秒数", FCVAR_NOTIFY, true, 0.0, true, 30.0);

    HookConVarChange(g_cvEnable, OnEnableChanged);

    AutoExecConfig(true, "plugin_wlboost_keyx_togglemode");

    BuildWeaponWhitelist();

    RegConsoleCmd("sm_wlboost",      Cmd_WLBoost);
    RegConsoleCmd("+wl_boost",       Cmd_WLBoost);
    RegConsoleCmd("-wl_boost",       Cmd_WLBoostStop);
    RegConsoleCmd("sm_wlboost_mode", Cmd_WLBoostMode);

    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_bModeContinuous[i] = false; // 默认：时间限制模式
        g_bBoostEnabled[i]   = false;
        g_fBoostUntil[i]     = 0.0;
        g_fNextReady[i]      = 0.0;
        g_hReadyTimer[i]     = null;
        g_hEndTimer[i]       = null;
        g_bThinkHooked[i]    = false;
    }
}

public void OnMapStart()
{
    ResetEntityCaches();
    BuildWeaponWhitelist();
}

public void OnClientPutInServer(int client)
{
    ResetClientStateFull(client);
    /* g_bModeContinuous[client] = false; */
}

public void OnClientDisconnect(int client)
{
    ResetClientStateFull(client);
}

public void OnPluginEnd()
{
    ResetAllClientsStateFull();

    if (g_WeaponWL != null)
    {
        delete g_WeaponWL;
        g_WeaponWL = null;
    }
}
