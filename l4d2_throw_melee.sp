/**
 * l4d2_throw_melee.sp
 *
 * 简介：
 *   L4D2 SourceMod 插件。玩家按绑定键后，如果当前手持 weapon_melee，
 *   插件不会删除玩家手上的近战，只生成一个同模型的显示实体。
 *   飞行方向使用玩家真实视角方向，包括 pitch；玩家看上/看下时会向上/向下飞。
 *   显示模型姿态默认跟随玩家视线方向，并额外做 pitch 90 度偏移：
 *   用来把原本“尖端向下、握柄向上”的近战模型转成“尖端朝视线前方、握柄朝玩家”。
 *   飞行实体不使用物理重力；每 0.1 秒移动一次，直到碰到墙/实体障碍或超过最大距离。
 *   飞行途中使用 oldPos -> newPos 的线段胶囊伤害检测：线段周围半径 50 的生物都会受伤。
 *   显示模型仍然每 0.1 秒移动一次，所以动画是离散的，但伤害路径是线性的。
 *   造成：
 *     1) 默认 1000 伤害；
 *     2) 如果目标当前血量 > 1000，才读取最大生命值，并额外造成 最大生命值 * 1/5 的伤害。
 *   同一个投掷近战对同一个目标只伤害一次，避免 0.1 秒 timer 重复扣血。
 *
 * 使用方法：
 *   1. 把本文件放到：addons/sourcemod/scripting/l4d2_throw_melee.sp
 *   2. 编译得到：l4d2_throw_melee.smx
 *   3. 把 .smx 放到：addons/sourcemod/plugins/
 *   4. 进游戏后在客户端控制台绑定按键，例如：
 *        bind g sm_throwmelee
 *   5. 默认参数会生成配置文件：cfg/sourcemod/l4d2_throw_melee.cfg
 *
 * 主要参数：
 *   l4d2_throw_melee_interval       默认 0.1，timer 间隔。
 *   l4d2_throw_melee_speed          默认 2000.0，飞行速度。
 *   l4d2_throw_melee_radius         默认 50.0，伤害半径。
 *   l4d2_throw_melee_damage         默认 1000.0，基础伤害。
 *   l4d2_throw_melee_extra_frac     默认 0.2，额外最大生命值比例。
 *   l4d2_throw_melee_max_distance   默认 2000.0，最大飞行距离。
 *   l4d2_throw_melee_cooldown       默认 30.0，成功投掷后的冷却时间。
 *   l4d2_throw_melee_kill_reduce    默认 2.0，玩家击杀 1 个特感后减少的冷却时间；不要求由投掷物击杀。
 *   l4d2_throw_melee_model_pitch_offset 默认 90.0，模型 pitch 修正；若尖端反向可改成 90.0。
 *   l4d2_throw_melee_model_yaw_offset   默认 0.0，模型 yaw 修正。
 *   l4d2_throw_melee_model_roll_offset  默认 0.0，模型 roll 修正。
 *   本地单人/监听服务器兼容：如果命令从 server console/client 0 触发，会自动寻找第一个真人幸存者。
 *   冷却缩短逻辑：监听 player_death，只要该玩家击杀特感，不管击杀途径，都会减少自己的投掷冷却。
 *   v1.2.8：重新加入命中声音，但不再使用服务端 EmitGameSound/EmitSound。
 *           改为对真人客户端执行 playgamesound <melee_hit entry>，播放原版 melee hit sound entry。
 *           这样声音不是严格 3D 定位，但避开服务端声音发射链，优先保证不闪退。
 *   v1.2.9：修复 g_sProjectileMeleeName 未定义导致的编译错误，并在投掷时记录近战脚本名。
 *   v1.2.10：修复 baseball_bat 映射到不存在模型导致投掷显示 ERROR；优先使用 w_bat.mdl，
 *            如果本机资源没有该模型，则回退到 w_cricket_bat.mdl。
 *   v1.2.11：根据网上资料确认 baseball_bat 的官方 world model 为 w_bat.mdl；若本机仍显示 ERROR，
 *            说明 prop_dynamic_override 直接加载该模型在当前资源/Mod 环境下不可靠。
 *            对 baseball_bat 改用 weapon_melee + melee_script_name 作为显示实体，由游戏脚本自动选模型。
 *   v1.2.12：新增成功投掷时播放近战斩空声。为降低崩溃风险，不使用 EmitSound，
 *            仍使用客户端 playgamesound；默认播放 Coach.MeleeSwing。
 *   v1.2.13：修正斩空声来源。Coach.MeleeSwing 是角色动画/人声音效，不是武器挥空声。
 *            现在按 melee script name 播放对应 melee_miss：Axe.Miss、Katana.Miss、Machete.Miss 等。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_NAME        "L4D2 Throw Melee"
#define PLUGIN_VERSION     "1.2.13"

#define TEAM_SURVIVOR      2
#define TEAM_INFECTED      3

ConVar g_cvEnable;
ConVar g_cvInterval;
ConVar g_cvSpeed;
ConVar g_cvRadius;
ConVar g_cvDamage;
ConVar g_cvExtraFrac;
ConVar g_cvMaxDistance;
ConVar g_cvCooldown;
ConVar g_cvKillReduce;
ConVar g_cvModelPitchOffset;
ConVar g_cvModelYawOffset;
ConVar g_cvModelRollOffset;
ConVar g_cvHitSoundEnable;
ConVar g_cvSwingSoundEnable;

int g_iProjectileRef[MAXPLAYERS + 1];
Handle g_hProjectileTimer[MAXPLAYERS + 1];
ArrayList g_hHitList[MAXPLAYERS + 1];

float g_fProjectilePos[MAXPLAYERS + 1][3];
float g_fProjectileDir[MAXPLAYERS + 1][3];
float g_fProjectileAng[MAXPLAYERS + 1][3];
float g_fProjectileSegmentStart[MAXPLAYERS + 1][3];
float g_fProjectileSegmentEnd[MAXPLAYERS + 1][3];
float g_fProjectileDistance[MAXPLAYERS + 1];
float g_fNextThrowTime[MAXPLAYERS + 1];
char g_sProjectileMeleeName[MAXPLAYERS + 1][64];

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "me",
    description = "Throw current melee weapon as a straight-line damage projectile in L4D2.",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar(
        "l4d2_throw_melee_enable",
        "1",
        "是否启用近战投掷功能。1=启用，0=关闭。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvInterval = CreateConVar(
        "l4d2_throw_melee_interval",
        "0.1",
        "投掷实体移动 timer 间隔。越大越省算力，但越容易漏掉高速经过的目标。",
        FCVAR_NOTIFY,
        true,
        0.05,
        true,
        1.0
    );

    g_cvSpeed = CreateConVar(
        "l4d2_throw_melee_speed",
        "2000.0",
        "近战投掷飞行速度，单位/秒。默认 2000 。",
        FCVAR_NOTIFY,
        true,
        100.0,
        true,
        3000.0
    );

    g_cvRadius = CreateConVar(
        "l4d2_throw_melee_radius",
        "50.0",
        "伤害检测半径。以飞行武器中心为圆心。",
        FCVAR_NOTIFY,
        true,
        1.0,
        true,
        300.0
    );

    g_cvDamage = CreateConVar(
        "l4d2_throw_melee_damage",
        "1000.0",
        "基础伤害。若目标当前血量 <= 此值，不再读取最大生命值。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        100000.0
    );

    g_cvExtraFrac = CreateConVar(
        "l4d2_throw_melee_extra_frac",
        "0.2",
        "目标当前血量大于基础伤害时，额外扣除的最大生命值比例。0.2 = 1/5。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        10.0
    );

    g_cvMaxDistance = CreateConVar(
        "l4d2_throw_melee_max_distance",
        "2000.0",
        "投掷最大飞行距离，超过后直接删除显示实体。",
        FCVAR_NOTIFY,
        true,
        100.0,
        true,
        10000.0
    );

    g_cvCooldown = CreateConVar(
        "l4d2_throw_melee_cooldown",
        "20.0",
        "成功投掷后的冷却时间。玩家冷却中按键时会提示剩余秒数。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        3600.0
    );

    g_cvKillReduce = CreateConVar(
        "l4d2_throw_melee_kill_reduce",
        "2.0",
        "玩家击杀 1 个特感后减少的冷却时间；不要求由投掷物击杀。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        3600.0
    );

    g_cvModelPitchOffset = CreateConVar(
        "l4d2_throw_melee_model_pitch_offset",
        "90.0",
        "投掷显示模型的 pitch 修正。默认 90：尖端朝玩家视线前方，握柄朝玩家。若尖端反向可改成 90。",
        FCVAR_NOTIFY,
        true,
        -360.0,
        true,
        360.0
    );

    g_cvModelYawOffset = CreateConVar(
        "l4d2_throw_melee_model_yaw_offset",
        "0.0",
        "投掷显示模型的 yaw 修正。不同自定义近战模型方向不一致时使用。",
        FCVAR_NOTIFY,
        true,
        -360.0,
        true,
        360.0
    );

    g_cvModelRollOffset = CreateConVar(
        "l4d2_throw_melee_model_roll_offset",
        "0.0",
        "投掷显示模型的 roll 修正。不同自定义近战模型横滚不一致时使用。",
        FCVAR_NOTIFY,
        true,
        -360.0,
        true,
        360.0
    );

    g_cvHitSoundEnable = CreateConVar(
        "l4d2_throw_melee_hit_sound_enable",
        "1",
        "是否播放投掷近战命中生物的原版近战命中声音。1=开启，0=关闭。本版使用客户端 playgamesound，不使用服务端 EmitSound。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_cvSwingSoundEnable = CreateConVar(
        "l4d2_throw_melee_swing_sound_enable",
        "1",
        "成功投掷近战时是否播放一次近战斩空声。1=开启，0=关闭。本版使用客户端 playgamesound，不使用服务端 EmitSound。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    RegConsoleCmd("sm_throwmelee", Cmd_ThrowMelee, "Throw current melee weapon forward.");
    RegConsoleCmd("sm_tmelee", Cmd_ThrowMelee, "Throw current melee weapon forward.");
    RegConsoleCmd("throwmelee", Cmd_ThrowMelee, "Throw current melee weapon forward.");
    RegConsoleCmd("throw_melee", Cmd_ThrowMelee, "Throw current melee weapon forward.");
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    for (int client = 1; client <= MaxClients; client++)
    {
        ResetClientState(client);
    }

    AutoExecConfig(true, "l4d2_throw_melee");
}

public void OnMapEnd()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        StopProjectile(client, true);
    }
}

public void OnClientDisconnect(int client)
{
    StopProjectile(client, true);
    ResetClientState(client);
}

public Action Cmd_ThrowMelee(int client, int args)
{
    // 正常 bind 调用时，client 应该是本地真人玩家，例如单人/监听服务器通常是 1。
    // 如果命令从 server console 或某些本地环境以 client 0 触发，尝试自动解析到第一个真人幸存者。
    client = ResolveCommandClient(client);

    if (client <= 0 || client > MaxClients)
    {
        PrintToServer("[ThrowMelee] No valid human survivor found for command.");
        return Plugin_Handled;
    }

    if (!g_cvEnable.BoolValue)
    {
        PrintToChat(client, "\x05[ThrowMelee]\x01 插件当前已关闭：l4d2_throw_melee_enable = 0");
        return Plugin_Handled;
    }

    if (!IsValidAliveSurvivor(client))
    {
        PrintToChat(client, "\x05[ThrowMelee]\x01 当前玩家不是存活幸存者，不能投掷。");
        return Plugin_Handled;
    }

    float now = GetGameTime();
    if (g_fNextThrowTime[client] > now)
    {
        int remain = RoundToCeil(g_fNextThrowTime[client] - now);
        PrintToChat(client, "\x05[ThrowMelee]\x01 冷却中，还剩 %d 秒。", remain);
        return Plugin_Handled;
    }

    if (IsProjectileActive(client))
    {
        // 理论上冷却远长于飞行时间；这里作为安全保护，避免同一玩家生成多个飞行实体。
        PrintToChat(client, "\x05[ThrowMelee]\x01 上一个投掷实体还未结束。");
        return Plugin_Handled;
    }

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEntity(weapon))
        return Plugin_Handled;

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));

    if (!StrEqual(classname, "weapon_melee", false))
    {
        PrintToChat(client, "\x05[ThrowMelee]\x01 当前手持的不是近战武器。");
        return Plugin_Handled;
    }

    char meleeName[64];
    GetMeleeScriptName(weapon, meleeName, sizeof(meleeName));

    bool useWeaponMeleeDisplay = ShouldUseWeaponMeleeDisplay(meleeName);

    char model[PLATFORM_MAX_PATH];
    model[0] = '\0';

    if (!useWeaponMeleeDisplay)
    {
        if (!GetMeleeWorldModel(weapon, meleeName, model, sizeof(model)))
        {
            PrintToChat(client, "\x05[ThrowMelee]\x01 无法识别该近战的世界模型：%s", meleeName);
            return Plugin_Handled;
        }

        PrecacheModel(model, true);
    }

    float eyePos[3];
    float eyeAng[3];
    float modelAng[3];
    float throwDir[3];

    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);

    // 飞行方向：使用玩家真实视角方向，包括 pitch。
    // 这样玩家看上/看下时，投掷物会按视线方向向上/向下飞。
    GetAngleVectors(eyeAng, throwDir, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(throwDir, throwDir);

    // 显示模型姿态：使用玩家真实视线角度，再加固定模型轴向修正。
    // L4D2 多数近战 world model 在默认姿态下容易表现为“尖端向下、握柄向上”。
    // 默认 pitch 90 会把该垂直轴转到视线方向：尖端朝前，握柄朝玩家。
    BuildProjectileModelAngles(eyeAng, modelAng);

    float spawnPos[3];
    spawnPos[0] = eyePos[0] + throwDir[0] * 45.0;
    spawnPos[1] = eyePos[1] + throwDir[1] * 45.0;
    spawnPos[2] = eyePos[2] + throwDir[2] * 45.0;

    int projectile = -1;

    if (useWeaponMeleeDisplay)
    {
        // baseball_bat 在部分资源/Mod 环境下用 prop_dynamic_override + w_bat.mdl 会显示 ERROR。
        // 这里改用真实 weapon_melee 显示实体，让游戏根据 melee_script_name 自动绑定模型。
        // 不删除玩家手上的近战；这个实体只作为短时间飞行显示物，生命周期结束后 Kill。
        projectile = CreateEntityByName("weapon_melee");
        if (projectile == -1 || !IsValidEntity(projectile))
        {
            PrintToChat(client, "\x05[ThrowMelee]\x01 创建棒球棍显示实体失败。");
            return Plugin_Handled;
        }

        DispatchKeyValue(projectile, "melee_script_name", "baseball_bat");
        DispatchKeyValue(projectile, "solid", "0");
        DispatchSpawn(projectile);
        ActivateEntity(projectile);

        SetEntityMoveType(projectile, MOVETYPE_NONE);
        SetEntProp(projectile, Prop_Send, "m_CollisionGroup", 2);
        TeleportEntity(projectile, spawnPos, modelAng, NULL_VECTOR);
    }
    else
    {
        projectile = CreateEntityByName("prop_dynamic_override");
        if (projectile == -1 || !IsValidEntity(projectile))
        {
            PrintToChat(client, "\x05[ThrowMelee]\x01 创建投掷显示实体失败。");
            return Plugin_Handled;
        }

        DispatchKeyValue(projectile, "model", model);
        DispatchKeyValue(projectile, "solid", "0");
        DispatchKeyValue(projectile, "disableshadows", "1");
        DispatchSpawn(projectile);
        ActivateEntity(projectile);
        TeleportEntity(projectile, spawnPos, modelAng, NULL_VECTOR);
    }

    // 不删除/收走玩家手上的近战；这里只生成显示用投掷实体。
    // 成功投掷时播放一次斩空声；只在真正生成 projectile 后播放，冷却中/非近战不会播放。
    QueueMeleeSwingSound(client, meleeName);

    g_fNextThrowTime[client] = GetGameTime() + g_cvCooldown.FloatValue;

    g_iProjectileRef[client] = EntIndexToEntRef(projectile);
    g_fProjectilePos[client][0] = spawnPos[0];
    g_fProjectilePos[client][1] = spawnPos[1];
    g_fProjectilePos[client][2] = spawnPos[2];
    g_fProjectileDir[client][0] = throwDir[0];
    g_fProjectileDir[client][1] = throwDir[1];
    g_fProjectileDir[client][2] = throwDir[2];
    g_fProjectileAng[client][0] = modelAng[0];
    g_fProjectileAng[client][1] = modelAng[1];
    g_fProjectileAng[client][2] = modelAng[2];
    g_fProjectileDistance[client] = 0.0;
    strcopy(g_sProjectileMeleeName[client], sizeof(g_sProjectileMeleeName[]), meleeName);

    delete g_hHitList[client];
    g_hHitList[client] = new ArrayList();

    float interval = g_cvInterval.FloatValue;
    g_hProjectileTimer[client] = CreateTimer(interval, Timer_ProjectileThink, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (victim <= 0 || victim > MaxClients || attacker <= 0 || attacker > MaxClients)
        return;

    if (victim == attacker)
        return;

    if (!IsClientInGame(victim) || !IsClientInGame(attacker))
        return;

    // 特感/Tank 都是 infected 阵营的玩家实体。
    // 这里不再要求由投掷物击杀：只要幸存者玩家击杀 infected 阵营玩家，就减少该幸存者自己的投掷冷却。
    if (GetClientTeam(victim) != TEAM_INFECTED || GetClientTeam(attacker) != TEAM_SURVIVOR)
        return;

    ReduceThrowCooldown(attacker, g_cvKillReduce.FloatValue);
}

public Action Timer_ProjectileThink(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients)
        return Plugin_Stop;

    int projectile = EntRefToEntIndex(g_iProjectileRef[client]);
    if (projectile == INVALID_ENT_REFERENCE || projectile <= MaxClients || !IsValidEntity(projectile))
    {
        StopProjectile(client, false);
        return Plugin_Stop;
    }

    float interval = g_cvInterval.FloatValue;
    float speed = g_cvSpeed.FloatValue;
    float step = speed * interval;

    float oldPos[3];
    oldPos[0] = g_fProjectilePos[client][0];
    oldPos[1] = g_fProjectilePos[client][1];
    oldPos[2] = g_fProjectilePos[client][2];

    float newPos[3];
    newPos[0] = oldPos[0] + g_fProjectileDir[client][0] * step;
    newPos[1] = oldPos[1] + g_fProjectileDir[client][1] * step;
    newPos[2] = oldPos[2] + g_fProjectileDir[client][2] * step;

    Handle trace = TR_TraceRayFilterEx(oldPos, newPos, MASK_SOLID, RayType_EndPoint, TraceFilter_WallOnly, projectile, TRACE_EVERYTHING_FILTER_PROPS);

    if (TR_DidHit(trace))
    {
        float hitPos[3];
        TR_GetEndPosition(hitPos, trace);
        CloseHandle(trace);

        TeleportEntity(projectile, hitPos, g_fProjectileAng[client], NULL_VECTOR);

        // 即使本次移动中途撞墙，也先对 oldPos -> hitPos 这一段做线性胶囊伤害。
        // 这样墙前的目标不会因为 timer 离散而漏判。
        DamageEntitiesAlongSegment(client, projectile, oldPos, hitPos);

        StopProjectile(client, false);
        return Plugin_Stop;
    }

    CloseHandle(trace);

    g_fProjectileDistance[client] += step;
    if (g_fProjectileDistance[client] >= g_cvMaxDistance.FloatValue)
    {
        StopProjectile(client, false);
        return Plugin_Stop;
    }

    g_fProjectilePos[client][0] = newPos[0];
    g_fProjectilePos[client][1] = newPos[1];
    g_fProjectilePos[client][2] = newPos[2];

    TeleportEntity(projectile, newPos, g_fProjectileAng[client], NULL_VECTOR);

    DamageEntitiesAlongSegment(client, projectile, oldPos, newPos);

    return Plugin_Continue;
}

public bool TraceFilter_WallOnly(int entity, int contentsMask, any projectile)
{
    if (entity == projectile)
        return false;

    // 不让飞行轨迹被玩家/特感挡住；伤害由半径检测处理。
    if (entity >= 1 && entity <= MaxClients)
        return false;

    if (entity > MaxClients && IsValidEntity(entity))
    {
        char classname[64];
        GetEntityClassname(entity, classname, sizeof(classname));

        // 普通感染者和 Witch 不负责挡住投掷物；它们只吃伤害。
        if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false))
            return false;
    }

    return true;
}

void DamageEntitiesAlongSegment(int client, int projectile, const float startPos[3], const float endPos[3])
{
    float radius = g_cvRadius.FloatValue;

    g_fProjectileSegmentStart[client][0] = startPos[0];
    g_fProjectileSegmentStart[client][1] = startPos[1];
    g_fProjectileSegmentStart[client][2] = startPos[2];

    g_fProjectileSegmentEnd[client][0] = endPos[0];
    g_fProjectileSegmentEnd[client][1] = endPos[1];
    g_fProjectileSegmentEnd[client][2] = endPos[2];

    float mid[3];
    mid[0] = (startPos[0] + endPos[0]) * 0.5;
    mid[1] = (startPos[1] + endPos[1]) * 0.5;
    mid[2] = (startPos[2] + endPos[2]) * 0.5;

    // 先用空间分区做粗筛：只枚举包住本次飞行线段胶囊体的球。
    // 枚举半径 = 本次移动距离 / 2 + 伤害半径。
    // 之后再对每个候选实体做点到线段距离判断，避免全图扫描。
    float segmentLen = GetVectorDistance(startPos, endPos);
    float enumRadius = segmentLen * 0.5 + radius;

    TR_EnumerateEntitiesSphere(mid, enumRadius, PARTITION_NON_STATIC_EDICTS, Enum_DamageSegment, GetClientUserId(client));
}

public bool Enum_DamageSegment(int entity, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients)
        return true;

    int projectile = EntRefToEntIndex(g_iProjectileRef[client]);
    if (projectile == INVALID_ENT_REFERENCE)
        return false;

    if (entity <= 0 || entity == projectile || entity == client)
        return true;

    if (!IsValidEntity(entity))
        return true;

    if (!IsDamageableTarget(entity))
        return true;

    float entPos[3];
    GetTargetCenter(entity, entPos);

    float radius = g_cvRadius.FloatValue;
    float radiusSq = radius * radius;

    // 精确筛选：目标中心到 oldPos -> newPos 线段的最短距离 <= 半径。
    // 这就是线性胶囊伤害，不再只检测离散动画帧位置。
    float distSq = DistancePointToSegmentSq(entPos, g_fProjectileSegmentStart[client], g_fProjectileSegmentEnd[client]);
    if (distSq > radiusSq)
        return true;

    if (AlreadyHitOrMark(client, entity))
        return true;

    DamageVictim(client, projectile, entity, entPos);

    return true;
}

void BuildProjectileModelAngles(const float eyeAng[3], float modelAng[3])
{
    modelAng[0] = NormalizeAngle(eyeAng[0] + g_cvModelPitchOffset.FloatValue);
    modelAng[1] = NormalizeAngle(eyeAng[1] + g_cvModelYawOffset.FloatValue);
    modelAng[2] = NormalizeAngle(eyeAng[2] + g_cvModelRollOffset.FloatValue);
}

float NormalizeAngle(float angle)
{
    while (angle > 180.0)
        angle -= 360.0;

    while (angle < -180.0)
        angle += 360.0;

    return angle;
}

float DistancePointToSegmentSq(const float point[3], const float startPos[3], const float endPos[3])
{
    float seg[3];
    seg[0] = endPos[0] - startPos[0];
    seg[1] = endPos[1] - startPos[1];
    seg[2] = endPos[2] - startPos[2];

    float toPoint[3];
    toPoint[0] = point[0] - startPos[0];
    toPoint[1] = point[1] - startPos[1];
    toPoint[2] = point[2] - startPos[2];

    float segLenSq = Dot3(seg, seg);
    if (segLenSq <= 0.0001)
        return GetVectorDistance(point, startPos, true);

    float t = Dot3(toPoint, seg) / segLenSq;
    if (t < 0.0)
        t = 0.0;
    else if (t > 1.0)
        t = 1.0;

    float closest[3];
    closest[0] = startPos[0] + seg[0] * t;
    closest[1] = startPos[1] + seg[1] * t;
    closest[2] = startPos[2] + seg[2] * t;

    return GetVectorDistance(point, closest, true);
}

float Dot3(const float a[3], const float b[3])
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

bool IsDamageableTarget(int entity)
{
    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity) || !IsPlayerAlive(entity))
            return false;

        // 只打感染者阵营：特感和 Tank 都是玩家实体。
        return GetClientTeam(entity) == TEAM_INFECTED;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (!StrEqual(classname, "infected", false) && !StrEqual(classname, "witch", false))
        return false;

    int hp = GetEntityHealthSafe(entity);
    return hp > 0;
}

void DamageVictim(int attacker, int inflictor, int victim, const float damagePos[3])
{
    int hp = GetEntityHealthSafe(victim);
    if (hp <= 0)
        return;

    float baseDamage = g_cvDamage.FloatValue;
    float damage = baseDamage;

    // 省算力关键：如果 1000 基础伤害已经能杀死，不读取最大生命值。
    if (float(hp) > baseDamage)
    {
        int maxHp = GetEntityMaxHealthSafe(victim, hp);
        if (maxHp > 0)
        {
            damage += float(maxHp) * g_cvExtraFrac.FloatValue;
        }
    }

    // v1.2.8：声音播放不再走服务端 EmitSound。
    // 先排队到极短 timer，再让真人客户端本地 playgamesound，避开命中伤害同一调用栈。
    QueueMeleeHitSound(attacker);

    SDKHooks_TakeDamage(victim, inflictor, attacker, damage, DMG_SLASH, -1, NULL_VECTOR, damagePos, true);
}


void QueueMeleeSwingSound(int owner, const char[] meleeName)
{
    if (!g_cvSwingSoundEnable.BoolValue)
        return;

    if (owner <= 0 || owner > MaxClients || !IsClientInGame(owner))
        return;

    char soundName[64];
    if (!GetMeleeMissSoundName(meleeName, soundName, sizeof(soundName)))
        return;

    // 使用 melee weapon script 里的 melee_miss entry，例如 Axe.Miss / Katana.Miss。
    // 仍然不使用 EmitSound/EmitGameSound，避免重新进入之前导致闪退的服务端声音链。
    DataPack pack;
    CreateDataTimer(0.01, Timer_PlayQueuedMeleeHitSound, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteString(soundName);
}

void QueueMeleeHitSound(int owner)
{
    if (!g_cvHitSoundEnable.BoolValue)
        return;

    if (owner <= 0 || owner > MaxClients || !IsClientInGame(owner))
        return;

    char soundName[64];
    if (!GetMeleeHitSoundName(g_sProjectileMeleeName[owner], soundName, sizeof(soundName)))
        return;

    // 用 0.01 秒 timer 避免在伤害处理/实体死亡删除的同一调用栈里触发声音相关逻辑。
    DataPack pack;
    CreateDataTimer(0.01, Timer_PlayQueuedMeleeHitSound, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteString(soundName);
}

public Action Timer_PlayQueuedMeleeHitSound(Handle timer, DataPack pack)
{
    pack.Reset();

    char soundName[64];
    pack.ReadString(soundName, sizeof(soundName));

    // 最保守方案：不使用 EmitGameSoundToAll / EmitSoundToAll。
    // playgamesound 是客户端本地播放 game sound entry；坏处是空间定位弱，好处是不会进入服务端空间声音发射链。
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        ClientCommand(client, "playgamesound %s", soundName);
    }

    return Plugin_Stop;
}

bool GetMeleeMissSoundName(const char[] meleeName, char[] soundName, int maxlen)
{
    // 这些名字来自 L4D2 melee weapon script 的 melee_miss 字段。
    // 未知近战不 fallback，避免播放错误角色音效或不存在的 sound entry。
    if (StrEqual(meleeName, "fireaxe", false))
        strcopy(soundName, maxlen, "Axe.Miss");
    else if (StrEqual(meleeName, "frying_pan", false))
        strcopy(soundName, maxlen, "Pan.Miss");
    else if (StrEqual(meleeName, "machete", false))
        strcopy(soundName, maxlen, "Machete.Miss");
    else if (StrEqual(meleeName, "baseball_bat", false))
        strcopy(soundName, maxlen, "Bat.Miss");
    else if (StrEqual(meleeName, "cricket_bat", false))
        strcopy(soundName, maxlen, "CricketBat.Miss");
    else if (StrEqual(meleeName, "crowbar", false))
        strcopy(soundName, maxlen, "Crowbar.Miss");
    else if (StrEqual(meleeName, "electric_guitar", false))
        strcopy(soundName, maxlen, "Guitar.Miss");
    else if (StrEqual(meleeName, "katana", false))
        strcopy(soundName, maxlen, "Katana.Miss");
    else if (StrEqual(meleeName, "tonfa", false))
        strcopy(soundName, maxlen, "Tonfa.Miss");
    else if (StrEqual(meleeName, "golfclub", false))
        strcopy(soundName, maxlen, "GolfClub.Miss");
    else if (StrEqual(meleeName, "knife", false))
        strcopy(soundName, maxlen, "Knife.Miss");
    else if (StrEqual(meleeName, "pitchfork", false))
        strcopy(soundName, maxlen, "Pitchfork.Miss");
    else if (StrEqual(meleeName, "shovel", false))
        strcopy(soundName, maxlen, "Shovel.Miss");
    else
    {
        soundName[0] = '\0';
        return false;
    }

    return true;
}

bool GetMeleeHitSoundName(const char[] meleeName, char[] soundName, int maxlen)
{
    // 这些名字来自 L4D2 melee weapon script 的 melee_hit 字段。
    // 不使用 fallback；未知近战直接不播放，避免错误声音名。
    if (StrEqual(meleeName, "fireaxe", false))
        strcopy(soundName, maxlen, "Axe.ImpactFlesh");
    else if (StrEqual(meleeName, "frying_pan", false))
        strcopy(soundName, maxlen, "Pan.ImpactFlesh");
    else if (StrEqual(meleeName, "machete", false))
        strcopy(soundName, maxlen, "Machete.ImpactFlesh");
    else if (StrEqual(meleeName, "baseball_bat", false))
        strcopy(soundName, maxlen, "Bat.ImpactFlesh");
    else if (StrEqual(meleeName, "cricket_bat", false))
        strcopy(soundName, maxlen, "CricketBat.ImpactFlesh");
    else if (StrEqual(meleeName, "crowbar", false))
        strcopy(soundName, maxlen, "Crowbar.ImpactFlesh");
    else if (StrEqual(meleeName, "electric_guitar", false))
        strcopy(soundName, maxlen, "Guitar.ImpactFlesh");
    else if (StrEqual(meleeName, "katana", false))
        strcopy(soundName, maxlen, "Katana.ImpactFlesh");
    else if (StrEqual(meleeName, "tonfa", false))
        strcopy(soundName, maxlen, "Tonfa.ImpactFlesh");
    else if (StrEqual(meleeName, "golfclub", false))
        strcopy(soundName, maxlen, "GolfClub.ImpactFlesh");
    else if (StrEqual(meleeName, "knife", false))
        strcopy(soundName, maxlen, "Knife.ImpactFlesh");
    else if (StrEqual(meleeName, "pitchfork", false))
        strcopy(soundName, maxlen, "Pitchfork.ImpactFlesh");
    else if (StrEqual(meleeName, "shovel", false))
        strcopy(soundName, maxlen, "Shovel.ImpactFlesh");
    else
    {
        soundName[0] = '\0';
        return false;
    }

    return true;
}

int GetEntityHealthSafe(int entity)
{
    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
            return 0;

        return GetClientHealth(entity);
    }

    if (HasEntProp(entity, Prop_Data, "m_iHealth"))
        return GetEntProp(entity, Prop_Data, "m_iHealth");

    if (HasEntProp(entity, Prop_Send, "m_iHealth"))
        return GetEntProp(entity, Prop_Send, "m_iHealth");

    return 0;
}

int GetEntityMaxHealthSafe(int entity, int currentHp)
{
    // 只有当前 HP > 基础伤害时才会调用本函数。
    // 优先读真正最大生命值；如果目标没有该属性，退回 currentHp，避免完全没有额外伤害。
    if (HasEntProp(entity, Prop_Data, "m_iMaxHealth"))
    {
        int maxHp = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
        if (maxHp > 0)
            return maxHp;
    }

    if (HasEntProp(entity, Prop_Send, "m_iMaxHealth"))
    {
        int maxHp = GetEntProp(entity, Prop_Send, "m_iMaxHealth");
        if (maxHp > 0)
            return maxHp;
    }

    return currentHp;
}

void GetTargetCenter(int entity, float out[3])
{
    if (entity >= 1 && entity <= MaxClients)
    {
        GetClientAbsOrigin(entity, out);
        out[2] += 40.0;
        return;
    }

    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", out);

    float mins[3];
    float maxs[3];
    if (HasEntProp(entity, Prop_Send, "m_vecMins") && HasEntProp(entity, Prop_Send, "m_vecMaxs"))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
        GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
        out[2] += (mins[2] + maxs[2]) * 0.5;
    }
}

bool AlreadyHitOrMark(int client, int entity)
{
    if (g_hHitList[client] == null)
        g_hHitList[client] = new ArrayList();

    int ref = EntIndexToEntRef(entity);

    if (g_hHitList[client].FindValue(ref) != -1)
        return true;

    g_hHitList[client].Push(ref);
    return false;
}

void ReduceThrowCooldown(int client, float seconds)
{
    if (client <= 0 || client > MaxClients || seconds <= 0.0)
        return;

    float now = GetGameTime();
    if (g_fNextThrowTime[client] <= now)
        return;

    g_fNextThrowTime[client] -= seconds;
    if (g_fNextThrowTime[client] < now)
        g_fNextThrowTime[client] = now;
}

void ResetClientState(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    g_iProjectileRef[client] = INVALID_ENT_REFERENCE;
    g_hProjectileTimer[client] = null;
    g_fProjectileDistance[client] = 0.0;
    g_fNextThrowTime[client] = 0.0;
    g_sProjectileMeleeName[client][0] = '\0';

    delete g_hHitList[client];
}

int ResolveCommandClient(int client)
{
    if (client >= 1 && client <= MaxClients)
        return client;

    // 只在 client 0 / 无效命令来源时使用。
    // 这里跳过 bot，是为了本地单人/监听服务器从控制台触发命令时，优先找到真人玩家。
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        if (GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
            continue;

        return i;
    }

    return 0;
}

bool IsValidAliveSurvivor(int client)
{
    if (client <= 0 || client > MaxClients)
        return false;

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return false;

    return GetClientTeam(client) == TEAM_SURVIVOR;
}

bool IsProjectileActive(int client)
{
    int entity = EntRefToEntIndex(g_iProjectileRef[client]);
    return entity != INVALID_ENT_REFERENCE && entity > MaxClients && IsValidEntity(entity);
}

void StopProjectile(int client, bool killTimer)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (killTimer && g_hProjectileTimer[client] != null)
    {
        KillTimer(g_hProjectileTimer[client]);
    }

    g_hProjectileTimer[client] = null;

    int projectile = EntRefToEntIndex(g_iProjectileRef[client]);
    if (projectile != INVALID_ENT_REFERENCE && projectile > MaxClients && IsValidEntity(projectile))
    {
        AcceptEntityInput(projectile, "Kill");
    }

    g_iProjectileRef[client] = INVALID_ENT_REFERENCE;
    g_fProjectileDistance[client] = 0.0;
    g_sProjectileMeleeName[client][0] = '\0';

    delete g_hHitList[client];
}

bool ShouldUseWeaponMeleeDisplay(const char[] meleeName)
{
    // 网上常见资料和开源 L4D2 weapons include 都把 baseball_bat 对应到
    // models/weapons/melee/w_bat.mdl。若本机仍显示 ERROR，通常是资源/Mod 环境中
    // prop_dynamic_override 直接加载 w_bat.mdl 不稳定。
    // 因此 baseball_bat 使用 weapon_melee + melee_script_name 让游戏脚本自己选模型。
    return StrEqual(meleeName, "baseball_bat", false) || StrEqual(meleeName, "bat", false);
}

void GetMeleeScriptName(int weapon, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (HasEntProp(weapon, Prop_Data, "m_strMapSetScriptName"))
    {
        GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", buffer, maxlen);
    }

    if (buffer[0] == '\0' && HasEntProp(weapon, Prop_Send, "m_strMapSetScriptName"))
    {
        GetEntPropString(weapon, Prop_Send, "m_strMapSetScriptName", buffer, maxlen);
    }

    if (buffer[0] == '\0')
    {
        strcopy(buffer, maxlen, "unknown");
    }
}

bool GetMeleeWorldModel(int weapon, const char[] meleeName, char[] model, int maxlen)
{
    model[0] = '\0';

    // 优先用常见官方 melee script name 映射，避免拿到 view model。
    if (StrEqual(meleeName, "fireaxe", false))
        strcopy(model, maxlen, "models/weapons/melee/w_fireaxe.mdl");
    else if (StrEqual(meleeName, "frying_pan", false))
        strcopy(model, maxlen, "models/weapons/melee/w_frying_pan.mdl");
    else if (StrEqual(meleeName, "machete", false))
        strcopy(model, maxlen, "models/weapons/melee/w_machete.mdl");
    else if (StrEqual(meleeName, "baseball_bat", false) || StrEqual(meleeName, "bat", false))
    {
        // L4D2 的棒球棍 world model 不是 w_baseball_bat.mdl。
        // 部分安装/资源包中实际路径为 w_bat.mdl；若不存在则用板球棍 world model 兜底，避免显示 ERROR。
        if (FileExists("models/weapons/melee/w_bat.mdl", true))
            strcopy(model, maxlen, "models/weapons/melee/w_bat.mdl");
        else
            strcopy(model, maxlen, "models/weapons/melee/w_cricket_bat.mdl");
    }
    else if (StrEqual(meleeName, "cricket_bat", false))
        strcopy(model, maxlen, "models/weapons/melee/w_cricket_bat.mdl");
    else if (StrEqual(meleeName, "crowbar", false))
        strcopy(model, maxlen, "models/weapons/melee/w_crowbar.mdl");
    else if (StrEqual(meleeName, "electric_guitar", false))
        strcopy(model, maxlen, "models/weapons/melee/w_electric_guitar.mdl");
    else if (StrEqual(meleeName, "katana", false))
        strcopy(model, maxlen, "models/weapons/melee/w_katana.mdl");
    else if (StrEqual(meleeName, "tonfa", false))
        strcopy(model, maxlen, "models/weapons/melee/w_tonfa.mdl");
    else if (StrEqual(meleeName, "golfclub", false))
        strcopy(model, maxlen, "models/weapons/melee/w_golfclub.mdl");
    else if (StrEqual(meleeName, "knife", false))
        strcopy(model, maxlen, "models/w_models/weapons/w_knife_t.mdl");
    else if (StrEqual(meleeName, "pitchfork", false))
        strcopy(model, maxlen, "models/weapons/melee/w_pitchfork.mdl");
    else if (StrEqual(meleeName, "shovel", false))
        strcopy(model, maxlen, "models/weapons/melee/w_shovel.mdl");

    if (model[0] != '\0')
        return true;

    // 自定义近战或未知脚本名：尝试读取实体自身模型。
    if (HasEntProp(weapon, Prop_Data, "m_ModelName"))
    {
        GetEntPropString(weapon, Prop_Data, "m_ModelName", model, maxlen);
    }

    if (model[0] == '\0' && HasEntProp(weapon, Prop_Send, "m_ModelName"))
    {
        GetEntPropString(weapon, Prop_Send, "m_ModelName", model, maxlen);
    }

    // 避免误用 view model；view model 近距离显示会很怪。
    if (StrContains(model, "/v_", false) != -1 || StrContains(model, "\\v_", false) != -1)
    {
        model[0] = '\0';
        return false;
    }

    return model[0] != '\0';
}
