/*
 * 文件名：meleeboost_pistol_infammo_killreduce.sp
 *
 * 简介：
 * - L4D2 SourceMod 插件：保留原有 Z 键近战加速逻辑，并新增手枪/马格南独立加速与无限子弹分支。
 * - 近战分支：沿用原来的 0.1 秒检测、肾上腺素优先、模式切换、移速提升逻辑。
 * - 手枪分支：检测当前武器是否为 weapon_pistol 或 weapon_pistol_magnum；按 Z 触发后持续 3 秒、冷却 10 秒；
 *   监听 weapon_fire 事件，在玩家开枪后一帧缩短下一次开枪间隔，并补回弹匣，实现加速期无限子弹。
 *   该逻辑不使用近战 0.1 秒循环检测，避免给手枪分支增加高频负担。
 * - 击杀特感减冷却：参考 whitelistboost，击杀普通特感减少冷却，击杀 Tank 立即恢复冷却；近战和手枪冷却都会处理。
 *
 * 使用方法：
 * 1. 保存为 addons/sourcemod/scripting/meleeboost_pistol_infammo_killreduce.sp
 * 2. 用 SourceMod spcomp 编译，生成 .smx 后放入 addons/sourcemod/plugins/
 * 3. 游戏内绑定按键：bind z "+melee_boost"
 * 4. 近战模式切换：sm_meleeboost_mode [0/1]
 *    - 0 = 原时间限制模式
 *    - 1 = 原全程模式
 * 5. 手枪/马格南分支独立于近战模式，默认：
 *    - sm_meleeboost_pistol_duration 3.0
 *    - sm_meleeboost_pistol_cooldown 10.0
 * 6. 手枪/马格南无限子弹默认开启：
 *    - sm_meleeboost_pistol_infammo 1
 *    - sm_meleeboost_pistol_refund 1
 * 7. 击杀普通特感减冷却默认：
 *    - sm_meleeboost_killreduce 0.5
 *
 * 依赖：
 * - SourceMod 1.12+
 * - SDKTools
 */

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name        = "L4D2 Melee Boost + Pistol Shot Boost + InfAmmo + KillReduceCD",
    author      = "me",
    description = "Z键近战加速；手枪/马格南开火后缩短下次开火间隔并补弹匣；击杀特感减冷却；严格清理计时器",
    version     = "2.3.0",
    url         = ""
};

/* ========================= CVAR ========================= */
ConVar g_cvEnable;
ConVar g_cvTeam;
ConVar g_cvScale;
ConVar g_cvDuration;        // 近战时间限制模式：非肾上腺素持续时间
ConVar g_cvCooldown;        // 近战时间限制模式：冷却
ConVar g_cvTick;            // 近战检测间隔（默认 0.1）
ConVar g_cvMoveScale;       // 近战加速期间移速倍率（默认 2.0）
ConVar g_cvCooldownNotify;
ConVar g_cvKillReduce;      // 击杀普通特感减少冷却秒数（默认 0.5）

ConVar g_cvPistolDuration;  // 手枪/马格南加速持续时间（默认 3）
ConVar g_cvPistolCooldown;  // 手枪/马格南加速冷却（默认 10）
ConVar g_cvPistolInfAmmo;   // 手枪/马格南加速期间是否无限子弹（默认 1）
ConVar g_cvPistolRefund;    // 手枪/马格南每次开火补回弹匣发数（默认 1）

/* ========================= 近战状态（玩家维度） ========================= */
bool   g_bModeContinuous[MAXPLAYERS + 1]; // true=全程模式；false=时间限制模式
bool   g_bBoostEnabled[MAXPLAYERS + 1];   // 当前是否处于“近战开启状态”（两种模式共享）

float  g_fBoostUntil[MAXPLAYERS + 1];     // 时间限制模式：非肾上腺素结束时刻
float  g_fNextReady[MAXPLAYERS + 1];      // 时间限制模式：下次可用时刻（冷却截止）
bool   g_bAdrenMode[MAXPLAYERS + 1];      // 时间限制模式：是否处于肾上腺素模式

bool   g_bCooldownReadyNotified[MAXPLAYERS + 1];
Handle g_hBoostTimer[MAXPLAYERS + 1];     // 0.1 秒重复定时器（仅近战开启期间存在）

/* ========================= 手枪/马格南状态（玩家维度，独立于近战） ========================= */
bool   g_bPistolBoostEnabled[MAXPLAYERS + 1];
float  g_fPistolBoostUntil[MAXPLAYERS + 1];
float  g_fPistolNextReady[MAXPLAYERS + 1];
bool   g_bPistolCooldownReadyNotified[MAXPLAYERS + 1];
Handle g_hPistolEndTimer[MAXPLAYERS + 1];

Handle g_hCooldownNotifyTimer = null;

/* ========================= 通用判断 ========================= */

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

/* 手枪白名单检测：只允许普通手枪与马格南 */
bool IsPistolBoostWeapon(int wep)
{
    if (wep <= MaxClients || !IsValidEdict(wep)) return false;

    char cls[64];
    if (!GetEntityClassname(wep, cls, sizeof(cls))) return false;

    return StrEqual(cls, "weapon_pistol", false)
        || StrEqual(cls, "weapon_pistol_magnum", false);
}

/* 肾上腺素状态 */
bool IsAdrenalineActive(int client)
{
    static int offs = -2; // -2=未初始化
    if (offs == -2)
        offs = GetEntSendPropOffs(client, "m_bAdrenalineActive");

    if (offs == -1) return false;
    return view_as<bool>(GetEntData(client, offs, 1));
}

/* 只缩短未来时间，不延长 */
stock void ClampFutureTimeNonExtend(int ent, const char[] prop, float now, float scale)
{
    float t = GetEntPropFloat(ent, Prop_Send, prop);
    if (t <= now) return;

    float rem = t - now;
    float target = rem * scale;

    if (target >= rem - 0.001) return;
    SetEntPropFloat(ent, Prop_Send, prop, now + target);
}

bool IsOnGround(int client)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || !IsPlayerAlive(client)) return false;

    return GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1;
}

void ApplyMoveSpeedBoostSmart(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (!IsClientInGame(client) || !IsPlayerAlive(client)) return;

    float scale = g_cvMoveScale.FloatValue;
    if (scale < 0.01) scale = 0.01;

    // 地面：直接使用 LaggedMovementValue
    if (IsOnGround(client))
    {
        SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", scale);
        return;
    }

    // 空中：只保留水平速度，不改 Z 轴
    float current = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
    if (current != 1.0)
    {
        float vVec[3];
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", vVec);

        float z = vVec[2];

        ScaleVector(vVec, current);
        vVec[2] = z;   // 保持竖直速度不变

        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vVec);
    }

    // 空中不要继续保留全局移速倍率，否则会连空中运动一起放大
    SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", 1.0);
}

void ClearMoveSpeedBoost(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (!IsClientInGame(client)) return;

    SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", 1.0);
}

/* ========================= 清理/重置（防泄露） ========================= */

void KillClientTimer(int client)
{
    if (g_hBoostTimer[client] != null)
    {
        delete g_hBoostTimer[client];
        g_hBoostTimer[client] = null;
    }
}

void KillPistolEndTimer(int client)
{
    if (g_hPistolEndTimer[client] != null)
    {
        delete g_hPistolEndTimer[client];
        g_hPistolEndTimer[client] = null;
    }
}

void StopBoost_NoCooldown(int client)
{
    // 用于近战全程模式：关闭不引入冷却
    KillClientTimer(client);
    g_bBoostEnabled[client] = false;
    g_bAdrenMode[client] = false;
    g_fBoostUntil[client] = 0.0;
    ClearMoveSpeedBoost(client);
}

void StopPistolBoostKeepCooldown(int client)
{
    if (client <= 0 || client > MaxClients) return;

    KillPistolEndTimer(client);
    g_bPistolBoostEnabled[client] = false;
    g_fPistolBoostUntil[client] = 0.0;
}

void ResetClientRuntime(int client)
{
    // 换关/断开/禁用：清理计时器与运行状态，不重置玩家模式
    KillClientTimer(client);
    KillPistolEndTimer(client);

    g_bBoostEnabled[client] = false;
    g_bAdrenMode[client] = false;
    g_fBoostUntil[client] = 0.0;
    g_fNextReady[client] = 0.0;
    g_bCooldownReadyNotified[client] = true;

    g_bPistolBoostEnabled[client] = false;
    g_fPistolBoostUntil[client] = 0.0;
    g_fPistolNextReady[client] = 0.0;
    g_bPistolCooldownReadyNotified[client] = true;

    ClearMoveSpeedBoost(client);
}

void ResetAllClientsRuntime()
{
    for (int i = 1; i <= MaxClients; i++)
        ResetClientRuntime(i);
}

/* ========================= 监听服 client=0 映射真人玩家 ========================= */

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

/* ========================= 冷却辅助：击杀特感减冷却 ========================= */

bool ReduceMeleeCooldown(int client, float seconds)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (!g_cvEnable.BoolValue) return false;
    if (g_bModeContinuous[client]) return false;

    float now = GetGameTime();
    if (g_fNextReady[client] <= now)
        return false;

    float oldRemain = g_fNextReady[client] - now;
    float newRemain = oldRemain - seconds;

    if (newRemain <= 0.0)
    {
        g_fNextReady[client] = 0.0;
        g_bCooldownReadyNotified[client] = true;
        PrintToChat(client, "[近战加速] 击杀特感：近战冷却立即恢复");
        return true;
    }

    g_fNextReady[client] = now + newRemain;
    g_bCooldownReadyNotified[client] = false;
    PrintToChat(client, "[近战加速] 击杀特感：近战冷却减少 %.1f 秒（剩余 %.1f 秒）", seconds, newRemain);
    return true;
}

bool ReducePistolCooldown(int client, float seconds)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (!g_cvEnable.BoolValue) return false;

    float now = GetGameTime();
    if (g_fPistolNextReady[client] <= now)
        return false;

    float oldRemain = g_fPistolNextReady[client] - now;
    float newRemain = oldRemain - seconds;

    if (newRemain <= 0.0)
    {
        g_fPistolNextReady[client] = 0.0;
        g_bPistolCooldownReadyNotified[client] = true;
        PrintToChat(client, "[近战加速] 击杀特感：手枪加速冷却立即恢复");
        return true;
    }

    g_fPistolNextReady[client] = now + newRemain;
    g_bPistolCooldownReadyNotified[client] = false;
    PrintToChat(client, "[近战加速] 击杀特感：手枪加速冷却减少 %.1f 秒（剩余 %.1f 秒）", seconds, newRemain);
    return true;
}

bool ResetMeleeCooldownImmediately(int client)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (!g_cvEnable.BoolValue) return false;
    if (g_bModeContinuous[client]) return false;

    float now = GetGameTime();
    if (g_fNextReady[client] <= now)
        return false;

    g_fNextReady[client] = 0.0;
    g_bCooldownReadyNotified[client] = true;
    PrintToChat(client, "[近战加速] 击杀 Tank：近战冷却立即恢复");
    return true;
}

bool ResetPistolCooldownImmediately(int client)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (!g_cvEnable.BoolValue) return false;

    float now = GetGameTime();
    if (g_fPistolNextReady[client] <= now)
        return false;

    g_fPistolNextReady[client] = 0.0;
    g_bPistolCooldownReadyNotified[client] = true;
    PrintToChat(client, "[近战加速] 击杀 Tank：手枪加速冷却立即恢复");
    return true;
}

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

/* ========================= 冷却完成提示 ========================= */

public Action Timer_CooldownNotify(Handle timer, any data)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    if (g_cvCooldownNotify != null && !g_cvCooldownNotify.BoolValue)
        return Plugin_Continue;

    float now = GetGameTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        if (GetClientTeam(client) != g_cvTeam.IntValue)
            continue;

        bool meleeReady = false;
        bool pistolReady = false;

        if (!g_bCooldownReadyNotified[client]
            && !g_bBoostEnabled[client]
            && g_fNextReady[client] > 0.0
            && now >= g_fNextReady[client])
        {
            meleeReady = true;
            g_bCooldownReadyNotified[client] = true;
        }

        if (!g_bPistolCooldownReadyNotified[client]
            && !g_bPistolBoostEnabled[client]
            && g_fPistolNextReady[client] > 0.0
            && now >= g_fPistolNextReady[client])
        {
            pistolReady = true;
            g_bPistolCooldownReadyNotified[client] = true;
        }

        if (meleeReady && pistolReady)
            PrintHintText(client, "近战/手枪加速冷却完毕");
        else if (meleeReady)
            PrintHintText(client, "近战加速冷却完毕");
        else if (pistolReady)
            PrintHintText(client, "手枪加速冷却完毕");
    }

    return Plugin_Continue;
}

/* ========================= 近战 0.1 秒定时器（核心 clamp） ========================= */

public Action Timer_MeleeBoost(Handle timer, any client)
{
    if (!IsEligible(client))
    {
        g_hBoostTimer[client] = null;
        g_bBoostEnabled[client] = false;
        g_bAdrenMode[client] = false;
        ClearMoveSpeedBoost(client);
        return Plugin_Stop;
    }

    float now = GetGameTime();
    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

    // 切枪立即取消近战加速
    if (!IsMeleeWeapon(wep))
    {
        g_hBoostTimer[client] = null;
        g_bBoostEnabled[client] = false;

        if (!g_bModeContinuous[client] && g_bAdrenMode[client])
        {
            g_bCooldownReadyNotified[client] = false;
            g_fNextReady[client] = now + g_cvCooldown.FloatValue;
        }

        g_bAdrenMode[client] = false;
        ClearMoveSpeedBoost(client);
        return Plugin_Stop;
    }

    // 智能移速处理：地面维持倍率，空中只保留水平速度，不改 Z 轴
    ApplyMoveSpeedBoostSmart(client);

    // 全程模式
    if (g_bModeContinuous[client])
    {
        float scale = g_cvScale.FloatValue;
        ClampFutureTimeNonExtend(client, "m_flNextAttack", now, scale);
        ClampFutureTimeNonExtend(wep,    "m_flNextPrimaryAttack",   now, scale);
        ClampFutureTimeNonExtend(wep,    "m_flNextSecondaryAttack", now, scale);
        return Plugin_Continue;
    }

    // 时间限制模式
    if (g_bAdrenMode[client])
    {
        if (!IsAdrenalineActive(client))
        {
            g_fNextReady[client] = now + g_cvCooldown.FloatValue;
            g_hBoostTimer[client] = null;
            g_bBoostEnabled[client] = false;
            g_bAdrenMode[client] = false;
            g_bCooldownReadyNotified[client] = false;
            ClearMoveSpeedBoost(client);
            return Plugin_Stop;
        }
    }
    else
    {
        if (now >= g_fBoostUntil[client])
        {
            g_hBoostTimer[client] = null;
            g_bBoostEnabled[client] = false;
            ClearMoveSpeedBoost(client);
            return Plugin_Stop;
        }
    }

    float scale2 = g_cvScale.FloatValue;
    ClampFutureTimeNonExtend(client, "m_flNextAttack", now, scale2);
    ClampFutureTimeNonExtend(wep,    "m_flNextPrimaryAttack",   now, scale2);
    ClampFutureTimeNonExtend(wep,    "m_flNextSecondaryAttack", now, scale2);

    return Plugin_Continue;
}

/* 创建近战计时器（仅在近战开启期间存在） */
void EnsureClientTimer(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (!IsClientInGame(client)) return;

    if (g_hBoostTimer[client] != null)
        return;

    float tick = g_cvTick.FloatValue;
    if (tick < 0.01) tick = 0.01;

    g_hBoostTimer[client] = CreateTimer(tick, Timer_MeleeBoost, client, TIMER_REPEAT);
}

/* ========================= 手枪/马格南无限子弹辅助 ========================= */

bool IsWeaponEntityValid(int wep)
{
    if (wep <= MaxClients)
        return false;

    if (!IsValidEdict(wep))
        return false;

    return true;
}

bool IsWeaponOwnedByClient(int client, int wep)
{
    if (client <= 0 || client > MaxClients)
        return false;

    if (!IsWeaponEntityValid(wep))
        return false;

    int owner = GetEntPropEnt(wep, Prop_Send, "m_hOwnerEntity");
    if (owner == client)
        return true;

    /* 个别情况下 m_hOwnerEntity 取不到，退回 active weapon 判断，避免误杀正常补弹。 */
    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    return active == wep;
}

void RefundPistolClip(int client, int wep)
{
    if (g_cvPistolInfAmmo == null || !g_cvPistolInfAmmo.BoolValue)
        return;

    if (!IsEligible(client))
        return;

    if (!IsWeaponEntityValid(wep))
        return;

    if (!IsPistolBoostWeapon(wep))
        return;

    if (!IsWeaponOwnedByClient(client, wep))
        return;

    int add = g_cvPistolRefund.IntValue;
    if (add <= 0)
        return;

    int clip = GetEntProp(wep, Prop_Send, "m_iClip1");
    if (clip < 0)
        return;

    /*
     * weapon_fire 后延迟一帧执行；通常此时弹匣已经扣除 1 发。
     * 因此补回 sm_meleeboost_pistol_refund 发即可模拟“加速期无限弹匣”。
     * 默认 refund=1，不会主动改大弹匣容量；若玩家把 refund 调高，则允许更激进的补弹。
     */
    SetEntProp(wep, Prop_Send, "m_iClip1", clip + add);
}

/* ========================= 手枪/马格南开火事件加速 ========================= */

bool IsPistolBoostActive(int client, float now)
{
    if (client <= 0 || client > MaxClients)
        return false;

    if (!g_bPistolBoostEnabled[client])
        return false;

    if (now < g_fPistolBoostUntil[client])
        return true;

    StopPistolBoostKeepCooldown(client);
    return false;
}

public Action Timer_PistolEndBoost(Handle timer, any client)
{
    if (client <= 0 || client > MaxClients)
        return Plugin_Stop;

    g_hPistolEndTimer[client] = null;

    if (!IsClientInGame(client))
        return Plugin_Stop;

    g_bPistolBoostEnabled[client] = false;
    g_fPistolBoostUntil[client] = 0.0;
    return Plugin_Stop;
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    if (!IsEligible(client))
        return;

    if (!g_bPistolBoostEnabled[client])
        return;

    float now = GetGameTime();
    if (!IsPistolBoostActive(client, now))
        return;

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsPistolBoostWeapon(wep))
    {
        StopPistolBoostKeepCooldown(client);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(userid);
    pack.WriteCell(EntIndexToEntRef(wep));

    // 延迟一帧：让游戏先扣弹匣并写入 next attack，再补弹匣和缩短下次开火间隔。
    RequestFrame(Frame_ApplyPistolShotBoostAndRefund, pack);
}

public void Frame_ApplyPistolShotBoostAndRefund(any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int wepRef = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (!IsEligible(client))
        return;

    float now = GetGameTime();
    if (!IsPistolBoostActive(client, now))
        return;

    int wep = EntRefToEntIndex(wepRef);
    if (!IsWeaponEntityValid(wep) || !IsPistolBoostWeapon(wep) || !IsWeaponOwnedByClient(client, wep))
    {
        /* 如果开火后一帧发生了极端切枪，退回检查当前武器；当前武器不是白名单则关闭手枪加速。 */
        wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        if (!IsPistolBoostWeapon(wep))
        {
            StopPistolBoostKeepCooldown(client);
            return;
        }
    }

    RefundPistolClip(client, wep);

    float scale = g_cvScale.FloatValue;
    ClampFutureTimeNonExtend(client, "m_flNextAttack", now, scale);
    ClampFutureTimeNonExtend(wep,    "m_flNextPrimaryAttack",   now, scale);
    ClampFutureTimeNonExtend(wep,    "m_flNextSecondaryAttack", now, scale);
}

/* ========================= 模式切换指令 ========================= */

void PrintModeStatus(int client)
{
    if (client <= 0) return;

    if (g_bModeContinuous[client])
    {
        PrintToChat(client, "[近战加速] 当前近战模式：全程模式（按 Z 开/关；无持续/无冷却）。手枪/马格南分支仍为独立 %.1f 秒持续 / %.1f 秒冷却。",
            g_cvPistolDuration.FloatValue, g_cvPistolCooldown.FloatValue);
    }
    else
    {
        PrintToChat(client, "[近战加速] 当前近战模式：时间限制（持续 %.1f 秒；冷却 %.1f 秒；击杀特感可减冷却）。手枪/马格南分支：%.1f 秒持续 / %.1f 秒冷却。",
            g_cvDuration.FloatValue, g_cvCooldown.FloatValue, g_cvPistolDuration.FloatValue, g_cvPistolCooldown.FloatValue);
    }
}

public Action Cmd_MeleeBoostMode(int client, int args)
{
    // 允许服务器控制台（client=0）；监听服映射到任意真人玩家用于“聊天提示”
    if (client <= 0)
    {
        if (IsDedicatedServer())
        {
            PrintToServer("[近战加速] sm_meleeboost_mode [0/1]：0=时间限制，1=全程模式；手枪/马格南分支固定独立倒计时");
            return Plugin_Handled;
        }

        int mapped = FindAnyHumanClientPreferSurvivor();
        if (mapped == 0) return Plugin_Handled;
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
        // 切换近战模式时：清理当前近战与手枪运行状态/冷却，避免状态不一致
        ResetClientRuntime(client);
        g_bModeContinuous[client] = newMode;
    }

    PrintModeStatus(client);
    return Plugin_Handled;
}

/* ========================= 触发命令（Z：近战或手枪/马格南） ========================= */

Action HandleMeleeBoostCommand(int client, float now)
{
    // 全程模式：按 Z 切换 开/关（允许关闭）
    if (g_bModeContinuous[client])
    {
        if (g_bBoostEnabled[client])
        {
            StopBoost_NoCooldown(client);
            PrintToChat(client, "[近战加速] 已关闭（全程模式）");
        }
        else
        {
            g_bBoostEnabled[client] = true;
            g_bAdrenMode[client] = false;
            g_fBoostUntil[client] = 0.0;
            g_fNextReady[client] = 0.0;
            g_bCooldownReadyNotified[client] = true;

            ApplyMoveSpeedBoostSmart(client);
            EnsureClientTimer(client);

            PrintToChat(client, "[近战加速] 已开启（全程模式）；按 Z 关闭；切枪会取消；移动速度倍率 %.2f",
                g_cvMoveScale.FloatValue);
        }
        return Plugin_Handled;
    }

    // ===== 时间限制模式：重复按 Z 不会取消 =====

    if (g_bBoostEnabled[client])
    {
        // 进行中：只提示剩余时间（肾上腺素模式没有固定剩余，给出提示即可）
        if (g_bAdrenMode[client])
        {
            PrintToChat(client, "[近战加速] 肾上腺素模式进行中：将持续到肾上腺素结束");
        }
        else
        {
            float left = g_fBoostUntil[client] - now;
            if (left < 0.0) left = 0.0;
            PrintToChat(client, "[近战加速] 时间限制模式进行中：剩余 %.1f 秒", left);
        }
        return Plugin_Handled;
    }

    // 肾上腺素优先：有肾上腺素则无视冷却直接进入肾上腺素模式
    if (IsAdrenalineActive(client))
    {
        g_bBoostEnabled[client] = true;
        g_bAdrenMode[client] = true;
        g_fBoostUntil[client] = 0.0; // 肾上腺素模式不使用固定截止
        // 冷却在肾上腺素结束时才开始（Timer 里处理）

        ApplyMoveSpeedBoostSmart(client);
        EnsureClientTimer(client);
        PrintToChat(client, "[近战加速] 肾上腺素激活：持续到效果结束（无视冷却）；移动速度倍率 %.2f",
            g_cvMoveScale.FloatValue);
        return Plugin_Handled;
    }

    // 非肾上腺素：检查冷却
    if (now < g_fNextReady[client])
    {
        PrintToChat(client, "[近战加速] 冷却中：%.1f 秒", g_fNextReady[client] - now);
        return Plugin_Handled;
    }

    // 非肾上腺素：触发，并在触发时开始冷却
    g_bBoostEnabled[client] = true;
    g_bAdrenMode[client] = false;
    g_fBoostUntil[client] = now + g_cvDuration.FloatValue;
    g_fNextReady[client]  = now + g_cvCooldown.FloatValue;
    g_bCooldownReadyNotified[client] = false;

    ApplyMoveSpeedBoostSmart(client);
    EnsureClientTimer(client);
    PrintToChat(client, "[近战加速] 已触发：持续 %.1f 秒；冷却 %.1f 秒（重复按 Z 不会取消）；移动速度倍率 %.2f",
        g_cvDuration.FloatValue, g_cvCooldown.FloatValue, g_cvMoveScale.FloatValue);

    return Plugin_Handled;
}

Action HandlePistolBoostCommand(int client, float now)
{
    if (g_bPistolBoostEnabled[client])
    {
        float left = g_fPistolBoostUntil[client] - now;
        if (left < 0.0) left = 0.0;
        PrintToChat(client, "[近战加速] 手枪/马格南加速进行中：剩余 %.1f 秒", left);
        return Plugin_Handled;
    }

    if (now < g_fPistolNextReady[client])
    {
        PrintToChat(client, "[近战加速] 手枪/马格南加速冷却中：%.1f 秒", g_fPistolNextReady[client] - now);
        return Plugin_Handled;
    }

    float duration = g_cvPistolDuration.FloatValue;
    float cooldown = g_cvPistolCooldown.FloatValue;

    g_bPistolBoostEnabled[client] = true;
    g_fPistolBoostUntil[client] = now + duration;
    g_fPistolNextReady[client] = now + cooldown;
    g_bPistolCooldownReadyNotified[client] = false;

    KillPistolEndTimer(client);
    g_hPistolEndTimer[client] = CreateTimer(duration, Timer_PistolEndBoost, client);

    PrintToChat(client, "[近战加速] 手枪/马格南加速已触发：持续 %.1f 秒；冷却 %.1f 秒；开枪后缩短下一次开枪间隔；无限子弹=%d；补弹=%d；scale=%.3f",
        duration, cooldown, g_cvPistolInfAmmo.IntValue, g_cvPistolRefund.IntValue, g_cvScale.FloatValue);

    return Plugin_Handled;
}

public Action Cmd_MeleeBoost(int client, int args)
{
    // 监听服 client=0 映射真人玩家
    if (client <= 0)
    {
        if (IsDedicatedServer())
            return Plugin_Handled;

        int mapped = FindAnyHumanClientPreferSurvivor();
        if (mapped == 0) return Plugin_Handled;
        client = mapped;
    }

    if (!IsClientInGame(client))
        return Plugin_Handled;

    if (!IsEligible(client))
        return Plugin_Handled;

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    float now = GetGameTime();

    if (IsMeleeWeapon(wep))
        return HandleMeleeBoostCommand(client, now);

    if (IsPistolBoostWeapon(wep))
        return HandlePistolBoostCommand(client, now);

    PrintToChat(client, "[近战加速] 请先切换到近战武器，或 weapon_pistol / weapon_pistol_magnum");
    return Plugin_Handled;
}

/* bind z "+melee_boost" 时，松开会触发 -melee_boost；本插件使用“按下触发”，松开应无动作 */
public Action Cmd_MeleeBoostStop(int client, int args)
{
    return Plugin_Handled;
}

/* ========================= 击杀特感减冷却事件 ========================= */

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsEligible(attacker))
        return;

    bool isTank = false;
    if (!IsTrackedSpecialInfectedVictim(victim, isTank))
        return;

    if (isTank)
    {
        ResetMeleeCooldownImmediately(attacker);
        ResetPistolCooldownImmediately(attacker);
        return;
    }

    float reduce = g_cvKillReduce.FloatValue;
    if (reduce <= 0.0)
        return;

    ReduceMeleeCooldown(attacker, reduce);
    ReducePistolCooldown(attacker, reduce);
}

/* ========================= 生命周期 ========================= */

public void OnEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!convar.BoolValue)
    {
        ResetAllClientsRuntime();
    }
}

public void OnPluginStart()
{
    g_cvEnable    = CreateConVar("sm_meleeboost_enable", "1", "是否启用插件(1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTeam      = CreateConVar("sm_meleeboost_team",   "2", "生效队伍(2=生还者)", FCVAR_NOTIFY, true, 0.0, true, 3.0);

    g_cvScale     = CreateConVar("sm_meleeboost_scale",  "0.25", "剩余时间缩放(越小越快；近战和手枪共用)", FCVAR_NOTIFY, true, 0.01, true, 1.0);
    g_cvDuration  = CreateConVar("sm_meleeboost_duration", "5.0", "近战时间限制模式：非肾上腺素持续时间(秒)", FCVAR_NOTIFY, true, 0.1, true, 60.0);
    g_cvCooldown  = CreateConVar("sm_meleeboost_cooldown", "10.0", "近战时间限制模式：冷却时间(秒)", FCVAR_NOTIFY, true, 0.1, true, 300.0);
    g_cvTick      = CreateConVar("sm_meleeboost_tick", "0.1", "近战检测间隔(秒)", FCVAR_NOTIFY, true, 0.01, true, 1.0);
    g_cvMoveScale = CreateConVar("sm_meleeboost_move_scale", "2.0", "近战加速期间移动速度倍率(2.0=+100%)", FCVAR_NOTIFY, true, 0.1, true, 3.0);

    g_cvCooldownNotify = CreateConVar("sm_meleeboost_cooldown_notify", "1", "是否提示冷却完成(1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvKillReduce     = CreateConVar("sm_meleeboost_killreduce", "0.5", "击杀普通特感时减少的冷却秒数；Tank 直接恢复", FCVAR_NOTIFY, true, 0.0, true, 30.0);

    g_cvPistolDuration = CreateConVar("sm_meleeboost_pistol_duration", "3.0", "手枪/马格南加速持续时间(秒)", FCVAR_NOTIFY, true, 0.1, true, 60.0);
    g_cvPistolCooldown = CreateConVar("sm_meleeboost_pistol_cooldown", "10.0", "手枪/马格南加速冷却时间(秒)", FCVAR_NOTIFY, true, 0.1, true, 300.0);
    g_cvPistolInfAmmo  = CreateConVar("sm_meleeboost_pistol_infammo", "1", "手枪/马格南加速期间是否补弹匣，实现无限子弹(1/0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPistolRefund   = CreateConVar("sm_meleeboost_pistol_refund", "1", "手枪/马格南加速期间每次开火补回弹匣发数", FCVAR_NOTIFY, true, 0.0, true, 10.0);

    HookConVarChange(g_cvEnable, OnEnableChanged);

    AutoExecConfig(true, "plugin_meleeboost_togglemode");

    // 触发：Z
    RegConsoleCmd("sm_meleeboost", Cmd_MeleeBoost);
    RegConsoleCmd("+melee_boost",  Cmd_MeleeBoost);
    RegConsoleCmd("-melee_boost",  Cmd_MeleeBoostStop);

    // 模式切换：仅影响近战分支；手枪/马格南分支固定独立倒计时
    RegConsoleCmd("sm_meleeboost_mode", Cmd_MeleeBoostMode);

    HookEvent("weapon_fire",  Event_WeaponFire,  EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_bModeContinuous[i] = false; // 默认：近战时间限制模式
        ResetClientRuntime(i);
        g_hBoostTimer[i] = null;
        g_hPistolEndTimer[i] = null;
    }

    if (g_hCooldownNotifyTimer == null)
        g_hCooldownNotifyTimer = CreateTimer(0.1, Timer_CooldownNotify, _, TIMER_REPEAT);
}

// 仅在“真正连接服务器”时设置默认模式，避免换关卡/重连流程导致模式被重置
public void OnClientConnected(int client)
{
    if (client <= 0 || client > MaxClients) return;
    // g_bModeContinuous[client] = false; // 默认：时间限制模式（可通过 sm_meleeboost_mode 手动改）
}

public void OnClientPutInServer(int client)
{
    // 不重置模式，只清理运行状态与计时器（防残留/防泄露）
    ResetClientRuntime(client);
}

public void OnClientDisconnect(int client)
{
    ResetClientRuntime(client);
}

public void OnMapStart()
{
    ResetAllClientsRuntime();
}

public void OnPluginEnd()
{
    if (g_hCooldownNotifyTimer != null)
    {
        delete g_hCooldownNotifyTimer;
        g_hCooldownNotifyTimer = null;
    }

    ResetAllClientsRuntime();
}
