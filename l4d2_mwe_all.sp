/*
 * l4d2_mwe_all.sp
 *
 * 使用方法:
 *   1. 将本文件放入 left4dead2/addons/sourcemod/scripting/l4d2_mwe_all.sp
 *   2. 使用 SourceMod 编译器编译: spcomp l4d2_mwe_all.sp
 *   3. 将生成的 l4d2_mwe_all.smx 放入 left4dead2/addons/sourcemod/plugins/
 *   4. 不要同时加载原来的 6 个独立 smx，否则同一武器效果会重复触发。
 *   5. 本整合版只生成/读取 1 个配置文件:
 *      - cfg/sourcemod/l4d2_mwe_all.cfg
 *
 * 简介:
 *   这是将步枪、狙击枪、霰弹枪、冲锋枪、手枪、近战/电锯 6 个独立插件整合后的单文件版。
 *   为了最大限度保持原功能不变，本文件采用模块名前缀隔离每个原插件的全局变量、函数、枚举和宏，
 *   再由统一的 SourceMod forward 入口转发到各模块。
 *
 *   1.0.1-combined-realhit 修复:
 *   - 步枪、狙击枪、普通手枪的命中目标类效果改为 SDKHook_OnTakeDamage/OnTakeDamageAlive 真实命中驱动。
 *   - 不再用 weapon_fire 后的服务器端 TraceRay 判定移动目标，减少“横向移动敌人必须打提前量才触发效果”的问题。
 *   - 马格南爆炸优先使用真实受击目标位置；没有真实受击目标时才用射线作为世界落点兜底。
 *
 * 注意:
 *   - 本文件不要求 Left 4 DHooks Direct。
 *   - 所有模块仍保留自己的 ConVar 名称，但统一写入 cfg/sourcemod/l4d2_mwe_all.cfg。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define MWE_ALL_VERSION "1.0.23-rifle-chance-fix"

#if !defined DMG_BULLET
#define DMG_BULLET (1 << 1)
#endif
#if !defined DMG_BURN
#define DMG_BURN (1 << 3)
#endif
#if !defined DMG_BUCKSHOT
#define DMG_BUCKSHOT (1 << 29)
#endif
#if !defined HITGROUP_HEAD
#define HITGROUP_HEAD 1
#endif

#define MWE_EXPLOSION_SOUND "weapons/hegrenade/explode5.wav"
#define MWE_UPGRADE_BIT_LASER_SIGHT (1 << 2)
int MWE_g_iExplosionSprite = -1;

// 1.0.9: 声明必须放在 OnMapStart 使用之前，否则旧版 SourcePawn 会报 undefined symbol。
float MWE_g_fMapStartTime = 0.0;

// 1.0.10: 可靠消息保护。
// L4D2 换图时会集中发送装备恢复、聊天、脚本、状态等可靠消息。
// 本插件的武器说明只是提示，不影响实际武器效果，因此默认全局关闭，并在换图前后强制静默。
ConVar MWE_g_cvCorePickupNotices = null;
ConVar MWE_g_cvCoreQuietSeconds = null;
ConVar MWE_g_cvCoreIntroHint = null;
ConVar MWE_g_cvCoreIntroDelay = null;
ConVar MWE_g_cvLaserRewardEnable = null;
ConVar MWE_g_cvLaserKillThreshold = null;
ConVar MWE_g_cvLaserSpecialKillPoints = null;
ConVar MWE_g_cvLaserTankKillPoints = null;
ConVar MWE_g_cvLaserCommandCost = null;
ConVar MWE_g_cvLaserChatNotify = null;
ConVar MWE_g_cvMountedGunEnable = null;
ConVar MWE_g_cvMountedGunBurnDuration = null;
ConVar MWE_g_cvMountedGunReigniteCooldown = null;
ConVar MWE_g_cvMountedGunExplosionChance = null;
ConVar MWE_g_cvMountedGunExplosionRadius = null;
ConVar MWE_g_cvMountedGunExplosionDamage = null;
ConVar MWE_g_cvMountedGunExplosionForce = null;
bool MWE_g_bReliableQuietWindow = false;
float MWE_g_fReliableQuietUntil = 0.0;
bool MWE_g_bIntroHintShown[MAXPLAYERS + 1];
bool MWE_g_bIntroHintPending[MAXPLAYERS + 1];
int MWE_g_iLaserKillScore[MAXPLAYERS + 1];
int MWE_g_iLaserLoopCount[MAXPLAYERS + 1];
StringMap MWE_g_smLaserKillScoreByAuth = null;
StringMap MWE_g_smLaserLoopCountByAuth = null;
bool MWE_g_bLaserCampaignTransition = false;
bool MWE_g_bLaserResetOnNextMap = false;
char MWE_g_sLaserPreviousMap[PLATFORM_MAX_PATH];

#define MWE_DEFAULT_MAPCHANGE_QUIET_TIME 45.0
#define MWE_MAPEND_QUIET_TIME 90.0
#define MWE_DEFAULT_INTRO_HINT_DELAY 50.0
#define MWE_TEAM_SURVIVOR 2

public Plugin myinfo =
{
    name = "L4D2 Multi Weapon Effects - All In One",
    author = "me",
    description = "All-in-one L4D2 multi weapon effects plugin: rifles, snipers, shotguns, SMGs, pistols, melee/chainsaw.",
    version = MWE_ALL_VERSION,
    url = ""
};

// ============================================================================
// Unified SourceMod forwards. These are the only automatic forwards exposed by
// the combined plugin. They dispatch to the renamed module implementations.
// ============================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    return Snipers_AskPluginLoad2(myself, late, error, errMax);
}

public void OnPluginStart()
{
    MWE_CreateCoreConVars();
    MWE_InitLaserRewardStorage();
    MWE_ResetSharedRuntime();
    Rifles_OnPluginStart();
    Snipers_OnPluginStart();
    Shotgun_OnPluginStart();
    Smgs_OnPluginStart();
    Pistols_OnPluginStart();
    Melee_OnPluginStart();

    // 所有模块的 ConVar 已经创建完毕后，只生成/执行这一份整合版 cfg。
    AutoExecConfig(true, "l4d2_mwe_all");

    HookEventEx("player_hurt", MWE_Event_PlayerHurtFallback, EventHookMode_Post);
    HookEventEx("infected_hurt", MWE_Event_InfectedHurtFallback, EventHookMode_Post);
    HookEventEx("bullet_impact", MWE_Event_BulletImpact, EventHookMode_Post);
    HookEventEx("weapon_fire", MWE_Event_MountedGunWeaponFire, EventHookMode_Post);
    HookEventEx("player_death", MWE_Event_PlayerDeathLaserReward, EventHookMode_Post);
    HookEventEx("round_end", MWE_Event_ReliableQuiet, EventHookMode_PostNoCopy);
    HookEventEx("map_transition", MWE_Event_ReliableQuiet, EventHookMode_PostNoCopy);
    HookEventEx("map_transition", MWE_Event_LaserCampaignTransition, EventHookMode_PostNoCopy);
    HookEventEx("mission_lost", MWE_Event_ReliableQuiet, EventHookMode_PostNoCopy);
    HookEventEx("finale_win", MWE_Event_ReliableQuiet, EventHookMode_PostNoCopy);
    HookEventEx("finale_win", MWE_Event_LaserCampaignCompleted, EventHookMode_PostNoCopy);
    HookEventEx("round_start", MWE_Event_RoundStartQuiet, EventHookMode_PostNoCopy);

    // 玩家在聊天框输入 !mwe 或 /mwe 会触发 sm_mwe；
    // 同时监听 say/say_team，使 mwe、武器、!武器 等纯聊天输入也能打开菜单。
    RegConsoleCmd("sm_mwe", MWE_Command_Help, "Open Multi Weapon Effects help menu. Chat: !mwe or /mwe");
    RegConsoleCmd("sm_mwelaser", MWE_Command_Laser, "Spend one SI-kill cycle credit to give laser sight to your primary weapon. Chat: !mwelaser");
    RegConsoleCmd("sm_mwehelp", MWE_Command_Help, "Open Multi Weapon Effects help menu. Chat: !mwehelp or /mwehelp");
    RegConsoleCmd("sm_weapons", MWE_Command_Help, "Open Multi Weapon Effects help menu. Chat: !weapons or /weapons");
    AddCommandListener(MWE_Command_Say, "say");
    AddCommandListener(MWE_Command_Say, "say_team");

    HookEventEx("player_spawn", MWE_Event_PlayerSpawnIntro, EventHookMode_Post);
    HookEventEx("player_team", MWE_Event_PlayerTeamIntro, EventHookMode_Post);
    HookEventEx("bot_player_replace", MWE_Event_BotPlayerReplaceIntro, EventHookMode_Post);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            MWE_InstallClientWeaponCacheHooks(client);
        }
    }
}

public void OnConfigsExecuted()
{
    // 这三个模块存在缓存型 ConVar。配置文件执行后必须刷新缓存，
    // 否则首次加载时可能继续使用默认值，直到管理员手动改动 ConVar。
    Shotgun_CacheConVars();
    Smgs_RefreshConfigCache();
    Pistols_OnConfigsExecuted();
}

public void OnMapStart()
{
    MWE_HandleLaserCampaignMapStart();
    MWE_g_fMapStartTime = GetGameTime();
    MWE_g_iExplosionSprite = PrecacheModel("sprites/zerogxplode.spr", true);
    PrecacheSound(MWE_EXPLOSION_SOUND, true);
    MWE_g_bReliableQuietWindow = false;
    MWE_g_fReliableQuietUntil = MWE_g_fMapStartTime + MWE_GetMapchangeQuietSeconds();
    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_g_bIntroHintShown[client] = false;
        MWE_g_bIntroHintPending[client] = false;
    }
    MWE_ResetMapRuntime();
    Shotgun_OnMapStart();
    Smgs_OnMapStart();
    Pistols_OnMapStart();
    Melee_OnMapStart();
}

public void OnMapEnd()
{
    MWE_BeginReliableQuietWindow(MWE_MAPEND_QUIET_TIME);
    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_g_bIntroHintPending[client] = false;
    }
    MWE_ResetMapRuntime();
}

public void OnPluginEnd()
{
    MWE_UninstallAllClientRuntimeHooks();
    Shotgun_OnPluginEnd();

    delete MWE_g_smLaserKillScoreByAuth;
    MWE_g_smLaserKillScoreByAuth = null;
    delete MWE_g_smLaserLoopCountByAuth;
    MWE_g_smLaserLoopCountByAuth = null;
}

public void OnClientPutInServer(int client)
{
    MWE_g_bIntroHintShown[client] = false;
    MWE_g_bIntroHintPending[client] = false;
    MWE_ClearLaserRewardClient(client);
    MWE_InstallClientWeaponCacheHooks(client);
    Rifles_OnClientPutInServer(client);
    Snipers_OnClientPutInServer(client);
    Shotgun_OnClientPutInServer(client);
    Pistols_OnClientPutInServer(client);
    Melee_OnClientPutInServer(client);
    MWE_ScheduleIntroHint(client);
}

public void OnClientPostAdminCheck(int client)
{
    MWE_RestoreLaserRewardClient(client);
}

public void OnClientDisconnect(int client)
{
    MWE_SaveLaserRewardClient(client);
    MWE_g_bIntroHintShown[client] = false;
    MWE_g_bIntroHintPending[client] = false;
    MWE_ClearClientRuntime(client);
    Rifles_OnClientDisconnect(client);
    Snipers_OnClientDisconnect(client);
    Shotgun_OnClientDisconnect(client);
    Melee_OnClientDisconnect(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    Rifles_OnEntityCreated(entity, classname);
    Snipers_OnEntityCreated(entity, classname);
    Shotgun_OnEntityCreated(entity, classname);
    Smgs_OnEntityCreated(entity, classname);
    Pistols_OnEntityCreated(entity, classname);
    Melee_OnEntityCreated(entity, classname);
}


// ============================================================================
// Shared CPU/recursion helpers for the combined plugin.
// ============================================================================

#define MWE_MAX_EDICTS 2049
#define MWE_HEAVY_SLOT_COUNT 16
#define MWE_HEAVY_RIFLE_EXPLOSION 0
#define MWE_HEAVY_RIFLE_GLOBAL 1
#define MWE_HEAVY_RIFLE_AREA_COMMON 2
#define MWE_HEAVY_SNIPER_AREA 3
#define MWE_HEAVY_SNIPER_GLOBAL 4
#define MWE_HEAVY_SHOTGUN_AREA 5

int MWE_g_iSharedTakeDamageEntRef[MWE_MAX_EDICTS];
float MWE_g_fLastHeavyEffectTime[MAXPLAYERS + 1][MWE_HEAVY_SLOT_COUNT];
bool MWE_g_bApplyingPluginDamage;


enum MWE_WeaponCategory
{
    MWE_WeaponCategory_None = 0,
    MWE_WeaponCategory_Rifle,
    MWE_WeaponCategory_Sniper,
    MWE_WeaponCategory_Shotgun,
    MWE_WeaponCategory_Smg,
    MWE_WeaponCategory_Pistol,
    MWE_WeaponCategory_Melee,
    MWE_WeaponCategory_Other
};

#define MWE_ACTIVE_WEAPON_CACHE_INTERVAL 0.50
#define MWE_LAST_FIRE_WEAPON_WINDOW 0.35

bool MWE_g_bWeaponCacheHooksInstalled[MAXPLAYERS + 1];
int MWE_g_iCachedWeaponEntRef[MAXPLAYERS + 1];
char MWE_g_sCachedWeaponClass[MAXPLAYERS + 1][64];
MWE_WeaponCategory MWE_g_iCachedWeaponCategory[MAXPLAYERS + 1];
float MWE_g_fNextWeaponRefreshTime[MAXPLAYERS + 1];
char MWE_g_sLastFireWeaponClass[MAXPLAYERS + 1][64];
MWE_WeaponCategory MWE_g_iLastFireWeaponCategory[MAXPLAYERS + 1];
float MWE_g_fLastFireWeaponTime[MAXPLAYERS + 1];

#define MWE_SHARED_HIT_DEDUP_WINDOW 0.12
#define MWE_MAPCHANGE_NOTIFY_SUPPRESS_TIME 20.0
#define MWE_PICKUP_NOTICE_COOLDOWN 6.0
int MWE_g_iLastSharedHitAttacker[MWE_MAX_EDICTS];
MWE_WeaponCategory MWE_g_iLastSharedHitCategory[MWE_MAX_EDICTS];
char MWE_g_sLastSharedHitWeapon[MWE_MAX_EDICTS][64];
float MWE_g_fLastSharedHitTime[MWE_MAX_EDICTS];
float MWE_g_fNextPickupNoticeTime[MAXPLAYERS + 1];
float MWE_g_fMountedGunNextIgniteTime[MWE_MAX_EDICTS];


void MWE_CreateCoreConVars()
{
    MWE_g_cvCorePickupNotices = CreateConVar(
        "sm_mwe_all_pickup_notices",
        "0",
        "整合版拾取武器说明聊天总开关。0=关闭提示并避免 reliable overflow；1=允许各模块按自身 notify 设置显示提示。",
        0,
        true,
        0.0,
        true,
        1.0
    );

    MWE_g_cvCoreQuietSeconds = CreateConVar(
        "sm_mwe_all_mapchange_quiet_seconds",
        "45.0",
        "每张地图开始后屏蔽拾取说明聊天的秒数，用于避开换图可靠消息高峰。",
        0,
        true,
        0.0,
        true,
        180.0
    );

    MWE_g_cvCoreIntroHint = CreateConVar(
        "sm_mwe_all_intro_hint",
        "1",
        "玩家首次成为幸存者后只发送 1 条 !mwe 菜单提示。0=关闭；1=开启。",
        0,
        true,
        0.0,
        true,
        1.0
    );

    MWE_g_cvCoreIntroDelay = CreateConVar(
        "sm_mwe_all_intro_delay",
        "50.0",
        "玩家成为幸存者后延迟多少秒发送 !mwe 菜单提示；会自动避开换图静默窗口。",
        0,
        true,
        5.0,
        true,
        180.0
    );

    MWE_g_cvLaserRewardEnable = CreateConVar(
        "sm_mwe_laser_reward_enable",
        "1",
        "特感击杀循环兑换激光瞄准器功能开关。1=开启；0=关闭。",
        0,
        true,
        0.0,
        true,
        1.0
    );

    MWE_g_cvLaserKillThreshold = CreateConVar(
        "sm_mwe_laser_kill_threshold",
        "50",
        "激光奖励循环阈值。同一战役内跨章节累计；达到或超过该值时点数清零，并获得 1 次 !mwelaser 使用次数。",
        0,
        true,
        1.0,
        true,
        1000.0
    );

    MWE_g_cvLaserSpecialKillPoints = CreateConVar(
        "sm_mwe_laser_special_kill_points",
        "1",
        "击杀普通特感 Smoker/Boomer/Hunter/Spitter/Jockey/Charger 增加的点数。",
        0,
        true,
        0.0,
        true,
        1000.0
    );

    MWE_g_cvLaserTankKillPoints = CreateConVar(
        "sm_mwe_laser_tank_kill_points",
        "10",
        "击杀 Tank 增加的点数。",
        0,
        true,
        0.0,
        true,
        1000.0
    );

    MWE_g_cvLaserCommandCost = CreateConVar(
        "sm_mwe_laser_command_cost",
        "1",
        "聊天命令 !mwelaser 每次消耗多少个已完成循环次数。0=免费使用。",
        0,
        true,
        0.0,
        true,
        100.0
    );

    MWE_g_cvLaserChatNotify = CreateConVar(
        "sm_mwe_laser_chat_notify",
        "1",
        "激光奖励循环完成和 !mwelaser 使用结果是否发送聊天提示。1=提示；0=静默。",
        0,
        true,
        0.0,
        true,
        1.0
    );

    MWE_g_cvMountedGunEnable = CreateConVar(
        "sm_mwe_mountedgun_enable",
        "1",
        "固定机枪效果总开关。1=开启；0=关闭。",
        0,
        true,
        0.0,
        true,
        1.0
    );

    MWE_g_cvMountedGunBurnDuration = CreateConVar(
        "sm_mwe_mountedgun_burn_duration",
        "5.0",
        "玩家操控固定机枪命中特感 / Witch / Tank 时的点燃持续时间（秒）。",
        0,
        true,
        0.1,
        true,
        60.0
    );

    MWE_g_cvMountedGunReigniteCooldown = CreateConVar(
        "sm_mwe_mountedgun_reignite_cooldown",
        "0.75",
        "同一目标被固定机枪重复点燃的最小间隔（秒），用于降低高射速重复触发。",
        0,
        true,
        0.0,
        true,
        10.0
    );

    MWE_g_cvMountedGunExplosionChance = CreateConVar(
        "sm_mwe_mountedgun_explosion_chance",
        "10.0",
        "固定机枪每发子弹在弹道命中点触发小爆炸的概率；墙面、地面、敌人命中点均可触发。",
        0,
        true,
        0.0,
        true,
        100.0
    );

    MWE_g_cvMountedGunExplosionRadius = CreateConVar(
        "sm_mwe_mountedgun_explosion_radius",
        "130.0",
        "固定机枪小爆炸的伤害和特感/Tank 僵直半径。",
        0,
        true,
        0.0,
        true,
        500.0
    );

    MWE_g_cvMountedGunExplosionDamage = CreateConVar(
        "sm_mwe_mountedgun_explosion_damage",
        "30.0",
        "固定机枪小爆炸的 DMG_BLAST 范围伤害。",
        0,
        true,
        0.0,
        true,
        1000.0
    );

    MWE_g_cvMountedGunExplosionForce = CreateConVar(
        "sm_mwe_mountedgun_explosion_force",
        "330.0",
        "DEPRECATED: 旧版固定机枪物理击退力度；1.0.16 起爆炸僵直统一使用 VScript Stagger。",
        0,
        true,
        0.0,
        true,
        1200.0
    );

    // cfg 统一由整合版主入口生成。
}

float MWE_GetMapchangeQuietSeconds()
{
    if (MWE_g_cvCoreQuietSeconds == null)
    {
        return MWE_DEFAULT_MAPCHANGE_QUIET_TIME;
    }

    float value = MWE_g_cvCoreQuietSeconds.FloatValue;
    if (value < 0.0)
    {
        return 0.0;
    }
    return value;
}

float MWE_GetIntroHintDelay()
{
    float delay = MWE_DEFAULT_INTRO_HINT_DELAY;
    if (MWE_g_cvCoreIntroDelay != null)
    {
        delay = MWE_g_cvCoreIntroDelay.FloatValue;
    }

    if (delay < 5.0)
    {
        delay = 5.0;
    }

    float now = GetGameTime();
    float quietLeft = MWE_g_fReliableQuietUntil - now + 5.0;
    if (quietLeft > delay)
    {
        delay = quietLeft;
    }

    return delay;
}

bool MWE_IsHumanSurvivorClient(int client, bool requireAlive)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    if (GetClientTeam(client) != MWE_TEAM_SURVIVOR)
    {
        return false;
    }

    if (requireAlive && !IsPlayerAlive(client))
    {
        return false;
    }

    return true;
}

void MWE_ScheduleIntroHint(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (MWE_g_cvCoreIntroHint != null && !MWE_g_cvCoreIntroHint.BoolValue)
    {
        return;
    }

    if (MWE_g_bIntroHintShown[client] || MWE_g_bIntroHintPending[client])
    {
        return;
    }

    MWE_g_bIntroHintPending[client] = true;
    CreateTimer(MWE_GetIntroHintDelay(), MWE_Timer_ShowIntroHint, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action MWE_Timer_ShowIntroHint(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || client > MaxClients)
    {
        return Plugin_Stop;
    }

    MWE_g_bIntroHintPending[client] = false;

    if (MWE_g_bIntroHintShown[client])
    {
        return Plugin_Stop;
    }

    if (MWE_g_cvCoreIntroHint != null && !MWE_g_cvCoreIntroHint.BoolValue)
    {
        return Plugin_Stop;
    }

    if (!MWE_IsHumanSurvivorClient(client, false))
    {
        return Plugin_Stop;
    }

    float now = GetGameTime();
    if (MWE_IsReliableQuietActive(now))
    {
        MWE_g_bIntroHintPending[client] = true;
        CreateTimer(8.0, MWE_Timer_ShowIntroHint, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    PrintToChat(client, "\x04[武器强化]\x01 输入 \x03!mwe\x01 或 \x03!武器\x01 查看全部武器效果说明。");
    MWE_g_bIntroHintShown[client] = true;
    return Plugin_Stop;
}

public void MWE_Event_PlayerSpawnIntro(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    MWE_ScheduleIntroHint(client);
}

public void MWE_Event_PlayerTeamIntro(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    MWE_ScheduleIntroHint(client);
}

public void MWE_Event_BotPlayerReplaceIntro(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("player"));
    MWE_ScheduleIntroHint(client);
}

public Action MWE_Command_Help(int client, int args)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Handled;
    }

    MWE_ShowHelpMainMenu(client);
    return Plugin_Handled;
}

public Action MWE_Command_Say(int client, const char[] command, int argc)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);

    if (StrEqual(text, "!mwelaser", false)
        || StrEqual(text, "/mwelaser", false)
        || StrEqual(text, "mwelaser", false))
    {
        MWE_Command_Laser(client, 0);
        return Plugin_Handled;
    }

    if (StrEqual(text, "!mwe", false)
        || StrEqual(text, "/mwe", false)
        || StrEqual(text, "mwe", false)
        || StrEqual(text, "!mwehelp", false)
        || StrEqual(text, "/mwehelp", false)
        || StrEqual(text, "mwehelp", false)
        || StrEqual(text, "!weapons", false)
        || StrEqual(text, "/weapons", false)
        || StrEqual(text, "weapons", false)
        || StrEqual(text, "!武器", false)
        || StrEqual(text, "/武器", false)
        || StrEqual(text, "武器", false))
    {
        MWE_ShowHelpMainMenu(client);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

void MWE_InitLaserRewardStorage()
{
    if (MWE_g_smLaserKillScoreByAuth == null)
    {
        MWE_g_smLaserKillScoreByAuth = new StringMap();
    }

    if (MWE_g_smLaserLoopCountByAuth == null)
    {
        MWE_g_smLaserLoopCountByAuth = new StringMap();
    }
}

bool MWE_GetLaserRewardAuthKey(int client, char[] key, int maxlen)
{
    key[0] = '\0';

    if (client < 1 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
    {
        return false;
    }

    if (GetClientAuthId(client, AuthId_SteamID64, key, maxlen, true) && key[0] != '\0')
    {
        return true;
    }

    key[0] = '\0';
    return GetClientAuthId(client, AuthId_Steam2, key, maxlen, true) && key[0] != '\0';
}

void MWE_SaveLaserRewardClient(int client)
{
    if (MWE_g_smLaserKillScoreByAuth == null || MWE_g_smLaserLoopCountByAuth == null)
    {
        return;
    }

    char authKey[64];
    if (!MWE_GetLaserRewardAuthKey(client, authKey, sizeof(authKey)))
    {
        return;
    }

    MWE_g_smLaserKillScoreByAuth.SetValue(authKey, MWE_g_iLaserKillScore[client], true);
    MWE_g_smLaserLoopCountByAuth.SetValue(authKey, MWE_g_iLaserLoopCount[client], true);
}

void MWE_RestoreLaserRewardClient(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    MWE_ClearLaserRewardClient(client);

    if (MWE_g_smLaserKillScoreByAuth == null || MWE_g_smLaserLoopCountByAuth == null)
    {
        return;
    }

    char authKey[64];
    if (!MWE_GetLaserRewardAuthKey(client, authKey, sizeof(authKey)))
    {
        return;
    }

    int value = 0;
    if (MWE_g_smLaserKillScoreByAuth.GetValue(authKey, value))
    {
        MWE_g_iLaserKillScore[client] = value;
    }

    value = 0;
    if (MWE_g_smLaserLoopCountByAuth.GetValue(authKey, value))
    {
        MWE_g_iLaserLoopCount[client] = value;
    }
}

void MWE_ResetAllLaserRewardProgress()
{
    if (MWE_g_smLaserKillScoreByAuth != null)
    {
        MWE_g_smLaserKillScoreByAuth.Clear();
    }

    if (MWE_g_smLaserLoopCountByAuth != null)
    {
        MWE_g_smLaserLoopCountByAuth.Clear();
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_ClearLaserRewardClient(client);
    }
}

bool MWE_GetOfficialCampaignKey(const char[] mapName, char[] campaignKey, int maxlen)
{
    campaignKey[0] = '\0';

    if (mapName[0] != 'c' && mapName[0] != 'C')
    {
        return false;
    }

    int pos = 1;
    if (!IsCharNumeric(mapName[pos]))
    {
        return false;
    }

    while (mapName[pos] != '\0' && IsCharNumeric(mapName[pos]))
    {
        pos++;
    }

    if ((mapName[pos] != 'm' && mapName[pos] != 'M') || !IsCharNumeric(mapName[pos + 1]))
    {
        return false;
    }

    if (pos >= maxlen)
    {
        pos = maxlen - 1;
    }

    strcopy(campaignKey, maxlen, mapName);
    campaignKey[pos] = '\0';
    return campaignKey[0] != '\0';
}

void MWE_HandleLaserCampaignMapStart()
{
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));

    bool resetProgress = MWE_g_bLaserResetOnNextMap;

    if (!resetProgress && MWE_g_sLaserPreviousMap[0] != '\0' && !StrEqual(currentMap, MWE_g_sLaserPreviousMap, false))
    {
        if (!MWE_g_bLaserCampaignTransition)
        {
            char previousCampaign[32];
            char currentCampaign[32];
            bool previousOfficial = MWE_GetOfficialCampaignKey(MWE_g_sLaserPreviousMap, previousCampaign, sizeof(previousCampaign));
            bool currentOfficial = MWE_GetOfficialCampaignKey(currentMap, currentCampaign, sizeof(currentCampaign));

            // 手动跳到同一官方战役的其他章节时继续累计；其余无 map_transition 的换图视为新战役。
            if (!previousOfficial || !currentOfficial || !StrEqual(previousCampaign, currentCampaign, false))
            {
                resetProgress = true;
            }
        }
    }

    if (resetProgress)
    {
        MWE_ResetAllLaserRewardProgress();
    }

    strcopy(MWE_g_sLaserPreviousMap, sizeof(MWE_g_sLaserPreviousMap), currentMap);
    MWE_g_bLaserCampaignTransition = false;
    MWE_g_bLaserResetOnNextMap = false;
}

public void MWE_Event_LaserCampaignTransition(Event event, const char[] name, bool dontBroadcast)
{
    // 普通章节过关：下一张图仍属于当前战役，保留玩家累计进度。
    MWE_g_bLaserCampaignTransition = true;
}

public void MWE_Event_LaserCampaignCompleted(Event event, const char[] name, bool dontBroadcast)
{
    // 最终关通关：保留到本图结束，在下一张地图开始时统一清零。
    MWE_g_bLaserResetOnNextMap = true;
    MWE_g_bLaserCampaignTransition = false;
}

void MWE_ClearLaserRewardClient(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    MWE_g_iLaserKillScore[client] = 0;
    MWE_g_iLaserLoopCount[client] = 0;
}

bool MWE_ShouldNotifyLaserReward()
{
    return MWE_g_cvLaserChatNotify != null && MWE_g_cvLaserChatNotify.BoolValue;
}

int MWE_GetLaserKillThreshold()
{
    if (MWE_g_cvLaserKillThreshold == null)
    {
        return 50;
    }

    int threshold = MWE_g_cvLaserKillThreshold.IntValue;
    if (threshold < 1)
    {
        threshold = 1;
    }
    return threshold;
}

int MWE_GetLaserSpecialKillPoints()
{
    if (MWE_g_cvLaserSpecialKillPoints == null)
    {
        return 1;
    }

    int points = MWE_g_cvLaserSpecialKillPoints.IntValue;
    return points < 0 ? 0 : points;
}

int MWE_GetLaserTankKillPoints()
{
    if (MWE_g_cvLaserTankKillPoints == null)
    {
        return 10;
    }

    int points = MWE_g_cvLaserTankKillPoints.IntValue;
    return points < 0 ? 0 : points;
}

int MWE_GetLaserCommandCost()
{
    if (MWE_g_cvLaserCommandCost == null)
    {
        return 1;
    }

    int cost = MWE_g_cvLaserCommandCost.IntValue;
    return cost < 0 ? 0 : cost;
}

public void MWE_Event_PlayerDeathLaserReward(Event event, const char[] name, bool dontBroadcast)
{
    if (MWE_g_cvLaserRewardEnable != null && !MWE_g_cvLaserRewardEnable.BoolValue)
    {
        return;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!MWE_IsHumanSurvivorClient(attacker, true))
    {
        return;
    }

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != 3)
    {
        return;
    }

    if (!HasEntProp(victim, Prop_Send, "m_zombieClass"))
    {
        return;
    }

    int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    int points = 0;
    if (zombieClass == 8)
    {
        points = MWE_GetLaserTankKillPoints();
    }
    else if (zombieClass >= 1 && zombieClass <= 6)
    {
        points = MWE_GetLaserSpecialKillPoints();
    }

    if (points <= 0)
    {
        return;
    }

    MWE_AddLaserKillPoints(attacker, points);
}

void MWE_AddLaserKillPoints(int client, int points)
{
    if (client < 1 || client > MaxClients || points <= 0)
    {
        return;
    }

    int threshold = MWE_GetLaserKillThreshold();
    MWE_g_iLaserKillScore[client] += points;

    if (MWE_g_iLaserKillScore[client] >= threshold)
    {
        MWE_g_iLaserKillScore[client] = 0;
        MWE_g_iLaserLoopCount[client]++;

        if (MWE_ShouldNotifyLaserReward() && IsClientInGame(client))
        {
            PrintToChat(client, "\x04[武器强化]\x01 特感击杀循环完成，已获得 \x03%d\x01 次激光奖励。输入 \x03!mwelaser\x01 消耗次数安装激光瞄准器。", MWE_g_iLaserLoopCount[client]);
        }
    }

    MWE_SaveLaserRewardClient(client);
}

public Action MWE_Command_Laser(int client, int args)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Handled;
    }

    if (MWE_g_cvLaserRewardEnable != null && !MWE_g_cvLaserRewardEnable.BoolValue)
    {
        PrintToChat(client, "\x04[武器强化]\x01 !mwelaser 当前已关闭。");
        return Plugin_Handled;
    }

    if (!MWE_IsHumanSurvivorClient(client, true))
    {
        PrintToChat(client, "\x04[武器强化]\x01 只有存活的真人幸存者可以使用 !mwelaser。");
        return Plugin_Handled;
    }

    int cost = MWE_GetLaserCommandCost();
    if (cost > 0 && MWE_g_iLaserLoopCount[client] < cost)
    {
        PrintToChat(client, "\x04[武器强化]\x01 激光奖励次数不足：当前 \x03%d\x01 / 需要 \x03%d\x01；本轮进度 \x03%d\x01 / \x03%d\x01。", MWE_g_iLaserLoopCount[client], cost, MWE_g_iLaserKillScore[client], MWE_GetLaserKillThreshold());
        return Plugin_Handled;
    }

    if (MWE_PrimaryWeaponHasLaserSight(client))
    {
        PrintToChat(client, "\x04[武器强化]\x01 你的主武器已经有激光瞄准器，本次不消耗奖励次数。");
        return Plugin_Handled;
    }

    if (!MWE_GiveLaserSightToPrimary(client))
    {
        PrintToChat(client, "\x04[武器强化]\x01 没有找到可安装激光的主武器，本次不消耗奖励次数。");
        return Plugin_Handled;
    }

    if (cost > 0)
    {
        MWE_g_iLaserLoopCount[client] -= cost;
        if (MWE_g_iLaserLoopCount[client] < 0)
        {
            MWE_g_iLaserLoopCount[client] = 0;
        }
        MWE_SaveLaserRewardClient(client);
    }

    if (MWE_ShouldNotifyLaserReward())
    {
        PrintToChat(client, "\x04[武器强化]\x01 已给主武器安装激光瞄准器，剩余激光奖励次数：\x03%d\x01。", MWE_g_iLaserLoopCount[client]);
    }
    return Plugin_Handled;
}

int MWE_GetPrimaryWeaponEntity(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return -1;
    }

    int weapon = GetPlayerWeaponSlot(client, 0);
    if (weapon > MaxClients && IsValidEntity(weapon))
    {
        return weapon;
    }

    return -1;
}

bool MWE_PrimaryWeaponHasLaserSight(int client)
{
    int weapon = MWE_GetPrimaryWeaponEntity(client);
    if (weapon <= MaxClients || !IsValidEntity(weapon) || !HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
    {
        return false;
    }

    int flags = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
    return (flags & MWE_UPGRADE_BIT_LASER_SIGHT) != 0;
}

bool MWE_GiveLaserSightToPrimary(int client)
{
    int weapon = MWE_GetPrimaryWeaponEntity(client);
    if (weapon <= MaxClients || !IsValidEntity(weapon) || !HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
    {
        return false;
    }

    int flags = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
    flags |= MWE_UPGRADE_BIT_LASER_SIGHT;
    SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", flags);
    return true;
}

void MWE_ShowHelpMainMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpMain);
    menu.SetTitle("武器强化说明\n聊天输入 !mwe / !武器 可再次打开");
    menu.AddItem("rifles", "步枪类");
    menu.AddItem("snipers", "狙击枪类");
    menu.AddItem("shotguns", "霰弹枪类");
    menu.AddItem("smgs", "冲锋枪类");
    menu.AddItem("pistols", "手枪 / 马格南");
    menu.AddItem("melee", "近战 / 电锯");
    menu.AddItem("mountedgun", "固定机枪");
    menu.AddItem("tips", "使用提示");
    menu.ExitButton = true;
    menu.Display(client, 30);
}

public int MWE_MenuHandler_HelpMain(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select)
    {
        return 0;
    }

    char info[32];
    menu.GetItem(item, info, sizeof(info));

    if (StrEqual(info, "rifles"))
    {
        MWE_ShowRiflesHelpMenu(client);
    }
    else if (StrEqual(info, "snipers"))
    {
        MWE_ShowSnipersHelpMenu(client);
    }
    else if (StrEqual(info, "shotguns"))
    {
        MWE_ShowShotgunsHelpMenu(client);
    }
    else if (StrEqual(info, "smgs"))
    {
        MWE_ShowSmgsHelpMenu(client);
    }
    else if (StrEqual(info, "pistols"))
    {
        MWE_ShowPistolsHelpMenu(client);
    }
    else if (StrEqual(info, "melee"))
    {
        MWE_ShowMeleeHelpMenu(client);
    }
    else if (StrEqual(info, "mountedgun"))
    {
        MWE_ShowMountedGunHelpMenu(client);
    }
    else if (StrEqual(info, "tips"))
    {
        MWE_ShowTipsHelpMenu(client);
    }

    return 0;
}

void MWE_AddBackItem(Menu menu)
{
    menu.AddItem("back", "返回分类菜单");
}

public int MWE_MenuHandler_HelpSub(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "back"))
        {
            MWE_ShowHelpMainMenu(client);
        }
    }

    return 0;
}

void MWE_ShowRiflesHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("步枪类效果");
    menu.AddItem("m16", "M16: 攻击给虚血/百分比伤害", ITEMDRAW_DISABLED);
    menu.AddItem("m4clip", "M16: 击杀特感时概率增加一整个实际弹匣容量", ITEMDRAW_DISABLED);
    menu.AddItem("ak47", "AK47: 打特感触发肾上腺素", ITEMDRAW_DISABLED);
    menu.AddItem("ak47b", "AK47: 肾上腺素射击25%弹匣+1；蹲下加伤", ITEMDRAW_DISABLED);
    menu.AddItem("sg552", "SG552: 特殊弹药/爆炸/火力全开", ITEMDRAW_DISABLED);
    menu.AddItem("desert", "三连发: 击退/附伤/小范围溅射", ITEMDRAW_DISABLED);
    menu.AddItem("m60", "M60: 爆炸点燃；攻击回血", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowSnipersHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("狙击枪类效果");
    menu.AddItem("military", "30狙: 攻击爆炸/范围点燃", ITEMDRAW_DISABLED);
    menu.AddItem("hunting", "15狙: 范围胆汁/虚血/肾上腺素", ITEMDRAW_DISABLED);
    menu.AddItem("awp", "AWP: 爆炸/附伤/肾上腺素", ITEMDRAW_DISABLED);
    menu.AddItem("awp2", "AWP: 低概率全场点燃+全队肾上腺素", ITEMDRAW_DISABLED);
    menu.AddItem("scout", "Scout: 全场胆汁/治疗/击退/回血", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowShotgunsHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("霰弹枪类效果");
    menu.AddItem("pump", "木喷: 打僵尸加虚血；小范围击退", ITEMDRAW_DISABLED);
    menu.AddItem("pump2", "木喷: 近距离附伤并触发肾上腺素", ITEMDRAW_DISABLED);
    menu.AddItem("chrome", "铁喷: 肾上腺素/燃烧弹/弹着点爆炸", ITEMDRAW_DISABLED);
    menu.AddItem("auto", "战术喷: 加虚血/击退/近距离附伤", ITEMDRAW_DISABLED);
    menu.AddItem("spas", "SPAS: 肾上腺素/燃烧弹/弹着点爆炸", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowSmgsHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("冲锋枪类效果");
    menu.AddItem("uzi", "UZI: 范围伤害；低概率秒杀小僵尸", ITEMDRAW_DISABLED);
    menu.AddItem("uzi2", "UZI: 特感损失当前生命；Tank不受秒杀", ITEMDRAW_DISABLED);
    menu.AddItem("silenced", "消音SMG: 附带燃烧伤害和点燃", ITEMDRAW_DISABLED);
    menu.AddItem("mp5", "MP5: 打特感/Tank回血；击中队友输血", ITEMDRAW_DISABLED);
    menu.AddItem("mp52", "MP5: 肾上腺素期间秒杀/虚血击退", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowPistolsHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("手枪 / 马格南效果");
    menu.AddItem("pistol", "手枪: 根据射击者损失的生命值追加伤害", ITEMDRAW_DISABLED);
    menu.AddItem("magnum", "马格南: 击中特感随机特殊弹药", ITEMDRAW_DISABLED);
    menu.AddItem("magnum2", "马格南: 命中Tank/Witch给随机特殊弹药", ITEMDRAW_DISABLED);
    menu.AddItem("magnum3", "马格南: 爆头必爆/非爆头按概率爆炸", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowMeleeHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("近战 / 电锯效果");
    menu.AddItem("melee", "近战: 低于40%血时攻击概率回实血", ITEMDRAW_DISABLED);
    menu.AddItem("melee2", "近战: 低于10%血时攻击概率肾上腺素", ITEMDRAW_DISABLED);
    menu.AddItem("chainsaw", "电锯: 攻击范围治疗", ITEMDRAW_DISABLED);
    menu.AddItem("chainsaw2", "电锯: 肾上腺素期间攻击给自己虚血", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowMountedGunHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("固定机枪效果");
    menu.AddItem("mounted1", "玩家操控固定机枪命中特感 / Tank / Witch 时点燃目标", ITEMDRAW_DISABLED);
    menu.AddItem("mounted2", "每发子弹10%概率在弹着点小爆炸；墙/地面也能触发", ITEMDRAW_DISABLED);
    menu.AddItem("mounted3", "小爆炸僵直特感 / Tank；普通/Witch不参与", ITEMDRAW_DISABLED);
    menu.AddItem("mounted4", "可调: sm_mwe_mountedgun_explosion_chance / radius / damage", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_ShowTipsHelpMenu(int client)
{
    Menu menu = new Menu(MWE_MenuHandler_HelpSub);
    menu.SetTitle("使用提示");
    menu.AddItem("tip1", "聊天框输入 !mwe 或 !武器 打开本菜单", ITEMDRAW_DISABLED);
    menu.AddItem("tip2", "建议保持拾取提示关闭，避免换图 reliable overflow", ITEMDRAW_DISABLED);
    menu.AddItem("tip3", "菜单只在玩家主动查看时显示，不影响武器效果", ITEMDRAW_DISABLED);
    menu.AddItem("tip4", "同一战役跨章节累计特感击杀，输入 !mwelaser 兑换激光", ITEMDRAW_DISABLED);
    MWE_AddBackItem(menu);
    menu.ExitButton = true;
    menu.Display(client, 30);
}

void MWE_BeginReliableQuietWindow(float seconds)
{
    float now = GetGameTime();
    MWE_g_bReliableQuietWindow = true;
    MWE_g_fReliableQuietUntil = now + seconds;

    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_g_fNextPickupNoticeTime[client] = MWE_g_fReliableQuietUntil;
    }
}

public void MWE_Event_ReliableQuiet(Event event, const char[] name, bool dontBroadcast)
{
    MWE_BeginReliableQuietWindow(MWE_MAPEND_QUIET_TIME);
}

public void MWE_Event_RoundStartQuiet(Event event, const char[] name, bool dontBroadcast)
{
    float now = GetGameTime();
    MWE_g_bReliableQuietWindow = false;
    MWE_g_fReliableQuietUntil = now + MWE_GetMapchangeQuietSeconds();

    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_g_fNextPickupNoticeTime[client] = MWE_g_fReliableQuietUntil;
    }
}

bool MWE_IsReliableQuietActive(float now)
{
    if (MWE_g_bReliableQuietWindow)
    {
        return true;
    }

    return now < MWE_g_fReliableQuietUntil;
}

bool MWE_CanQueuePickupNotice(int client)
{
    // Auto pickup/equip weapon descriptions are intentionally disabled.
    // Players should use the chat menu commands (!mwe / !武器) to view all descriptions.
    // This prevents item_pickup / WeaponEquipPost bursts during map transition from sending reliable chat messages.
    return false;
}

bool MWE_CanSendPickupNotice(int client, const char[] noticeKey)
{
    // Auto pickup/equip weapon descriptions are intentionally disabled.
    // Keep the function as a global gate so old module code cannot print pickup descriptions
    // even if per-module notify ConVars are enabled in an existing cfg file.
    return false;
}

void MWE_MarkPickupNoticeSent(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    MWE_g_fNextPickupNoticeTime[client] = GetGameTime() + MWE_PICKUP_NOTICE_COOLDOWN;
}

void MWE_ResetSharedRuntime()
{
    for (int i = 0; i < MWE_MAX_EDICTS; i++)
    {
        MWE_g_iSharedTakeDamageEntRef[i] = 0;
        MWE_g_iLastSharedHitAttacker[i] = 0;
        MWE_g_iLastSharedHitCategory[i] = MWE_WeaponCategory_None;
        MWE_g_sLastSharedHitWeapon[i][0] = '\0';
        MWE_g_fLastSharedHitTime[i] = 0.0;
        MWE_g_fMountedGunNextIgniteTime[i] = 0.0;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_ClearClientWeaponCache(client);
        MWE_g_bWeaponCacheHooksInstalled[client] = false;
        MWE_g_bIntroHintShown[client] = false;
        MWE_g_bIntroHintPending[client] = false;
        MWE_ClearLaserRewardClient(client);
        MWE_g_fNextPickupNoticeTime[client] = 0.0;
        for (int slot = 0; slot < MWE_HEAVY_SLOT_COUNT; slot++)
        {
            MWE_g_fLastHeavyEffectTime[client][slot] = 0.0;
        }
    }

    MWE_g_bApplyingPluginDamage = false;
}

void MWE_ResetMapRuntime()
{
    for (int i = MaxClients + 1; i < MWE_MAX_EDICTS; i++)
    {
        MWE_g_iSharedTakeDamageEntRef[i] = 0;
        MWE_g_iLastSharedHitAttacker[i] = 0;
        MWE_g_iLastSharedHitCategory[i] = MWE_WeaponCategory_None;
        MWE_g_sLastSharedHitWeapon[i][0] = '\0';
        MWE_g_fLastSharedHitTime[i] = 0.0;
        MWE_g_fMountedGunNextIgniteTime[i] = 0.0;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_ClearClientWeaponCache(client);
        MWE_g_bIntroHintShown[client] = false;
        MWE_g_bIntroHintPending[client] = false;
        MWE_g_fNextPickupNoticeTime[client] = MWE_g_fReliableQuietUntil;
        // 换图时不要把 Hook 安装标记改成 false。
        // 客户端实体通常会跨战役章节保留；如果这里只清标记不 Unhook，
        // 下一图再次安装 WeaponSwitchPost/WeaponEquipPost 会造成重复回调和进图瞬间卡顿。
        for (int slot = 0; slot < MWE_HEAVY_SLOT_COUNT; slot++)
        {
            MWE_g_fLastHeavyEffectTime[client][slot] = 0.0;
        }
    }

    MWE_g_bApplyingPluginDamage = false;
}

void MWE_ClearClientRuntime(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    MWE_g_iSharedTakeDamageEntRef[client] = 0;
    MWE_g_iLastSharedHitAttacker[client] = 0;
    MWE_g_iLastSharedHitCategory[client] = MWE_WeaponCategory_None;
    MWE_g_sLastSharedHitWeapon[client][0] = '\0';
    MWE_g_fLastSharedHitTime[client] = 0.0;
    MWE_UninstallClientWeaponCacheHooks(client);
    MWE_ClearClientWeaponCache(client);
    MWE_g_bWeaponCacheHooksInstalled[client] = false;
    MWE_g_bIntroHintShown[client] = false;
    MWE_g_bIntroHintPending[client] = false;
    MWE_ClearLaserRewardClient(client);
    MWE_g_fNextPickupNoticeTime[client] = 0.0;
    if (client < MWE_MAX_EDICTS)
    {
        MWE_g_fMountedGunNextIgniteTime[client] = 0.0;
    }
    for (int slot = 0; slot < MWE_HEAVY_SLOT_COUNT; slot++)
    {
        MWE_g_fLastHeavyEffectTime[client][slot] = 0.0;
    }
}

void MWE_HookSharedTakeDamage(int entity)
{
    if (entity <= 0 || entity >= MWE_MAX_EDICTS)
    {
        return;
    }

    if (entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
        {
            return;
        }
    }
    else if (!IsValidEntity(entity))
    {
        return;
    }

    int ref = EntIndexToEntRef(entity);
    if (MWE_g_iSharedTakeDamageEntRef[entity] == ref)
    {
        return;
    }

    SDKHook(entity, SDKHook_OnTakeDamage, MWE_OnTakeDamage);
    SDKHook(entity, SDKHook_TraceAttack, MWE_OnTraceAttack);
    MWE_g_iSharedTakeDamageEntRef[entity] = ref;
}

public Action MWE_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (damage <= 0.0 || MWE_g_bApplyingPluginDamage)
    {
        return Plugin_Continue;
    }

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return Plugin_Continue;
    }

    if ((damagetype & DMG_BULLET) != 0 && MWE_IsClientUsingMountedGun(attacker))
    {
        MWE_TryApplyMountedGunBurn(victim, attacker);
    }

    MWE_WeaponCategory category = MWE_GetDamageWeaponCategory(attacker);

    if (category == MWE_WeaponCategory_Rifle)
    {
        return Rifles_OnEntityTakeDamage(victim, attacker, inflictor, damage, damagetype);
    }

    if (category == MWE_WeaponCategory_Sniper)
    {
        return Snipers_OnTakeDamage(victim, attacker, inflictor, damage, damagetype);
    }

    if (category == MWE_WeaponCategory_Shotgun)
    {
        return Shotgun_OnTakeDamage(victim, attacker, inflictor, damage, damagetype);
    }

    return Plugin_Continue;
}

public Action MWE_OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (damage <= 0.0 || MWE_g_bApplyingPluginDamage)
    {
        return Plugin_Continue;
    }

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return Plugin_Continue;
    }

    char weapon[64];
    if (!MWE_GetDamageWeaponClass(attacker, weapon, sizeof(weapon)))
    {
        return Plugin_Continue;
    }

    if (StrEqual(weapon, "weapon_pistol_magnum", false))
    {
        return Pistols_OnTraceAttackMagnum(victim, attacker, inflictor, damage, damagetype, ammotype, hitbox, hitgroup);
    }

    if (StrEqual(weapon, "weapon_rifle_ak47", false))
    {
        return Rifles_OnTraceAttackAK47(victim, attacker, inflictor, damage, damagetype, ammotype, hitbox, hitgroup);
    }

    return Plugin_Continue;
}

void MWE_InstallClientWeaponCacheHooks(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    if (!MWE_g_bWeaponCacheHooksInstalled[client])
    {
        SDKHook(client, SDKHook_WeaponSwitchPost, MWE_OnWeaponSwitchPost);
        SDKHook(client, SDKHook_WeaponEquipPost, MWE_OnWeaponEquipPost);
        MWE_g_bWeaponCacheHooksInstalled[client] = true;
    }

    MWE_RefreshActiveWeaponCache(client);
}

void MWE_UninstallClientWeaponCacheHooks(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (MWE_g_bWeaponCacheHooksInstalled[client])
    {
        if (IsClientInGame(client))
        {
            SDKUnhook(client, SDKHook_WeaponSwitchPost, MWE_OnWeaponSwitchPost);
            SDKUnhook(client, SDKHook_WeaponEquipPost, MWE_OnWeaponEquipPost);
        }
        MWE_g_bWeaponCacheHooksInstalled[client] = false;
    }
}

void MWE_UninstallAllClientRuntimeHooks()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        MWE_UninstallClientWeaponCacheHooks(client);
        Snipers_UninstallWeaponEquipHook(client);
        Shotgun_UninstallWeaponEquipHook(client);
    }
}

public void MWE_OnWeaponSwitchPost(int client, int weaponEnt)
{
    if (!MWE_RefreshWeaponCacheFromEntity(client, weaponEnt))
    {
        MWE_RefreshActiveWeaponCache(client);
    }
}

public void MWE_OnWeaponEquipPost(int client, int weaponEnt)
{
    if (!MWE_RefreshWeaponCacheFromEntity(client, weaponEnt))
    {
        MWE_RefreshActiveWeaponCache(client);
    }
}

void MWE_ClearClientWeaponCache(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    MWE_g_iCachedWeaponEntRef[client] = 0;
    MWE_g_sCachedWeaponClass[client][0] = '\0';
    MWE_g_iCachedWeaponCategory[client] = MWE_WeaponCategory_None;
    MWE_g_fNextWeaponRefreshTime[client] = 0.0;
    MWE_g_sLastFireWeaponClass[client][0] = '\0';
    MWE_g_iLastFireWeaponCategory[client] = MWE_WeaponCategory_None;
    MWE_g_fLastFireWeaponTime[client] = 0.0;
}

bool MWE_GetActiveWeaponClass(int client, char[] weapon, int maxLen)
{
    return MWE_GetCachedActiveWeaponClass(client, weapon, maxLen);
}

bool MWE_GetCachedActiveWeaponClass(int client, char[] weapon, int maxLen)
{
    weapon[0] = '\0';

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    int weaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        return false;
    }

    int ref = EntIndexToEntRef(weaponEnt);
    float now = GetGameTime();
    if (MWE_g_iCachedWeaponEntRef[client] == ref
        && now < MWE_g_fNextWeaponRefreshTime[client]
        && MWE_g_sCachedWeaponClass[client][0] != '\0')
    {
        strcopy(weapon, maxLen, MWE_g_sCachedWeaponClass[client]);
        return true;
    }

    if (!MWE_RefreshWeaponCacheFromEntity(client, weaponEnt))
    {
        return false;
    }

    strcopy(weapon, maxLen, MWE_g_sCachedWeaponClass[client]);
    return weapon[0] != '\0';
}

bool MWE_RefreshActiveWeaponCache(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    int weaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        MWE_g_iCachedWeaponEntRef[client] = 0;
        MWE_g_sCachedWeaponClass[client][0] = '\0';
        MWE_g_iCachedWeaponCategory[client] = MWE_WeaponCategory_None;
        MWE_g_fNextWeaponRefreshTime[client] = 0.0;
        return false;
    }

    return MWE_RefreshWeaponCacheFromEntity(client, weaponEnt);
}

bool MWE_RefreshWeaponCacheFromEntity(int client, int weaponEnt)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        return false;
    }

    char weapon[64];
    GetEntityClassname(weaponEnt, weapon, sizeof(weapon));
    if (weapon[0] == '\0')
    {
        return false;
    }

    MWE_g_iCachedWeaponEntRef[client] = EntIndexToEntRef(weaponEnt);
    strcopy(MWE_g_sCachedWeaponClass[client], sizeof(MWE_g_sCachedWeaponClass[]), weapon);
    MWE_g_iCachedWeaponCategory[client] = MWE_GetWeaponCategory(weapon);
    MWE_g_fNextWeaponRefreshTime[client] = GetGameTime() + MWE_ACTIVE_WEAPON_CACHE_INTERVAL;
    return true;
}

void MWE_RecordWeaponFire(int client, const char[] weapon)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || weapon[0] == '\0')
    {
        return;
    }

    strcopy(MWE_g_sLastFireWeaponClass[client], sizeof(MWE_g_sLastFireWeaponClass[]), weapon);
    MWE_g_iLastFireWeaponCategory[client] = MWE_GetWeaponCategory(weapon);
    MWE_g_fLastFireWeaponTime[client] = GetGameTime();
}

bool MWE_GetDamageWeaponClass(int client, char[] weapon, int maxLen)
{
    weapon[0] = '\0';

    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    float now = GetGameTime();
    if (MWE_g_sLastFireWeaponClass[client][0] != '\0'
        && now - MWE_g_fLastFireWeaponTime[client] <= MWE_LAST_FIRE_WEAPON_WINDOW)
    {
        strcopy(weapon, maxLen, MWE_g_sLastFireWeaponClass[client]);
        return true;
    }

    return MWE_GetCachedActiveWeaponClass(client, weapon, maxLen);
}

MWE_WeaponCategory MWE_GetDamageWeaponCategory(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return MWE_WeaponCategory_None;
    }

    float now = GetGameTime();
    if (MWE_g_iLastFireWeaponCategory[client] != MWE_WeaponCategory_None
        && now - MWE_g_fLastFireWeaponTime[client] <= MWE_LAST_FIRE_WEAPON_WINDOW)
    {
        return MWE_g_iLastFireWeaponCategory[client];
    }

    char weapon[64];
    if (!MWE_GetCachedActiveWeaponClass(client, weapon, sizeof(weapon)))
    {
        return MWE_WeaponCategory_None;
    }

    return MWE_g_iCachedWeaponCategory[client];
}

MWE_WeaponCategory MWE_GetWeaponCategory(const char[] weapon)
{
    if (MWE_IsRifleWeapon(weapon))
    {
        return MWE_WeaponCategory_Rifle;
    }

    if (MWE_IsSniperWeapon(weapon))
    {
        return MWE_WeaponCategory_Sniper;
    }

    if (MWE_IsShotgunWeapon(weapon))
    {
        return MWE_WeaponCategory_Shotgun;
    }

    if (MWE_IsSmgWeapon(weapon))
    {
        return MWE_WeaponCategory_Smg;
    }

    if (MWE_IsPistolWeapon(weapon))
    {
        return MWE_WeaponCategory_Pistol;
    }

    if (MWE_IsMeleeWeapon(weapon))
    {
        return MWE_WeaponCategory_Melee;
    }

    return MWE_WeaponCategory_Other;
}

bool MWE_IsRifleWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_rifle", false)
        || StrEqual(weapon, "weapon_rifle_ak47", false)
        || StrEqual(weapon, "weapon_rifle_sg552", false)
        || StrEqual(weapon, "weapon_rifle_desert", false)
        || StrEqual(weapon, "weapon_rifle_m60", false);
}

bool MWE_IsSniperWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_sniper_military", false)
        || StrEqual(weapon, "weapon_hunting_rifle", false)
        || StrEqual(weapon, "weapon_sniper_awp", false)
        || StrEqual(weapon, "weapon_sniper_scout", false);
}

bool MWE_IsShotgunWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_pumpshotgun", false)
        || StrEqual(weapon, "weapon_shotgun_chrome", false)
        || StrEqual(weapon, "weapon_autoshotgun", false)
        || StrEqual(weapon, "weapon_shotgun_spas", false);
}

bool MWE_IsSmgWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_smg", false)
        || StrEqual(weapon, "weapon_smg_silenced", false)
        || StrEqual(weapon, "weapon_smg_mp5", false);
}

bool MWE_IsPistolWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_pistol", false)
        || StrEqual(weapon, "weapon_pistol_magnum", false);
}

bool MWE_IsMeleeWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_melee", false)
        || StrEqual(weapon, "weapon_chainsaw", false)
        || StrEqual(weapon, "weapon_grenade_launcher", false);
}


#define MWE_MOUNTEDGUN_TRACE_DISTANCE 8192.0
#define MWE_MOUNTEDGUN_TANK_FORCE_SCALE 0.25
#define MWE_MOUNTEDGUN_MIN_Z_PUSH 120.0

public void MWE_Event_MountedGunWeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return;
    }

    if (!MWE_IsClientUsingMountedGun(client))
    {
        return;
    }

    float chance = 10.0;
    if (MWE_g_cvMountedGunExplosionChance != null)
    {
        chance = MWE_g_cvMountedGunExplosionChance.FloatValue;
    }

    if (chance <= 0.0 || GetRandomFloat(0.0, 100.0) > chance)
    {
        return;
    }

    float hitPos[3];
    if (!MWE_TraceMountedGunBullet(client, hitPos))
    {
        return;
    }

    MWE_CreateMountedGunExplosion(hitPos, client);
}

bool MWE_TraceMountedGunBullet(int client, float hitPos[3])
{
    float start[3];
    float angles[3];
    float fwd[3];
    float end[3];

    GetClientEyePosition(client, start);
    GetClientEyeAngles(client, angles);
    GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);

    end[0] = start[0] + fwd[0] * MWE_MOUNTEDGUN_TRACE_DISTANCE;
    end[1] = start[1] + fwd[1] * MWE_MOUNTEDGUN_TRACE_DISTANCE;
    end[2] = start[2] + fwd[2] * MWE_MOUNTEDGUN_TRACE_DISTANCE;

    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SHOT, RayType_EndPoint, MWE_TraceFilter_MountedGun, client);
    bool didHit = TR_DidHit(trace);
    if (didHit)
    {
        TR_GetEndPosition(hitPos, trace);
    }
    else
    {
        hitPos[0] = end[0];
        hitPos[1] = end[1];
        hitPos[2] = end[2];
    }
    delete trace;
    return didHit;
}

public bool MWE_TraceFilter_MountedGun(int entity, int contentsMask, any data)
{
    int client = data;
    if (entity == client)
    {
        return false;
    }

    if (client >= 1 && client <= MaxClients && IsClientInGame(client))
    {
        int useEntity = GetEntPropEnt(client, Prop_Send, "m_hUseEntity");
        if (entity == useEntity)
        {
            return false;
        }
    }

    if (entity >= 1 && entity <= MaxClients)
    {
        if (IsClientInGame(entity) && GetClientTeam(entity) == MWE_TEAM_SURVIVOR)
        {
            return false;
        }
    }

    return true;
}

void MWE_CreateMountedGunExplosion(float origin[3], int attacker)
{
    float radius = 130.0;
    float damage = 30.0;

    if (MWE_g_cvMountedGunExplosionRadius != null)
    {
        radius = MWE_g_cvMountedGunExplosionRadius.FloatValue;
    }
    if (MWE_g_cvMountedGunExplosionDamage != null)
    {
        damage = MWE_g_cvMountedGunExplosionDamage.FloatValue;
    }

    MWE_CreateUnifiedExplosionDamage(origin, attacker, radius, damage, 1.0);
}

void MWE_KnockMountedGunTargets(float origin[3], int attacker)
{
    float radius = 130.0;
    float force = 330.0;
    if (MWE_g_cvMountedGunExplosionRadius != null)
    {
        radius = MWE_g_cvMountedGunExplosionRadius.FloatValue;
    }
    if (MWE_g_cvMountedGunExplosionForce != null)
    {
        force = MWE_g_cvMountedGunExplosionForce.FloatValue;
    }
    if (radius <= 0.0 || force <= 0.0)
    {
        return;
    }

    float radiusSq = radius * radius;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!MWE_IsMountedGunBurnTarget(client))
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(client, pos);
        if (MWE_VectorDistanceSq(origin, pos) <= radiusSq)
        {
            float scale = force;
            if (HasEntProp(client, Prop_Send, "m_zombieClass") && GetEntProp(client, Prop_Send, "m_zombieClass") == 8)
            {
                scale *= MWE_MOUNTEDGUN_TANK_FORCE_SCALE;
            }
            MWE_PushEntityAwayFromPoint(client, origin, pos, scale);
        }
    }

    MWE_KnockMountedGunWitches("witch", origin, radiusSq, force);
    MWE_KnockMountedGunWitches("witch_bride", origin, radiusSq, force);
}

void MWE_KnockMountedGunWitches(const char[] classname, float origin[3], float radiusSq, float force)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!IsValidEntity(entity))
        {
            continue;
        }

        float pos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        if (MWE_VectorDistanceSq(origin, pos) <= radiusSq)
        {
            MWE_PushEntityAwayFromPoint(entity, origin, pos, force);
        }
    }
}

void MWE_PushEntityAwayFromPoint(int entity, float origin[3], float pos[3], float force)
{
    float vec[3];
    vec[0] = pos[0] - origin[0];
    vec[1] = pos[1] - origin[1];
    vec[2] = 0.0;

    float len = SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
    if (len < 1.0)
    {
        vec[0] = 1.0;
        vec[1] = 0.0;
        len = 1.0;
    }

    float velocity[3];
    velocity[0] = vec[0] / len * force;
    velocity[1] = vec[1] / len * force;
    velocity[2] = MWE_MOUNTEDGUN_MIN_Z_PUSH;
    TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, velocity);
}

bool MWE_IsMountedGunEntity(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return false;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, "prop_minigun", false)
        || StrEqual(classname, "prop_minigun_l4d1", false)
        || StrEqual(classname, "prop_mounted_machine_gun", false);
}

bool MWE_IsClientUsingMountedGun(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return false;
    }

    int useEntity = GetEntPropEnt(client, Prop_Send, "m_hUseEntity");
    return MWE_IsMountedGunEntity(useEntity);
}

bool MWE_IsMountedGunBurnTarget(int victim)
{
    if (victim <= 0)
    {
        return false;
    }

    if (victim >= 1 && victim <= MaxClients)
    {
        if (!IsClientInGame(victim) || !IsPlayerAlive(victim) || GetClientTeam(victim) != 3)
        {
            return false;
        }

        if (!HasEntProp(victim, Prop_Send, "m_zombieClass"))
        {
            return false;
        }

        int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
        return zombieClass >= 1 && zombieClass <= 8;
    }

    if (!IsValidEntity(victim))
    {
        return false;
    }

    char classname[64];
    GetEntityClassname(victim, classname, sizeof(classname));
    return StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false);
}

void MWE_TryApplyMountedGunBurn(int victim, int attacker)
{
    if (MWE_g_cvMountedGunEnable == null || !MWE_g_cvMountedGunEnable.BoolValue)
    {
        return;
    }

    if (!MWE_IsMountedGunBurnTarget(victim))
    {
        return;
    }

    float duration = 5.0;
    if (MWE_g_cvMountedGunBurnDuration != null)
    {
        duration = MWE_g_cvMountedGunBurnDuration.FloatValue;
    }
    if (duration <= 0.0)
    {
        return;
    }

    float cooldown = 0.0;
    if (MWE_g_cvMountedGunReigniteCooldown != null)
    {
        cooldown = MWE_g_cvMountedGunReigniteCooldown.FloatValue;
    }

    if (victim > 0 && victim < MWE_MAX_EDICTS)
    {
        float now = GetGameTime();
        if (now < MWE_g_fMountedGunNextIgniteTime[victim])
        {
            return;
        }
        MWE_g_fMountedGunNextIgniteTime[victim] = now + cooldown;
    }

    IgniteEntity(victim, duration);
}

void MWE_CreateUnifiedExplosionDamage(float origin[3], int attacker, float radius, float damage, float damageScale)
{
    if (radius <= 0.0 || damage <= 0.0 || damageScale <= 0.0)
    {
        return;
    }

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return;
    }

    MWE_ShowUnifiedExplosionEffect(origin, radius, damage);

    float finalDamage = damage * damageScale;
    if (finalDamage <= 0.0)
    {
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!MWE_IsExplosionDamageClientTarget(client))
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(client, pos);
        if (!MWE_IsWithinRadius(origin, pos, radius))
        {
            continue;
        }

        MWE_SDKHooks_TakeDamage(client, attacker, attacker, finalDamage, DMG_BLAST);

        if (MWE_IsExplosionStaggerClientTarget(client))
        {
            MWE_StaggerClientFromExplosion(client, origin);
        }
    }

    MWE_DamageExplosionEntitiesByClassname("infected", origin, radius, finalDamage, attacker);
    MWE_DamageExplosionEntitiesByClassname("witch", origin, radius, finalDamage, attacker);
    MWE_DamageExplosionEntitiesByClassname("witch_bride", origin, radius, finalDamage, attacker);
}

void MWE_ShowUnifiedExplosionEffect(float origin[3], float radius, float damage)
{
    if (MWE_g_iExplosionSprite > 0)
    {
        TE_SetupExplosion(origin, MWE_g_iExplosionSprite, 5.0, 1, 0, RoundToNearest(radius), RoundToNearest(damage));
        TE_SendToAll();
    }

    EmitAmbientSound(MWE_EXPLOSION_SOUND, origin, SOUND_FROM_WORLD, SNDLEVEL_GUNFIRE);
}

bool MWE_IsExplosionDamageClientTarget(int client)
{
    return client >= 1
        && client <= MaxClients
        && IsClientInGame(client)
        && IsPlayerAlive(client)
        && GetClientTeam(client) == 3;
}

bool MWE_IsExplosionStaggerClientTarget(int client)
{
    if (!MWE_IsExplosionDamageClientTarget(client))
    {
        return false;
    }

    if (!HasEntProp(client, Prop_Send, "m_zombieClass"))
    {
        return false;
    }

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    return (zombieClass >= 1 && zombieClass <= 6) || zombieClass == 8;
}

void MWE_StaggerClientFromExplosion(int client, const float origin[3])
{
    MWE_RunVScript("local e = EntIndexToHScript(%d); if (e != null && e.IsValid()) { e.Stagger(Vector(%.2f, %.2f, %.2f)); }", client, origin[0], origin[1], origin[2]);
}

void MWE_DamageExplosionEntitiesByClassname(const char[] classname, float origin[3], float radius, float damage, int attacker)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!IsValidEntity(entity))
        {
            continue;
        }

        float pos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            MWE_SDKHooks_TakeDamage(entity, attacker, attacker, damage, DMG_BLAST);
        }
    }
}

void MWE_RunVScript(const char[] fmt, any ...)
{
    char code[512];
    VFormat(code, sizeof(code), fmt, 2);

    int script = CreateEntityByName("logic_script");
    if (script == -1)
    {
        LogError("[MWE] Failed to create logic_script. Code: %s", code);
        return;
    }

    DispatchSpawn(script);
    SetVariantString(code);
    AcceptEntityInput(script, "RunScriptCode");
    AcceptEntityInput(script, "Kill");
}

void MWE_SDKHooks_TakeDamage(int entity, int inflictor, int attacker, float damage, int damageType)
{
    bool oldGuard = MWE_g_bApplyingPluginDamage;
    MWE_g_bApplyingPluginDamage = true;
    SDKHooks_TakeDamage(entity, inflictor, attacker, damage, damageType);
    MWE_g_bApplyingPluginDamage = oldGuard;
}

float MWE_VectorDistanceSq(const float a[3], const float b[3])
{
    float dx = a[0] - b[0];
    float dy = a[1] - b[1];
    float dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

bool MWE_IsWithinRadius(const float a[3], const float b[3], float radius)
{
    if (radius < 0.0)
    {
        return false;
    }

    return MWE_VectorDistanceSq(a, b) <= radius * radius;
}

bool MWE_CanRunHeavyEffect(int client, int slot, float interval)
{
    if (client < 1 || client > MaxClients || slot < 0 || slot >= MWE_HEAVY_SLOT_COUNT)
    {
        return true;
    }

    if (interval <= 0.0)
    {
        return true;
    }

    float now = GetGameTime();
    if (now - MWE_g_fLastHeavyEffectTime[client][slot] < interval)
    {
        return false;
    }

    MWE_g_fLastHeavyEffectTime[client][slot] = now;
    return true;
}

void MWE_MarkSharedRealHit(int attacker, int victim, MWE_WeaponCategory category, const char[] weapon)
{
    if (attacker < 1 || attacker > MaxClients)
    {
        return;
    }

    if (victim <= 0 || victim >= MWE_MAX_EDICTS)
    {
        return;
    }

    MWE_g_iLastSharedHitAttacker[victim] = attacker;
    MWE_g_iLastSharedHitCategory[victim] = category;
    strcopy(MWE_g_sLastSharedHitWeapon[victim], sizeof(MWE_g_sLastSharedHitWeapon[]), weapon);
    MWE_g_fLastSharedHitTime[victim] = GetGameTime();
}

bool MWE_WasSharedRealHitRecently(int attacker, int victim, MWE_WeaponCategory category, const char[] weapon)
{
    if (attacker < 1 || attacker > MaxClients)
    {
        return false;
    }

    if (victim <= 0 || victim >= MWE_MAX_EDICTS)
    {
        return false;
    }

    if (MWE_g_iLastSharedHitAttacker[victim] != attacker)
    {
        return false;
    }

    if (MWE_g_iLastSharedHitCategory[victim] != category)
    {
        return false;
    }

    if (!StrEqual(MWE_g_sLastSharedHitWeapon[victim], weapon, false))
    {
        return false;
    }

    return GetGameTime() - MWE_g_fLastSharedHitTime[victim] <= MWE_SHARED_HIT_DEDUP_WINDOW;
}


public void MWE_Event_BulletImpact(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    float impact[3];
    impact[0] = event.GetFloat("x");
    impact[1] = event.GetFloat("y");
    impact[2] = event.GetFloat("z");

    char weapon[64];
    if (!MWE_GetDamageWeaponClass(client, weapon, sizeof(weapon)))
    {
        return;
    }

    // 霰弹枪不接入 bullet_impact：多弹丸一枪可能产生多个 impact，保持原来的单次准星 TraceRay 兜底逻辑。
    if (MWE_IsShotgunWeapon(weapon))
    {
        return;
    }

    if (MWE_IsRifleWeapon(weapon))
    {
        Rifles_CachePendingBulletImpact(client, impact);
    }
    else if (MWE_IsSniperWeapon(weapon))
    {
        Snipers_CachePendingBulletImpact(client, impact);
    }
    else if (StrEqual(weapon, "weapon_pistol_magnum", false))
    {
        Pistols_CachePendingMagnumBulletImpact(client, impact);
    }
}

public void MWE_Event_PlayerHurtFallback(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int hitgroup = event.GetInt("hitgroup", 0);

    MWE_HandleHurtFallback(attacker, victim, hitgroup);
}

public void MWE_Event_InfectedHurtFallback(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = event.GetInt("entityid", -1);
    int hitgroup = event.GetInt("hitgroup", 0);

    MWE_HandleHurtFallback(attacker, victim, hitgroup);
}

void MWE_HandleHurtFallback(int attacker, int victim, int hitgroup)
{
    if (MWE_g_bApplyingPluginDamage)
    {
        return;
    }

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return;
    }

    if (victim <= 0 || !IsValidEntity(victim))
    {
        return;
    }

    char weapon[64];
    if (!MWE_GetDamageWeaponClass(attacker, weapon, sizeof(weapon)))
    {
        return;
    }

    MWE_WeaponCategory category = MWE_GetWeaponCategory(weapon);
    if (category != MWE_WeaponCategory_Rifle
        && category != MWE_WeaponCategory_Sniper
        && category != MWE_WeaponCategory_Shotgun)
    {
        return;
    }

    if (MWE_WasSharedRealHitRecently(attacker, victim, category, weapon))
    {
        return;
    }

    MWE_MarkSharedRealHit(attacker, victim, category, weapon);

    if (category == MWE_WeaponCategory_Rifle)
    {
        Rifles_HandleRealDamageHitWithHitgroup(attacker, victim, weapon, hitgroup);
    }
    else if (category == MWE_WeaponCategory_Sniper)
    {
        Snipers_HandleRealDamageHit(attacker, victim, weapon);
    }
    else if (category == MWE_WeaponCategory_Shotgun)
    {
        Shotgun_HandleFallbackRealHit(attacker, victim, weapon);
    }
}


// ============================================================================
// Module: Rifles (from l4d2_mwe_rifles.sp)
// ============================================================================

/**
 * l4d2_mwe_rifles.sp
 *
 * 使用方法 / Usage:
 *   1. 将本文件放入: left4dead2/addons/sourcemod/scripting/l4d2_mwe_rifles.sp
 *   2. 使用 SourceMod 编译器编译: spcomp l4d2_mwe_rifles.sp
 *   3. 将生成的 l4d2_mwe_rifles.smx 放入: left4dead2/addons/sourcemod/plugins/
 *   4. 本整合版配置统一写入: left4dead2/cfg/sourcemod/l4d2_mwe_all.cfg
 *   5. 服务器内执行 sm plugins refresh 或换图后生效。
 *
 * 简介 / Introduction:
 *   这是“多武器效果”项目中的步枪独立版 SourceMod 插件。
 *   只处理 5 把突击步枪：M16、AK47、SG552、三连发、M60。
 *   插件只挂钩 item_pickup 与 weapon_fire，避免使用不存在的 L4D2 事件。
 *   伤害使用 SDKHooks_TakeDamage；目标检测使用射线追踪与实体类型判定。
 *
 * 说明 / Notes:
 *   - 本文件不依赖 Left 4 DHooks Direct，降低编译门槛。
 *   - “肾上腺素”采用插件内状态 + 移速加成模拟，用于触发本插件的联动逻辑。
 *   - “击退”采用 TeleportEntity 设置速度模拟，不调用 L4D_StaggerPlayer。
 *   - 特殊弹药采用 m_upgradeBitVec / m_nUpgradedPrimaryAmmoLoaded，若服务器版本没有对应属性会静默跳过。
 */



#define Rifles_PLUGIN_VERSION "1.0.5-rifles-pickup-strict"
#define Rifles_TRACE_DISTANCE 18192.0
#define Rifles_TEAM_SURVIVOR 2
#define Rifles_TEAM_INFECTED 3
#define Rifles_ZC_SMOKER 1
#define Rifles_ZC_BOOMER 2
#define Rifles_ZC_HUNTER 3
#define Rifles_ZC_SPITTER 4
#define Rifles_ZC_JOCKEY 5
#define Rifles_ZC_CHARGER 6
#define Rifles_ZC_TANK 8
#define Rifles_MAX_AREA_TARGETS 96
#define Rifles_PENDING_EXPLOSION_NONE 0
#define Rifles_PENDING_EXPLOSION_AK47_DUCK 1
#define Rifles_PENDING_EXPLOSION_SG552 2
#define Rifles_PENDING_EXPLOSION_SG552_FULLPOWER 3
#define Rifles_PENDING_EXPLOSION_M60 4
#if !defined DMG_BUCKSHOT
#define DMG_BUCKSHOT (1 << 29)
#endif
#if !defined HITGROUP_HEAD
#define HITGROUP_HEAD 1
#endif

#define Rifles_UPGRADE_INCENDIARY_AMMO 0
#define Rifles_UPGRADE_EXPLOSIVE_AMMO 1
#define Rifles_UPGRADE_LASER_SIGHT 2

enum Rifles_TargetType
{
    Rifles_Target_Invalid = 0,
    Rifles_Target_CommonInfected,
    Rifles_Target_SpecialInfected,
    Rifles_Target_Tank,
    Rifles_Target_Witch,
    Rifles_Target_Survivor
};


ConVar Rifles_g_cvEnabled;
ConVar Rifles_g_cvNotify;
ConVar Rifles_g_cvDebug;

ConVar Rifles_g_cvEnableM16;
ConVar Rifles_g_cvEnableAK47;
ConVar Rifles_g_cvEnableSG552;
ConVar Rifles_g_cvEnableDesert;
ConVar Rifles_g_cvEnableM60;

ConVar Rifles_g_cvM16TempChance;
ConVar Rifles_g_cvM16PercentChance;
ConVar Rifles_g_cvM16TempAmount;
ConVar Rifles_g_cvM4ClipBonusEnable;
ConVar Rifles_g_cvM4ClipBonusChance;
ConVar Rifles_g_cvM4ClipBonusMode;
ConVar Rifles_g_cvM4ClipBonusAmount;
ConVar Rifles_g_cvM4ClipBonusMax;

ConVar Rifles_g_cvAKAdrenDuration;
ConVar Rifles_g_cvAKAdrenClipChance;
ConVar Rifles_g_cvAKDuckDamage;
ConVar Rifles_g_cvAKDuckExplosionChance;
ConVar Rifles_g_cvAKDuckGlobalFireChance;

ConVar Rifles_g_cvSG552UpgradeChance;
ConVar Rifles_g_cvSG552ExplosionChance;
ConVar Rifles_g_cvSG552FullPower;

ConVar Rifles_g_cvDesertKnockChance;
ConVar Rifles_g_cvDesertTankKnockChance;
ConVar Rifles_g_cvDesertBonusChance;
ConVar Rifles_g_cvDesertBonusDamage;
ConVar Rifles_g_cvDesertCommonKnockChance;
ConVar Rifles_g_cvDesertSplashChance;
ConVar Rifles_g_cvDesertSplashDamage;

ConVar Rifles_g_cvM60ExplosionChance;
ConVar Rifles_g_cvM60HealChance;
ConVar Rifles_g_cvM60HealAmount;

ConVar Rifles_g_cvExplosionRadius;
ConVar Rifles_g_cvExplosionDamage;
ConVar Rifles_g_cvSmallRadius;
ConVar Rifles_g_cvKnockForce;
ConVar Rifles_g_cvIgniteDuration;
ConVar Rifles_g_cvAdrenSpeed;
ConVar Rifles_g_cvDamageMultiplier;

ConVar Rifles_g_cvPillsDecay;

bool Rifles_g_bAdrenActive[MAXPLAYERS + 1];
Handle Rifles_g_hAdrenTimer[MAXPLAYERS + 1];
float Rifles_g_flKnownAdrenUntil[MAXPLAYERS + 1];
bool Rifles_g_bHasAdrenalineProp;
bool Rifles_g_bApplyingPluginDamage[MAXPLAYERS + 1];

float Rifles_g_fLastNotifyTime[MAXPLAYERS + 1];
char Rifles_g_sLastNotifyWeapon[MAXPLAYERS + 1][64];
int Rifles_g_iLastAKAdrenVictim[MAXPLAYERS + 1];
float Rifles_g_fLastAKAdrenTime[MAXPLAYERS + 1];
int Rifles_g_iLastAKHeadCorrectionVictim[MAXPLAYERS + 1];
float Rifles_g_fLastAKHeadCorrectionTime[MAXPLAYERS + 1];
int Rifles_g_iShotSerial[MAXPLAYERS + 1];
int Rifles_g_iPendingExplosionShot[MAXPLAYERS + 1];
int Rifles_g_iPendingExplosionType[MAXPLAYERS + 1];
int Rifles_g_iProcessedExplosionShot[MAXPLAYERS + 1];
bool Rifles_g_bPendingExplosionHasPos[MAXPLAYERS + 1];
float Rifles_g_fPendingExplosionPos[MAXPLAYERS + 1][3];

public void Rifles_OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        SetFailState("This plugin only supports Left 4 Dead 2.");
    }

    Rifles_CreateConVars();

    // Auto pickup descriptions disabled: use !mwe / !武器 menu instead.
    HookEvent("weapon_fire", Rifles_Event_WeaponFire, EventHookMode_Post);
    HookEvent("player_hurt", Rifles_Event_PlayerHurt, EventHookMode_Post);
    HookEvent("player_disconnect", Rifles_Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_death", Rifles_Event_PlayerDeath, EventHookMode_Post);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            MWE_HookSharedTakeDamage(i);
        }
    }
    Rifles_HookExistingDamageEntities();

    RegAdminCmd("sm_mwer_test", Rifles_Cmd_TestCurrentRifle, ADMFLAG_ROOT, "Test current rifle effect once.");

    Rifles_g_cvPillsDecay = FindConVar("pain_pills_decay_rate");

    // cfg 统一由整合版主入口生成。
}

public void Rifles_OnClientDisconnect(int client)
{
    Rifles_ClearAdrenaline(client);
    if (client > 0 && client <= MaxClients)
    {
        Rifles_g_fLastNotifyTime[client] = 0.0;
        Rifles_g_sLastNotifyWeapon[client][0] = '\0';
        Rifles_g_iLastAKAdrenVictim[client] = 0;
        Rifles_g_fLastAKAdrenTime[client] = 0.0;
        Rifles_g_iLastAKHeadCorrectionVictim[client] = 0;
        Rifles_g_fLastAKHeadCorrectionTime[client] = 0.0;
        Rifles_g_iShotSerial[client] = 0;
        Rifles_g_iPendingExplosionShot[client] = 0;
        Rifles_g_iPendingExplosionType[client] = Rifles_PENDING_EXPLOSION_NONE;
        Rifles_g_iProcessedExplosionShot[client] = 0;
        Rifles_g_bPendingExplosionHasPos[client] = false;
        Rifles_g_fPendingExplosionPos[client][0] = 0.0;
        Rifles_g_fPendingExplosionPos[client][1] = 0.0;
        Rifles_g_fPendingExplosionPos[client][2] = 0.0;
    }
}

public void Rifles_OnClientPutInServer(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        MWE_HookSharedTakeDamage(client);
    }
}

public void Rifles_OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients)
    {
        return;
    }

    if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false))
    {
        MWE_HookSharedTakeDamage(entity);
    }
}

void Rifles_HookExistingDamageEntities()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch_bride")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }
}

public Action Rifles_OnEntityTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (damage <= 0.0 || !Rifles_g_cvEnabled.BoolValue)
    {
        return Plugin_Continue;
    }

    if (!Rifles_IsHumanSurvivorAlive(attacker))
    {
        return Plugin_Continue;
    }

    // Plugin-applied bonus damage will also pass through SDKHooks. Do not let it
    // recursively trigger another weapon effect.
    if (Rifles_g_bApplyingPluginDamage[attacker])
    {
        return Plugin_Continue;
    }

    // Real rifle hits normally arrive as bullet damage. This keeps fire/blast
    // damage from molotovs, explosions, and our own area effects from retriggering.
    if ((damagetype & DMG_BULLET) == 0 && (damagetype & DMG_BUCKSHOT) == 0)
    {
        return Plugin_Continue;
    }

    char weapon[64];
    if (!MWE_GetDamageWeaponClass(attacker, weapon, sizeof(weapon)))
    {
        return Plugin_Continue;
    }

    Rifles_HandleRealDamageHit(attacker, victim, weapon);
    return Plugin_Continue;
}




public Action Rifles_Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!Rifles_g_cvEnabled.BoolValue || !Rifles_g_cvEnableAK47.BoolValue)
    {
        return Plugin_Continue;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!Rifles_IsHumanSurvivorAlive(attacker) || victim <= 0 || victim > MaxClients)
    {
        return Plugin_Continue;
    }

    // player_hurt is used only as an AK47 adrenaline fallback. Damage, explosions,
    // and other rifle effects remain handled by the shared SDKHook_OnTakeDamage path.
    Rifles_HandleAK47DamageHit(attacker, victim);
    return Plugin_Continue;
}

public Action Rifles_Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
    {
        Rifles_ClearAdrenaline(client);
    }
    return Plugin_Continue;
}

public Action Rifles_Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    // First process the killer reward while the death event still contains the
    // victim zombie class and the weapon name that caused the kill.
    Rifles_TryGiveM16ClipBonusOnSpecialKill(event);

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
    {
        Rifles_ClearAdrenaline(client);
    }
    return Plugin_Continue;
}

void Rifles_CreateConVars()
{
    Rifles_g_cvEnabled = CreateConVar("sm_mwer_enabled", "1", "Enable rifle effects. 1=on, 0=off", 0, true, 0.0, true, 1.0);
    Rifles_g_cvNotify = CreateConVar("sm_mwer_notify", "0", "DEPRECATED: pickup weapon ability messages are disabled; use !mwe / !武器 menu. 1=on, 0=off", 0, true, 0.0, true, 1.0);
    Rifles_g_cvDebug = CreateConVar("sm_mwer_debug", "0", "Enable debug logs. 1=on, 0=off", 0, true, 0.0, true, 1.0);

    Rifles_g_cvEnableM16 = CreateConVar("sm_mwer_enable_m16", "1", "Enable M16 effects.", 0, true, 0.0, true, 1.0);
    Rifles_g_cvEnableAK47 = CreateConVar("sm_mwer_enable_ak47", "1", "Enable AK47 effects.", 0, true, 0.0, true, 1.0);
    Rifles_g_cvEnableSG552 = CreateConVar("sm_mwer_enable_sg552", "1", "Enable SG552 effects.", 0, true, 0.0, true, 1.0);
    Rifles_g_cvEnableDesert = CreateConVar("sm_mwer_enable_desert", "1", "Enable Desert Rifle effects.", 0, true, 0.0, true, 1.0);
    Rifles_g_cvEnableM60 = CreateConVar("sm_mwer_enable_m60", "1", "Enable M60 effects.", 0, true, 0.0, true, 1.0);

    Rifles_g_cvM16TempChance = CreateConVar("sm_mwer_m16_temp_chance", "80", "M16 temp-health chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvM16PercentChance = CreateConVar("sm_mwer_m16_percent_chance", "20", "M16 percent damage chance. Checked before temp-health, so the two effects are mutually exclusive.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvM16TempAmount = CreateConVar("sm_mwer_m16_temp_amount", "1.0", "M16 temp-health amount.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvM4ClipBonusEnable = CreateConVar("sm_mwer_m4_clip_bonus_enable", "1", "Enable M16 weapon_rifle magazine bonus when killing a special infected or Tank. 1=on, 0=off", 0, true, 0.0, true, 1.0);
    Rifles_g_cvM4ClipBonusChance = CreateConVar("sm_mwer_m4_clip_bonus_chance", "20.0", "M16 weapon_rifle chance percent per special-infected/Tank kill to add bullets directly into the current magazine.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvM4ClipBonusMode = CreateConVar("sm_mwer_m4_clip_bonus_mode", "1", "M16 magazine bonus mode. 0=add fixed sm_mwer_m4_clip_bonus_amount; 1=automatically add one actual weapon magazine using GetMaxClip1().", 0, true, 0.0, true, 1.0);
    Rifles_g_cvM4ClipBonusAmount = CreateConVar("sm_mwer_m4_clip_bonus_amount", "40", "Fixed bullets added when mode=0; also used as fallback if automatic GetMaxClip1() returns an invalid value. Reserve ammo is never changed.", 0, true, 1.0, true, 1000.0);
    Rifles_g_cvM4ClipBonusMax = CreateConVar("sm_mwer_m4_clip_bonus_max", "0", "Optional maximum m_iClip1 after the M16 magazine bonus. 0=no cap.", 0, true, 0.0, true, 2000.0);

    Rifles_g_cvAKAdrenDuration = CreateConVar("sm_mwer_ak47_adren_duration", "5.0", "AK47 simulated adrenaline duration.", 0, true, 0.1, true, 60.0);
    Rifles_g_cvAKAdrenClipChance = CreateConVar("sm_mwer_ak47_adren_clip_chance", "25.0", "AK47 chance percent to refund 1 bullet into the current magazine per shot while adrenaline is active.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvAKDuckDamage = CreateConVar("sm_mwer_ak47_duck_damage", "16.0", "AK47 extra damage while ducking.", 0, true, 0.0, true, 500.0);
    Rifles_g_cvAKDuckExplosionChance = CreateConVar("sm_mwer_ak47_duck_explosion_chance", "8.0", "AK47 ducking explosion chance percent.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvAKDuckGlobalFireChance = CreateConVar("sm_mwer_ak47_duck_global_fire_chance", "1.0", "AK47 ducking global infected ignite chance percent.", 0, true, 0.0, true, 100.0);

    Rifles_g_cvSG552UpgradeChance = CreateConVar("sm_mwer_sg552_upgrade_chance", "5.0", "SG552 special ammo chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvSG552ExplosionChance = CreateConVar("sm_mwer_sg552_explosion_chance", "10.0", "SG552 explosion chance percent, including shots fired while adrenaline full-power mode is active.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvSG552FullPower = CreateConVar("sm_mwer_sg552_adren_fullpower", "1", "SG552 triggers explosion + ignite + special ammo while plugin adrenaline is active.", 0, true, 0.0, true, 1.0);

    Rifles_g_cvDesertKnockChance = CreateConVar("sm_mwer_desert_knock_chance", "20.0", "Desert Rifle special infected knockback chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvDesertTankKnockChance = CreateConVar("sm_mwer_desert_tank_knock_chance", "10.0", "Desert Rifle Tank knockback chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvDesertBonusChance = CreateConVar("sm_mwer_desert_bonus_chance", "5.0", "Desert Rifle bonus damage + adrenaline chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvDesertBonusDamage = CreateConVar("sm_mwer_desert_bonus_damage", "20.0", "Desert Rifle bonus damage.", 0, true, 0.0, true, 500.0);
    Rifles_g_cvDesertCommonKnockChance = CreateConVar("sm_mwer_desert_common_knock_chance", "30.0", "Desert Rifle common infected area knockback chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvDesertSplashChance = CreateConVar("sm_mwer_desert_splash_chance", "30.0", "Desert Rifle common infected splash damage chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvDesertSplashDamage = CreateConVar("sm_mwer_desert_splash_damage", "3.0", "Desert Rifle common infected splash damage.", 0, true, 0.0, true, 100.0);

    Rifles_g_cvM60ExplosionChance = CreateConVar("sm_mwer_m60_explosion_chance", "5.0", "M60 explosion + ignite chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvM60HealChance = CreateConVar("sm_mwer_m60_heal_chance", "50.0", "M60 real-health recovery chance.", 0, true, 0.0, true, 100.0);
    Rifles_g_cvM60HealAmount = CreateConVar("sm_mwer_m60_heal_amount", "1", "M60 real-health recovery amount.", 0, true, 0.0, true, 50.0);

    Rifles_g_cvExplosionRadius = CreateConVar("sm_mwer_explosion_radius", "150.0", "Generic rifle explosion radius.", 0, true, 0.0, true, 1000.0);
    Rifles_g_cvExplosionDamage = CreateConVar("sm_mwer_explosion_damage", "50.0", "Generic rifle explosion damage.", 0, true, 0.0, true, 1000.0);
    Rifles_g_cvSmallRadius = CreateConVar("sm_mwer_small_radius", "50.0", "Small area effect radius.", 0, true, 0.0, true, 1000.0);
    Rifles_g_cvKnockForce = CreateConVar("sm_mwer_knock_force", "350.0", "Velocity used for simulated knockback.", 0, true, 0.0, true, 2000.0);
    Rifles_g_cvIgniteDuration = CreateConVar("sm_mwer_ignite_duration", "8.0", "Ignite duration for rifle fire effects.", 0, true, 0.1, true, 60.0);
    Rifles_g_cvAdrenSpeed = CreateConVar("sm_mwer_adren_speed", "1.0", "Deprecated: AK47 now uses native adrenaline; this value is no longer used.", 0, true, 1.0, true, 2.0);
    Rifles_g_bHasAdrenalineProp = FindSendPropInfo("CTerrorPlayer", "m_bAdrenalineActive") != -1;
    Rifles_g_cvDamageMultiplier = CreateConVar("sm_mwer_damage_multiplier", "1.0", "Global multiplier for plugin-applied rifle damage.", 0, true, 0.0, true, 10.0);
}

public Action Rifles_Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    // Pickup-triggered weapon descriptions are deleted. Use !mwe / !武器 menu only.
    return Plugin_Continue;
}

public Action Rifles_Timer_ShowPickupMessage(Handle timer, any userid)
{
    // Deleted pickup-description timer.
    return Plugin_Stop;
}

public Action Rifles_Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!Rifles_g_cvEnabled.BoolValue)
    {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Rifles_IsHumanSurvivorAlive(client))
    {
        return Plugin_Continue;
    }

    char weapon[64];
    if (!MWE_GetCachedActiveWeaponClass(client, weapon, sizeof(weapon)))
    {
        return Plugin_Continue;
    }

    if (MWE_IsRifleWeapon(weapon))
    {
        Rifles_g_iShotSerial[client]++;
        if (Rifles_g_iShotSerial[client] <= 0)
        {
            Rifles_g_iShotSerial[client] = 1;
        }
    }

    MWE_RecordWeaponFire(client, weapon);
    Rifles_RouteRifleEffect(client, weapon);
    return Plugin_Continue;
}

public Action Rifles_Cmd_TestCurrentRifle(int client, int args)
{
    if (!Rifles_IsHumanSurvivorAlive(client))
    {
        ReplyToCommand(client, "[MWER] You must be an alive human survivor.");
        return Plugin_Handled;
    }

    char weapon[64];
    if (!Rifles_GetCurrentWeaponClass(client, weapon, sizeof(weapon)))
    {
        ReplyToCommand(client, "[MWER] No active weapon found.");
        return Plugin_Handled;
    }

    Rifles_RouteRifleEffect(client, weapon);
    ReplyToCommand(client, "[MWER] Tested current weapon: %s", weapon);
    return Plugin_Handled;
}

void Rifles_RouteRifleEffect(int client, const char[] weapon)
{
    if (StrEqual(weapon, "weapon_rifle", false))
    {
        Rifles_Weapon_M16_OnFire(client);
    }
    else if (StrEqual(weapon, "weapon_rifle_ak47", false))
    {
        if (Rifles_g_cvEnableAK47.BoolValue) Rifles_Weapon_AK47_OnFire(client);
    }
    else if (StrEqual(weapon, "weapon_rifle_sg552", false))
    {
        if (Rifles_g_cvEnableSG552.BoolValue) Rifles_Weapon_SG552_OnFire(client);
    }
    else if (StrEqual(weapon, "weapon_rifle_desert", false))
    {
        if (Rifles_g_cvEnableDesert.BoolValue) Rifles_Weapon_Desert_OnFire(client);
    }
    else if (StrEqual(weapon, "weapon_rifle_m60", false))
    {
        if (Rifles_g_cvEnableM60.BoolValue) Rifles_Weapon_M60_OnFire(client);
    }
}

bool Rifles_ShowRifleDescription(int client, const char[] weapon)
{
    // Auto weapon descriptions are completely removed. Use !mwe / !武器 menu only.
    return false;
}

bool Rifles_NormalizePickupRifleClass(const char[] rawItem, char[] weapon, int maxlen)
{
    weapon[0] = '\0';

    if (rawItem[0] == '\0')
    {
        return false;
    }

    if (StrEqual(rawItem, "weapon_rifle", false) || StrEqual(rawItem, "rifle", false))
    {
        strcopy(weapon, maxlen, "weapon_rifle");
        return true;
    }
    if (StrEqual(rawItem, "weapon_rifle_ak47", false) || StrEqual(rawItem, "rifle_ak47", false))
    {
        strcopy(weapon, maxlen, "weapon_rifle_ak47");
        return true;
    }
    if (StrEqual(rawItem, "weapon_rifle_sg552", false) || StrEqual(rawItem, "rifle_sg552", false))
    {
        strcopy(weapon, maxlen, "weapon_rifle_sg552");
        return true;
    }
    if (StrEqual(rawItem, "weapon_rifle_desert", false) || StrEqual(rawItem, "rifle_desert", false))
    {
        strcopy(weapon, maxlen, "weapon_rifle_desert");
        return true;
    }
    if (StrEqual(rawItem, "weapon_rifle_m60", false) || StrEqual(rawItem, "rifle_m60", false))
    {
        strcopy(weapon, maxlen, "weapon_rifle_m60");
        return true;
    }

    return false;
}

bool Rifles_ShouldSuppressNotify(int client, const char[] weapon)
{
    if (client <= 0 || client > MaxClients)
    {
        return true;
    }

    if (!MWE_CanSendPickupNotice(client, weapon))
    {
        return true;
    }

    float now = GetGameTime();
    return StrEqual(Rifles_g_sLastNotifyWeapon[client], weapon, false) && (now - Rifles_g_fLastNotifyTime[client]) < 1.0;
}

void Rifles_MarkNotifySent(int client, const char[] weapon)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    Rifles_g_fLastNotifyTime[client] = GetGameTime();
    strcopy(Rifles_g_sLastNotifyWeapon[client], sizeof(Rifles_g_sLastNotifyWeapon[]), weapon);
    MWE_MarkPickupNoticeSent(client);
}

void Rifles_Weapon_M16_OnFire(int client)
{
    // M16 magazine replenishment is handled by player_death after a confirmed
    // special-infected/Tank kill, rather than rolling once for every shot.

    // Target-dependent M16 effects are processed in Rifles_OnEntityTakeDamage.
    // This avoids server-side manual TraceRay desync against laterally moving targets.
}



void Rifles_HandleAK47DamageHit(int attacker, int victim)
{
    if (!Rifles_IsHumanSurvivorAlive(attacker))
    {
        return;
    }

    char weapon[64];
    if (!MWE_GetDamageWeaponClass(attacker, weapon, sizeof(weapon)) || !StrEqual(weapon, "weapon_rifle_ak47", false))
    {
        return;
    }

    Rifles_TargetType type = Rifles_GetTargetType(victim);
    Rifles_TryApplyAK47Adrenaline(attacker, victim, type, "player_hurt fallback");
}

void Rifles_Weapon_AK47_OnFire(int client)
{
    // Magazine refund is a pure "on fire" effect.
    // Duck explosion is decided per shot here, then resolved either on the real enemy hit
    // or on the world bullet endpoint if no enemy damage target is reported.
    if (Rifles_IsPluginAdrenalineActive(client))
    {
        Rifles_TryRefundAK47ClipAmmo(client);
    }

    if ((GetEntityFlags(client) & FL_DUCKING) != 0
        && Rifles_Chance(Rifles_g_cvAKDuckExplosionChance.FloatValue)
        && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_EXPLOSION, 0.10))
    {
        Rifles_MarkPendingExplosion(client, Rifles_PENDING_EXPLOSION_AK47_DUCK);
    }
}



void Rifles_Weapon_SG552_OnFire(int client)
{
    // Special ammo is an on-fire self effect. Explosion/ignite is decided per shot here,
    // then resolved on the real enemy hit or on the world bullet endpoint fallback.
    if (Rifles_g_cvSG552FullPower.BoolValue && Rifles_IsPluginAdrenalineActive(client))
    {
        Rifles_GiveRandomSpecialAmmo(client);
        Rifles_DebugLog("SG552 full power ammo: client=%N", client);

        // Adrenaline full-power mode no longer forces every shot to explode.
        // It uses the same configurable per-shot explosion chance as normal SG552 fire.
        if (Rifles_Chance(Rifles_g_cvSG552ExplosionChance.FloatValue)
            && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_EXPLOSION, 0.10))
        {
            Rifles_MarkPendingExplosion(client, Rifles_PENDING_EXPLOSION_SG552_FULLPOWER);
        }
        return;
    }

    if (Rifles_Chance(Rifles_g_cvSG552UpgradeChance.FloatValue))
    {
        Rifles_GiveRandomSpecialAmmo(client);
        Rifles_DebugLog("SG552 special ammo: client=%N", client);
    }

    if (Rifles_Chance(Rifles_g_cvSG552ExplosionChance.FloatValue)
        && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_EXPLOSION, 0.10))
    {
        Rifles_MarkPendingExplosion(client, Rifles_PENDING_EXPLOSION_SG552);
    }
}



void Rifles_Weapon_Desert_OnFire(int client)
{
    // Desert Rifle effects depend on the real victim and are handled in OnTakeDamage.
}



void Rifles_Weapon_M60_OnFire(int client)
{
    // Explosion/ignite is decided per shot here, then resolved on the real enemy hit
    // or on the world bullet endpoint fallback. Heal remains a real-hit effect.
    if (Rifles_Chance(Rifles_g_cvM60ExplosionChance.FloatValue)
        && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_EXPLOSION, 0.10))
    {
        Rifles_MarkPendingExplosion(client, Rifles_PENDING_EXPLOSION_M60);
    }
}

void Rifles_HandleRealDamageHit(int client, int target, const char[] weapon)
{
    Rifles_HandleRealDamageHitWithHitgroup(client, target, weapon, 0);
}

void Rifles_HandleRealDamageHitWithHitgroup(int client, int target, const char[] weapon, int hitgroup)
{
    Rifles_TargetType type = Rifles_GetTargetType(target);
    if (!Rifles_IsEnemyType(type) && type != Rifles_Target_Survivor)
    {
        return;
    }

    MWE_MarkSharedRealHit(client, target, MWE_WeaponCategory_Rifle, weapon);

    float hitPos[3];
    Rifles_GetEntityOrigin(target, hitPos);

    if (StrEqual(weapon, "weapon_rifle", false))
    {
        if (Rifles_g_cvEnableM16.BoolValue)
        {
            Rifles_Weapon_M16_OnRealHit(client, target, type);
        }
    }
    else if (StrEqual(weapon, "weapon_rifle_ak47", false))
    {
        if (Rifles_g_cvEnableAK47.BoolValue)
        {
            Rifles_Weapon_AK47_OnRealHitWithHitgroup(client, target, type, hitPos, hitgroup);
        }
    }
    else if (StrEqual(weapon, "weapon_rifle_sg552", false))
    {
        if (Rifles_g_cvEnableSG552.BoolValue)
        {
            Rifles_Weapon_SG552_OnRealHit(client, target, type, hitPos);
        }
    }
    else if (StrEqual(weapon, "weapon_rifle_desert", false))
    {
        if (Rifles_g_cvEnableDesert.BoolValue)
        {
            Rifles_Weapon_Desert_OnRealHit(client, target, type, hitPos);
        }
    }
    else if (StrEqual(weapon, "weapon_rifle_m60", false))
    {
        if (Rifles_g_cvEnableM60.BoolValue)
        {
            Rifles_Weapon_M60_OnRealHit(client, target, type, hitPos);
        }
    }
}


void Rifles_Weapon_M16_OnRealHit(int client, int target, Rifles_TargetType type)
{
    if (!Rifles_IsEnemyType(type))
    {
        return;
    }

    if (Rifles_Chance(Rifles_g_cvM16PercentChance.FloatValue))
    {
        float percent = 0.0;
        switch (type)
        {
            case Rifles_Target_CommonInfected: percent = 0.50;
            case Rifles_Target_SpecialInfected: percent = 0.25;
            case Rifles_Target_Tank: percent = 0.0125;
            case Rifles_Target_Witch: percent = 0.10;
        }

        if (percent > 0.0)
        {
            Rifles_ApplyPercentDamage(target, percent, client, DMG_BUCKSHOT);
        }

        float temp = Rifles_GetClientTempHealth(client);
        if (temp > 0.0)
        {
            Rifles_ApplyDamage(target, temp, client, DMG_BULLET);
        }

        Rifles_DebugLog("M16 real-hit percent damage: client=%N target=%d type=%d", client, target, type);
        return;
    }

    if (Rifles_Chance(Rifles_g_cvM16TempChance.FloatValue))
    {
        Rifles_GiveTempHealth(client, Rifles_g_cvM16TempAmount.FloatValue);
        Rifles_DebugLog("M16 real-hit temp health: client=%N", client);
    }
}

bool Rifles_CanProcessAK47AdrenalineHit(int attacker, int target)
{
    if (attacker < 1 || attacker > MaxClients)
    {
        return false;
    }

    float now = GetGameTime();
    if (Rifles_g_iLastAKAdrenVictim[attacker] == target
        && now - Rifles_g_fLastAKAdrenTime[attacker] <= 0.08)
    {
        return false;
    }

    Rifles_g_iLastAKAdrenVictim[attacker] = target;
    Rifles_g_fLastAKAdrenTime[attacker] = now;
    return true;
}

void Rifles_TryApplyAK47Adrenaline(int attacker, int target, Rifles_TargetType type, const char[] source)
{
    if (type == Rifles_Target_SpecialInfected || type == Rifles_Target_Tank || type == Rifles_Target_Witch)
    {
        if (!Rifles_CanProcessAK47AdrenalineHit(attacker, target))
        {
            return;
        }

        Rifles_GivePluginAdrenaline(attacker, Rifles_g_cvAKAdrenDuration.FloatValue);
        Rifles_DebugLog("AK47 adrenaline: attacker=%N target=%d type=%d source=%s", attacker, target, type, source);
    }
    else if (type == Rifles_Target_Survivor && Rifles_IsAliveSurvivor(target))
    {
        if (!Rifles_CanProcessAK47AdrenalineHit(attacker, target))
        {
            return;
        }

        Rifles_GivePluginAdrenaline(target, Rifles_g_cvAKAdrenDuration.FloatValue);
        Rifles_DebugLog("AK47 teammate adrenaline: attacker=%N target=%N source=%s", attacker, target, source);
    }
}

void Rifles_Weapon_AK47_OnRealHit(int client, int target, Rifles_TargetType type, float hitPos[3])
{
    Rifles_Weapon_AK47_OnRealHitWithHitgroup(client, target, type, hitPos, 0);
}

float Rifles_GetAK47DuckDamageByHitgroup(int hitgroup)
{
    float damage = Rifles_g_cvAKDuckDamage.FloatValue;
    if (hitgroup == HITGROUP_HEAD)
    {
        damage *= 4.0;
    }
    return damage;
}

bool Rifles_CanProcessAK47HeadCorrection(int attacker, int target)
{
    // Deprecated in 1.0.6: AK47 crouch bonus damage is now applied in TraceAttack,
    // where the original hitgroup is still attached to the bullet trace.
    return false;
}

void Rifles_TryApplyAK47HeadDuckCorrection(int client, int target, int hitgroup)
{
    // Deprecated in 1.0.6. Keeping the symbol avoids breaking older call paths,
    // but no extra SDKHooks_TakeDamage is emitted here anymore.
    return;
}

public Action Rifles_OnTraceAttackAK47(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!Rifles_g_cvEnabled.BoolValue || !Rifles_g_cvEnableAK47.BoolValue)
    {
        return Plugin_Continue;
    }

    if (!Rifles_IsHumanSurvivorAlive(attacker))
    {
        return Plugin_Continue;
    }

    if ((damagetype & DMG_BULLET) == 0 && (damagetype & DMG_BUCKSHOT) == 0)
    {
        return Plugin_Continue;
    }

    if ((GetEntityFlags(attacker) & FL_DUCKING) == 0)
    {
        return Plugin_Continue;
    }

    Rifles_TargetType type = Rifles_GetTargetType(victim);
    if (!Rifles_IsEnemyType(type))
    {
        return Plugin_Continue;
    }

    float bonusDamage = Rifles_GetAK47DuckDamageByHitgroup(hitgroup) * Rifles_g_cvDamageMultiplier.FloatValue;
    if (bonusDamage <= 0.0)
    {
        return Plugin_Continue;
    }

    damage += bonusDamage;
    Rifles_DebugLog("AK47 TraceAttack duck bonus: attacker=%N victim=%d hitgroup=%d bonus=%.1f", attacker, victim, hitgroup, bonusDamage);
    return Plugin_Changed;
}

void Rifles_Weapon_AK47_OnRealHitWithHitgroup(int client, int target, Rifles_TargetType type, float hitPos[3], int hitgroup)
{
    Rifles_TryApplyAK47Adrenaline(client, target, type, "real-hit");

    if ((GetEntityFlags(client) & FL_DUCKING) == 0)
    {
        return;
    }

    // AK47 crouch bonus damage is applied in MWE_OnTraceAttack / Rifles_OnTraceAttackAK47.
    // This keeps the extra damage inside the original bullet trace and preserves head hitgroup context.

    if (Rifles_TryConsumePendingExplosion(client, Rifles_PENDING_EXPLOSION_AK47_DUCK))
    {
        Rifles_RunPendingExplosionEffect(client, Rifles_PENDING_EXPLOSION_AK47_DUCK, hitPos, target, type);
        Rifles_DebugLog("AK47 real-hit duck explosion: client=%N", client);
    }

    if (Rifles_Chance(Rifles_g_cvAKDuckGlobalFireChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_GLOBAL, 0.50))
    {
        Rifles_IgniteAllEnemies(client);
        Rifles_DebugLog("AK47 real-hit global ignite: client=%N", client);
    }
}


void Rifles_Weapon_SG552_OnRealHit(int client, int target, Rifles_TargetType type, float hitPos[3])
{
    if (!Rifles_IsEnemyType(type))
    {
        return;
    }

    if (Rifles_g_cvSG552FullPower.BoolValue && Rifles_IsPluginAdrenalineActive(client))
    {
        if (Rifles_TryConsumePendingExplosion(client, Rifles_PENDING_EXPLOSION_SG552_FULLPOWER))
        {
            Rifles_RunPendingExplosionEffect(client, Rifles_PENDING_EXPLOSION_SG552_FULLPOWER, hitPos, target, type);
            Rifles_DebugLog("SG552 real-hit full power: client=%N target=%d", client, target);
        }
        return;
    }

    if (Rifles_TryConsumePendingExplosion(client, Rifles_PENDING_EXPLOSION_SG552))
    {
        Rifles_RunPendingExplosionEffect(client, Rifles_PENDING_EXPLOSION_SG552, hitPos, target, type);
        Rifles_DebugLog("SG552 real-hit explosion: client=%N target=%d", client, target);
    }
}

void Rifles_Weapon_Desert_OnRealHit(int client, int target, Rifles_TargetType type, float hitPos[3])
{
    if ((type == Rifles_Target_SpecialInfected || type == Rifles_Target_Witch) && Rifles_Chance(Rifles_g_cvDesertKnockChance.FloatValue))
    {
        Rifles_KnockAwayFromClient(target, client, Rifles_g_cvKnockForce.FloatValue);
        Rifles_DebugLog("Desert real-hit SI knockback: client=%N target=%d", client, target);
    }
    else if (type == Rifles_Target_Tank && Rifles_Chance(Rifles_g_cvDesertTankKnockChance.FloatValue))
    {
        Rifles_KnockAwayFromClient(target, client, Rifles_g_cvKnockForce.FloatValue);
        Rifles_DebugLog("Desert real-hit Tank knockback: client=%N target=%d", client, target);
    }

    if (Rifles_IsEnemyType(type) && Rifles_Chance(Rifles_g_cvDesertBonusChance.FloatValue))
    {
        Rifles_ApplyDamage(target, Rifles_g_cvDesertBonusDamage.FloatValue, client, DMG_BUCKSHOT);
        Rifles_GivePluginAdrenaline(client, Rifles_g_cvAKAdrenDuration.FloatValue);
        Rifles_DebugLog("Desert real-hit bonus damage + adrenaline: client=%N target=%d", client, target);
    }

    if (Rifles_Chance(Rifles_g_cvDesertCommonKnockChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_AREA_COMMON, 0.10))
    {
        Rifles_KnockCommonInfectedRadius(hitPos, Rifles_g_cvSmallRadius.FloatValue, client, Rifles_g_cvKnockForce.FloatValue);
    }

    if (type == Rifles_Target_CommonInfected && Rifles_Chance(Rifles_g_cvDesertSplashChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_RIFLE_AREA_COMMON, 0.10))
    {
        Rifles_DamageCommonInfectedRadius(hitPos, Rifles_g_cvSmallRadius.FloatValue, Rifles_g_cvDesertSplashDamage.FloatValue, client);
    }
}

void Rifles_Weapon_M60_OnRealHit(int client, int target, Rifles_TargetType type, float hitPos[3])
{
    if (Rifles_TryConsumePendingExplosion(client, Rifles_PENDING_EXPLOSION_M60))
    {
        Rifles_RunPendingExplosionEffect(client, Rifles_PENDING_EXPLOSION_M60, hitPos, target, type);
        Rifles_DebugLog("M60 real-hit explosion + ignite: client=%N target=%d", client, target);
    }

    if (Rifles_IsEnemyType(type) && Rifles_Chance(Rifles_g_cvM60HealChance.FloatValue))
    {
        Rifles_HealRealHealthCapped(client, Rifles_g_cvM60HealAmount.IntValue, 100);
        Rifles_DebugLog("M60 real-hit heal: client=%N", client);
    }
}




int Rifles_TraceFromClient(int client, float hitPos[3])
{
    float start[3];
    float angles[3];
    float fwd[3];
    float end[3];

    GetClientEyePosition(client, start);
    GetClientEyeAngles(client, angles);
    GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);

    end[0] = start[0] + fwd[0] * Rifles_TRACE_DISTANCE;
    end[1] = start[1] + fwd[1] * Rifles_TRACE_DISTANCE;
    end[2] = start[2] + fwd[2] * Rifles_TRACE_DISTANCE;

    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SHOT, RayType_EndPoint, Rifles_TraceFilter_NoSelf, client);
    int entity = -1;

    if (TR_DidHit(trace))
    {
        TR_GetEndPosition(hitPos, trace);
        entity = TR_GetEntityIndex(trace);
    }
    else
    {
        hitPos[0] = end[0];
        hitPos[1] = end[1];
        hitPos[2] = end[2];
    }

    delete trace;
    return entity;
}

public bool Rifles_TraceFilter_NoSelf(int entity, int contentsMask, any data)
{
    int client = data;
    if (entity == client)
    {
        return false;
    }
    return true;
}

void Rifles_MarkPendingExplosion(int client, int explosionType)
{
    if (client < 1 || client > MaxClients || Rifles_g_iShotSerial[client] <= 0)
    {
        return;
    }

    if (Rifles_g_cvExplosionRadius.FloatValue <= 0.0 || Rifles_g_cvExplosionDamage.FloatValue <= 0.0)
    {
        return;
    }

    int shotSerial = Rifles_g_iShotSerial[client];
    Rifles_g_iPendingExplosionShot[client] = shotSerial;
    Rifles_g_iPendingExplosionType[client] = explosionType;
    Rifles_g_bPendingExplosionHasPos[client] = false;
    Rifles_g_fPendingExplosionPos[client][0] = 0.0;
    Rifles_g_fPendingExplosionPos[client][1] = 0.0;
    Rifles_g_fPendingExplosionPos[client][2] = 0.0;

    DataPack pack;
    CreateDataTimer(0.05, Rifles_Timer_ProcessPendingExplosion, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(shotSerial);
    pack.WriteCell(explosionType);
}


void Rifles_CachePendingBulletImpact(int client, float impact[3])
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    int shotSerial = Rifles_g_iShotSerial[client];
    if (shotSerial <= 0)
    {
        return;
    }

    if (Rifles_g_iPendingExplosionShot[client] != shotSerial
        || Rifles_g_iPendingExplosionType[client] == Rifles_PENDING_EXPLOSION_NONE
        || Rifles_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return;
    }

    Rifles_g_fPendingExplosionPos[client][0] = impact[0];
    Rifles_g_fPendingExplosionPos[client][1] = impact[1];
    Rifles_g_fPendingExplosionPos[client][2] = impact[2];
    Rifles_g_bPendingExplosionHasPos[client] = true;
}

bool Rifles_TryConsumePendingExplosion(int client, int explosionType)
{
    if (client < 1 || client > MaxClients)
    {
        return false;
    }

    int shotSerial = Rifles_g_iShotSerial[client];
    if (shotSerial <= 0)
    {
        return false;
    }

    if (Rifles_g_iPendingExplosionShot[client] != shotSerial
        || Rifles_g_iPendingExplosionType[client] != explosionType
        || Rifles_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return false;
    }

    Rifles_g_iProcessedExplosionShot[client] = shotSerial;
    return true;
}

public Action Rifles_Timer_ProcessPendingExplosion(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int shotSerial = pack.ReadCell();
    int explosionType = pack.ReadCell();

    int client = GetClientOfUserId(userid);
    if (!Rifles_g_cvEnabled.BoolValue || !Rifles_IsHumanSurvivorAlive(client))
    {
        return Plugin_Stop;
    }

    if (Rifles_g_iPendingExplosionShot[client] != shotSerial
        || Rifles_g_iPendingExplosionType[client] != explosionType
        || Rifles_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return Plugin_Stop;
    }

    float hitPos[3];
    if (Rifles_g_bPendingExplosionHasPos[client])
    {
        hitPos[0] = Rifles_g_fPendingExplosionPos[client][0];
        hitPos[1] = Rifles_g_fPendingExplosionPos[client][1];
        hitPos[2] = Rifles_g_fPendingExplosionPos[client][2];
    }
    else
    {
        Rifles_TraceFromClient(client, hitPos);
    }

    Rifles_g_iProcessedExplosionShot[client] = shotSerial;
    Rifles_RunPendingExplosionEffect(client, explosionType, hitPos, -1, Rifles_Target_Invalid);
    Rifles_DebugLog("rifle endpoint explosion: client=%N type=%d shot=%d", client, explosionType, shotSerial);
    return Plugin_Stop;
}

void Rifles_RunPendingExplosionEffect(int client, int explosionType, float origin[3], int target, Rifles_TargetType type)
{
    Rifles_ExplosionDamage(origin, client, Rifles_g_cvExplosionRadius.FloatValue, Rifles_g_cvExplosionDamage.FloatValue);

    if (explosionType == Rifles_PENDING_EXPLOSION_SG552
        || explosionType == Rifles_PENDING_EXPLOSION_SG552_FULLPOWER
        || explosionType == Rifles_PENDING_EXPLOSION_M60)
    {
        Rifles_IgniteRadius(origin, Rifles_g_cvExplosionRadius.FloatValue, client);
    }

    if (explosionType == Rifles_PENDING_EXPLOSION_M60 && Rifles_IsEnemyType(type) && target > 0)
    {
        Rifles_IgniteTarget(target, Rifles_g_cvIgniteDuration.FloatValue);
    }
}

Rifles_TargetType Rifles_GetTargetType(int entity)
{
    if (entity <= 0)
    {
        return Rifles_Target_Invalid;
    }

    if (entity <= MaxClients)
    {
        if (!IsClientInGame(entity) || !IsPlayerAlive(entity))
        {
            return Rifles_Target_Invalid;
        }

        int team = GetClientTeam(entity);
        if (team == Rifles_TEAM_SURVIVOR)
        {
            return Rifles_Target_Survivor;
        }
        if (team == Rifles_TEAM_INFECTED)
        {
            int zc = GetEntProp(entity, Prop_Send, "m_zombieClass");
            if (zc == Rifles_ZC_TANK)
            {
                return Rifles_Target_Tank;
            }
            if (zc >= Rifles_ZC_SMOKER && zc <= Rifles_ZC_CHARGER)
            {
                return Rifles_Target_SpecialInfected;
            }
        }
        return Rifles_Target_Invalid;
    }

    if (!IsValidEntity(entity))
    {
        return Rifles_Target_Invalid;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (StrEqual(classname, "infected", false))
    {
        return Rifles_Target_CommonInfected;
    }
    if (StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false))
    {
        return Rifles_Target_Witch;
    }

    return Rifles_Target_Invalid;
}

bool Rifles_IsEnemyType(Rifles_TargetType type)
{
    return type == Rifles_Target_CommonInfected || type == Rifles_Target_SpecialInfected || type == Rifles_Target_Tank || type == Rifles_Target_Witch;
}

bool Rifles_IsHumanSurvivorAlive(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && IsPlayerAlive(client)
        && GetClientTeam(client) == Rifles_TEAM_SURVIVOR;
}

bool Rifles_IsAliveSurvivor(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && IsPlayerAlive(client)
        && GetClientTeam(client) == Rifles_TEAM_SURVIVOR;
}

bool Rifles_GetCurrentWeaponClass(int client, char[] weapon, int maxlen)
{
    int ent = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (ent <= MaxClients || !IsValidEntity(ent))
    {
        return false;
    }

    GetEntityClassname(ent, weapon, maxlen);
    return weapon[0] != '\0';
}

bool Rifles_Chance(float percent)
{
    if (percent <= 0.0)
    {
        return false;
    }
    if (percent >= 100.0)
    {
        return true;
    }

    // 0.01% precision. Supports values such as 0.1 without relying on float RNG natives.
    int roll = GetURandomInt() % 10000;
    return float(roll) < (percent * 100.0);
}

void Rifles_ApplyDamage(int target, float damage, int attacker, int damageType)
{
    if (damage <= 0.0 || !Rifles_IsValidDamageTarget(target) || !Rifles_IsHumanSurvivorAlive(attacker))
    {
        return;
    }

    Rifles_TargetType type = Rifles_GetTargetType(target);
    if (!Rifles_IsEnemyType(type))
    {
        return;
    }

    float finalDamage = damage * Rifles_g_cvDamageMultiplier.FloatValue;
    Rifles_g_bApplyingPluginDamage[attacker] = true;
    MWE_SDKHooks_TakeDamage(target, attacker, attacker, finalDamage, damageType);
    Rifles_g_bApplyingPluginDamage[attacker] = false;
}



void Rifles_ApplyPercentDamage(int target, float percent, int attacker, int damageType)
{
    Rifles_TargetType type = Rifles_GetTargetType(target);
    if (!Rifles_IsEnemyType(type) || percent <= 0.0)
    {
        return;
    }

    int maxHp = Rifles_GetEntityMaxHealthSafe(target, type);
    if (maxHp <= 0)
    {
        return;
    }

    Rifles_ApplyDamage(target, float(maxHp) * percent, attacker, damageType);
}

bool Rifles_IsValidDamageTarget(int entity)
{
    if (entity <= 0)
    {
        return false;
    }
    if (entity <= MaxClients)
    {
        return IsClientInGame(entity) && IsPlayerAlive(entity);
    }
    return IsValidEntity(entity);
}

int Rifles_GetEntityMaxHealthSafe(int entity, Rifles_TargetType type)
{
    int hp = 0;

    if (entity > 0 && IsValidEntity(entity) && FindDataMapInfo(entity, "m_iMaxHealth") != -1)
    {
        hp = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
    }

    if (hp > 0)
    {
        return hp;
    }

    switch (type)
    {
        case Rifles_Target_CommonInfected: return 50;
        case Rifles_Target_SpecialInfected: return 250;
        case Rifles_Target_Tank: return 4000;
        case Rifles_Target_Witch: return 1000;
    }

    return 0;
}

void Rifles_ExplosionDamage(float origin[3], int attacker, float radius, float damage)
{
    float damageScale = 1.0;
    if (Rifles_g_cvDamageMultiplier != null)
    {
        damageScale = Rifles_g_cvDamageMultiplier.FloatValue;
    }
    MWE_CreateUnifiedExplosionDamage(origin, attacker, radius, damage, damageScale);
}

void Rifles_IgniteRadius(float origin[3], float radius, int attacker)
{
    if (radius <= 0.0)
    {
        return;
    }

    int targets[Rifles_MAX_AREA_TARGETS];
    int count = Rifles_FindTargetsInRadius(origin, radius, targets, sizeof(targets));
    for (int i = 0; i < count; i++)
    {
        Rifles_TargetType type = Rifles_GetTargetType(targets[i]);
        if (Rifles_IsEnemyType(type))
        {
            Rifles_IgniteTarget(targets[i], Rifles_g_cvIgniteDuration.FloatValue);
        }
    }
}

void Rifles_IgniteAllEnemies(int attacker)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == Rifles_TEAM_INFECTED)
        {
            Rifles_IgniteTarget(i, Rifles_g_cvIgniteDuration.FloatValue);
        }
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        Rifles_IgniteTarget(entity, Rifles_g_cvIgniteDuration.FloatValue);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        Rifles_IgniteTarget(entity, Rifles_g_cvIgniteDuration.FloatValue);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch_bride")) != -1)
    {
        Rifles_IgniteTarget(entity, Rifles_g_cvIgniteDuration.FloatValue);
    }
}

void Rifles_IgniteTarget(int target, float duration)
{
    if (!Rifles_IsValidDamageTarget(target))
    {
        return;
    }

    Rifles_TargetType type = Rifles_GetTargetType(target);
    if (!Rifles_IsEnemyType(type))
    {
        return;
    }

    IgniteEntity(target, duration);
}

void Rifles_KnockCommonInfectedRadius(float origin[3], float radius, int attacker, float force)
{
    if (radius <= 0.0 || force <= 0.0)
    {
        return;
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        float pos[3];
        Rifles_GetEntityOrigin(entity, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Rifles_KnockAwayFromPoint(entity, origin, force);
        }
    }
}

void Rifles_DamageCommonInfectedRadius(float origin[3], float radius, float damage, int attacker)
{
    if (radius <= 0.0 || damage <= 0.0)
    {
        return;
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        float pos[3];
        Rifles_GetEntityOrigin(entity, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Rifles_ApplyDamage(entity, damage, attacker, DMG_BULLET);
        }
    }
}

void Rifles_KnockAwayFromClient(int target, int client, float force)
{
    float origin[3];
    GetClientAbsOrigin(client, origin);
    Rifles_KnockAwayFromPoint(target, origin, force);
}

void Rifles_KnockAwayFromPoint(int target, float origin[3], float force)
{
    if (force <= 0.0 || !Rifles_IsValidDamageTarget(target))
    {
        return;
    }

    Rifles_TargetType type = Rifles_GetTargetType(target);
    if (!Rifles_IsEnemyType(type))
    {
        return;
    }

    float pos[3];
    Rifles_GetEntityOrigin(target, pos);

    float velocity[3];
    velocity[0] = pos[0] - origin[0];
    velocity[1] = pos[1] - origin[1];
    velocity[2] = 80.0;

    if (NormalizeVector(velocity, velocity) <= 0.001)
    {
        velocity[0] = 0.0;
        velocity[1] = 0.0;
        velocity[2] = 1.0;
    }

    ScaleVector(velocity, force);
    velocity[2] += 160.0;
    TeleportEntity(target, NULL_VECTOR, NULL_VECTOR, velocity);
}

int Rifles_FindTargetsInRadius(float origin[3], float radius, int[] targets, int maxTargets)
{
    int count = 0;

    for (int i = 1; i <= MaxClients && count < maxTargets; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(i, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            targets[count++] = i;
        }
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1 && count < maxTargets)
    {
        float pos[3];
        Rifles_GetEntityOrigin(entity, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            targets[count++] = entity;
        }
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1 && count < maxTargets)
    {
        float pos[3];
        Rifles_GetEntityOrigin(entity, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            targets[count++] = entity;
        }
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch_bride")) != -1 && count < maxTargets)
    {
        float pos[3];
        Rifles_GetEntityOrigin(entity, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            targets[count++] = entity;
        }
    }

    return count;
}

void Rifles_GetEntityOrigin(int entity, float pos[3])
{
    if (entity > 0 && entity <= MaxClients)
    {
        GetClientAbsOrigin(entity, pos);
        return;
    }

    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
}

float Rifles_GetClientTempHealth(int client)
{
    if (!Rifles_IsAliveSurvivor(client))
    {
        return 0.0;
    }

    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    float bufferTime = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float decay = 0.27;

    if (Rifles_g_cvPillsDecay != null)
    {
        decay = Rifles_g_cvPillsDecay.FloatValue;
    }

    float temp = buffer - ((GetGameTime() - bufferTime) * decay);
    if (temp < 0.0)
    {
        temp = 0.0;
    }
    return temp;
}

void Rifles_GiveTempHealth(int client, float amount)
{
    if (!Rifles_IsAliveSurvivor(client) || amount <= 0.0)
    {
        return;
    }

    // 严格回血规则：先把已有的实血+虚血修正到不超过 100，
    // 再判断是否还能增加虚血，最后再次强制裁剪。
    Rifles_ClampSurvivorTotalHealth(client, 100.0);

    int realHp = GetClientHealth(client);
    float temp = Rifles_GetClientTempHealth(client);
    float total = float(realHp) + temp;

    if (total >= 100.0)
    {
        Rifles_ClampSurvivorTotalHealth(client, 100.0);
        return;
    }

    float canAdd = 100.0 - total;
    float add = amount;
    if (add > canAdd)
    {
        add = canAdd;
    }

    if (add <= 0.0)
    {
        Rifles_ClampSurvivorTotalHealth(client, 100.0);
        return;
    }

    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", temp + add);
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
    Rifles_ClampSurvivorTotalHealth(client, 100.0);
}

void Rifles_HealRealHealthCapped(int client, int amount, int totalCap)
{
    // 统一回血规则：实血 + 当前有效虚血必须 < 100 才能回血；回血后总量不能超过 100。
    // totalCap 参数保留是为了兼容旧调用点，但这里强制使用 100 作为总血量上限。
    totalCap = 100;

    if (!Rifles_IsAliveSurvivor(client) || amount <= 0)
    {
        return;
    }

    Rifles_ClampSurvivorTotalHealth(client, float(totalCap));

    int realHp = GetClientHealth(client);
    float tempHp = Rifles_GetClientTempHealth(client);
    float totalHp = float(realHp) + tempHp;

    if (totalHp >= float(totalCap))
    {
        Rifles_ClampSurvivorTotalHealth(client, float(totalCap));
        return;
    }

    float canAddFloat = float(totalCap) - totalHp;
    int canAdd = RoundToFloor(canAddFloat);

    if (canAdd <= 0)
    {
        Rifles_ClampSurvivorTotalHealth(client, float(totalCap));
        return;
    }

    int add = amount;
    if (add > canAdd)
    {
        add = canAdd;
    }

    int newHp = realHp + add;
    if (newHp > totalCap)
    {
        newHp = totalCap;
    }

    SetEntityHealth(client, newHp);
    Rifles_ClampSurvivorTotalHealth(client, float(totalCap));
}

void Rifles_ClampSurvivorTotalHealth(int client, float totalCap)
{
    if (!Rifles_IsAliveSurvivor(client) || totalCap <= 0.0)
    {
        return;
    }

    int realHp = GetClientHealth(client);
    float tempHp = Rifles_GetClientTempHealth(client);
    float now = GetGameTime();

    if (realHp >= RoundToCeil(totalCap))
    {
        SetEntityHealth(client, RoundToFloor(totalCap));
        SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
        SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", now);
        return;
    }

    float maxTemp = totalCap - float(realHp);
    if (maxTemp < 0.0)
    {
        maxTemp = 0.0;
    }

    if (tempHp > maxTemp)
    {
        // 只有真的超出 100 时才重写 buffer/time。
        // 未超出时不刷新 m_healthBufferTime，避免玩家连续开火把虚血衰减时间不断重置。
        SetEntPropFloat(client, Prop_Send, "m_healthBuffer", maxTemp);
        SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", now);
    }
}

void Rifles_GivePluginAdrenaline(int client, float duration)
{
    if (!Rifles_IsAliveSurvivor(client) || duration <= 0.0)
    {
        return;
    }

    // Use the game's native adrenaline implementation.
    // The old version simulated adrenaline by changing m_flLaggedMovementValue,
    // which made AK47 feel like a custom speed boost instead of normal adrenaline.
    Rifles_RunVScript("local p = EntIndexToHScript(%d); if (p != null && p.IsValid() && p.IsSurvivor()) { p.UseAdrenaline(%.3f); }", client, duration);

    float until = GetGameTime() + duration;
    if (until > Rifles_g_flKnownAdrenUntil[client])
    {
        Rifles_g_flKnownAdrenUntil[client] = until;
    }

    Rifles_g_bAdrenActive[client] = true;

    if (Rifles_g_hAdrenTimer[client] != null)
    {
        delete Rifles_g_hAdrenTimer[client];
        Rifles_g_hAdrenTimer[client] = null;
    }
    Rifles_g_hAdrenTimer[client] = CreateTimer(duration, Rifles_Timer_EndAdrenaline, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

bool Rifles_IsPluginAdrenalineActive(int client)
{
    if (!Rifles_IsAliveSurvivor(client))
    {
        return false;
    }

    if (Rifles_g_bHasAdrenalineProp && GetEntProp(client, Prop_Send, "m_bAdrenalineActive") != 0)
    {
        return true;
    }

    return Rifles_g_bAdrenActive[client] || Rifles_g_flKnownAdrenUntil[client] > GetGameTime();
}

public Action Rifles_Timer_EndAdrenaline(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && client <= MaxClients)
    {
        Rifles_g_hAdrenTimer[client] = null;
        Rifles_g_bAdrenActive[client] = false;
    }
    return Plugin_Stop;
}

void Rifles_ClearAdrenaline(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (Rifles_g_hAdrenTimer[client] != null)
    {
        delete Rifles_g_hAdrenTimer[client];
        Rifles_g_hAdrenTimer[client] = null;
    }

    Rifles_g_bAdrenActive[client] = false;
    Rifles_g_flKnownAdrenUntil[client] = 0.0;
}

void Rifles_RunVScript(const char[] fmt, any ...)
{
    char code[512];
    VFormat(code, sizeof(code), fmt, 2);

    int script = CreateEntityByName("logic_script");
    if (script == -1)
    {
        LogError("[MWE Rifles] Failed to create logic_script. Code: %s", code);
        return;
    }

    DispatchSpawn(script);
    SetVariantString(code);
    AcceptEntityInput(script, "RunScriptCode");
    AcceptEntityInput(script, "Kill");
}

void Rifles_TryGiveM16ClipBonusOnSpecialKill(Event event)
{
    if (!Rifles_g_cvEnabled.BoolValue)
    {
        return;
    }

    if (Rifles_g_cvM4ClipBonusEnable != null && !Rifles_g_cvM4ClipBonusEnable.BoolValue)
    {
        return;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!Rifles_IsHumanSurvivorAlive(attacker))
    {
        return;
    }

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != 3)
    {
        return;
    }

    if (!HasEntProp(victim, Prop_Send, "m_zombieClass"))
    {
        return;
    }

    int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (!((zombieClass >= 1 && zombieClass <= 6) || zombieClass == 8))
    {
        return;
    }

    // L4D2 normally reports the M16 as "rifle" in player_death. Accept a
    // few equivalent names as well, but do not reward kills made by grenades,
    // fire, melee, or another weapon merely while the player is holding an M16.
    char eventWeapon[64];
    event.GetString("weapon", eventWeapon, sizeof(eventWeapon));
    if (!StrEqual(eventWeapon, "rifle", false)
        && !StrEqual(eventWeapon, "weapon_rifle", false)
        && !StrEqual(eventWeapon, "rifle_m16", false)
        && !StrEqual(eventWeapon, "m16", false))
    {
        return;
    }

    Rifles_TryGiveM4ClipBonus(attacker);
}

void Rifles_TryGiveM4ClipBonus(int client)
{
    if (!Rifles_IsAliveSurvivor(client))
    {
        return;
    }

    if (Rifles_g_cvM4ClipBonusEnable != null && !Rifles_g_cvM4ClipBonusEnable.BoolValue)
    {
        return;
    }

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return;
    }

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (!StrEqual(classname, "weapon_rifle", false))
    {
        return;
    }

    if (!HasEntProp(weapon, Prop_Send, "m_iClip1"))
    {
        return;
    }

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip < 0)
    {
        return;
    }

    float chance = 20.0;
    if (Rifles_g_cvM4ClipBonusChance != null)
    {
        chance = Rifles_g_cvM4ClipBonusChance.FloatValue;
    }
    if (!Rifles_Chance(chance))
    {
        return;
    }

    int fallbackAmount = 40;
    if (Rifles_g_cvM4ClipBonusAmount != null)
    {
        fallbackAmount = Rifles_g_cvM4ClipBonusAmount.IntValue;
    }
    if (fallbackAmount <= 0)
    {
        return;
    }

    int maxClip = 0;
    if (Rifles_g_cvM4ClipBonusMax != null)
    {
        maxClip = Rifles_g_cvM4ClipBonusMax.IntValue;
    }

    int mode = 1;
    if (Rifles_g_cvM4ClipBonusMode != null)
    {
        mode = Rifles_g_cvM4ClipBonusMode.IntValue;
    }

    if (mode == 1)
    {
        Rifles_GiveAutomaticM16Magazine(weapon, fallbackAmount, maxClip);
        return;
    }

    int newClip = clip + fallbackAmount;
    if (maxClip > 0 && newClip > maxClip)
    {
        newClip = maxClip;
    }
    if (newClip <= clip)
    {
        return;
    }

    SetEntProp(weapon, Prop_Send, "m_iClip1", newClip);
}

void Rifles_GiveAutomaticM16Magazine(int weapon, int fallbackAmount, int maxClipLimit)
{
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return;
    }

    // L4D2 VScript exposes CBaseCombatWeapon.GetMaxClip1(). This reads the
    // weapon's actual magazine capacity instead of assuming M16 is always 40/50.
    // Only m_iClip1 is changed; the survivor's reserve ammo remains untouched.
    Rifles_RunVScript(
        "local w = EntIndexToHScript(%d); if (w != null && w.IsValid()) { local current = NetProps.GetPropInt(w, \"m_iClip1\"); local amount = w.GetMaxClip1(); if (amount <= 0) amount = %d; local result = current + amount; if (%d > 0 && result > %d) result = %d; if (result > current) NetProps.SetPropInt(w, \"m_iClip1\", result); }",
        weapon,
        fallbackAmount,
        maxClipLimit,
        maxClipLimit,
        maxClipLimit
    );
}

void Rifles_TryRefundAK47ClipAmmo(int client)
{
    if (!Rifles_IsAliveSurvivor(client))
    {
        return;
    }

    float chance = 25.0;
    if (Rifles_g_cvAKAdrenClipChance != null)
    {
        chance = Rifles_g_cvAKAdrenClipChance.FloatValue;
    }

    if (chance <= 0.0 || GetRandomFloat(0.0, 100.0) >= chance)
    {
        return;
    }

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return;
    }

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (!StrEqual(classname, "weapon_rifle_ak47", false))
    {
        return;
    }

    // m_iClip1 is the bullets currently loaded in the magazine.
    // This deliberately does not touch reserve ammo.
    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (clip < 0)
    {
        return;
    }

    SetEntProp(weapon, Prop_Send, "m_iClip1", clip + 1);
}

void Rifles_GiveRandomSpecialAmmo(int client)
{
    if (!Rifles_IsAliveSurvivor(client))
    {
        return;
    }

    int upgrade = GetRandomInt(Rifles_UPGRADE_INCENDIARY_AMMO, Rifles_UPGRADE_EXPLOSIVE_AMMO);
    Rifles_GiveWeaponUpgrade(client, upgrade, 30);
}

void Rifles_GiveWeaponUpgrade(int client, int upgradeId, int upgradedAmmo)
{
    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return;
    }

    if (Rifles_HasEntitySendProp(weapon, "m_upgradeBitVec"))
    {
        int flags = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
        flags |= (1 << upgradeId);
        SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", flags);
    }

    if (Rifles_HasEntitySendProp(weapon, "m_nUpgradedPrimaryAmmoLoaded"))
    {
        int current = GetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
        if (current < upgradedAmmo)
        {
            SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", upgradedAmmo);
        }
    }
}

bool Rifles_HasEntitySendProp(int entity, const char[] prop)
{
    if (entity <= 0 || !IsValidEntity(entity))
    {
        return false;
    }

    char netclass[64];
    if (!GetEntityNetClass(entity, netclass, sizeof(netclass)))
    {
        return false;
    }

    return FindSendPropInfo(netclass, prop) != -1;
}

void Rifles_CreateExplosionVisual(float origin[3])
{
    int ent = CreateEntityByName("env_explosion");
    if (ent == -1)
    {
        return;
    }

    DispatchKeyValue(ent, "iMagnitude", "0");
    DispatchKeyValue(ent, "spawnflags", "1");
    DispatchSpawn(ent);
    TeleportEntity(ent, origin, NULL_VECTOR, NULL_VECTOR);
    AcceptEntityInput(ent, "Explode");
    AcceptEntityInput(ent, "Kill");
}

void Rifles_DebugLog(const char[] format, any ...)
{
    if (!Rifles_g_cvDebug.BoolValue)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogMessage("[MWER] %s", buffer);
}


// ============================================================================
// Module: Snipers (from l4d2_mwe_snipers.sp)
// ============================================================================

/**
 * l4d2_mwe_snipers.sp
 *
 * 使用方法 / Usage:
 * 1. 将本文件放入: left4dead2/addons/sourcemod/scripting/l4d2_mwe_snipers.sp
 * 2. 使用 SourceMod 编译器 spcomp 编译，生成 l4d2_mwe_snipers.smx。
 * 3. 将 .smx 放入: left4dead2/addons/sourcemod/plugins/
 * 4. 启动服务器或执行 sm plugins refresh。
 * 5. 本整合版配置统一写入: left4dead2/cfg/sourcemod/l4d2_mwe_all.cfg
 *
 * 简介 / Intro:
 * 这是“多武器效果”项目的狙击枪独立版 SourceMod 插件。
 * 只处理 4 把狙击枪: 30狙、15狙、AWP、Scout。
 * 插件使用 weapon_fire + 视线射线追踪触发效果，不钩不存在的 witch_hurt 等事件。
 * 高级 L4D2 行为（胆汁、肾上腺素、救起、击退）通过 logic_script 执行 VScript 原生函数实现。
 */



#define Snipers_PLUGIN_VERSION "1.0.4"
#define Snipers_TRACE_DISTANCE 18192.0
#define Snipers_PENDING_EXPLOSION_NONE 0
#define Snipers_PENDING_EXPLOSION_MILITARY 1
#define Snipers_PENDING_EXPLOSION_AWP 2
#define Snipers_TEAM_SURVIVOR 2
#define Snipers_TEAM_INFECTED 3
#define Snipers_ZC_TANK 8
#define Snipers_PICKUP_NOTIFY_COOLDOWN 1.50


enum Snipers_TargetType
{
    Snipers_Target_Invalid = 0,
    Snipers_Target_CommonInfected,
    Snipers_Target_SpecialInfected,
    Snipers_Target_Tank,
    Snipers_Target_Witch,
    Snipers_Target_Survivor
};

ConVar Snipers_g_cvEnabled;
ConVar Snipers_g_cvNotify;
ConVar Snipers_g_cvDebug;
ConVar Snipers_g_cvDecayRate;

ConVar Snipers_g_cvWeaponMilitary;
ConVar Snipers_g_cvWeaponHunting;
ConVar Snipers_g_cvWeaponAWP;
ConVar Snipers_g_cvWeaponScout;

ConVar Snipers_g_cvMilitaryExplosionChance;
ConVar Snipers_g_cvMilitaryIgniteChance;
ConVar Snipers_g_cvMilitaryExplosionRadius;
ConVar Snipers_g_cvMilitaryExplosionDamage;
ConVar Snipers_g_cvMilitaryIgniteRadius;
ConVar Snipers_g_cvMilitaryIgniteDuration;

ConVar Snipers_g_cvHuntingBileChance;
ConVar Snipers_g_cvHuntingTempChance;
ConVar Snipers_g_cvHuntingBileRadius;
ConVar Snipers_g_cvHuntingBileDamage;
ConVar Snipers_g_cvHuntingTempAmount;
ConVar Snipers_g_cvHuntingTeamTempRadius;
ConVar Snipers_g_cvHuntingAdrenalineDuration;

ConVar Snipers_g_cvAWPExplosionChance;
ConVar Snipers_g_cvAWPAllFireChance;
ConVar Snipers_g_cvAWPExplosionRadius;
ConVar Snipers_g_cvAWPExplosionDamage;
ConVar Snipers_g_cvAWPAdrenalineDuration;
ConVar Snipers_g_cvAWPAllFireDuration;

ConVar Snipers_g_cvScoutAllBileChance;
ConVar Snipers_g_cvScoutAllyHealChance;
ConVar Snipers_g_cvScoutRangeHealChance;
ConVar Snipers_g_cvScoutAllyHealAmount;
ConVar Snipers_g_cvScoutSelfHealAmount;
ConVar Snipers_g_cvScoutRangeHealAmount;
ConVar Snipers_g_cvScoutRangeHealRadius;
ConVar Snipers_g_cvScoutAllBileDamage;
ConVar Snipers_g_cvScoutKnockForce;

bool Snipers_g_bLateLoaded;
bool Snipers_g_bWeaponEquipHookInstalled[MAXPLAYERS + 1];
char Snipers_g_sLastPickupNotifyWeapon[MAXPLAYERS + 1][64];
float Snipers_g_fLastPickupNotifyTime[MAXPLAYERS + 1];
bool Snipers_g_bApplyingPluginDamage[MAXPLAYERS + 1];
bool Snipers_g_bApplyingAnyPluginDamage;
int Snipers_g_iShotSerial[MAXPLAYERS + 1];
int Snipers_g_iPendingExplosionShot[MAXPLAYERS + 1];
int Snipers_g_iPendingExplosionType[MAXPLAYERS + 1];
int Snipers_g_iProcessedExplosionShot[MAXPLAYERS + 1];
bool Snipers_g_bPendingExplosionHasPos[MAXPLAYERS + 1];
float Snipers_g_fPendingExplosionPos[MAXPLAYERS + 1][3];
int Snipers_g_iLastAWPEffectShot[2049];
int Snipers_g_iLastAWPEffectAttacker[2049];

public APLRes Snipers_AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    Snipers_g_bLateLoaded = late;
    return APLRes_Success;
}

void Snipers_InstallWeaponEquipHook(int client)
{
    // Auto weapon-equip descriptions disabled: use !mwe / !武器 menu instead.
    return;
}

void Snipers_UninstallWeaponEquipHook(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (Snipers_g_bWeaponEquipHookInstalled[client])
    {
        if (IsClientInGame(client))
        {
            SDKUnhook(client, SDKHook_WeaponEquipPost, Snipers_SDK_OnWeaponEquipPost);
        }
        Snipers_g_bWeaponEquipHookInstalled[client] = false;
    }
}

public void Snipers_OnPluginStart()
{
    Snipers_CreateConVars();

    // Auto pickup descriptions disabled: use !mwe / !武器 menu instead.
    HookEvent("weapon_fire", Snipers_Event_WeaponFire, EventHookMode_Post);


    RegConsoleCmd("sm_mwesniper_info", Snipers_Cmd_Info, "显示狙击枪特效插件状态");

    // cfg 统一由整合版主入口生成。

    Snipers_g_cvDecayRate = FindConVar("pain_pills_decay_rate");

    // WeaponEquipPost 只在玩家获得/装备新武器实体时触发，
    // 不使用 WeaponSwitchPost，因此普通切枪不会显示提示。
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            MWE_HookSharedTakeDamage(i);
            Snipers_InstallWeaponEquipHook(i);
        }
    }

    Snipers_HookExistingDamageEntities();

    if (Snipers_g_bLateLoaded)
    {
        Snipers_DebugLog("Plugin late-loaded.");
    }
}

void Snipers_CreateConVars()
{
    Snipers_g_cvEnabled = CreateConVar("sm_mwe_sniper_enabled", "1", "狙击枪特效总开关。1=开启, 0=关闭", 0, true, 0.0, true, 1.0);
    Snipers_g_cvNotify = CreateConVar("sm_mwe_sniper_notify", "0", "DEPRECATED: pickup sniper notices are disabled; use !mwe / !武器 menu.", 0, true, 0.0, true, 1.0);
    Snipers_g_cvDebug = CreateConVar("sm_mwe_sniper_debug", "0", "调试日志。1=开启, 0=关闭", 0, true, 0.0, true, 1.0);

    Snipers_g_cvWeaponMilitary = CreateConVar("sm_mwe_sniper_weapon_military", "1", "30狙 weapon_sniper_military 开关", 0, true, 0.0, true, 1.0);
    Snipers_g_cvWeaponHunting = CreateConVar("sm_mwe_sniper_weapon_hunting", "1", "15狙 weapon_hunting_rifle 开关", 0, true, 0.0, true, 1.0);
    Snipers_g_cvWeaponAWP = CreateConVar("sm_mwe_sniper_weapon_awp", "1", "AWP weapon_sniper_awp 开关", 0, true, 0.0, true, 1.0);
    Snipers_g_cvWeaponScout = CreateConVar("sm_mwe_sniper_weapon_scout", "1", "Scout weapon_sniper_scout 开关", 0, true, 0.0, true, 1.0);

    Snipers_g_cvMilitaryExplosionChance = CreateConVar("sm_mwe_sniper_military_explosion_chance", "10.0", "30狙爆炸概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvMilitaryIgniteChance = CreateConVar("sm_mwe_sniper_military_ignite_chance", "5.0", "30狙范围点燃概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvMilitaryExplosionRadius = CreateConVar("sm_mwe_sniper_military_explosion_radius", "180.0", "30狙爆炸半径", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvMilitaryExplosionDamage = CreateConVar("sm_mwe_sniper_military_explosion_damage", "80.0", "30狙爆炸伤害", 0, true, 0.0, true, 10000.0);
    Snipers_g_cvMilitaryIgniteRadius = CreateConVar("sm_mwe_sniper_military_ignite_radius", "150.0", "30狙点燃半径", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvMilitaryIgniteDuration = CreateConVar("sm_mwe_sniper_military_ignite_duration", "8.0", "30狙点燃时长", 0, true, 0.0, true, 60.0);

    Snipers_g_cvHuntingBileChance = CreateConVar("sm_mwe_sniper_hunting_bile_chance", "15.0", "15狙范围胆汁概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvHuntingTempChance = CreateConVar("sm_mwe_sniper_hunting_temp_chance", "20.0", "15狙击中目标后虚血/队友虚血概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvHuntingBileRadius = CreateConVar("sm_mwe_sniper_hunting_bile_radius", "600.0", "15狙范围胆汁半径", 0, true, 0.0, true, 2000.0);
    Snipers_g_cvHuntingBileDamage = CreateConVar("sm_mwe_sniper_hunting_bile_damage", "10.0", "15狙胆汁附带小伤害。设为0可关闭", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvHuntingTempAmount = CreateConVar("sm_mwe_sniper_hunting_temp_amount", "10.0", "15狙给予虚血量", 0, true, 0.0, true, 100.0);
    Snipers_g_cvHuntingTeamTempRadius = CreateConVar("sm_mwe_sniper_hunting_team_temp_radius", "200.0", "15狙队友虚血范围", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvHuntingAdrenalineDuration = CreateConVar("sm_mwe_sniper_hunting_adrenaline_duration", "10.0", "15狙触发虚血时给予射击者肾上腺素时长", 0, true, 0.0, true, 60.0);

    Snipers_g_cvAWPExplosionChance = CreateConVar("sm_mwe_sniper_awp_explosion_chance", "20.0", "AWP爆炸概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvAWPAllFireChance = CreateConVar("sm_mwe_sniper_awp_all_fire_chance", "1.0", "AWP全场点燃+全队肾上腺素概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvAWPExplosionRadius = CreateConVar("sm_mwe_sniper_awp_explosion_radius", "220.0", "AWP爆炸半径", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvAWPExplosionDamage = CreateConVar("sm_mwe_sniper_awp_explosion_damage", "120.0", "AWP爆炸伤害", 0, true, 0.0, true, 10000.0);
    Snipers_g_cvAWPAdrenalineDuration = CreateConVar("sm_mwe_sniper_awp_adrenaline_duration", "5.0", "AWP击中特感/Tank/Witch后给予射击者肾上腺素时长", 0, true, 0.0, true, 60.0);
    Snipers_g_cvAWPAllFireDuration = CreateConVar("sm_mwe_sniper_awp_all_fire_duration", "10.0", "AWP全场点燃时长", 0, true, 0.0, true, 60.0);

    Snipers_g_cvScoutAllBileChance = CreateConVar("sm_mwe_sniper_scout_all_bile_chance", "30.0", "Scout全场胆汁概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvScoutAllyHealChance = CreateConVar("sm_mwe_sniper_scout_ally_heal_chance", "30.0", "Scout击中队友时治疗概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvScoutRangeHealChance = CreateConVar("sm_mwe_sniper_scout_range_heal_chance", "20.0", "Scout击中特感后范围治疗概率", 0, true, 0.0, true, 100.0);
    Snipers_g_cvScoutAllyHealAmount = CreateConVar("sm_mwe_sniper_scout_ally_heal_amount", "20", "Scout队友治疗实血量", 0, true, 0.0, true, 100.0);
    Snipers_g_cvScoutSelfHealAmount = CreateConVar("sm_mwe_sniper_scout_self_heal_amount", "10", "Scout击中特感后射击者回血量", 0, true, 0.0, true, 100.0);
    Snipers_g_cvScoutRangeHealAmount = CreateConVar("sm_mwe_sniper_scout_range_heal_amount", "10.0", "Scout范围治疗虚血量", 0, true, 0.0, true, 100.0);
    Snipers_g_cvScoutRangeHealRadius = CreateConVar("sm_mwe_sniper_scout_range_heal_radius", "200.0", "Scout范围治疗半径", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvScoutAllBileDamage = CreateConVar("sm_mwe_sniper_scout_all_bile_damage", "10.0", "Scout全场胆汁附带小伤害。设为0可关闭", 0, true, 0.0, true, 1000.0);
    Snipers_g_cvScoutKnockForce = CreateConVar("sm_mwe_sniper_scout_knock_force", "400.0", "Scout击退向量力度", 0, true, 0.0, true, 2000.0);
}

public Action Snipers_Cmd_Info(int client, int args)
{
    if (client > 0 && IsClientInGame(client))
    {
        ReplyToCommand(client, "[MWE Snipers] enabled=%d, notify=%d, debug=%d", Snipers_g_cvEnabled.BoolValue, Snipers_g_cvNotify.BoolValue, Snipers_g_cvDebug.BoolValue);
    }
    else
    {
        PrintToServer("[MWE Snipers] enabled=%d, notify=%d, debug=%d", Snipers_g_cvEnabled.BoolValue, Snipers_g_cvNotify.BoolValue, Snipers_g_cvDebug.BoolValue);
    }
    return Plugin_Handled;
}

public void Snipers_OnClientPutInServer(int client)
{
    if (Snipers_IsValidClientIndex(client))
    {
        MWE_HookSharedTakeDamage(client);
        Snipers_InstallWeaponEquipHook(client);
    }
}

public void Snipers_OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients)
    {
        return;
    }

    if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false))
    {
        MWE_HookSharedTakeDamage(entity);
    }
}

void Snipers_HookExistingDamageEntities()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch_bride")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }
}

public Action Snipers_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (damage <= 0.0 || !Snipers_g_cvEnabled.BoolValue)
    {
        return Plugin_Continue;
    }

    if (Snipers_g_bApplyingAnyPluginDamage)
    {
        return Plugin_Continue;
    }

    if (!Snipers_IsHumanSurvivor(attacker))
    {
        return Plugin_Continue;
    }

    if (Snipers_g_bApplyingPluginDamage[attacker])
    {
        return Plugin_Continue;
    }

    if ((damagetype & DMG_BULLET) == 0 && (damagetype & DMG_BUCKSHOT) == 0)
    {
        return Plugin_Continue;
    }

    char weapon[64];
    if (!MWE_GetDamageWeaponClass(attacker, weapon, sizeof(weapon)))
    {
        return Plugin_Continue;
    }

    Snipers_HandleRealDamageHit(attacker, victim, weapon);
    return Plugin_Continue;
}




public void Snipers_SDK_OnWeaponEquipPost(int client, int weaponEnt)
{
    // WeaponEquipPost must never show weapon descriptions.
    return;
}

public void Snipers_Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    // Pickup-triggered weapon descriptions are deleted. Use !mwe / !武器 menu only.
    return;
}

public Action Snipers_Timer_ShowPickupInfo(Handle timer, any userid)
{
    // Deleted pickup-description timer.
    return Plugin_Stop;
}

public void Snipers_OnClientDisconnect(int client)
{
    Snipers_UninstallWeaponEquipHook(client);

    if (client >= 1 && client <= MaxClients)
    {
        Snipers_g_sLastPickupNotifyWeapon[client][0] = '\0';
        Snipers_g_fLastPickupNotifyTime[client] = 0.0;
        Snipers_g_iShotSerial[client] = 0;
        Snipers_g_iPendingExplosionShot[client] = 0;
        Snipers_g_iPendingExplosionType[client] = Snipers_PENDING_EXPLOSION_NONE;
        Snipers_g_iProcessedExplosionShot[client] = 0;
        Snipers_g_bPendingExplosionHasPos[client] = false;
        Snipers_g_fPendingExplosionPos[client][0] = 0.0;
        Snipers_g_fPendingExplosionPos[client][1] = 0.0;
        Snipers_g_fPendingExplosionPos[client][2] = 0.0;
    }
}

public void Snipers_Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!Snipers_g_cvEnabled.BoolValue)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Snipers_IsHumanSurvivor(client))
    {
        return;
    }

    char weapon[64];
    if (!MWE_GetCachedActiveWeaponClass(client, weapon, sizeof(weapon)))
    {
        return;
    }

    MWE_RecordWeaponFire(client, weapon);

    if (Snipers_IsSniperWeaponClass(weapon))
    {
        Snipers_g_iShotSerial[client]++;
        if (Snipers_g_iShotSerial[client] <= 0)
        {
            Snipers_g_iShotSerial[client] = 1;
        }
    }

    if (StrEqual(weapon, "weapon_sniper_military"))
    {
        if (Snipers_g_cvWeaponMilitary.BoolValue)
        {
            Snipers_HandleMilitarySniper(client);
        }
    }
    else if (StrEqual(weapon, "weapon_hunting_rifle"))
    {
        if (Snipers_g_cvWeaponHunting.BoolValue)
        {
            Snipers_HandleHuntingRifle(client);
        }
    }
    else if (StrEqual(weapon, "weapon_sniper_awp"))
    {
        if (Snipers_g_cvWeaponAWP.BoolValue)
        {
            Snipers_HandleAWP(client);
        }
    }
    else if (StrEqual(weapon, "weapon_sniper_scout"))
    {
        if (Snipers_g_cvWeaponScout.BoolValue)
        {
            Snipers_HandleScout(client);
        }
    }
}

void Snipers_HandleMilitarySniper(int client)
{
    // Explosion is decided per shot here, then resolved on the real enemy hit
    // or on the world bullet endpoint fallback.
    if (Snipers_Chance(Snipers_g_cvMilitaryExplosionChance.FloatValue)
        && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_AREA, 0.10))
    {
        Snipers_MarkPendingExplosion(client, Snipers_PENDING_EXPLOSION_MILITARY);
    }
}



void Snipers_HandleHuntingRifle(int client)
{
    // Targeted hunting-rifle effects are processed on the real damage victim.
}



void Snipers_HandleAWP(int client)
{
    // Explosion is decided per shot here, then resolved on the real enemy hit
    // or on the world bullet endpoint fallback. The rare all-map effect stays on fire.
    if (Snipers_Chance(Snipers_g_cvAWPExplosionChance.FloatValue)
        && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_AREA, 0.10))
    {
        Snipers_MarkPendingExplosion(client, Snipers_PENDING_EXPLOSION_AWP);
    }

    if (Snipers_Chance(Snipers_g_cvAWPAllFireChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_GLOBAL, 0.50))
    {
        Snipers_Effect_IgniteAllEnemies(client, Snipers_g_cvAWPAllFireDuration.FloatValue);
        Snipers_Effect_GiveAdrenalineAllSurvivors(Snipers_g_cvAWPAllFireDuration.FloatValue);
        Snipers_DebugLog("AWP all fire/adrenaline by %N", client);
    }
}



void Snipers_HandleScout(int client)
{
    // Scout all-bile is an on-fire global effect. Ally/enemy hit effects are
    // processed on the real damage victim.
    if (Snipers_Chance(Snipers_g_cvScoutAllBileChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_GLOBAL, 0.50))
    {
        Snipers_Effect_VomitAllEnemies(client, Snipers_g_cvScoutAllBileDamage.FloatValue);
        Snipers_DebugLog("Scout all bile by %N", client);
    }
}




void Snipers_HandleRealDamageHit(int client, int target, const char[] weapon)
{
    Snipers_TargetType type = Snipers_GetTargetType(target);
    if (!Snipers_IsEnemyType(type) && type != Snipers_Target_Survivor)
    {
        return;
    }

    MWE_MarkSharedRealHit(client, target, MWE_WeaponCategory_Sniper, weapon);

    if (StrEqual(weapon, "weapon_sniper_military", false))
    {
        if (Snipers_g_cvWeaponMilitary.BoolValue)
        {
            Snipers_HandleMilitaryRealHit(client, target, type);
        }
    }
    else if (StrEqual(weapon, "weapon_hunting_rifle", false))
    {
        if (Snipers_g_cvWeaponHunting.BoolValue)
        {
            Snipers_HandleHuntingRealHit(client, target, type);
        }
    }
    else if (StrEqual(weapon, "weapon_sniper_awp", false))
    {
        if (Snipers_g_cvWeaponAWP.BoolValue)
        {
            Snipers_HandleAWPRealHit(client, target, type);
        }
    }
    else if (StrEqual(weapon, "weapon_sniper_scout", false))
    {
        if (Snipers_g_cvWeaponScout.BoolValue)
        {
            Snipers_HandleScoutRealHit(client, target, type);
        }
    }
}

void Snipers_HandleMilitaryRealHit(int client, int target, Snipers_TargetType type)
{
    if (!Snipers_IsEnemyType(type))
    {
        return;
    }

    float hitPos[3];
    Snipers_GetEntityPosition(target, hitPos);

    if (Snipers_TryConsumePendingExplosion(client, Snipers_PENDING_EXPLOSION_MILITARY))
    {
        Snipers_RunPendingExplosionEffect(client, Snipers_PENDING_EXPLOSION_MILITARY, hitPos);
        Snipers_DebugLog("30 sniper real-hit explosion by %N", client);
    }

    if (Snipers_Chance(Snipers_g_cvMilitaryIgniteChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_AREA, 0.10))
    {
        Snipers_Effect_IgniteRadius(hitPos, Snipers_g_cvMilitaryIgniteRadius.FloatValue, client, Snipers_g_cvMilitaryIgniteDuration.FloatValue);
        Snipers_DebugLog("30 sniper real-hit ignite radius by %N", client);
    }
}

void Snipers_HandleHuntingRealHit(int client, int target, Snipers_TargetType type)
{
    if (!Snipers_IsEnemyType(type))
    {
        return;
    }

    float hitPos[3];
    Snipers_GetEntityPosition(target, hitPos);

    if (Snipers_Chance(Snipers_g_cvHuntingBileChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_AREA, 0.10))
    {
        Snipers_Effect_VomitRadius(hitPos, Snipers_g_cvHuntingBileRadius.FloatValue, client, Snipers_g_cvHuntingBileDamage.FloatValue);
        Snipers_DebugLog("Hunting rifle real-hit bile radius by %N", client);
    }

    if (Snipers_Chance(Snipers_g_cvHuntingTempChance.FloatValue))
    {
        Snipers_Effect_GiveTempHealth(client, Snipers_g_cvHuntingTempAmount.FloatValue);
        Snipers_Effect_GiveTeamTempHealthNear(client, Snipers_g_cvHuntingTeamTempRadius.FloatValue, Snipers_g_cvHuntingTempAmount.FloatValue);
        Snipers_Effect_GiveAdrenaline(client, Snipers_g_cvHuntingAdrenalineDuration.FloatValue);
        Snipers_DebugLog("Hunting rifle real-hit temp/adrenaline by %N on target %d", client, target);
    }
}

void Snipers_HandleAWPRealHit(int client, int target, Snipers_TargetType type)
{
    if (!Snipers_IsEnemyType(type))
    {
        return;
    }

    int shotSerial = Snipers_g_iShotSerial[client];
    if (shotSerial > 0 && target > 0 && target < 2049)
    {
        if (Snipers_g_iLastAWPEffectAttacker[target] == client && Snipers_g_iLastAWPEffectShot[target] == shotSerial)
        {
            return;
        }

        Snipers_g_iLastAWPEffectAttacker[target] = client;
        Snipers_g_iLastAWPEffectShot[target] = shotSerial;
    }

    float hitPos[3];
    Snipers_GetEntityPosition(target, hitPos);

    if (Snipers_TryConsumePendingExplosion(client, Snipers_PENDING_EXPLOSION_AWP))
    {
        Snipers_RunPendingExplosionEffect(client, Snipers_PENDING_EXPLOSION_AWP, hitPos);
        Snipers_DebugLog("AWP real-hit explosion by %N", client);
    }

    Snipers_ApplyAWPBonusDamage(target, type, client);
    Snipers_Effect_GiveAdrenaline(client, Snipers_g_cvAWPAdrenalineDuration.FloatValue);
    Snipers_DebugLog("AWP real-hit bonus damage by %N on target %d", client, target);
}

void Snipers_HandleScoutRealHit(int client, int target, Snipers_TargetType type)
{
    if (type == Snipers_Target_Survivor)
    {
        Snipers_Effect_ReviveIfNeeded(target);

        if (Snipers_Chance(Snipers_g_cvScoutAllyHealChance.FloatValue))
        {
            Snipers_Effect_HealReal(target, Snipers_g_cvScoutAllyHealAmount.IntValue, true);
            Snipers_ClearBlackWhiteState(target);
            Snipers_DebugLog("Scout real-hit ally heal by %N on %N", client, target);
        }
        return;
    }

    if (Snipers_IsEnemyType(type))
    {
        Snipers_ApplyScoutEnemyEffect(target, type, client);
        Snipers_Effect_StaggerAway(target, client, Snipers_g_cvScoutKnockForce.FloatValue);

        int heal = Snipers_g_cvScoutSelfHealAmount.IntValue;
        if (type == Snipers_Target_Tank && heal > 5)
        {
            heal = 5;
        }
        Snipers_Effect_HealReal(client, heal, true);

        if (Snipers_Chance(Snipers_g_cvScoutRangeHealChance.FloatValue) && MWE_CanRunHeavyEffect(client, MWE_HEAVY_SNIPER_AREA, 0.10))
        {
            Snipers_Effect_GiveTeamTempHealthNear(client, Snipers_g_cvScoutRangeHealRadius.FloatValue, Snipers_g_cvScoutRangeHealAmount.FloatValue);
        }

        Snipers_DebugLog("Scout real-hit enemy effect by %N on target %d", client, target);
    }
}

void Snipers_ApplyAWPBonusDamage(int target, Snipers_TargetType type, int attacker)
{
    float damage = 0.0;

    switch (type)
    {
        case Snipers_Target_CommonInfected:
        {
            damage = float(Snipers_GetEntityHealthSafe(target));
        }
        case Snipers_Target_SpecialInfected:
        {
            damage = Snipers_GetEntityMaxHealthSafe(target) * 0.50 + 25.0;
        }
        case Snipers_Target_Tank:
        {
            damage = Snipers_GetEntityMaxHealthSafe(target) / 50.0;
        }
        case Snipers_Target_Witch:
        {
            damage = Snipers_GetEntityMaxHealthSafe(target) * 0.10;
        }
        default:
        {
            return;
        }
    }

    Snipers_Effect_ApplyDamage(target, damage, attacker, DMG_BULLET);
}

void Snipers_ApplyScoutEnemyEffect(int target, Snipers_TargetType type, int attacker)
{
    float damage = 0.0;

    switch (type)
    {
        case Snipers_Target_CommonInfected:
        {
            damage = 0.0;
        }
        case Snipers_Target_SpecialInfected:
        {
            int zc = Snipers_GetZombieClassSafe(target);
            if (zc == 6) // Charger
            {
                damage = Snipers_GetEntityHealthSafe(target) / 4.0;
            }
            else
            {
                damage = Snipers_GetEntityHealthSafe(target) / 3.0;
            }
        }
        case Snipers_Target_Tank:
        {
            damage = Snipers_GetEntityHealthSafe(target) / 50.0;
        }
        case Snipers_Target_Witch:
        {
            damage = Snipers_GetEntityHealthSafe(target) / 10.0;
        }
        default:
        {
            return;
        }
    }

    if (damage > 0.0)
    {
        Snipers_Effect_ApplyDamage(target, damage, attacker, DMG_BUCKSHOT);
    }
}

bool Snipers_GetClientWeaponClass(int client, char[] weapon, int maxLen)
{
    weapon[0] = '\0';

    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client))
    {
        return false;
    }

    int weaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        return false;
    }

    GetEntityClassname(weaponEnt, weapon, maxLen);
    return weapon[0] != '\0';
}

bool Snipers_GetClientSlotWeaponClass(int client, int slot, char[] weapon, int maxLen)
{
    weapon[0] = '\0';

    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client))
    {
        return false;
    }

    int weaponEnt = GetPlayerWeaponSlot(client, slot);
    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        return false;
    }

    GetEntityClassname(weaponEnt, weapon, maxLen);
    return weapon[0] != '\0';
}

bool Snipers_LooksLikePossibleSniperPickup(const char[] rawItem)
{
    if (rawItem[0] == '\0')
    {
        return true;
    }

    return StrContains(rawItem, "sniper", false) != -1
        || StrContains(rawItem, "hunting", false) != -1
        || StrContains(rawItem, "awp", false) != -1
        || StrContains(rawItem, "scout", false) != -1;
}

bool Snipers_NormalizeSniperWeaponName(const char[] rawItem, char[] weapon, int maxLen)
{
    weapon[0] = '\0';

    if (rawItem[0] == '\0')
    {
        return false;
    }

    if (StrEqual(rawItem, "sniper_military", false) || StrEqual(rawItem, "military_sniper", false))
    {
        strcopy(weapon, maxLen, "weapon_sniper_military");
    }
    else if (StrEqual(rawItem, "hunting_rifle", false))
    {
        strcopy(weapon, maxLen, "weapon_hunting_rifle");
    }
    else if (StrEqual(rawItem, "sniper_awp", false) || StrEqual(rawItem, "awp", false))
    {
        strcopy(weapon, maxLen, "weapon_sniper_awp");
    }
    else if (StrEqual(rawItem, "sniper_scout", false) || StrEqual(rawItem, "scout", false))
    {
        strcopy(weapon, maxLen, "weapon_sniper_scout");
    }
    else if (StrContains(rawItem, "weapon_", false) == 0)
    {
        strcopy(weapon, maxLen, rawItem);
    }
    else
    {
        Format(weapon, maxLen, "weapon_%s", rawItem);
    }

    return Snipers_IsSniperWeaponClass(weapon);
}

bool Snipers_IsSniperWeaponClass(const char[] weapon)
{
    return StrEqual(weapon, "weapon_sniper_military", false)
        || StrEqual(weapon, "weapon_hunting_rifle", false)
        || StrEqual(weapon, "weapon_sniper_awp", false)
        || StrEqual(weapon, "weapon_sniper_scout", false);
}

bool Snipers_IsSniperWeaponEnabled(const char[] weapon)
{
    if (StrEqual(weapon, "weapon_sniper_military", false))
    {
        return Snipers_g_cvWeaponMilitary.BoolValue;
    }
    if (StrEqual(weapon, "weapon_hunting_rifle", false))
    {
        return Snipers_g_cvWeaponHunting.BoolValue;
    }
    if (StrEqual(weapon, "weapon_sniper_awp", false))
    {
        return Snipers_g_cvWeaponAWP.BoolValue;
    }
    if (StrEqual(weapon, "weapon_sniper_scout", false))
    {
        return Snipers_g_cvWeaponScout.BoolValue;
    }

    return false;
}

bool Snipers_ShowWeaponDescription(int client, const char[] weapon)
{
    // Auto weapon descriptions are completely removed. Use !mwe / !武器 menu only.
    return false;
}

bool Snipers_TraceClientShot(int client, int &entity, float hitPos[3])
{
    entity = -1;

    float eyePos[3];
    float eyeAngles[3];
    float fwdVec[3];
    float right[3];
    float up[3];
    float endPos[3];

    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAngles);
    GetAngleVectors(eyeAngles, fwdVec, right, up);
    NormalizeVector(fwdVec, fwdVec);
    ScaleVector(fwdVec, Snipers_TRACE_DISTANCE);
    AddVectors(eyePos, fwdVec, endPos);

    Handle trace = TR_TraceRayFilterEx(eyePos, endPos, MASK_SHOT, RayType_EndPoint, Snipers_TraceFilter_IgnoreSelf, client);
    bool didHit = TR_DidHit(trace);
    TR_GetEndPosition(hitPos, trace);

    if (didHit)
    {
        entity = TR_GetEntityIndex(trace);
    }

    delete trace;
    return didHit;
}

public bool Snipers_TraceFilter_IgnoreSelf(int entity, int contentsMask, any data)
{
    int client = data;
    if (entity == client)
    {
        return false;
    }
    return true;
}

void Snipers_MarkPendingExplosion(int client, int explosionType)
{
    if (client < 1 || client > MaxClients || Snipers_g_iShotSerial[client] <= 0)
    {
        return;
    }

    float radius = Snipers_GetPendingExplosionRadius(explosionType);
    float damage = Snipers_GetPendingExplosionDamage(explosionType);
    if (radius <= 0.0 || damage <= 0.0)
    {
        return;
    }

    int shotSerial = Snipers_g_iShotSerial[client];
    Snipers_g_iPendingExplosionShot[client] = shotSerial;
    Snipers_g_iPendingExplosionType[client] = explosionType;
    Snipers_g_bPendingExplosionHasPos[client] = false;
    Snipers_g_fPendingExplosionPos[client][0] = 0.0;
    Snipers_g_fPendingExplosionPos[client][1] = 0.0;
    Snipers_g_fPendingExplosionPos[client][2] = 0.0;

    DataPack pack;
    CreateDataTimer(0.05, Snipers_Timer_ProcessPendingExplosion, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(shotSerial);
    pack.WriteCell(explosionType);
}


void Snipers_CachePendingBulletImpact(int client, float impact[3])
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    int shotSerial = Snipers_g_iShotSerial[client];
    if (shotSerial <= 0)
    {
        return;
    }

    if (Snipers_g_iPendingExplosionShot[client] != shotSerial
        || Snipers_g_iPendingExplosionType[client] == Snipers_PENDING_EXPLOSION_NONE
        || Snipers_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return;
    }

    Snipers_g_fPendingExplosionPos[client][0] = impact[0];
    Snipers_g_fPendingExplosionPos[client][1] = impact[1];
    Snipers_g_fPendingExplosionPos[client][2] = impact[2];
    Snipers_g_bPendingExplosionHasPos[client] = true;
}

bool Snipers_TryConsumePendingExplosion(int client, int explosionType)
{
    if (client < 1 || client > MaxClients)
    {
        return false;
    }

    int shotSerial = Snipers_g_iShotSerial[client];
    if (shotSerial <= 0)
    {
        return false;
    }

    if (Snipers_g_iPendingExplosionShot[client] != shotSerial
        || Snipers_g_iPendingExplosionType[client] != explosionType
        || Snipers_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return false;
    }

    Snipers_g_iProcessedExplosionShot[client] = shotSerial;
    return true;
}

public Action Snipers_Timer_ProcessPendingExplosion(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int shotSerial = pack.ReadCell();
    int explosionType = pack.ReadCell();

    int client = GetClientOfUserId(userid);
    if (!Snipers_g_cvEnabled.BoolValue || !Snipers_IsHumanSurvivor(client))
    {
        return Plugin_Stop;
    }

    if (Snipers_g_iPendingExplosionShot[client] != shotSerial
        || Snipers_g_iPendingExplosionType[client] != explosionType
        || Snipers_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return Plugin_Stop;
    }

    float hitPos[3];
    if (Snipers_g_bPendingExplosionHasPos[client])
    {
        hitPos[0] = Snipers_g_fPendingExplosionPos[client][0];
        hitPos[1] = Snipers_g_fPendingExplosionPos[client][1];
        hitPos[2] = Snipers_g_fPendingExplosionPos[client][2];
    }
    else
    {
        int entity = -1;
        Snipers_TraceClientShot(client, entity, hitPos);
    }

    Snipers_g_iProcessedExplosionShot[client] = shotSerial;
    Snipers_RunPendingExplosionEffect(client, explosionType, hitPos);
    Snipers_DebugLog("sniper endpoint explosion: client=%N type=%d shot=%d", client, explosionType, shotSerial);
    return Plugin_Stop;
}

float Snipers_GetPendingExplosionRadius(int explosionType)
{
    if (explosionType == Snipers_PENDING_EXPLOSION_MILITARY)
    {
        return Snipers_g_cvMilitaryExplosionRadius.FloatValue;
    }
    if (explosionType == Snipers_PENDING_EXPLOSION_AWP)
    {
        return Snipers_g_cvAWPExplosionRadius.FloatValue;
    }
    return 0.0;
}

float Snipers_GetPendingExplosionDamage(int explosionType)
{
    if (explosionType == Snipers_PENDING_EXPLOSION_MILITARY)
    {
        return Snipers_g_cvMilitaryExplosionDamage.FloatValue;
    }
    if (explosionType == Snipers_PENDING_EXPLOSION_AWP)
    {
        return Snipers_g_cvAWPExplosionDamage.FloatValue;
    }
    return 0.0;
}

void Snipers_RunPendingExplosionEffect(int client, int explosionType, float origin[3])
{
    Snipers_Effect_Explosion(origin, client, Snipers_GetPendingExplosionRadius(explosionType), Snipers_GetPendingExplosionDamage(explosionType));
}

Snipers_TargetType Snipers_GetTargetType(int entity)
{
    if (entity <= 0)
    {
        return Snipers_Target_Invalid;
    }

    if (entity <= MaxClients)
    {
        if (!IsClientInGame(entity) || !IsPlayerAlive(entity))
        {
            return Snipers_Target_Invalid;
        }

        int team = GetClientTeam(entity);
        if (team == Snipers_TEAM_SURVIVOR)
        {
            return Snipers_Target_Survivor;
        }

        if (team == Snipers_TEAM_INFECTED)
        {
            int zc = Snipers_GetZombieClassSafe(entity);
            if (zc == Snipers_ZC_TANK)
            {
                return Snipers_Target_Tank;
            }
            if (zc >= 1 && zc <= 6)
            {
                return Snipers_Target_SpecialInfected;
            }
        }

        return Snipers_Target_Invalid;
    }

    if (!IsValidEntity(entity))
    {
        return Snipers_Target_Invalid;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (StrEqual(classname, "infected", false))
    {
        return Snipers_Target_CommonInfected;
    }
    if (StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false))
    {
        return Snipers_Target_Witch;
    }

    return Snipers_Target_Invalid;
}

bool Snipers_IsEnemyType(Snipers_TargetType type)
{
    return type == Snipers_Target_CommonInfected || type == Snipers_Target_SpecialInfected || type == Snipers_Target_Tank || type == Snipers_Target_Witch;
}

bool Snipers_IsValidClientIndex(int client)
{
    return client >= 1 && client <= MaxClients;
}

bool Snipers_IsHumanSurvivor(int client)
{
    return Snipers_IsValidClientIndex(client)
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && IsPlayerAlive(client)
        && GetClientTeam(client) == Snipers_TEAM_SURVIVOR;
}

bool Snipers_IsValidDamageTarget(int entity)
{
    if (entity <= 0)
    {
        return false;
    }

    if (entity <= MaxClients)
    {
        return IsClientInGame(entity) && IsPlayerAlive(entity);
    }

    return IsValidEntity(entity);
}

bool Snipers_Chance(float chance)
{
    if (chance <= 0.0)
    {
        return false;
    }
    if (chance >= 100.0)
    {
        return true;
    }

    int threshold = RoundToNearest(chance * 100.0);
    int roll = GetURandomInt() % 10000;
    return roll < threshold;
}

void Snipers_Effect_ApplyDamage(int target, float damage, int attacker, int damageType)
{
    if (!Snipers_IsValidDamageTarget(target) || damage <= 0.0)
    {
        return;
    }

    if (!Snipers_IsValidClientIndex(attacker) || !IsClientInGame(attacker))
    {
        return;
    }

    bool oldAnyGuard = Snipers_g_bApplyingAnyPluginDamage;
    bool oldAttackerGuard = Snipers_g_bApplyingPluginDamage[attacker];

    Snipers_g_bApplyingAnyPluginDamage = true;
    Snipers_g_bApplyingPluginDamage[attacker] = true;
    MWE_SDKHooks_TakeDamage(target, attacker, attacker, damage, damageType);
    Snipers_g_bApplyingPluginDamage[attacker] = oldAttackerGuard;
    Snipers_g_bApplyingAnyPluginDamage = oldAnyGuard;
}



void Snipers_Effect_Explosion(float origin[3], int attacker, float radius, float damage)
{
    MWE_CreateUnifiedExplosionDamage(origin, attacker, radius, damage, 1.0);
}

void Snipers_CreateExplosionVisual(float origin[3])
{
    int ent = CreateEntityByName("env_explosion");
    if (ent == -1)
    {
        return;
    }

    DispatchKeyValue(ent, "iMagnitude", "0");
    DispatchKeyValue(ent, "spawnflags", "64");

    float angles[3];
    float velocity[3];
    TeleportEntity(ent, origin, angles, velocity);
    DispatchSpawn(ent);
    AcceptEntityInput(ent, "Explode");
    AcceptEntityInput(ent, "Kill");
}

void Snipers_Effect_IgniteRadius(float origin[3], float radius, int attacker, float duration)
{
    if (radius <= 0.0 || duration <= 0.0)
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
        {
            continue;
        }

        Snipers_TargetType type = Snipers_GetTargetType(i);
        if (!Snipers_IsEnemyType(type))
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(i, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Snipers_Effect_IgniteTarget(i, duration);
        }
    }

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "infected")) != -1)
    {
        if (!IsValidEntity(ent))
        {
            continue;
        }
        float pos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Snipers_Effect_IgniteTarget(ent, duration);
        }
    }

    ent = -1;
    while ((ent = FindEntityByClassname(ent, "witch")) != -1)
    {
        if (!IsValidEntity(ent))
        {
            continue;
        }
        float pos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Snipers_Effect_IgniteTarget(ent, duration);
        }
    }
}

void Snipers_Effect_IgniteTarget(int target, float duration)
{
    Snipers_TargetType type = Snipers_GetTargetType(target);
    if (!Snipers_IsEnemyType(type))
    {
        return;
    }

    IgniteEntity(target, duration);
}

void Snipers_Effect_IgniteAllEnemies(int attacker, float duration)
{
    if (duration <= 0.0)
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == Snipers_TEAM_INFECTED)
        {
            Snipers_Effect_IgniteTarget(i, duration);
        }
    }

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "infected")) != -1)
    {
        Snipers_Effect_IgniteTarget(ent, duration);
    }

    ent = -1;
    while ((ent = FindEntityByClassname(ent, "witch")) != -1)
    {
        Snipers_Effect_IgniteTarget(ent, duration);
    }
}

void Snipers_Effect_VomitRadius(float origin[3], float radius, int attacker, float damage)
{
    if (radius <= 0.0)
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
        {
            continue;
        }

        Snipers_TargetType type = Snipers_GetTargetType(i);
        if (type != Snipers_Target_SpecialInfected && type != Snipers_Target_Tank)
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(i, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Snipers_Effect_VomitTarget(i, attacker, damage);
        }
    }

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "witch")) != -1)
    {
        if (!IsValidEntity(ent))
        {
            continue;
        }
        float pos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Snipers_Effect_VomitTarget(ent, attacker, damage);
        }
    }
}

void Snipers_Effect_VomitAllEnemies(int attacker, float damage)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == Snipers_TEAM_INFECTED)
        {
            Snipers_Effect_VomitTarget(i, attacker, damage);
        }
    }

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "witch")) != -1)
    {
        Snipers_Effect_VomitTarget(ent, attacker, damage);
    }
}

void Snipers_Effect_VomitTarget(int target, int attacker, float damage)
{
    Snipers_TargetType type = Snipers_GetTargetType(target);
    if (type != Snipers_Target_SpecialInfected && type != Snipers_Target_Tank && type != Snipers_Target_Witch)
    {
        return;
    }

    Snipers_RunVScript("local e = EntIndexToHScript(%d); if (e != null && e.IsValid()) { e.HitWithVomit(); }", target);

    if (damage > 0.0)
    {
        Snipers_Effect_ApplyDamage(target, damage, attacker, DMG_BUCKSHOT);
    }
}

void Snipers_Effect_GiveTempHealth(int client, float amount)
{
    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != Snipers_TEAM_SURVIVOR)
    {
        return;
    }

    if (amount <= 0.0)
    {
        return;
    }

    float currentTemp = Snipers_GetClientTempHealth(client);
    float health = float(GetClientHealth(client));
    float maxAdd = 100.0 - health - currentTemp;

    if (maxAdd <= 0.0)
    {
        return;
    }

    if (amount > maxAdd)
    {
        amount = maxAdd;
    }

    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", currentTemp + amount);
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}

float Snipers_GetClientTempHealth(int client)
{
    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client))
    {
        return 0.0;
    }

    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    if (buffer <= 0.0)
    {
        return 0.0;
    }

    float bufferTime = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float decayRate = 0.27;
    if (Snipers_g_cvDecayRate != null)
    {
        decayRate = Snipers_g_cvDecayRate.FloatValue;
    }

    float elapsed = GetGameTime() - bufferTime;
    float temp = buffer - (elapsed * decayRate);
    if (temp < 0.0)
    {
        temp = 0.0;
    }

    return temp;
}

void Snipers_Effect_GiveTeamTempHealthNear(int centerClient, float radius, float amount)
{
    if (!Snipers_IsValidClientIndex(centerClient) || !IsClientInGame(centerClient))
    {
        return;
    }

    float origin[3];
    GetClientAbsOrigin(centerClient, origin);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != Snipers_TEAM_SURVIVOR)
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(i, pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Snipers_Effect_GiveTempHealth(i, amount);
        }
    }
}

void Snipers_Effect_HealReal(int client, int amount, bool capAtHundred)
{
    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != Snipers_TEAM_SURVIVOR)
    {
        return;
    }

    if (amount <= 0)
    {
        return;
    }

    int health = GetClientHealth(client);
    int newHealth = health + amount;
    if (capAtHundred && newHealth > 100)
    {
        newHealth = 100;
    }

    SetEntityHealth(client, newHealth);
}

void Snipers_Effect_GiveAdrenaline(int client, float duration)
{
    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != Snipers_TEAM_SURVIVOR)
    {
        return;
    }

    if (duration <= 0.0)
    {
        return;
    }

    Snipers_RunVScript("local p = EntIndexToHScript(%d); if (p != null && p.IsValid() && p.IsSurvivor()) { p.UseAdrenaline(%.2f); }", client, duration);
}

void Snipers_Effect_GiveAdrenalineAllSurvivors(float duration)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == Snipers_TEAM_SURVIVOR)
        {
            Snipers_Effect_GiveAdrenaline(i, duration);
        }
    }
}

void Snipers_Effect_ReviveIfNeeded(int client)
{
    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client) || GetClientTeam(client) != Snipers_TEAM_SURVIVOR)
    {
        return;
    }

    Snipers_RunVScript("local p = EntIndexToHScript(%d); if (p != null && p.IsValid() && p.IsSurvivor()) { if (p.IsIncapacitated() || p.IsHangingFromLedge()) { p.SetReviveCount(0); p.ReviveFromIncap(); p.SetHealth(30); } }", client);
}

void Snipers_ClearBlackWhiteState(int client)
{
    if (!Snipers_IsValidClientIndex(client) || !IsClientInGame(client) || GetClientTeam(client) != Snipers_TEAM_SURVIVOR)
    {
        return;
    }

    Snipers_RunVScript("local p = EntIndexToHScript(%d); if (p != null && p.IsValid() && p.IsSurvivor()) { p.SetReviveCount(0); }", client);
}

void Snipers_Effect_StaggerAway(int target, int attacker, float force)
{
    if (force <= 0.0)
    {
        return;
    }

    Snipers_TargetType type = Snipers_GetTargetType(target);
    if (type != Snipers_Target_SpecialInfected && type != Snipers_Target_Tank)
    {
        return;
    }

    float targetPos[3];
    float attackerPos[3];
    Snipers_GetEntityPosition(target, targetPos);
    GetClientAbsOrigin(attacker, attackerPos);

    float dir[3];
    SubtractVectors(targetPos, attackerPos, dir);
    if (NormalizeVector(dir, dir) == 0.0)
    {
        dir[0] = 1.0;
        dir[1] = 0.0;
        dir[2] = 0.0;
    }

    ScaleVector(dir, force);
    Snipers_RunVScript("local e = EntIndexToHScript(%d); if (e != null && e.IsValid()) { e.Stagger(Vector(%.2f, %.2f, %.2f)); }", target, dir[0], dir[1], dir[2]);
}

void Snipers_GetEntityPosition(int entity, float pos[3])
{
    if (entity > 0 && entity <= MaxClients && IsClientInGame(entity))
    {
        GetClientAbsOrigin(entity, pos);
        return;
    }

    if (entity > MaxClients && IsValidEntity(entity))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        return;
    }

    pos[0] = 0.0;
    pos[1] = 0.0;
    pos[2] = 0.0;
}

int Snipers_GetZombieClassSafe(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return 0;
    }

    if (!HasEntProp(client, Prop_Send, "m_zombieClass"))
    {
        return 0;
    }

    return GetEntProp(client, Prop_Send, "m_zombieClass");
}

float Snipers_GetEntityMaxHealthSafe(int entity)
{
    if (entity <= 0)
    {
        return 1.0;
    }

    if (HasEntProp(entity, Prop_Data, "m_iMaxHealth"))
    {
        int maxHealth = GetEntProp(entity, Prop_Data, "m_iMaxHealth");
        if (maxHealth > 0)
        {
            return float(maxHealth);
        }
    }

    Snipers_TargetType type = Snipers_GetTargetType(entity);
    switch (type)
    {
        case Snipers_Target_CommonInfected:
        {
            return 50.0;
        }
        case Snipers_Target_SpecialInfected:
        {
            return 250.0;
        }
        case Snipers_Target_Tank:
        {
            return 4000.0;
        }
        case Snipers_Target_Witch:
        {
            return 1000.0;
        }
        default:
        {
            return float(Snipers_GetEntityHealthSafe(entity));
        }
    }
}

int Snipers_GetEntityHealthSafe(int entity)
{
    if (entity <= 0)
    {
        return 1;
    }

    if (entity <= MaxClients)
    {
        if (IsClientInGame(entity))
        {
            return GetClientHealth(entity);
        }
        return 1;
    }

    if (IsValidEntity(entity) && HasEntProp(entity, Prop_Data, "m_iHealth"))
    {
        int health = GetEntProp(entity, Prop_Data, "m_iHealth");
        if (health > 0)
        {
            return health;
        }
    }

    return 1;
}

void Snipers_RunVScript(const char[] fmt, any ...)
{
    char code[512];
    VFormat(code, sizeof(code), fmt, 2);

    int script = CreateEntityByName("logic_script");
    if (script == -1)
    {
        LogError("[MWE Snipers] Failed to create logic_script. Code: %s", code);
        return;
    }

    DispatchSpawn(script);
    SetVariantString(code);
    AcceptEntityInput(script, "RunScriptCode");
    AcceptEntityInput(script, "Kill");
}

void Snipers_DebugLog(const char[] fmt, any ...)
{
    if (!Snipers_g_cvDebug.BoolValue)
    {
        return;
    }

    char msg[256];
    VFormat(msg, sizeof(msg), fmt, 2);
    LogMessage("[MWE Snipers] %s", msg);
}


// ============================================================================
// Module: Shotgun (from l4d2_mwe_shotgun.sp)
// ============================================================================

/*
 * 文件名: l4d2_shotgun_effects.sp
 * 简介: Left 4 Dead 2 霰弹枪特效 SourceMod 插件。只处理木喷、铁喷、战术喷、SPAS。
 *
 * 使用方法:
 * 1. 将本文件放入: left4dead2/addons/sourcemod/scripting/l4d2_shotgun_effects.sp
 * 2. 使用 SourceMod 编译器编译: spcomp l4d2_shotgun_effects.sp
 * 3. 将生成的 l4d2_shotgun_effects.smx 放入: left4dead2/addons/sourcemod/plugins/
 * 4. 本整合版配置统一写入: left4dead2/cfg/sourcemod/l4d2_mwe_all.cfg
 * 5. 本插件需要 SourceMod、SDKTools、SDKHooks。无需 Left 4 DHooks。
 *
 * 设计说明:
 * - 不使用原 Squirrel 脚本的多次 TraceLine 实现。
 * - 用 SDKHook_OnTakeDamage 取得真实受击实体，weapon_fire 只记录本次开火和处理“开火类”概率。
 * - 这样可以避免每次效果重复射线检测，也能直接知道哪个实体被实际击中。
 * - 拾取自动介绍已删除；完整说明仅通过聊天命令 !mwe / !武器 的菜单查看。
 */



#if !defined DMG_BUCKSHOT
    #define DMG_BUCKSHOT (1 << 29)
#endif

#define Shotgun_PLUGIN_VERSION "1.0.0"
#define Shotgun_TEAM_SURVIVOR 2
#define Shotgun_TEAM_INFECTED 3
#define Shotgun_TRACE_DISTANCE 18192.0
#define Shotgun_ZOMBIECLASS_TANK 8
#define Shotgun_SCRIPT_LOGIC_CLASS "logic_script"


enum Shotgun_TargetType
{
    Shotgun_Target_Invalid = 0,
    Shotgun_Target_CommonInfected,
    Shotgun_Target_SpecialInfected,
    Shotgun_Target_Tank,
    Shotgun_Target_Witch,
    Shotgun_Target_Survivor
};

ConVar Shotgun_g_cvEnabled;
ConVar Shotgun_g_cvHumansOnly;
ConVar Shotgun_g_cvShowNotice;
ConVar Shotgun_g_cvDebug;

ConVar Shotgun_g_cvEnablePump;
ConVar Shotgun_g_cvEnableChrome;
ConVar Shotgun_g_cvEnableAuto;
ConVar Shotgun_g_cvEnableSpas;

ConVar Shotgun_g_cvPumpTempChance;
ConVar Shotgun_g_cvPumpCloseChance;
ConVar Shotgun_g_cvAutoTempChance;
ConVar Shotgun_g_cvAutoCloseChance;
ConVar Shotgun_g_cvChromeAdrenChance;
ConVar Shotgun_g_cvChromeExplosionChance;
ConVar Shotgun_g_cvSpasAdrenChance;
ConVar Shotgun_g_cvSpasExplosionChance;

ConVar Shotgun_g_cvTempAmount;
ConVar Shotgun_g_cvCloseRange;
ConVar Shotgun_g_cvCloseDamageMin;
ConVar Shotgun_g_cvCloseDamageMax;
ConVar Shotgun_g_cvCommonPushRadius;
ConVar Shotgun_g_cvCommonPushForce;
ConVar Shotgun_g_cvCommonPushDamage;
ConVar Shotgun_g_cvExplosionRadius;
ConVar Shotgun_g_cvExplosionDamage;
ConVar Shotgun_g_cvAdrenDuration;
ConVar Shotgun_g_cvDamageMultiplier;
ConVar Shotgun_g_cvPainPillsDecayRate;

bool Shotgun_g_bEnabled;
bool Shotgun_g_bHumansOnly;
bool Shotgun_g_bShowNotice;
bool Shotgun_g_bDebug;
bool Shotgun_g_bHasAdrenalineProp;
bool Shotgun_g_bInsidePluginDamage;
bool Shotgun_g_bWeaponEquipHookInstalled[MAXPLAYERS + 1];

int Shotgun_g_iShotSerial[MAXPLAYERS + 1];
int Shotgun_g_iLastTempShot[MAXPLAYERS + 1];
int Shotgun_g_iLastCloseShot[MAXPLAYERS + 1];
int Shotgun_g_iLastPushShot[MAXPLAYERS + 1];
int Shotgun_g_iPendingExplosionShot[MAXPLAYERS + 1];
int Shotgun_g_iProcessedExplosionShot[MAXPLAYERS + 1];
int Shotgun_g_iScriptLogic = -1;
int Shotgun_g_iExplosionSprite = -1;

float Shotgun_g_flLastShotTime[MAXPLAYERS + 1];
float Shotgun_g_flKnownAdrenUntil[MAXPLAYERS + 1];
float Shotgun_g_flLastNoticeTime[MAXPLAYERS + 1];
char Shotgun_g_sLastShotWeapon[MAXPLAYERS + 1][64];
char Shotgun_g_sLastNoticeWeapon[MAXPLAYERS + 1][64];
bool Shotgun_g_bPendingExplosionHasPos[MAXPLAYERS + 1];
float Shotgun_g_fPendingExplosionPos[MAXPLAYERS + 1][3];

void Shotgun_InstallWeaponEquipHook(int client)
{
    // Auto weapon-equip descriptions disabled: use !mwe / !武器 menu instead.
    return;
}

void Shotgun_UninstallWeaponEquipHook(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (Shotgun_g_bWeaponEquipHookInstalled[client])
    {
        if (IsClientInGame(client))
        {
            SDKUnhook(client, SDKHook_WeaponEquipPost, Shotgun_OnWeaponEquipPost);
        }
        Shotgun_g_bWeaponEquipHookInstalled[client] = false;
    }
}

public void Shotgun_OnPluginStart()
{
    Shotgun_CreateConVars();
    Shotgun_HookConVarChanges();
    Shotgun_CacheConVars();

    HookEvent("weapon_fire", Shotgun_Event_WeaponFire, EventHookMode_Post);
    // Auto pickup descriptions disabled: use !mwe / !武器 menu instead.

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            Shotgun_OnClientPutInServer(client);
        }
    }

    // cfg 统一由整合版主入口生成。
}

public void Shotgun_OnMapStart()
{
    Shotgun_g_iExplosionSprite = PrecacheModel("sprites/zerogxplode.vmt", true);
    Shotgun_EnsureScriptLogic();
    Shotgun_HookExistingDamageTargets();
}

public void Shotgun_OnPluginEnd()
{
    if (Shotgun_IsValidEntityIndex(Shotgun_g_iScriptLogic))
    {
        AcceptEntityInput(Shotgun_g_iScriptLogic, "Kill");
    }
}

public void Shotgun_OnClientPutInServer(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    MWE_HookSharedTakeDamage(client);
    Shotgun_InstallWeaponEquipHook(client);
}

public void Shotgun_OnClientDisconnect(int client)
{
    Shotgun_UninstallWeaponEquipHook(client);

    if (client < 1 || client > MaxClients)
    {
        return;
    }

    Shotgun_g_iShotSerial[client] = 0;
    Shotgun_g_iLastTempShot[client] = 0;
    Shotgun_g_iLastCloseShot[client] = 0;
    Shotgun_g_iLastPushShot[client] = 0;
    Shotgun_g_iPendingExplosionShot[client] = 0;
    Shotgun_g_iProcessedExplosionShot[client] = 0;
    Shotgun_g_flLastShotTime[client] = 0.0;
    Shotgun_g_flKnownAdrenUntil[client] = 0.0;
    Shotgun_g_flLastNoticeTime[client] = 0.0;
    Shotgun_g_sLastShotWeapon[client][0] = '\0';
    Shotgun_g_sLastNoticeWeapon[client][0] = '\0';
    Shotgun_g_bPendingExplosionHasPos[client] = false;
    Shotgun_g_fPendingExplosionPos[client][0] = 0.0;
    Shotgun_g_fPendingExplosionPos[client][1] = 0.0;
    Shotgun_g_fPendingExplosionPos[client][2] = 0.0;
}

public void Shotgun_OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients)
    {
        return;
    }

    if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false))
    {
        MWE_HookSharedTakeDamage(entity);
    }
}

void Shotgun_CreateConVars()
{
    Shotgun_g_cvEnabled = CreateConVar("sm_l4d2_shotgun_enabled", "1", "霰弹枪特效总开关。1=启用，0=禁用。", 0, true, 0.0, true, 1.0);
    Shotgun_g_cvHumansOnly = CreateConVar("sm_l4d2_shotgun_humans_only", "1", "只允许真人生还者触发效果。1=忽略 Bot，0=Bot 也可触发。", 0, true, 0.0, true, 1.0);
    Shotgun_g_cvShowNotice = CreateConVar("sm_l4d2_shotgun_show_notice", "0", "DEPRECATED: pickup shotgun notices are disabled; use !mwe / !武器 menu.", 0, true, 0.0, true, 1.0);
    Shotgun_g_cvDebug = CreateConVar("sm_l4d2_shotgun_debug", "0", "调试日志开关。", 0, true, 0.0, true, 1.0);

    Shotgun_g_cvEnablePump = CreateConVar("sm_l4d2_shotgun_enable_pump", "1", "启用木喷 weapon_pumpshotgun 特效。", 0, true, 0.0, true, 1.0);
    Shotgun_g_cvEnableChrome = CreateConVar("sm_l4d2_shotgun_enable_chrome", "1", "启用铁喷 weapon_shotgun_chrome 特效。", 0, true, 0.0, true, 1.0);
    Shotgun_g_cvEnableAuto = CreateConVar("sm_l4d2_shotgun_enable_auto", "1", "启用战术喷 weapon_autoshotgun 特效。", 0, true, 0.0, true, 1.0);
    Shotgun_g_cvEnableSpas = CreateConVar("sm_l4d2_shotgun_enable_spas", "1", "启用 SPAS weapon_shotgun_spas 特效。", 0, true, 0.0, true, 1.0);

    Shotgun_g_cvPumpTempChance = CreateConVar("sm_l4d2_shotgun_pump_temp_chance", "30", "木喷击中僵尸时给予射击者虚血的概率。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvPumpCloseChance = CreateConVar("sm_l4d2_shotgun_pump_close_chance", "10", "木喷近距离命中时造成附加伤害并触发肾上腺素的概率。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvAutoTempChance = CreateConVar("sm_l4d2_shotgun_auto_temp_chance", "15", "战术喷击中僵尸时给予射击者虚血的概率。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvAutoCloseChance = CreateConVar("sm_l4d2_shotgun_auto_close_chance", "15", "战术喷近距离命中时造成附加伤害并触发肾上腺素的概率。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvChromeAdrenChance = CreateConVar("sm_l4d2_shotgun_chrome_adren_chance", "10", "铁喷开火触发肾上腺素的概率。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvChromeExplosionChance = CreateConVar("sm_l4d2_shotgun_chrome_explosion_chance", "10", "铁喷本次射击触发爆炸的概率；命中敌人则在命中点爆炸，否则在弹道终点爆炸。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvSpasAdrenChance = CreateConVar("sm_l4d2_shotgun_spas_adren_chance", "15", "SPAS 开火触发肾上腺素的概率。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvSpasExplosionChance = CreateConVar("sm_l4d2_shotgun_spas_explosion_chance", "15", "SPAS 本次射击触发爆炸的概率；命中敌人则在命中点爆炸，否则在弹道终点爆炸。", 0, true, 0.0, true, 100.0);

    Shotgun_g_cvTempAmount = CreateConVar("sm_l4d2_shotgun_temp_amount", "10.0", "木喷/战术喷触发虚血时增加的虚血量。", 0, true, 0.0, true, 100.0);
    Shotgun_g_cvCloseRange = CreateConVar("sm_l4d2_shotgun_close_range", "100.0", "近距离附加伤害判定距离。", 0, true, 1.0, true, 1000.0);
    Shotgun_g_cvCloseDamageMin = CreateConVar("sm_l4d2_shotgun_close_damage_min", "100.0", "近距离附加伤害最小值。", 0, true, 0.0, true, 10000.0);
    Shotgun_g_cvCloseDamageMax = CreateConVar("sm_l4d2_shotgun_close_damage_max", "200.0", "近距离附加伤害最大值。", 0, true, 0.0, true, 10000.0);
    Shotgun_g_cvCommonPushRadius = CreateConVar("sm_l4d2_shotgun_common_push_radius", "50.0", "木喷/战术喷命中点周围普通感染者击退半径。", 0, true, 0.0, true, 1000.0);
    Shotgun_g_cvCommonPushForce = CreateConVar("sm_l4d2_shotgun_common_push_force", "360.0", "普通感染者击退力度。", 0, true, 0.0, true, 3000.0);
    Shotgun_g_cvCommonPushDamage = CreateConVar("sm_l4d2_shotgun_common_push_damage", "0.0", "普通感染者击退时附加伤害。0=只击退不伤害。", 0, true, 0.0, true, 1000.0);
    Shotgun_g_cvExplosionRadius = CreateConVar("sm_l4d2_shotgun_explosion_radius", "150.0", "铁喷/SPAS 弹着点爆炸半径。", 0, true, 0.0, true, 1000.0);
    Shotgun_g_cvExplosionDamage = CreateConVar("sm_l4d2_shotgun_explosion_damage", "50.0", "铁喷/SPAS 弹着点爆炸伤害。", 0, true, 0.0, true, 10000.0);
    Shotgun_g_cvAdrenDuration = CreateConVar("sm_l4d2_shotgun_adren_duration", "5.0", "霰弹枪触发肾上腺素的持续时间。", 0, true, 0.1, true, 60.0);
    Shotgun_g_cvDamageMultiplier = CreateConVar("sm_l4d2_shotgun_damage_multiplier", "1.0", "插件附加伤害倍率。", 0, true, 0.0, true, 20.0);

    Shotgun_g_cvPainPillsDecayRate = FindConVar("pain_pills_decay_rate");
    Shotgun_g_bHasAdrenalineProp = FindSendPropInfo("CTerrorPlayer", "m_bAdrenalineActive") != -1;
}

void Shotgun_HookConVarChanges()
{
    HookConVarChange(Shotgun_g_cvEnabled, Shotgun_OnConVarChanged);
    HookConVarChange(Shotgun_g_cvHumansOnly, Shotgun_OnConVarChanged);
    HookConVarChange(Shotgun_g_cvShowNotice, Shotgun_OnConVarChanged);
    HookConVarChange(Shotgun_g_cvDebug, Shotgun_OnConVarChanged);
}

public void Shotgun_OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Shotgun_CacheConVars();
}

void Shotgun_CacheConVars()
{
    Shotgun_g_bEnabled = Shotgun_g_cvEnabled.BoolValue;
    Shotgun_g_bHumansOnly = Shotgun_g_cvHumansOnly.BoolValue;
    Shotgun_g_bShowNotice = false; // hard disabled: use !mwe / !武器 menu
    Shotgun_g_bDebug = Shotgun_g_cvDebug.BoolValue;
}

public void Shotgun_Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    // Pickup-triggered weapon descriptions are deleted. Use !mwe / !武器 menu only.
    return;
}

public void Shotgun_Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!Shotgun_g_bEnabled)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Shotgun_IsValidSurvivor(client, true))
    {
        return;
    }

    char rawWeapon[64];
    char weapon[64];
    event.GetString("weapon", rawWeapon, sizeof(rawWeapon));
    Shotgun_NormalizeWeaponClass(rawWeapon, weapon, sizeof(weapon));

    if (!Shotgun_IsShotgunWeapon(weapon))
    {
        MWE_GetCachedActiveWeaponClass(client, weapon, sizeof(weapon));
        if (!Shotgun_IsShotgunWeapon(weapon))
        {
            return;
        }
    }

    if (!Shotgun_IsWeaponEnabled(weapon))
    {
        return;
    }

    MWE_RecordWeaponFire(client, weapon);

    Shotgun_g_iShotSerial[client]++;
    if (Shotgun_g_iShotSerial[client] <= 0)
    {
        Shotgun_g_iShotSerial[client] = 1;
    }

    Shotgun_g_flLastShotTime[client] = GetGameTime();
    strcopy(Shotgun_g_sLastShotWeapon[client], sizeof(Shotgun_g_sLastShotWeapon[]), weapon);

    Shotgun_HandleOnFireEffects(client, weapon, Shotgun_g_iShotSerial[client]);
}

public void Shotgun_OnWeaponEquipPost(int client, int weaponEntity)
{
    // WeaponEquipPost must never show weapon descriptions.
    return;
}

void Shotgun_HandleOnFireEffects(int client, const char[] weapon, int shotSerial)
{
    if (StrEqual(weapon, "weapon_shotgun_chrome", false))
    {
        if (Shotgun_Chance(Shotgun_g_cvChromeAdrenChance.IntValue))
        {
            if (Shotgun_IsClientAdrenalineActive(client))
            {
                Shotgun_GiveIncendiaryUpgrade(client);
            }
            Shotgun_GiveAdrenaline(client, Shotgun_g_cvAdrenDuration.FloatValue);
            Shotgun_DebugLog("Chrome adrenaline: client=%N shot=%d", client, shotSerial);
        }

        if (Shotgun_Chance(Shotgun_g_cvChromeExplosionChance.IntValue))
        {
            Shotgun_g_iPendingExplosionShot[client] = shotSerial;
            Shotgun_StartPendingExplosionFallback(client, shotSerial);
            Shotgun_DebugLog("Chrome pending explosion: client=%N shot=%d", client, shotSerial);
        }
    }
    else if (StrEqual(weapon, "weapon_shotgun_spas", false))
    {
        if (Shotgun_Chance(Shotgun_g_cvSpasAdrenChance.IntValue))
        {
            if (Shotgun_IsClientAdrenalineActive(client))
            {
                Shotgun_GiveIncendiaryUpgrade(client);
            }
            Shotgun_GiveAdrenaline(client, Shotgun_g_cvAdrenDuration.FloatValue);
            Shotgun_DebugLog("SPAS adrenaline: client=%N shot=%d", client, shotSerial);
        }

        if (Shotgun_Chance(Shotgun_g_cvSpasExplosionChance.IntValue))
        {
            Shotgun_g_iPendingExplosionShot[client] = shotSerial;
            Shotgun_StartPendingExplosionFallback(client, shotSerial);
            Shotgun_DebugLog("SPAS pending explosion: client=%N shot=%d", client, shotSerial);
        }
    }
}

public Action Shotgun_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!Shotgun_g_bEnabled || Shotgun_g_bInsidePluginDamage)
    {
        return Plugin_Continue;
    }

    if (!Shotgun_IsValidSurvivor(attacker, true))
    {
        return Plugin_Continue;
    }

    Shotgun_TargetType targetType = Shotgun_GetTargetType(victim);
    if (!Shotgun_IsEnemyTarget(targetType))
    {
        return Plugin_Continue;
    }

    char weapon[64];
    Shotgun_ResolveCurrentShotWeapon(attacker, weapon, sizeof(weapon));
    if (!Shotgun_IsShotgunWeapon(weapon) || !Shotgun_IsWeaponEnabled(weapon))
    {
        return Plugin_Continue;
    }

    MWE_MarkSharedRealHit(attacker, victim, MWE_WeaponCategory_Shotgun, weapon);

    int shotSerial = Shotgun_ResolveShotSerial(attacker, weapon);
    float victimPos[3];
    float attackerPos[3];
    if (!Shotgun_GetEntityPosition(victim, victimPos) || !Shotgun_GetEntityPosition(attacker, attackerPos))
    {
        return Plugin_Continue;
    }

    if (StrEqual(weapon, "weapon_pumpshotgun", false))
    {
        Shotgun_HandlePumpOrAutoHit(attacker, victim, targetType, victimPos, attackerPos, shotSerial, true);
    }
    else if (StrEqual(weapon, "weapon_autoshotgun", false))
    {
        Shotgun_HandlePumpOrAutoHit(attacker, victim, targetType, victimPos, attackerPos, shotSerial, false);
    }
    else if (StrEqual(weapon, "weapon_shotgun_chrome", false) || StrEqual(weapon, "weapon_shotgun_spas", false))
    {
        Shotgun_HandleChromeOrSpasHit(attacker, victimPos, shotSerial);
    }

    return Plugin_Continue;
}
void Shotgun_HandleFallbackRealHit(int attacker, int victim, const char[] weapon)
{
    if (!Shotgun_g_bEnabled || Shotgun_g_bInsidePluginDamage)
    {
        return;
    }

    if (!Shotgun_IsValidSurvivor(attacker, true))
    {
        return;
    }

    Shotgun_TargetType targetType = Shotgun_GetTargetType(victim);
    if (!Shotgun_IsEnemyTarget(targetType))
    {
        return;
    }

    if (!Shotgun_IsShotgunWeapon(weapon) || !Shotgun_IsWeaponEnabled(weapon))
    {
        return;
    }

    int shotSerial = Shotgun_ResolveShotSerial(attacker, weapon);
    float victimPos[3];
    float attackerPos[3];
    if (!Shotgun_GetEntityPosition(victim, victimPos) || !Shotgun_GetEntityPosition(attacker, attackerPos))
    {
        return;
    }

    MWE_MarkSharedRealHit(attacker, victim, MWE_WeaponCategory_Shotgun, weapon);

    if (StrEqual(weapon, "weapon_pumpshotgun", false))
    {
        Shotgun_HandlePumpOrAutoHit(attacker, victim, targetType, victimPos, attackerPos, shotSerial, true);
    }
    else if (StrEqual(weapon, "weapon_autoshotgun", false))
    {
        Shotgun_HandlePumpOrAutoHit(attacker, victim, targetType, victimPos, attackerPos, shotSerial, false);
    }
    else if (StrEqual(weapon, "weapon_shotgun_chrome", false) || StrEqual(weapon, "weapon_shotgun_spas", false))
    {
        Shotgun_HandleChromeOrSpasHit(attacker, victimPos, shotSerial);
    }
}


void Shotgun_HandlePumpOrAutoHit(int attacker, int victim, Shotgun_TargetType targetType, const float victimPos[3], const float attackerPos[3], int shotSerial, bool pump)
{
    int tempChance = pump ? Shotgun_g_cvPumpTempChance.IntValue : Shotgun_g_cvAutoTempChance.IntValue;
    int closeChance = pump ? Shotgun_g_cvPumpCloseChance.IntValue : Shotgun_g_cvAutoCloseChance.IntValue;
    char weaponName[8];
    if (pump)
    {
        strcopy(weaponName, sizeof(weaponName), "pump");
    }
    else
    {
        strcopy(weaponName, sizeof(weaponName), "auto");
    }

    if (Shotgun_g_iLastPushShot[attacker] != shotSerial && MWE_CanRunHeavyEffect(attacker, MWE_HEAVY_SHOTGUN_AREA, 0.10))
    {
        Shotgun_g_iLastPushShot[attacker] = shotSerial;
        Shotgun_PushCommonInfectedRadius(victimPos, Shotgun_g_cvCommonPushRadius.FloatValue, Shotgun_g_cvCommonPushForce.FloatValue, Shotgun_g_cvCommonPushDamage.FloatValue, attacker);
    }

    if (Shotgun_g_iLastTempShot[attacker] != shotSerial && Shotgun_Chance(tempChance))
    {
        Shotgun_g_iLastTempShot[attacker] = shotSerial;
        Shotgun_GiveTempHealth(attacker, Shotgun_g_cvTempAmount.FloatValue);
        Shotgun_DebugLog("%s temp health: client=%N shot=%d", weaponName, attacker, shotSerial);
    }

    float distance = GetVectorDistance(attackerPos, victimPos);
    if (distance <= Shotgun_g_cvCloseRange.FloatValue && Shotgun_g_iLastCloseShot[attacker] != shotSerial && Shotgun_Chance(closeChance))
    {
        Shotgun_g_iLastCloseShot[attacker] = shotSerial;

        float minDamage = Shotgun_g_cvCloseDamageMin.FloatValue;
        float maxDamage = Shotgun_g_cvCloseDamageMax.FloatValue;
        if (maxDamage < minDamage)
        {
            maxDamage = minDamage;
        }

        float bonusDamage = GetRandomFloat(minDamage, maxDamage);
        int damageType = targetType == Shotgun_Target_CommonInfected ? DMG_BUCKSHOT : DMG_BLAST;
        Shotgun_ApplyDamage(victim, bonusDamage, attacker, damageType);
        Shotgun_GiveAdrenaline(attacker, 1.0);

        Shotgun_DebugLog("%s close bonus: client=%N victim=%d distance=%.1f damage=%.1f shot=%d", weaponName, attacker, victim, distance, bonusDamage, shotSerial);
    }
}

void Shotgun_HandleChromeOrSpasHit(int attacker, const float victimPos[3], int shotSerial)
{
    if (Shotgun_g_iPendingExplosionShot[attacker] == shotSerial && Shotgun_g_iProcessedExplosionShot[attacker] != shotSerial && MWE_CanRunHeavyEffect(attacker, MWE_HEAVY_SHOTGUN_AREA, 0.10))
    {
        Shotgun_g_iProcessedExplosionShot[attacker] = shotSerial;
        Shotgun_CreateExplosionDamage(victimPos, attacker, Shotgun_g_cvExplosionRadius.FloatValue, Shotgun_g_cvExplosionDamage.FloatValue);
        Shotgun_DebugLog("shotgun explosion: client=%N shot=%d", attacker, shotSerial);
    }
}

void Shotgun_StartPendingExplosionFallback(int client, int shotSerial)
{
    if (client < 1 || client > MaxClients || shotSerial <= 0)
    {
        return;
    }

    if (Shotgun_g_cvExplosionRadius.FloatValue <= 0.0 || Shotgun_g_cvExplosionDamage.FloatValue <= 0.0)
    {
        return;
    }

    Shotgun_TraceFromClient(client, Shotgun_g_fPendingExplosionPos[client]);
    Shotgun_g_bPendingExplosionHasPos[client] = true;

    DataPack pack;
    CreateDataTimer(0.05, Shotgun_Timer_ProcessPendingExplosion, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(shotSerial);
}

public Action Shotgun_Timer_ProcessPendingExplosion(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int shotSerial = pack.ReadCell();

    int client = GetClientOfUserId(userid);
    if (!Shotgun_g_bEnabled || !Shotgun_IsValidSurvivor(client, true))
    {
        return Plugin_Stop;
    }

    if (Shotgun_g_iPendingExplosionShot[client] != shotSerial
        || Shotgun_g_iProcessedExplosionShot[client] == shotSerial)
    {
        return Plugin_Stop;
    }

    if (!MWE_CanRunHeavyEffect(client, MWE_HEAVY_SHOTGUN_AREA, 0.10))
    {
        return Plugin_Stop;
    }

    float hitPos[3];
    if (Shotgun_g_bPendingExplosionHasPos[client])
    {
        hitPos[0] = Shotgun_g_fPendingExplosionPos[client][0];
        hitPos[1] = Shotgun_g_fPendingExplosionPos[client][1];
        hitPos[2] = Shotgun_g_fPendingExplosionPos[client][2];
    }
    else
    {
        Shotgun_TraceFromClient(client, hitPos);
    }

    Shotgun_g_iProcessedExplosionShot[client] = shotSerial;
    Shotgun_CreateExplosionDamage(hitPos, client, Shotgun_g_cvExplosionRadius.FloatValue, Shotgun_g_cvExplosionDamage.FloatValue);
    Shotgun_DebugLog("shotgun endpoint explosion: client=%N shot=%d", client, shotSerial);
    return Plugin_Stop;
}

bool Shotgun_TraceFromClient(int client, float hitPos[3])
{
    float start[3];
    float angles[3];
    float fwd[3];
    float end[3];

    GetClientEyePosition(client, start);
    GetClientEyeAngles(client, angles);
    GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);

    end[0] = start[0] + fwd[0] * Shotgun_TRACE_DISTANCE;
    end[1] = start[1] + fwd[1] * Shotgun_TRACE_DISTANCE;
    end[2] = start[2] + fwd[2] * Shotgun_TRACE_DISTANCE;

    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SHOT, RayType_EndPoint, Shotgun_TraceFilter_NoSelf, client);
    bool didHit = TR_DidHit(trace);
    if (didHit)
    {
        TR_GetEndPosition(hitPos, trace);
    }
    else
    {
        hitPos[0] = end[0];
        hitPos[1] = end[1];
        hitPos[2] = end[2];
    }
    delete trace;
    return didHit;
}

public bool Shotgun_TraceFilter_NoSelf(int entity, int contentsMask, any data)
{
    int client = data;
    if (entity == client)
    {
        return false;
    }
    return true;
}

int Shotgun_ResolveShotSerial(int client, const char[] weapon)
{
    float now = GetGameTime();
    if (Shotgun_g_iShotSerial[client] <= 0 || now - Shotgun_g_flLastShotTime[client] > 0.35 || !StrEqual(Shotgun_g_sLastShotWeapon[client], weapon, false))
    {
        Shotgun_g_iShotSerial[client]++;
        if (Shotgun_g_iShotSerial[client] <= 0)
        {
            Shotgun_g_iShotSerial[client] = 1;
        }
        Shotgun_g_flLastShotTime[client] = now;
        strcopy(Shotgun_g_sLastShotWeapon[client], sizeof(Shotgun_g_sLastShotWeapon[]), weapon);
    }

    return Shotgun_g_iShotSerial[client];
}

void Shotgun_ResolveCurrentShotWeapon(int client, char[] weapon, int maxlen)
{
    if (GetGameTime() - Shotgun_g_flLastShotTime[client] <= 0.35 && Shotgun_IsShotgunWeapon(Shotgun_g_sLastShotWeapon[client]))
    {
        strcopy(weapon, maxlen, Shotgun_g_sLastShotWeapon[client]);
        return;
    }

    MWE_GetDamageWeaponClass(client, weapon, maxlen);
}

bool Shotgun_GetActiveWeaponClass(int client, char[] weapon, int maxlen)
{
    weapon[0] = '\0';

    if (!Shotgun_IsValidSurvivor(client, false))
    {
        return false;
    }

    int weaponEntity = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!Shotgun_IsValidEntityIndex(weaponEntity))
    {
        return false;
    }

    GetEntityClassname(weaponEntity, weapon, maxlen);
    return weapon[0] != '\0';
}

void Shotgun_NormalizeWeaponClass(const char[] raw, char[] output, int maxlen)
{
    output[0] = '\0';

    if (raw[0] == '\0')
    {
        return;
    }

    if (strncmp(raw, "weapon_", 7, false) == 0)
    {
        strcopy(output, maxlen, raw);
        return;
    }

    if (StrEqual(raw, "pumpshotgun", false))
    {
        strcopy(output, maxlen, "weapon_pumpshotgun");
    }
    else if (StrEqual(raw, "shotgun_chrome", false))
    {
        strcopy(output, maxlen, "weapon_shotgun_chrome");
    }
    else if (StrEqual(raw, "autoshotgun", false))
    {
        strcopy(output, maxlen, "weapon_autoshotgun");
    }
    else if (StrEqual(raw, "shotgun_spas", false))
    {
        strcopy(output, maxlen, "weapon_shotgun_spas");
    }
}

bool Shotgun_IsShotgunWeapon(const char[] weapon)
{
    return StrEqual(weapon, "weapon_pumpshotgun", false)
        || StrEqual(weapon, "weapon_shotgun_chrome", false)
        || StrEqual(weapon, "weapon_autoshotgun", false)
        || StrEqual(weapon, "weapon_shotgun_spas", false);
}

bool Shotgun_IsWeaponEnabled(const char[] weapon)
{
    if (StrEqual(weapon, "weapon_pumpshotgun", false))
    {
        return Shotgun_g_cvEnablePump.BoolValue;
    }
    if (StrEqual(weapon, "weapon_shotgun_chrome", false))
    {
        return Shotgun_g_cvEnableChrome.BoolValue;
    }
    if (StrEqual(weapon, "weapon_autoshotgun", false))
    {
        return Shotgun_g_cvEnableAuto.BoolValue;
    }
    if (StrEqual(weapon, "weapon_shotgun_spas", false))
    {
        return Shotgun_g_cvEnableSpas.BoolValue;
    }
    return false;
}

bool Shotgun_IsValidSurvivor(int client, bool requireAlive)
{
    if (client < 1 || client > MaxClients)
    {
        return false;
    }
    if (!IsClientInGame(client))
    {
        return false;
    }
    if (requireAlive && !IsPlayerAlive(client))
    {
        return false;
    }
    if (GetClientTeam(client) != Shotgun_TEAM_SURVIVOR)
    {
        return false;
    }
    if (Shotgun_g_bHumansOnly && IsFakeClient(client))
    {
        return false;
    }
    return true;
}

bool Shotgun_IsEnemyTarget(Shotgun_TargetType type)
{
    return type == Shotgun_Target_CommonInfected
        || type == Shotgun_Target_SpecialInfected
        || type == Shotgun_Target_Tank
        || type == Shotgun_Target_Witch;
}

Shotgun_TargetType Shotgun_GetTargetType(int entity)
{
    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
        {
            return Shotgun_Target_Invalid;
        }

        int team = GetClientTeam(entity);
        if (team == Shotgun_TEAM_SURVIVOR)
        {
            return Shotgun_Target_Survivor;
        }
        if (team == Shotgun_TEAM_INFECTED)
        {
            int zombieClass = GetEntProp(entity, Prop_Send, "m_zombieClass");
            if (zombieClass == Shotgun_ZOMBIECLASS_TANK)
            {
                return Shotgun_Target_Tank;
            }
            return Shotgun_Target_SpecialInfected;
        }
        return Shotgun_Target_Invalid;
    }

    if (!Shotgun_IsValidEntityIndex(entity))
    {
        return Shotgun_Target_Invalid;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    if (StrEqual(classname, "infected", false))
    {
        return Shotgun_Target_CommonInfected;
    }
    if (StrEqual(classname, "witch", false))
    {
        return Shotgun_Target_Witch;
    }

    return Shotgun_Target_Invalid;
}

bool Shotgun_GetEntityPosition(int entity, float pos[3])
{
    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
        {
            return false;
        }
        GetClientAbsOrigin(entity, pos);
        return true;
    }

    if (!Shotgun_IsValidEntityIndex(entity))
    {
        return false;
    }

    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
    return true;
}

bool Shotgun_IsValidEntityIndex(int entity)
{
    return entity > 0 && IsValidEntity(entity);
}

bool Shotgun_Chance(int chance)
{
    if (chance <= 0)
    {
        return false;
    }
    if (chance >= 100)
    {
        return true;
    }
    return (GetURandomInt() % 100) < chance;
}

void Shotgun_GiveTempHealth(int client, float amount)
{
    if (!Shotgun_IsValidSurvivor(client, true) || amount <= 0.0)
    {
        return;
    }

    float currentTemp = Shotgun_GetCurrentTempHealth(client);
    int realHealth = GetClientHealth(client);
    float maxAllowed = 100.0 - float(realHealth);
    if (maxAllowed <= 0.0)
    {
        return;
    }

    float newTemp = currentTemp + amount;
    if (newTemp > maxAllowed)
    {
        newTemp = maxAllowed;
    }

    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", newTemp);
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}

float Shotgun_GetCurrentTempHealth(int client)
{
    if (!Shotgun_IsValidSurvivor(client, false))
    {
        return 0.0;
    }

    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    float bufferTime = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float decayRate = 0.27;
    if (Shotgun_g_cvPainPillsDecayRate != null)
    {
        decayRate = Shotgun_g_cvPainPillsDecayRate.FloatValue;
    }

    float temp = buffer - ((GetGameTime() - bufferTime) * decayRate);
    if (temp < 0.0)
    {
        temp = 0.0;
    }
    return temp;
}

void Shotgun_GiveAdrenaline(int client, float duration)
{
    if (!Shotgun_IsValidSurvivor(client, true) || duration <= 0.0)
    {
        return;
    }

    char code[256];
    Format(code, sizeof(code), "local p = GetPlayerFromUserID(%d); if (p != null) { p.UseAdrenaline(%.3f); }", GetClientUserId(client), duration);
    Shotgun_RunVScript(code);

    float until = GetGameTime() + duration;
    if (until > Shotgun_g_flKnownAdrenUntil[client])
    {
        Shotgun_g_flKnownAdrenUntil[client] = until;
    }
}

bool Shotgun_IsClientAdrenalineActive(int client)
{
    if (!Shotgun_IsValidSurvivor(client, true))
    {
        return false;
    }

    if (Shotgun_g_bHasAdrenalineProp && GetEntProp(client, Prop_Send, "m_bAdrenalineActive") != 0)
    {
        return true;
    }

    return Shotgun_g_flKnownAdrenUntil[client] > GetGameTime();
}

void Shotgun_GiveIncendiaryUpgrade(int client)
{
    if (!Shotgun_IsValidSurvivor(client, true))
    {
        return;
    }

    char code[256];
    Format(code, sizeof(code), "local p = GetPlayerFromUserID(%d); if (p != null) { p.GiveUpgrade(0); }", GetClientUserId(client));
    Shotgun_RunVScript(code);
}

void Shotgun_RunVScript(const char[] code)
{
    int logic = Shotgun_EnsureScriptLogic();
    if (!Shotgun_IsValidEntityIndex(logic))
    {
        LogError("[ShotgunEffects] Cannot create logic_script for VScript code: %s", code);
        return;
    }

    SetVariantString(code);
    AcceptEntityInput(logic, "RunScriptCode");
}

int Shotgun_EnsureScriptLogic()
{
    if (Shotgun_IsValidEntityIndex(Shotgun_g_iScriptLogic))
    {
        return Shotgun_g_iScriptLogic;
    }

    int entity = CreateEntityByName(Shotgun_SCRIPT_LOGIC_CLASS);
    if (Shotgun_IsValidEntityIndex(entity))
    {
        DispatchSpawn(entity);
        Shotgun_g_iScriptLogic = entity;
    }

    return Shotgun_g_iScriptLogic;
}

void Shotgun_ApplyDamage(int target, float damage, int attacker, int damageType)
{
    if (damage <= 0.0 || !Shotgun_IsValidSurvivor(attacker, true))
    {
        return;
    }

    Shotgun_TargetType targetType = Shotgun_GetTargetType(target);
    if (!Shotgun_IsEnemyTarget(targetType))
    {
        return;
    }

    float finalDamage = damage * Shotgun_g_cvDamageMultiplier.FloatValue;
    if (finalDamage <= 0.0)
    {
        return;
    }

    Shotgun_g_bInsidePluginDamage = true;
    MWE_SDKHooks_TakeDamage(target, attacker, attacker, finalDamage, damageType);
    Shotgun_g_bInsidePluginDamage = false;
}

void Shotgun_CreateExplosionDamage(const float origin[3], int attacker, float radius, float damage)
{
    float vecOrigin[3];
    vecOrigin[0] = origin[0];
    vecOrigin[1] = origin[1];
    vecOrigin[2] = origin[2];

    float damageScale = 1.0;
    if (Shotgun_g_cvDamageMultiplier != null)
    {
        damageScale = Shotgun_g_cvDamageMultiplier.FloatValue;
    }
    MWE_CreateUnifiedExplosionDamage(vecOrigin, attacker, radius, damage, damageScale);
}

void Shotgun_DamageEntitiesInRadius(const char[] classname, const float origin[3], float radius, float damage, int attacker, int damageType)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!Shotgun_IsValidEntityIndex(entity))
        {
            continue;
        }

        float pos[3];
        if (!Shotgun_GetEntityPosition(entity, pos))
        {
            continue;
        }

        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Shotgun_ApplyDamage(entity, damage, attacker, damageType);
        }
    }
}

void Shotgun_PushCommonInfectedRadius(const float origin[3], float radius, float force, float damage, int attacker)
{
    if (radius <= 0.0)
    {
        return;
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        if (!Shotgun_IsValidEntityIndex(entity))
        {
            continue;
        }

        float pos[3];
        if (!Shotgun_GetEntityPosition(entity, pos))
        {
            continue;
        }

        if (!MWE_IsWithinRadius(origin, pos, radius))
        {
            continue;
        }

        if (force > 0.0)
        {
            Shotgun_PushEntityFromPoint(entity, origin, force);
        }
        if (damage > 0.0)
        {
            Shotgun_ApplyDamage(entity, damage, attacker, DMG_BUCKSHOT);
        }
    }
}

void Shotgun_PushEntityFromPoint(int entity, const float origin[3], float force)
{
    if (!Shotgun_IsValidEntityIndex(entity) || force <= 0.0)
    {
        return;
    }

    float pos[3];
    if (!Shotgun_GetEntityPosition(entity, pos))
    {
        return;
    }

    float velocity[3];
    SubtractVectors(pos, origin, velocity);
    velocity[2] = 0.0;

    if (NormalizeVector(velocity, velocity) <= 0.01)
    {
        velocity[0] = GetRandomFloat(-1.0, 1.0);
        velocity[1] = GetRandomFloat(-1.0, 1.0);
        velocity[2] = 0.0;
        NormalizeVector(velocity, velocity);
    }

    ScaleVector(velocity, force);
    velocity[2] = force * 0.35;
    TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, velocity);
}

void Shotgun_SendExplosionVisual(const float origin[3], float radius, float damage)
{
    if (Shotgun_g_iExplosionSprite <= 0)
    {
        return;
    }

    TE_SetupExplosion(origin, Shotgun_g_iExplosionSprite, 5.0, 1, 0, RoundToNearest(radius), RoundToNearest(damage));
    TE_SendToAll();
}

void Shotgun_ShowWeaponNotice(int client, const char[] weapon)
{
    // Deleted automatic shotgun notice body.
    return;
}

void Shotgun_HookExistingDamageTargets()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        MWE_HookSharedTakeDamage(entity);
    }
}

void Shotgun_DebugLog(const char[] format, any ...)
{
    if (!Shotgun_g_bDebug)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogMessage("[ShotgunEffects] %s", buffer);
}


// ============================================================================
// Module: Smgs (from l4d2_mwe_smgs.sp)
// ============================================================================

/**
 * l4d2_mwe_smgs.sp
 *
 * 使用方法 / Usage:
 * 1. 将本文件放入: left4dead2/addons/sourcemod/scripting/l4d2_mwe_smgs.sp
 * 2. 使用 SourceMod spcomp 编译，生成 l4d2_mwe_smgs.smx。
 *    例: addons/sourcemod/scripting/spcomp l4d2_mwe_smgs.sp
 * 3. 将生成的 l4d2_mwe_smgs.smx 放入: left4dead2/addons/sourcemod/plugins/
 * 4. 单人模式或本地开房间也可使用；前提是本地 L4D2 已安装并加载 SourceMod。
 * 5. 本整合版配置统一写入: cfg/sourcemod/l4d2_mwe_all.cfg
 *
 * 简介 / Introduction:
 * 这是 L4D2 冲锋枪特效插件的 SourceMod 版本，只实现 3 把冲锋枪：
 * - UZI: weapon_smg
 * - 消音冲锋枪: weapon_smg_silenced
 * - MP5: weapon_smg_mp5
 *
 * 当前实现特点:
 * - 不使用每枪射线追踪；效果基于 player_hurt / infected_hurt 与 Witch 实体 SDKHooks 受伤钩子。
 * - 拾取武器时不再自动显示介绍；完整说明仅通过聊天命令 !mwe / !武器 的菜单查看。
 * - UZI 秒杀/百分比伤害不作用于 Tank。
 * - MP5 不秒杀特感玩家；肾上腺素期间只秒杀普通感染者和 Witch。
 *
 * 主要效果:
 * - UZI: 命中后 10% 以目标为中心造成 50 半径、25 伤害范围伤害；1% 触发百分比伤害。
 * - 消音冲锋枪: 命中后 10% 附带燃烧伤害和点燃效果。
 * - MP5: 击中特感/Tank 回血；击中队友可输血；肾上腺素期间秒杀普通感染者/Witch；有虚血时击退被命中的普通感染者。
 * - 所有回血逻辑先检查实血+虚血总量；只有总量 < 100 才回血，回血后硬性压制实血+虚血不超过 100。
 *
 * 依赖:
 * - SourceMod 1.10+
 * - SDKHooks
 * - SDKTools
 */



#define Smgs_PLUGIN_VERSION       "1.2.5-smgs-mp5-hard-health-cap"
#define Smgs_TEAM_SURVIVOR        2
#define Smgs_TEAM_INFECTED        3
#define Smgs_ZC_SMOKER            1
#define Smgs_ZC_BOOMER            2
#define Smgs_ZC_HUNTER            3
#define Smgs_ZC_SPITTER           4
#define Smgs_ZC_JOCKEY            5
#define Smgs_ZC_CHARGER           6
#define Smgs_ZC_TANK              8
#define Smgs_HIT_WEAPON_WINDOW    0.80
#define Smgs_SUPPRESS_WINDOW      0.05

#if !defined DMG_BULLET
#define DMG_BULLET           (1 << 1)
#endif

#if !defined DMG_BURN
#define DMG_BURN             (1 << 3)
#endif

#if !defined DMG_BUCKSHOT
#define DMG_BUCKSHOT         (1 << 29)
#endif

enum Smgs_TargetType
{
    Smgs_Target_Invalid = 0,
    Smgs_Target_Survivor,
    Smgs_Target_CommonInfected,
    Smgs_Target_SpecialInfected,
    Smgs_Target_Tank,
    Smgs_Target_Witch
};

enum Smgs_WeaponType
{
    Smgs_Weapon_None = 0,
    Smgs_Weapon_Uzi,
    Smgs_Weapon_SilencedSmg,
    Smgs_Weapon_MP5
};


ConVar Smgs_g_hEnable;
ConVar Smgs_g_hNotify;
ConVar Smgs_g_hDebug;

ConVar Smgs_g_hUziEnable;
ConVar Smgs_g_hUziSplashChance;
ConVar Smgs_g_hUziInstantChance;
ConVar Smgs_g_hUziSplashRadius;
ConVar Smgs_g_hUziSplashDamage;

ConVar Smgs_g_hSilencedEnable;
ConVar Smgs_g_hSilencedBurnChance;
ConVar Smgs_g_hSilencedBurnDamage;
ConVar Smgs_g_hSilencedBurnDuration;

ConVar Smgs_g_hMp5Enable;
ConVar Smgs_g_hMp5HealAmount;
ConVar Smgs_g_hMp5HealTank;
ConVar Smgs_g_hMp5TransfusionAmount;
ConVar Smgs_g_hMp5AdrenKill;
ConVar Smgs_g_hMp5KnockbackForce;

ConVar Smgs_g_hPainPillsDecayRate;

bool  Smgs_g_bEnable;
bool  Smgs_g_bNotify;
bool  Smgs_g_bDebug;

bool  Smgs_g_bUziEnable;
int   Smgs_g_iUziSplashChance;
int   Smgs_g_iUziInstantChance;
float Smgs_g_fUziSplashRadius;
float Smgs_g_fUziSplashDamage;

bool  Smgs_g_bSilencedEnable;
int   Smgs_g_iSilencedBurnChance;
float Smgs_g_fSilencedBurnDamage;
float Smgs_g_fSilencedBurnDuration;

bool  Smgs_g_bMp5Enable;
int   Smgs_g_iMp5HealAmount;
bool  Smgs_g_bMp5HealTank;
int   Smgs_g_iMp5TransfusionAmount;
bool  Smgs_g_bMp5AdrenKill;
float Smgs_g_fMp5KnockbackForce;

Smgs_WeaponType Smgs_g_iLastFireWeapon[MAXPLAYERS + 1];
float      Smgs_g_fLastFireTime[MAXPLAYERS + 1];
float      Smgs_g_fSuppressEffectsUntil[MAXPLAYERS + 1];

int Smgs_g_iOffsAdrenalineActive = -1;
int Smgs_g_iOffsHealthBuffer = -1;
int Smgs_g_iOffsHealthBufferTime = -1;

/**
 * 插件初始化: 创建 ConVar、注册事件、缓存常用 SendProp 偏移。
 */
public void Smgs_OnPluginStart()
{
    Smgs_CreateConVars();
    Smgs_HookConVarChanges();
    Smgs_RefreshConfigCache();

    // Auto pickup descriptions disabled: use !mwe / !武器 menu instead.
    HookEventEx("weapon_fire", Smgs_Event_WeaponFire, EventHookMode_Post);
    HookEventEx("player_hurt", Smgs_Event_PlayerHurt, EventHookMode_Post);
    HookEventEx("infected_hurt", Smgs_Event_InfectedHurt, EventHookMode_Post);

    // Witch 不注册 game event，统一使用实体受伤钩子，避免本地环境缺失事件导致启动失败。
    Smgs_HookExistingWitches();

    LogMessage("[L4D2 MWE SMGs] Loaded version %s. Witch damage uses SDKHook_OnTakeDamagePost only.", Smgs_PLUGIN_VERSION);

    RegAdminCmd("sm_mwe_smg_reload", Smgs_Command_ReloadConfigCache, ADMFLAG_CONFIG, "Reload cached cvars for l4d2_mwe_smgs.");

    Smgs_g_iOffsAdrenalineActive = FindSendPropInfo("CTerrorPlayer", "m_bAdrenalineActive");
    Smgs_g_iOffsHealthBuffer = FindSendPropInfo("CTerrorPlayer", "m_healthBuffer");
    Smgs_g_iOffsHealthBufferTime = FindSendPropInfo("CTerrorPlayer", "m_healthBufferTime");
    Smgs_g_hPainPillsDecayRate = FindConVar("pain_pills_decay_rate");

    // cfg 统一由整合版主入口生成。
}

/**
 * 实体创建时，给 Witch 注册受伤后钩子。不依赖 Witch 相关 game event。
 */
public void Smgs_OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "witch", false))
    {
        RequestFrame(Smgs_Frame_HookWitch, EntIndexToEntRef(entity));
    }
}

/**
 * 延迟一帧注册，避免实体刚创建时尚未完全初始化。
 */
public void Smgs_Frame_HookWitch(any entRef)
{
    int entity = EntRefToEntIndex(entRef);
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return;
    }

    Smgs_HookWitchEntity(entity);
}

/**
 * 地图中已存在 Witch 时也注册钩子，支持插件中途加载。
 */
void Smgs_HookExistingWitches()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        Smgs_HookWitchEntity(entity);
    }
}

/**
 * 注册单个 Witch 的受伤后钩子。
 */
void Smgs_HookWitchEntity(int entity)
{
    if (!Smgs_IsValidEntityIndex(entity) || entity <= MaxClients)
    {
        return;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    if (!StrEqual(classname, "witch", false))
    {
        return;
    }

    SDKHook(entity, SDKHook_OnTakeDamagePost, Smgs_OnWitchTakeDamagePost);
}

/**
 * 地图开始时清理缓存。
 */
public void Smgs_OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        Smgs_g_iLastFireWeapon[i] = Smgs_Weapon_None;
        Smgs_g_fLastFireTime[i] = 0.0;
        Smgs_g_fSuppressEffectsUntil[i] = 0.0;
    }

    Smgs_HookExistingWitches();
}

/**
 * 创建所有配置项。范围型 ConVar 带最小/最大值钳制。
 */
void Smgs_CreateConVars()
{
    Smgs_g_hEnable = CreateConVar("l4d2_mwe_enable", "1", "Enable multi weapon effects core. / 启用多武器特效主开关", 0, true, 0.0, true, 1.0);
    Smgs_g_hNotify = CreateConVar("l4d2_mwe_notify", "0", "DEPRECATED: pickup SMG notices are disabled; use !mwe / !武器 menu.", 0, true, 0.0, true, 1.0);
    Smgs_g_hDebug = CreateConVar("l4d2_mwe_debug", "0", "Enable debug logging. / 启用调试日志", 0, true, 0.0, true, 1.0);

    Smgs_g_hUziEnable = CreateConVar("l4d2_mwe_smg_uzi_enable", "1", "Enable UZI effects. / 启用 UZI 效果", 0, true, 0.0, true, 1.0);
    Smgs_g_hUziSplashChance = CreateConVar("l4d2_mwe_smg_uzi_splash_chance", "10", "UZI splash damage chance percent after real hit. / UZI 真实命中后范围伤害概率", 0, true, 0.0, true, 100.0);
    Smgs_g_hUziInstantChance = CreateConVar("l4d2_mwe_smg_uzi_instant_chance", "1", "UZI percent damage chance; Tank is ignored. / UZI 秒杀/百分比伤害概率，Tank 不生效", 0, true, 0.0, true, 100.0);
    Smgs_g_hUziSplashRadius = CreateConVar("l4d2_mwe_smg_uzi_splash_radius", "50.0", "UZI splash radius from hit target. / UZI 以命中目标为中心的范围伤害半径", 0, true, 0.0, true, 1000.0);
    Smgs_g_hUziSplashDamage = CreateConVar("l4d2_mwe_smg_uzi_splash_damage", "25.0", "UZI splash damage. / UZI 范围伤害值", 0, true, 0.0, true, 1000.0);

    Smgs_g_hSilencedEnable = CreateConVar("l4d2_mwe_smg_silenced_enable", "1", "Enable Silenced SMG effects. / 启用消音冲锋枪效果", 0, true, 0.0, true, 1.0);
    Smgs_g_hSilencedBurnChance = CreateConVar("l4d2_mwe_smg_silenced_burn_chance", "10", "Silenced SMG burn chance percent after real hit. / 消音冲锋枪真实命中后燃烧概率", 0, true, 0.0, true, 100.0);
    Smgs_g_hSilencedBurnDamage = CreateConVar("l4d2_mwe_smg_silenced_burn_damage", "1.0", "Silenced SMG burn damage. / 消音冲锋枪燃烧伤害", 0, true, 0.0, true, 1000.0);
    Smgs_g_hSilencedBurnDuration = CreateConVar("l4d2_mwe_smg_silenced_burn_duration", "3.0", "Silenced SMG ignite duration. / 消音冲锋枪点燃持续时间", 0, true, 0.0, true, 60.0);

    Smgs_g_hMp5Enable = CreateConVar("l4d2_mwe_smg_mp5_enable", "1", "Enable MP5 effects. / 启用 MP5 效果", 0, true, 0.0, true, 1.0);
    Smgs_g_hMp5HealAmount = CreateConVar("l4d2_mwe_smg_mp5_heal_amount", "1", "MP5 real health gained when hitting SI. / MP5 击中特感回血量", 0, true, 0.0, true, 100.0);
    Smgs_g_hMp5HealTank = CreateConVar("l4d2_mwe_smg_mp5_heal_tank", "1", "Allow MP5 heal on Tank hit. / MP5 打 Tank 是否回血", 0, true, 0.0, true, 1.0);
    Smgs_g_hMp5TransfusionAmount = CreateConVar("l4d2_mwe_smg_mp5_transfusion_amount", "1", "MP5 health transferred to hit teammate. / MP5 击中队友时输血量", 0, true, 0.0, true, 100.0);
    Smgs_g_hMp5AdrenKill = CreateConVar("l4d2_mwe_smg_mp5_adrenaline_kill", "1", "MP5 kills common infected and Witch while adrenaline is active; SI/Tank are ignored. / 肾上腺素期间 MP5 秒杀普通感染者和 Witch，不秒特感/Tank", 0, true, 0.0, true, 1.0);
    Smgs_g_hMp5KnockbackForce = CreateConVar("l4d2_mwe_smg_mp5_knockback_force", "280.0", "MP5 common infected knockback force when shooter has temp health. / MP5 有虚血时击退被命中的普通感染者力度", 0, true, 0.0, true, 2000.0);
}

/**
 * 注册 ConVar 变化监听，确保修改后立即生效。
 */
void Smgs_HookConVarChanges()
{
    Smgs_g_hEnable.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hNotify.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hDebug.AddChangeHook(Smgs_OnAnyConVarChanged);

    Smgs_g_hUziEnable.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hUziSplashChance.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hUziInstantChance.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hUziSplashRadius.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hUziSplashDamage.AddChangeHook(Smgs_OnAnyConVarChanged);

    Smgs_g_hSilencedEnable.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hSilencedBurnChance.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hSilencedBurnDamage.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hSilencedBurnDuration.AddChangeHook(Smgs_OnAnyConVarChanged);

    Smgs_g_hMp5Enable.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hMp5HealAmount.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hMp5HealTank.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hMp5TransfusionAmount.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hMp5AdrenKill.AddChangeHook(Smgs_OnAnyConVarChanged);
    Smgs_g_hMp5KnockbackForce.AddChangeHook(Smgs_OnAnyConVarChanged);
}

/**
 * ConVar 改变后刷新缓存。
 */
public void Smgs_OnAnyConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Smgs_RefreshConfigCache();
}

/**
 * 将 ConVar 值缓存到普通变量，减少高频事件中的重复读取。
 */
void Smgs_RefreshConfigCache()
{
    Smgs_g_bEnable = Smgs_g_hEnable.BoolValue;
    Smgs_g_bNotify = false; // hard disabled: use !mwe / !武器 menu
    Smgs_g_bDebug = Smgs_g_hDebug.BoolValue;

    Smgs_g_bUziEnable = Smgs_g_hUziEnable.BoolValue;
    Smgs_g_iUziSplashChance = Smgs_ClampInt(Smgs_g_hUziSplashChance.IntValue, 0, 100);
    Smgs_g_iUziInstantChance = Smgs_ClampInt(Smgs_g_hUziInstantChance.IntValue, 0, 100);
    Smgs_g_fUziSplashRadius = Smgs_ClampFloat(Smgs_g_hUziSplashRadius.FloatValue, 0.0, 1000.0);
    Smgs_g_fUziSplashDamage = Smgs_ClampFloat(Smgs_g_hUziSplashDamage.FloatValue, 0.0, 1000.0);

    Smgs_g_bSilencedEnable = Smgs_g_hSilencedEnable.BoolValue;
    Smgs_g_iSilencedBurnChance = Smgs_ClampInt(Smgs_g_hSilencedBurnChance.IntValue, 0, 100);
    Smgs_g_fSilencedBurnDamage = Smgs_ClampFloat(Smgs_g_hSilencedBurnDamage.FloatValue, 0.0, 1000.0);
    Smgs_g_fSilencedBurnDuration = Smgs_ClampFloat(Smgs_g_hSilencedBurnDuration.FloatValue, 0.0, 60.0);

    Smgs_g_bMp5Enable = Smgs_g_hMp5Enable.BoolValue;
    Smgs_g_iMp5HealAmount = Smgs_ClampInt(Smgs_g_hMp5HealAmount.IntValue, 0, 100);
    Smgs_g_bMp5HealTank = Smgs_g_hMp5HealTank.BoolValue;
    Smgs_g_iMp5TransfusionAmount = Smgs_ClampInt(Smgs_g_hMp5TransfusionAmount.IntValue, 0, 100);
    Smgs_g_bMp5AdrenKill = Smgs_g_hMp5AdrenKill.BoolValue;
    Smgs_g_fMp5KnockbackForce = Smgs_ClampFloat(Smgs_g_hMp5KnockbackForce.FloatValue, 0.0, 2000.0);
}

/**
 * 手动刷新缓存命令。
 */
public Action Smgs_Command_ReloadConfigCache(int client, int args)
{
    Smgs_RefreshConfigCache();
    ReplyToCommand(client, "[MWE-SMG] ConVar cache refreshed.");
    return Plugin_Handled;
}

/**
 * 拾取武器提示。
 * 注意: SourceMod client 索引正常是 1..MaxClients；无效通常是 0，不是负数。
 */
public void Smgs_Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    // Pickup-triggered weapon descriptions are deleted. Use !mwe / !武器 menu only.
    return;
}

/**
 * 拾取提示兜底: 延迟读取当前武器实体。
 */
public Action Smgs_Timer_ShowPickupInfoFallback(Handle timer, any userId)
{
    // Deleted pickup-description fallback timer.
    return Plugin_Stop;
}

/**
 * 只给指定玩家显示武器说明。
 */
void Smgs_ShowPickupInfo(int client, Smgs_WeaponType type)
{
    // Deleted automatic SMG notice body.
    return;
}

/**
 * 开火事件只缓存武器类型，不做射线、不做实体遍历。
 */
public void Smgs_Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!Smgs_g_bEnable)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Smgs_IsHumanSurvivorAlive(client))
    {
        return;
    }

    char cachedWeapon[64];
    if (MWE_GetCachedActiveWeaponClass(client, cachedWeapon, sizeof(cachedWeapon)))
    {
        MWE_RecordWeaponFire(client, cachedWeapon);
    }

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));

    Smgs_WeaponType type = Smgs_GetWeaponTypeFromName(weapon);
    if (type == Smgs_Weapon_None)
    {
        type = Smgs_GetClientActiveWeaponType(client);
    }

    Smgs_g_iLastFireWeapon[client] = type;
    Smgs_g_fLastFireTime[client] = GetGameTime();
}

/**
 * 玩家受伤事件: 处理真实命中的 UZI、消音、MP5 效果。
 */
public void Smgs_Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!Smgs_g_bEnable)
    {
        return;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));

    if (!Smgs_IsHumanSurvivorAlive(attacker) || !Smgs_IsValidClient(victim) || attacker == victim)
    {
        return;
    }

    if (Smgs_ShouldSuppressEffects(attacker))
    {
        return;
    }

    Smgs_WeaponType weapon = Smgs_GetRecentAttackWeapon(attacker);
    Smgs_TargetType victimType = Smgs_GetTargetType(victim);

    switch (weapon)
    {
        case Smgs_Weapon_Uzi:
        {
            if (Smgs_g_bUziEnable)
            {
                Smgs_HandleUziHit(attacker, victim, victimType);
            }
        }
        case Smgs_Weapon_SilencedSmg:
        {
            if (Smgs_g_bSilencedEnable)
            {
                Smgs_HandleSilencedHit(attacker, victim, victimType);
            }
        }
        case Smgs_Weapon_MP5:
        {
            if (Smgs_g_bMp5Enable)
            {
                Smgs_HandleMp5PlayerHit(attacker, victim, victimType);
            }
        }
        default:
        {
            return;
        }
    }
}

/**
 * 普通感染者受伤事件: 处理真实命中的 UZI、消音、MP5 效果。
 */
public void Smgs_Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!Smgs_g_bEnable)
    {
        return;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!Smgs_IsHumanSurvivorAlive(attacker))
    {
        return;
    }

    if (Smgs_ShouldSuppressEffects(attacker))
    {
        return;
    }

    int entity = event.GetInt("entityid");
    if (Smgs_GetTargetType(entity) != Smgs_Target_CommonInfected)
    {
        return;
    }

    Smgs_WeaponType weapon = Smgs_GetRecentAttackWeapon(attacker);
    switch (weapon)
    {
        case Smgs_Weapon_Uzi:
        {
            if (Smgs_g_bUziEnable)
            {
                Smgs_HandleUziHit(attacker, entity, Smgs_Target_CommonInfected);
            }
        }
        case Smgs_Weapon_SilencedSmg:
        {
            if (Smgs_g_bSilencedEnable)
            {
                Smgs_HandleSilencedHit(attacker, entity, Smgs_Target_CommonInfected);
            }
        }
        case Smgs_Weapon_MP5:
        {
            if (Smgs_g_bMp5Enable)
            {
                Smgs_HandleMp5CommonHit(attacker, entity);
            }
        }
        default:
        {
            return;
        }
    }
}

/**
 * Witch 受伤后钩子: 处理真实命中的 UZI、消音、MP5 效果。
 * 不依赖 Witch 相关 game event，兼容本地/单人环境。
 */
public void Smgs_OnWitchTakeDamagePost(int witch, int attacker, int inflictor, float damage, int damageType)
{
    if (!Smgs_g_bEnable || damage <= 0.0)
    {
        return;
    }

    if (!Smgs_IsHumanSurvivorAlive(attacker))
    {
        return;
    }

    if (Smgs_ShouldSuppressEffects(attacker))
    {
        return;
    }

    if (Smgs_GetTargetType(witch) != Smgs_Target_Witch)
    {
        return;
    }

    Smgs_WeaponType weapon = Smgs_GetRecentAttackWeapon(attacker);
    switch (weapon)
    {
        case Smgs_Weapon_Uzi:
        {
            if (Smgs_g_bUziEnable)
            {
                Smgs_HandleUziHit(attacker, witch, Smgs_Target_Witch);
            }
        }
        case Smgs_Weapon_SilencedSmg:
        {
            if (Smgs_g_bSilencedEnable)
            {
                Smgs_HandleSilencedHit(attacker, witch, Smgs_Target_Witch);
            }
        }
        case Smgs_Weapon_MP5:
        {
            if (Smgs_g_bMp5Enable)
            {
                Smgs_HandleMp5WitchHit(attacker, witch);
            }
        }
        default:
        {
            return;
        }
    }
}

/**
 * UZI 真实命中后的效果。
 */
void Smgs_HandleUziHit(int attacker, int target, Smgs_TargetType type)
{
    if (type != Smgs_Target_CommonInfected && type != Smgs_Target_SpecialInfected && type != Smgs_Target_Tank && type != Smgs_Target_Witch)
    {
        return;
    }

    float center[3];
    if (!Smgs_GetEntityCenter(target, center))
    {
        return;
    }

    if (Smgs_Chance(Smgs_g_iUziSplashChance) && Smgs_g_fUziSplashRadius > 0.0 && Smgs_g_fUziSplashDamage > 0.0)
    {
        Smgs_ApplyRadiusDamage(center, Smgs_g_fUziSplashRadius, Smgs_g_fUziSplashDamage, attacker, DMG_BULLET);
        Smgs_DebugLog("UZI splash: attacker=%N target=%d radius=%.1f damage=%.1f", attacker, target, Smgs_g_fUziSplashRadius, Smgs_g_fUziSplashDamage);
    }

    if (Smgs_Chance(Smgs_g_iUziInstantChance))
    {
        Smgs_ApplyUziInstantDamage(target, attacker);
        Smgs_DebugLog("UZI instant/percent: attacker=%N target=%d type=%d", attacker, target, type);
    }
}

/**
 * 消音冲锋枪真实命中后的燃烧效果。
 */
void Smgs_HandleSilencedHit(int attacker, int target, Smgs_TargetType type)
{
    if (type != Smgs_Target_CommonInfected && type != Smgs_Target_SpecialInfected && type != Smgs_Target_Tank && type != Smgs_Target_Witch)
    {
        return;
    }

    if (!Smgs_Chance(Smgs_g_iSilencedBurnChance))
    {
        return;
    }

    Smgs_ApplyDamageSafe(target, Smgs_g_fSilencedBurnDamage, attacker, DMG_BURN);
    Smgs_IgniteTargetSafe(target, Smgs_g_fSilencedBurnDuration);
    Smgs_DebugLog("Silenced burn: attacker=%N target=%d type=%d", attacker, target, type);
}

/**
 * MP5 击中玩家后的效果。
 */
void Smgs_HandleMp5PlayerHit(int attacker, int victim, Smgs_TargetType victimType)
{
    if (victimType == Smgs_Target_SpecialInfected || (Smgs_g_bMp5HealTank && victimType == Smgs_Target_Tank))
    {
        Smgs_HealRealHealth(attacker, Smgs_g_iMp5HealAmount, true);
        Smgs_DebugLog("MP5 heal: attacker=%N victim=%N type=%d", attacker, victim, victimType);
        return;
    }

    if (victimType == Smgs_Target_Survivor && victim != attacker)
    {
        Smgs_TransferHealth(attacker, victim, Smgs_g_iMp5TransfusionAmount);
        Smgs_DebugLog("MP5 transfusion hit: attacker=%N victim=%N", attacker, victim);
    }
}

/**
 * MP5 击中普通感染者后的效果。
 */
void Smgs_HandleMp5CommonHit(int attacker, int entity)
{
    if (Smgs_GetClientTempHealth(attacker) > 0.0 && Smgs_g_fMp5KnockbackForce > 0.0)
    {
        Smgs_KnockbackCommonInfected(entity, attacker, Smgs_g_fMp5KnockbackForce);
    }

    if (Smgs_g_bMp5AdrenKill && Smgs_IsAdrenalineActive(attacker))
    {
        Smgs_ApplyDamageSafe(entity, 100000.0, attacker, DMG_BULLET);
        Smgs_DebugLog("MP5 adrenaline kill common: attacker=%N entity=%d", attacker, entity);
    }
}

/**
 * MP5 击中 Witch 后的效果。按当前设计保留肾上腺素秒杀 Witch。
 */
void Smgs_HandleMp5WitchHit(int attacker, int witch)
{
    if (Smgs_g_bMp5AdrenKill && Smgs_IsAdrenalineActive(attacker))
    {
        Smgs_ApplyDamageSafe(witch, 100000.0, attacker, DMG_BULLET);
        Smgs_DebugLog("MP5 adrenaline kill witch: attacker=%N witch=%d", attacker, witch);
    }
}

/**
 * UZI 秒杀/百分比伤害。Tank 直接跳过。
 */
void Smgs_ApplyUziInstantDamage(int target, int attacker)
{
    Smgs_TargetType type = Smgs_GetTargetType(target);
    float health = Smgs_GetEntityCurrentHealth(target);
    if (health <= 0.0)
    {
        return;
    }

    float damage = 0.0;
    switch (type)
    {
        case Smgs_Target_CommonInfected:
        {
            damage = health + 1.0;
        }
        case Smgs_Target_SpecialInfected:
        {
            damage = health * 0.5;
        }
        case Smgs_Target_Tank:
        {
            return;
        }
        case Smgs_Target_Witch:
        {
            damage = health * 0.25;
        }
        default:
        {
            return;
        }
    }

    Smgs_ApplyDamageSafe(target, damage, attacker, DMG_BULLET);
}

/**
 * 半径伤害: 遍历感染者玩家、普通感染者、Witch；跳过生还者友军。
 */
void Smgs_ApplyRadiusDamage(float center[3], float radius, float damage, int attacker, int damageType)
{
    if (radius <= 0.0 || damage <= 0.0)
    {
        return;
    }

    float radiusSq = radius * radius;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != Smgs_TEAM_INFECTED)
        {
            continue;
        }

        Smgs_TargetType type = Smgs_GetTargetType(i);
        if (type != Smgs_Target_SpecialInfected && type != Smgs_Target_Tank)
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(i, pos);
        if (Smgs_IsVectorDistanceSqWithin(center, pos, radiusSq))
        {
            Smgs_ApplyDamageSafe(i, damage, attacker, damageType);
        }
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "infected")) != -1)
    {
        if (!Smgs_IsValidEntityIndex(entity))
        {
            continue;
        }

        float pos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        if (Smgs_IsVectorDistanceSqWithin(center, pos, radiusSq))
        {
            Smgs_ApplyDamageSafe(entity, damage, attacker, damageType);
        }
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        if (!Smgs_IsValidEntityIndex(entity))
        {
            continue;
        }

        float pos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        if (Smgs_IsVectorDistanceSqWithin(center, pos, radiusSq))
        {
            Smgs_ApplyDamageSafe(entity, damage, attacker, damageType);
        }
    }
}

/**
 * 击退一个被命中的普通感染者: 用速度向量模拟推离射击者。
 */
void Smgs_KnockbackCommonInfected(int entity, int attacker, float force)
{
    if (!Smgs_IsValidEntityIndex(entity) || force <= 0.0)
    {
        return;
    }

    float attackerPos[3];
    float pos[3];
    GetClientAbsOrigin(attacker, attackerPos);
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);

    float velocity[3];
    MakeVectorFromPoints(attackerPos, pos, velocity);
    velocity[2] = 0.0;

    if (GetVectorLength(velocity) < 0.01)
    {
        velocity[0] = GetRandomFloat(-1.0, 1.0);
        velocity[1] = GetRandomFloat(-1.0, 1.0);
        velocity[2] = 0.0;
    }

    NormalizeVector(velocity, velocity);
    ScaleVector(velocity, force);
    velocity[2] = 120.0;

    TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, velocity);
}

/**
 * 生命输血: 射击者扣真实生命，队友按“实血+有效虚血 < 100”规则回血。
 * 目标总血已满时不输血；回血后目标总血不会超过 100；射击者不会因此死亡。
 */
void Smgs_TransferHealth(int fromClient, int toClient, int amount)
{
    if (amount <= 0 || !Smgs_IsHumanSurvivorAlive(fromClient) || !Smgs_IsValidSurvivorAlive(toClient))
    {
        return;
    }

    int fromHp = GetClientHealth(fromClient);
    if (fromHp <= 1 || !Smgs_CanReceiveHealth(toClient))
    {
        return;
    }

    int realAmount = amount;
    realAmount = Smgs_MinInt(realAmount, fromHp - 1);

    if (realAmount <= 0)
    {
        return;
    }

    int healed = Smgs_HealRealHealth(toClient, realAmount, true);
    if (healed <= 0)
    {
        return;
    }

    SetEntityHealth(fromClient, fromHp - healed);
    Smgs_ClampClientTotalHealthTo100(toClient);
    RequestFrame(Smgs_Frame_ClampClientTotalHealth, GetClientUserId(toClient));
}

/**
 * 增加真实生命。
 * 规则：先计算 实血 + 有效虚血；只有总量 < 100 才回血；回血后总量不超过 100。
 * 返回实际消耗/应用的实血回血点数，便于输血逻辑扣除相同数值。
 */
int Smgs_HealRealHealth(int client, int amount, bool clampTotalHealth)
{
    if (amount <= 0 || !Smgs_IsValidSurvivorAlive(client))
    {
        return 0;
    }

    // 先清理已经超过 100 的状态，避免 MP5 连续触发时叠在残留虚血上。
    Smgs_ClampClientTotalHealthTo100(client);

    int hp = GetClientHealth(client);
    float temp = Smgs_GetClientTempHealth(client);
    float total = float(hp) + temp;
    float missing = 100.0 - total;

    if (missing <= 0.0 || hp >= 100)
    {
        Smgs_ClampClientTotalHealthTo100(client);
        return 0;
    }

    int add = amount;
    int maxRealAdd = 100 - hp;
    add = Smgs_MinInt(add, maxRealAdd);

    // 实血是整数。剩余空间不足 1 点时允许补 1 点实血，但补完立即扣掉对应虚血，最终总量仍为 100。
    if (float(add) > missing)
    {
        add = RoundToFloor(missing);
        if (add < 1 && missing > 0.0)
        {
            add = 1;
        }
    }

    if (add <= 0)
    {
        Smgs_ClampClientTotalHealthTo100(client);
        return 0;
    }

    int newHp = hp + add;
    if (newHp > 100)
    {
        newHp = 100;
    }

    SetEntityHealth(client, newHp);

    if (clampTotalHealth)
    {
        Smgs_ClampClientTotalHealthTo100(client);
        // L4D2 有时会在同一帧后刷新 m_healthBuffer；下一帧再压一次，防止 HUD 显示超过 100。
        RequestFrame(Smgs_Frame_ClampClientTotalHealth, GetClientUserId(client));
    }

    return newHp - hp;
}

/**
 * 安全伤害接口。设置短暂抑制窗口，避免插件伤害递归触发自身效果。
 */
void Smgs_ApplyDamageSafe(int target, float damage, int attacker, int damageType)
{
    if (damage <= 0.0 || !Smgs_IsValidEntityIndex(target) || !Smgs_IsValidClient(attacker))
    {
        return;
    }

    if (target >= 1 && target <= MaxClients)
    {
        if (!IsClientInGame(target) || !IsPlayerAlive(target))
        {
            return;
        }
    }

    Smgs_g_fSuppressEffectsUntil[attacker] = GetGameTime() + Smgs_SUPPRESS_WINDOW;
    MWE_SDKHooks_TakeDamage(target, attacker, attacker, damage, damageType);
}

/**
 * 点燃目标。部分实体可能不接受 IgniteEntity，失败时保留前面的 DMG_BURN 伤害。
 */
void Smgs_IgniteTargetSafe(int target, float duration)
{
    if (duration <= 0.0 || !Smgs_IsValidEntityIndex(target))
    {
        return;
    }

    IgniteEntity(target, duration, false, 0.0, false);
}

/**
 * 根据事件/类名里的武器名解析武器类型。兼容短名和完整 classname。
 */
Smgs_WeaponType Smgs_GetWeaponTypeFromName(const char[] name)
{
    if (name[0] == '\0')
    {
        return Smgs_Weapon_None;
    }

    if (StrEqual(name, "smg", false) || StrEqual(name, "weapon_smg", false))
    {
        return Smgs_Weapon_Uzi;
    }

    if (StrEqual(name, "smg_silenced", false) || StrEqual(name, "weapon_smg_silenced", false))
    {
        return Smgs_Weapon_SilencedSmg;
    }

    if (StrEqual(name, "smg_mp5", false) || StrEqual(name, "weapon_smg_mp5", false))
    {
        return Smgs_Weapon_MP5;
    }

    return Smgs_Weapon_None;
}

/**
 * 获取玩家当前武器类型。
 */
Smgs_WeaponType Smgs_GetClientActiveWeaponType(int client)
{
    char weapon[64];
    if (!Smgs_GetClientActiveWeaponClass(client, weapon, sizeof(weapon)))
    {
        return Smgs_Weapon_None;
    }

    return Smgs_GetWeaponTypeFromName(weapon);
}

/**
 * 获取玩家当前武器类名。
 */
bool Smgs_GetClientActiveWeaponClass(int client, char[] weapon, int maxLen)
{
    weapon[0] = '\0';

    if (!Smgs_IsValidClient(client))
    {
        return false;
    }

    int weaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!Smgs_IsValidEntityIndex(weaponEnt))
    {
        return false;
    }

    GetEntityClassname(weaponEnt, weapon, maxLen);
    return weapon[0] != '\0';
}

/**
 * 获取最近一次开火武器。缓存失效时退回当前武器。
 */
Smgs_WeaponType Smgs_GetRecentAttackWeapon(int client)
{
    float now = GetGameTime();
    if ((now - Smgs_g_fLastFireTime[client]) <= Smgs_HIT_WEAPON_WINDOW && Smgs_g_iLastFireWeapon[client] != Smgs_Weapon_None)
    {
        return Smgs_g_iLastFireWeapon[client];
    }

    return Smgs_GetClientActiveWeaponType(client);
}

/**
 * 是否跳过插件自身伤害产生的事件。
 */
bool Smgs_ShouldSuppressEffects(int attacker)
{
    if (!Smgs_IsValidClient(attacker))
    {
        return true;
    }

    return GetGameTime() <= Smgs_g_fSuppressEffectsUntil[attacker];
}

/**
 * 获取实体目标类型。
 */
Smgs_TargetType Smgs_GetTargetType(int entity)
{
    if (!Smgs_IsValidEntityIndex(entity))
    {
        return Smgs_Target_Invalid;
    }

    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
        {
            return Smgs_Target_Invalid;
        }

        int team = GetClientTeam(entity);
        if (team == Smgs_TEAM_SURVIVOR)
        {
            return Smgs_Target_Survivor;
        }

        if (team == Smgs_TEAM_INFECTED)
        {
            int zombieClass = GetEntProp(entity, Prop_Send, "m_zombieClass");
            if (zombieClass == Smgs_ZC_TANK)
            {
                return Smgs_Target_Tank;
            }

            if (zombieClass >= Smgs_ZC_SMOKER && zombieClass <= Smgs_ZC_CHARGER)
            {
                return Smgs_Target_SpecialInfected;
            }
        }

        return Smgs_Target_Invalid;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (StrEqual(classname, "infected", false))
    {
        return Smgs_Target_CommonInfected;
    }

    if (StrEqual(classname, "witch", false))
    {
        return Smgs_Target_Witch;
    }

    return Smgs_Target_Invalid;
}

/**
 * 获取实体中心/原点。
 */
bool Smgs_GetEntityCenter(int entity, float pos[3])
{
    if (!Smgs_IsValidEntityIndex(entity))
    {
        return false;
    }

    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
        {
            return false;
        }

        GetClientAbsOrigin(entity, pos);
        pos[2] += 36.0;
        return true;
    }

    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
    return true;
}

/**
 * 当前生命。玩家读取 GetClientHealth，非玩家读取 m_iHealth。
 */
float Smgs_GetEntityCurrentHealth(int entity)
{
    if (!Smgs_IsValidEntityIndex(entity))
    {
        return 0.0;
    }

    if (entity >= 1 && entity <= MaxClients)
    {
        if (!IsClientInGame(entity) || !IsPlayerAlive(entity))
        {
            return 0.0;
        }

        return float(GetClientHealth(entity));
    }

    return float(GetEntProp(entity, Prop_Data, "m_iHealth"));
}

/**
 * 读取计算后的虚血。考虑衰减，避免 m_healthBuffer 残留值误判。
 */
float Smgs_GetClientTempHealth(int client)
{
    if (!Smgs_IsValidSurvivorAlive(client) || Smgs_g_iOffsHealthBuffer < 0)
    {
        return 0.0;
    }

    float buffer = Smgs_GetClientRawHealthBuffer(client);
    if (buffer <= 0.0)
    {
        return 0.0;
    }

    if (Smgs_g_iOffsHealthBufferTime < 0 || Smgs_g_hPainPillsDecayRate == null)
    {
        return buffer;
    }

    float bufferTime = GetEntDataFloat(client, Smgs_g_iOffsHealthBufferTime);
    float decayRate = Smgs_g_hPainPillsDecayRate.FloatValue;
    float temp = buffer - ((GetGameTime() - bufferTime) * decayRate);
    return temp > 0.0 ? temp : 0.0;
}

/**
 * 读取原始虚血缓冲。用于硬性上限处理，避免 m_healthBuffer 残留导致 HUD 总血量超过 100。
 */
float Smgs_GetClientRawHealthBuffer(int client)
{
    if (!Smgs_IsValidSurvivorAlive(client) || Smgs_g_iOffsHealthBuffer < 0)
    {
        return 0.0;
    }

    float buffer = GetEntDataFloat(client, Smgs_g_iOffsHealthBuffer);
    return buffer > 0.0 ? buffer : 0.0;
}

/**
 * 设置虚血缓冲，并刷新缓冲时间。
 */
void Smgs_SetClientHealthBuffer(int client, float value)
{
    if (!Smgs_IsValidSurvivorAlive(client) || Smgs_g_iOffsHealthBuffer < 0)
    {
        return;
    }

    value = Smgs_ClampFloat(value, 0.0, 100.0);
    SetEntDataFloat(client, Smgs_g_iOffsHealthBuffer, value, true);

    if (Smgs_g_iOffsHealthBufferTime >= 0)
    {
        SetEntDataFloat(client, Smgs_g_iOffsHealthBufferTime, GetGameTime(), true);
    }
}

/**
 * 判断生还者是否还能回血。只看总血量：实血 + 当前有效虚血。
 */
bool Smgs_CanReceiveHealth(int client)
{
    if (!Smgs_IsValidSurvivorAlive(client))
    {
        return false;
    }

    return Smgs_GetClientTotalHealth(client) < 100.0;
}

/**
 * 获取总血量：实血 + 当前有效虚血。
 */
float Smgs_GetClientTotalHealth(int client)
{
    if (!Smgs_IsValidSurvivorAlive(client))
    {
        return 0.0;
    }

    return float(GetClientHealth(client)) + Smgs_GetClientTempHealth(client);
}

/**
 * 将总血量压到 100 以内。优先削减虚血，不降低实血。
 * 同时检查原始 m_healthBuffer，防止有效虚血已衰减但原始缓冲仍让 HUD/后续逻辑显示超过 100。
 */
void Smgs_ClampClientTotalHealthTo100(int client)
{
    if (!Smgs_IsValidSurvivorAlive(client))
    {
        return;
    }

    int hp = GetClientHealth(client);
    if (hp > 100)
    {
        SetEntityHealth(client, 100);
        hp = 100;
    }

    float maxTemp = 100.0 - float(hp);
    if (maxTemp < 0.0)
    {
        maxTemp = 0.0;
    }

    float effectiveTemp = Smgs_GetClientTempHealth(client);
    float rawTemp = Smgs_GetClientRawHealthBuffer(client);

    if (effectiveTemp > maxTemp || rawTemp > maxTemp)
    {
        Smgs_SetClientHealthBuffer(client, maxTemp);
    }
}

/**
 * 下一帧再次压总血量。用于处理 L4D2 在受伤/回血事件后刷新虚血缓冲的情况。
 */
public void Smgs_Frame_ClampClientTotalHealth(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0)
    {
        Smgs_ClampClientTotalHealthTo100(client);
    }
}

/**
 * 检查肾上腺素状态。
 */
bool Smgs_IsAdrenalineActive(int client)
{
    if (!Smgs_IsValidSurvivorAlive(client) || Smgs_g_iOffsAdrenalineActive <= 0)
    {
        return false;
    }

    return GetEntData(client, Smgs_g_iOffsAdrenalineActive, 1) != 0;
}

/**
 * 概率检查。chance=0 永不触发，chance=100 必定触发。
 */
bool Smgs_Chance(int chance)
{
    if (chance <= 0)
    {
        return false;
    }

    if (chance >= 100)
    {
        return true;
    }

    return (GetURandomInt() % 100) < chance;
}

/**
 * 人类生还者，不要求存活。用于拾取事件。
 */
bool Smgs_IsHumanSurvivor(int client)
{
    return Smgs_IsValidClient(client)
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && GetClientTeam(client) == Smgs_TEAM_SURVIVOR;
}

/**
 * 人类生还者且存活。
 */
bool Smgs_IsHumanSurvivorAlive(int client)
{
    return Smgs_IsHumanSurvivor(client) && IsPlayerAlive(client);
}

/**
 * 生还者玩家。
 */
bool Smgs_IsValidSurvivor(int client)
{
    return Smgs_IsValidClient(client)
        && IsClientInGame(client)
        && GetClientTeam(client) == Smgs_TEAM_SURVIVOR;
}

/**
 * 生还者玩家且存活。
 */
bool Smgs_IsValidSurvivorAlive(int client)
{
    return Smgs_IsValidSurvivor(client) && IsPlayerAlive(client);
}

/**
 * 基本 client 范围检查。SourceMod client 正常是 1..MaxClients；0 是无效/服务器控制台。
 */
bool Smgs_IsValidClient(int client)
{
    return client >= 1 && client <= MaxClients;
}

/**
 * 实体范围与有效性检查。
 */
bool Smgs_IsValidEntityIndex(int entity)
{
    if (entity <= 0)
    {
        return false;
    }

    if (entity <= MaxClients)
    {
        return IsClientInGame(entity);
    }

    return IsValidEntity(entity);
}

bool Smgs_IsVectorDistanceSqWithin(float a[3], float b[3], float radiusSq)
{
    float dx = a[0] - b[0];
    float dy = a[1] - b[1];
    float dz = a[2] - b[2];
    return (dx * dx + dy * dy + dz * dz) <= radiusSq;
}

int Smgs_ClampInt(int value, int minValue, int maxValue)
{
    if (value < minValue)
    {
        return minValue;
    }

    if (value > maxValue)
    {
        return maxValue;
    }

    return value;
}

float Smgs_ClampFloat(float value, float minValue, float maxValue)
{
    if (value < minValue)
    {
        return minValue;
    }

    if (value > maxValue)
    {
        return maxValue;
    }

    return value;
}

int Smgs_MinInt(int a, int b)
{
    return a < b ? a : b;
}

/**
 * 调试日志。关闭调试时不写日志。
 */
void Smgs_DebugLog(const char[] format, any ...)
{
    if (!Smgs_g_bDebug)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogMessage("[MWE-SMG] %s", buffer);
}


// ============================================================================
// Module: Pistols (from l4d2_mwe_pistols.sp)
// ============================================================================

/*
 * 文件: l4d2_mwe_pistols.sp
 * 简介: L4D2 多武器特效项目的“手枪类”独立 SourceMod 插件。
 *       支持 weapon_pistol 与 weapon_pistol_magnum，不依赖 Left4DHooks，只使用 SourceMod + SDKTools + SDKHooks。
 *
 * 使用方法:
 * 1. 将本文件放到: left4dead2/addons/sourcemod/scripting/l4d2_mwe_pistols.sp
 * 2. 使用 SourceMod 编译器编译:
 *      spcomp l4d2_mwe_pistols.sp
 * 3. 将生成的 l4d2_mwe_pistols.smx 放到:
 *      left4dead2/addons/sourcemod/plugins/
 * 4. 启动服务器或执行:
 *      sm plugins load l4d2_mwe_pistols
 * 5. 本整合版配置统一写入:
 *      left4dead2/cfg/sourcemod/l4d2_mwe_all.cfg
 *
 * 功能概要:
 * - 普通手枪 weapon_pistol:
 *   1) 开火时根据射击者当前实血追加伤害: base + (100 - hp) * factor。
 *
 * - 马格南 weapon_pistol_magnum:
 *   1) 击中特感时，按概率给予随机武器升级。
 *   2) 击中 Tank 或 Witch 时：不再给予激光，只给予燃烧弹/高爆弹。
 *   3) 命中敌人头部时必定触发原有范围爆炸伤害；非爆头弹着点按配置概率触发。
 *   4) 使用 TraceAttack + SDKHook_OnTakeDamageAlive 缓存马格南实际命中目标，修复一枪爆头打死敌人后爆炸漏触发。
 *   5) 随机升级不再包含激光瞄准器，只在燃烧弹/高爆弹中随机。
 *
 * 说明:
 * - 武器升级使用 upgrade_add 指令，插件会临时移除 cheat 标记再执行。
 * - 本插件只处理真人生还者，bot 不会触发效果。
 */



#define Pistols_PLUGIN_VERSION        "1.0.4"
#define Pistols_TRACE_DISTANCE        18192.0
#define Pistols_TEAM_SURVIVOR         2
#define Pistols_TEAM_INFECTED         3
#define Pistols_ZOMBIECLASS_TANK      8
#define Pistols_SOUND_EXPLOSION       "weapons/hegrenade/explode5.wav"
#define Pistols_MAGNUM_HIT_CACHE_TIME  0.35
#define Pistols_UPGRADE_BIT_INCENDIARY (1 << 0)
#define Pistols_UPGRADE_BIT_EXPLOSIVE  (1 << 1)
#define Pistols_UPGRADE_BIT_LASER      (1 << 2)
#define Pistols_UPGRADE_NONE           0
#define Pistols_UPGRADE_LASER          1
#define Pistols_UPGRADE_INCENDIARY     2
#define Pistols_UPGRADE_EXPLOSIVE      3


enum Pistols_TargetType
{
    Pistols_Target_Invalid = 0,
    Pistols_Target_CommonInfected,
    Pistols_Target_SpecialInfected,
    Pistols_Target_Tank,
    Pistols_Target_Witch,
    Pistols_Target_Survivor
};

enum struct Pistols_TraceResult
{
    bool hit;
    int entity;
    float hitPos[3];
    float endPos[3];
}

ConVar Pistols_g_hEnabled;
ConVar Pistols_g_hNotify;
ConVar Pistols_g_hDebug;
ConVar Pistols_g_hWeaponPistol;
ConVar Pistols_g_hWeaponMagnum;

ConVar Pistols_g_hPistolBaseDamage;
ConVar Pistols_g_hPistolMissingHealthFactor;

ConVar Pistols_g_hMagnumUpgradeChance;
ConVar Pistols_g_hMagnumExplosionChance;
ConVar Pistols_g_hMagnumExplosionRadius;
ConVar Pistols_g_hMagnumExplosionDamage;

ConVar Pistols_g_hDamageMultiplier;

bool  Pistols_g_bEnabled;
bool  Pistols_g_bNotify;
bool  Pistols_g_bDebug;
bool  Pistols_g_bWeaponPistol;
bool  Pistols_g_bWeaponMagnum;
float Pistols_g_flPistolBaseDamage;
float Pistols_g_flPistolMissingHealthFactor;
float Pistols_g_flMagnumUpgradeChance;
float Pistols_g_flMagnumExplosionChance;
float Pistols_g_flMagnumExplosionRadius;
float Pistols_g_flMagnumExplosionDamage;
float Pistols_g_flDamageMultiplier;
int   Pistols_g_iExplosionSprite = 0;

int   Pistols_g_iPendingMagnumTarget[MAXPLAYERS + 1];
int   Pistols_g_iPendingMagnumTargetType[MAXPLAYERS + 1];
float Pistols_g_flPendingMagnumHitTime[MAXPLAYERS + 1];
bool  Pistols_g_bPendingMagnumExplosion[MAXPLAYERS + 1];
bool  Pistols_g_bPendingMagnumHeadshot[MAXPLAYERS + 1];
bool  Pistols_g_bPendingMagnumHasHitPos[MAXPLAYERS + 1];
float Pistols_g_fPendingMagnumHitPos[MAXPLAYERS + 1][3];
bool  Pistols_g_bApplyingPluginDamage[MAXPLAYERS + 1];

public void Pistols_OnPluginStart()
{
    Pistols_CreatePluginConVars();
    Pistols_HookPluginConVars();
    Pistols_RefreshCvarCache();

    // Auto pickup descriptions disabled: use !mwe / !武器 menu instead.
    HookEvent("weapon_fire", Pistols_Event_WeaponFire, EventHookMode_Post);

    Pistols_HookExistingDamageTargets();

    RegAdminCmd("sm_mwe_pistol_info", Pistols_Cmd_Info, ADMFLAG_GENERIC, "Show L4D2 MWE pistols plugin status.");

    // cfg 统一由整合版主入口生成。
}

public void Pistols_OnMapStart()
{
    Pistols_g_iExplosionSprite = PrecacheModel("sprites/zerogxplode.spr", true);
    PrecacheSound(Pistols_SOUND_EXPLOSION, true);
}

public void Pistols_OnConfigsExecuted()
{
    Pistols_RefreshCvarCache();
}

void Pistols_CreatePluginConVars()
{
    Pistols_g_hEnabled = CreateConVar(
        "sm_mwe_pistols_enabled", "1",
        "手枪类插件总开关 / Enable pistols effects plugin.",
        0, true, 0.0, true, 1.0);

    Pistols_g_hNotify = CreateConVar(
        "sm_mwe_pistols_notify", "0",
        "DEPRECATED: pickup pistol notices are disabled; use !mwe / !武器 menu.",
        0, true, 0.0, true, 1.0);

    Pistols_g_hDebug = CreateConVar(
        "sm_mwe_pistols_debug", "0",
        "调试日志开关 / Enable debug logging.",
        0, true, 0.0, true, 1.0);

    Pistols_g_hWeaponPistol = CreateConVar(
        "sm_mwe_pistol_enabled", "1",
        "普通手枪效果开关 / Enable weapon_pistol effects.",
        0, true, 0.0, true, 1.0);

    Pistols_g_hWeaponMagnum = CreateConVar(
        "sm_mwe_magnum_enabled", "1",
        "马格南效果开关 / Enable weapon_pistol_magnum effects.",
        0, true, 0.0, true, 1.0);

    Pistols_g_hPistolBaseDamage = CreateConVar(
        "sm_mwe_pistol_base_damage", "0.0",
        "普通手枪追加伤害公式的基础值 / Base bonus damage for pistol.",
        0, true, 0.0, true, 500.0);

    Pistols_g_hPistolMissingHealthFactor = CreateConVar(
        "sm_mwe_pistol_missing_health_factor", "0.5",
        "普通手枪低血增伤系数，默认为 (100-hp)/2 / Missing health damage factor.",
        0, true, 0.0, true, 5.0);

    Pistols_g_hMagnumUpgradeChance = CreateConVar(
        "sm_mwe_magnum_upgrade_chance", "50.0",
        "马格南击中特感时给予随机特殊弹药概率，不再给予激光 / Magnum random special ammo chance on SI hit; laser sight is disabled.",
        0, true, 0.0, true, 100.0);

    Pistols_g_hMagnumExplosionChance = CreateConVar(
        "sm_mwe_magnum_explosion_chance", "10.0",
        "马格南普通爆炸概率；特感/Tank/Witch 头部命中强制爆炸，普通感染者爆头不强制 / Magnum normal explosion chance; SI/Tank/Witch headshots always explode, common headshots do not force explosion.",
        0, true, 0.0, true, 100.0);

    Pistols_g_hMagnumExplosionRadius = CreateConVar(
        "sm_mwe_magnum_explosion_radius", "180.0",
        "马格南爆炸半径 / Magnum explosion radius.",
        0, true, 0.0, true, 1000.0);

    Pistols_g_hMagnumExplosionDamage = CreateConVar(
        "sm_mwe_magnum_explosion_damage", "80.0",
        "马格南爆炸伤害 / Magnum explosion damage.",
        0, true, 0.0, true, 1000.0);

    Pistols_g_hDamageMultiplier = CreateConVar(
        "sm_mwe_pistols_damage_multiplier", "1.0",
        "手枪类插件所有附加伤害倍率 / Global damage multiplier for this plugin.",
        0, true, 0.0, true, 20.0);
}

void Pistols_HookPluginConVars()
{
    Pistols_g_hEnabled.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hNotify.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hDebug.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hWeaponPistol.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hWeaponMagnum.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hPistolBaseDamage.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hPistolMissingHealthFactor.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hMagnumUpgradeChance.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hMagnumExplosionChance.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hMagnumExplosionRadius.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hMagnumExplosionDamage.AddChangeHook(Pistols_CvarChanged_RefreshCache);
    Pistols_g_hDamageMultiplier.AddChangeHook(Pistols_CvarChanged_RefreshCache);
}

public void Pistols_CvarChanged_RefreshCache(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Pistols_RefreshCvarCache();
}

void Pistols_RefreshCvarCache()
{
    Pistols_g_bEnabled = Pistols_g_hEnabled.BoolValue;
    Pistols_g_bNotify = false; // hard disabled: use !mwe / !武器 menu
    Pistols_g_bDebug = Pistols_g_hDebug.BoolValue;
    Pistols_g_bWeaponPistol = Pistols_g_hWeaponPistol.BoolValue;
    Pistols_g_bWeaponMagnum = Pistols_g_hWeaponMagnum.BoolValue;

    Pistols_g_flPistolBaseDamage = Pistols_g_hPistolBaseDamage.FloatValue;
    Pistols_g_flPistolMissingHealthFactor = Pistols_g_hPistolMissingHealthFactor.FloatValue;

    Pistols_g_flMagnumUpgradeChance = Pistols_g_hMagnumUpgradeChance.FloatValue;
    Pistols_g_flMagnumExplosionChance = Pistols_g_hMagnumExplosionChance.FloatValue;
    Pistols_g_flMagnumExplosionRadius = Pistols_g_hMagnumExplosionRadius.FloatValue;
    Pistols_g_flMagnumExplosionDamage = Pistols_g_hMagnumExplosionDamage.FloatValue;

    Pistols_g_flDamageMultiplier = Pistols_g_hDamageMultiplier.FloatValue;
}

public Action Pistols_Cmd_Info(int client, int args)
{
    ReplyToCommand(client,
        "[MWE Pistols] enabled=%d pistol=%d magnum=%d debug=%d version=%s",
        Pistols_g_bEnabled, Pistols_g_bWeaponPistol, Pistols_g_bWeaponMagnum, Pistols_g_bDebug, Pistols_PLUGIN_VERSION);
    return Plugin_Handled;
}

void Pistols_HookExistingDamageTargets()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_OnTakeDamageAlive, Pistols_SDK_OnTakeDamageAlive);
        }
    }

    Pistols_HookExistingClassname("infected");
    Pistols_HookExistingClassname("witch");
    Pistols_HookExistingClassname("witch_bride");
}

void Pistols_HookExistingClassname(const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (IsValidEntity(entity))
        {
            SDKHook(entity, SDKHook_OnTakeDamageAlive, Pistols_SDK_OnTakeDamageAlive);
        }
    }
}

public void Pistols_OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamageAlive, Pistols_SDK_OnTakeDamageAlive);
}

public void Pistols_OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false) || StrEqual(classname, "witch_bride", false))
    {
        SDKHook(entity, SDKHook_OnTakeDamageAlive, Pistols_SDK_OnTakeDamageAlive);
    }
}

public Action Pistols_OnTraceAttackMagnum(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!Pistols_g_bEnabled || !Pistols_g_bWeaponMagnum || damage <= 0.0)
    {
        return Plugin_Continue;
    }

    if (!Pistols_IsHumanSurvivor(attacker, true))
    {
        return Plugin_Continue;
    }

    if (Pistols_g_bApplyingPluginDamage[attacker])
    {
        return Plugin_Continue;
    }

    if ((damagetype & DMG_BULLET) == 0)
    {
        return Plugin_Continue;
    }

    Pistols_TargetType type = Pistols_Target_GetType(victim);
    if (!Pistols_IsEnemyTarget(type))
    {
        return Plugin_Continue;
    }

    bool headshot = (hitgroup == HITGROUP_HEAD);
    bool forceHeadshotExplosion = headshot && Pistols_IsMagnumForcedHeadshotTarget(type);

    // 这里只缓存“会强制爆炸的爆头”标记。
    // 普通感染者爆头不再强制爆炸，但仍会保留命中目标/位置；若本发按 sm_mwe_magnum_explosion_chance 随机成功，仍在命中点爆炸。
    Pistols_CachePendingMagnumHit(attacker, victim, type, forceHeadshotExplosion);

    if (forceHeadshotExplosion
        && Pistols_g_flMagnumExplosionRadius > 0.0
        && Pistols_g_flMagnumExplosionDamage > 0.0)
    {
        // 特感/Tank/Witch 头部命中强制覆盖开火时的普通爆炸概率结果；即使目标被这一枪击杀，也会在定时器里按缓存命中点爆炸。
        Pistols_g_bPendingMagnumExplosion[attacker] = true;
    }

    Pistols_DebugLog("Magnum trace cache: attacker=%N victim=%d type=%d hitgroup=%d headshot=%d force=%d damage=%.1f", attacker, victim, view_as<int>(type), hitgroup, headshot, forceHeadshotExplosion, damage);
    return Plugin_Continue;
}

public Action Pistols_SDK_OnTakeDamageAlive(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!Pistols_g_bEnabled || damage <= 0.0)
    {
        return Plugin_Continue;
    }

    if (!Pistols_IsHumanSurvivor(attacker, true))
    {
        return Plugin_Continue;
    }

    if (Pistols_g_bApplyingPluginDamage[attacker])
    {
        return Plugin_Continue;
    }

    if ((damagetype & DMG_BULLET) == 0)
    {
        return Plugin_Continue;
    }

    char weapon[64];
    if (!Pistols_GetClientActiveWeaponClass(attacker, weapon, sizeof(weapon)))
    {
        return Plugin_Continue;
    }

    Pistols_TargetType type = Pistols_Target_GetType(victim);

    if (StrEqual(weapon, "weapon_pistol", false))
    {
        if (Pistols_g_bWeaponPistol)
        {
            Pistols_ProcessPistolRealHit(attacker, victim, type);
        }
    }
    else if (StrEqual(weapon, "weapon_pistol_magnum", false))
    {
        if (Pistols_g_bWeaponMagnum && Pistols_IsEnemyTarget(type))
        {
            // OnTakeDamageAlive 没有 hitgroup；如果 TraceAttack 已经记录了爆头，这里不会覆盖爆头标记。
            Pistols_CachePendingMagnumHit(attacker, victim, type, false);
            Pistols_DebugLog("Magnum damage cache: attacker=%N victim=%d type=%d damage=%.1f", attacker, victim, view_as<int>(type), damage);
        }
    }

    return Plugin_Continue;
}



public void Pistols_Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    // Pickup-triggered weapon descriptions are deleted. Use !mwe / !武器 menu only.
    return;
}

public Action Pistols_Timer_ShowWeaponHint(Handle timer, any userid)
{
    // Deleted pickup-description timer.
    return Plugin_Stop;
}

public void Pistols_Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!Pistols_g_bEnabled)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Pistols_IsHumanSurvivor(client, true))
    {
        return;
    }

    char weapon[64];
    if (!MWE_GetCachedActiveWeaponClass(client, weapon, sizeof(weapon)))
    {
        return;
    }

    MWE_RecordWeaponFire(client, weapon);

    if (StrEqual(weapon, "weapon_pistol"))
    {
        if (Pistols_g_bWeaponPistol)
        {
            Pistols_Weapon_Pistol_OnFire(client);
        }
    }
    else if (StrEqual(weapon, "weapon_pistol_magnum"))
    {
        if (Pistols_g_bWeaponMagnum)
        {
            Pistols_Weapon_Magnum_OnFire(client);
        }
    }
}

void Pistols_Weapon_Pistol_OnFire(int client)
{
    // Pistol hit effects are processed from SDKHook_OnTakeDamageAlive.
    // Manual TraceRay here caused visible lead-compensation mismatch on moving enemies.
}



void Pistols_Weapon_Magnum_OnFire(int client)
{
    float now = GetGameTime();
    bool keepFreshTraceHit = Pistols_g_iPendingMagnumTarget[client] > 0
        && now - Pistols_g_flPendingMagnumHitTime[client] <= 0.05;

    // 正常顺序是 weapon_fire 先到；若某些环境下 TraceAttack 先到，不要把刚记录的爆头命中清掉。
    if (!keepFreshTraceHit)
    {
        Pistols_ClearPendingMagnumHit(client);
    }

    bool forceHeadshotExplosion = keepFreshTraceHit && Pistols_g_bPendingMagnumHeadshot[client];

    // 非爆头弹着点按配置概率爆炸；如果本发子弹随后被 TraceAttack 判定为敌人头部命中，会强制覆盖为 true。
    Pistols_g_bPendingMagnumExplosion[client] = (forceHeadshotExplosion || Pistols_Chance(Pistols_g_flMagnumExplosionChance))
        && Pistols_g_flMagnumExplosionRadius > 0.0
        && Pistols_g_flMagnumExplosionDamage > 0.0;

    // Delay lets TraceAttack / SDKHook_OnTakeDamageAlive cache the actual victim of this shot.
    CreateTimer(0.05, Pistols_Timer_ProcessMagnumHitEffect, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}




void Pistols_CachePendingMagnumBulletImpact(int client, float impact[3])
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (!Pistols_g_bPendingMagnumExplosion[client])
    {
        return;
    }

    // bullet_impact 是“子弹最终弹着点”，只适合没有命中敌人时使用。
    // 沙鹰爆头秒杀特感时，TraceAttack 会先缓存死亡前的目标位置；
    // 如果这里再覆盖成 bullet_impact，就会出现爆炸落到穿过尸体后的墙面/终点。
    float now = GetGameTime();
    if (Pistols_g_iPendingMagnumTarget[client] > 0
        && now - Pistols_g_flPendingMagnumHitTime[client] <= Pistols_MAGNUM_HIT_CACHE_TIME)
    {
        Pistols_TargetType cachedType = view_as<Pistols_TargetType>(Pistols_g_iPendingMagnumTargetType[client]);
        if (Pistols_IsEnemyTarget(cachedType) && Pistols_g_bPendingMagnumHasHitPos[client])
        {
            return;
        }
    }

    // 只缓存真实 bullet_impact 弹着点；如果后续 TraceAttack / OnTakeDamage 记录到敌人命中，敌人命中点优先。
    Pistols_g_fPendingMagnumHitPos[client][0] = impact[0];
    Pistols_g_fPendingMagnumHitPos[client][1] = impact[1];
    Pistols_g_fPendingMagnumHitPos[client][2] = impact[2];
    Pistols_g_bPendingMagnumHasHitPos[client] = true;
}

public Action Pistols_Timer_ProcessMagnumHitEffect(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!Pistols_IsHumanSurvivor(client, true) || !Pistols_g_bEnabled || !Pistols_g_bWeaponMagnum)
    {
        return Plugin_Stop;
    }

    int target = -1;
    Pistols_TargetType type = Pistols_Target_Invalid;
    float now = GetGameTime();

    if (Pistols_g_iPendingMagnumTarget[client] > 0
        && now - Pistols_g_flPendingMagnumHitTime[client] <= Pistols_MAGNUM_HIT_CACHE_TIME)
    {
        target = Pistols_g_iPendingMagnumTarget[client];
        type = view_as<Pistols_TargetType>(Pistols_g_iPendingMagnumTargetType[client]);
    }

    if (Pistols_g_bPendingMagnumExplosion[client])
    {
        float origin[3];
        bool haveOrigin = false;

        if (target > 0 && Pistols_IsValidDamageTarget(target))
        {
            Pistols_GetEntityPosition(target, origin);
            haveOrigin = true;
        }
        else if (Pistols_g_bPendingMagnumHasHitPos[client])
        {
            // 目标被本发子弹击杀后，实体可能已经死亡/失效；使用命中时缓存的位置，保证爆头击杀也能爆炸。
            origin[0] = Pistols_g_fPendingMagnumHitPos[client][0];
            origin[1] = Pistols_g_fPendingMagnumHitPos[client][1];
            origin[2] = Pistols_g_fPendingMagnumHitPos[client][2];
            haveOrigin = true;
        }
        else
        {
            // Explosion without a real damage victim still needs a world fallback.
            // This fallback no longer drives hit-based upgrade logic.
            Pistols_TraceResult trace;
            if (Pistols_Trace_FireRay(client, trace))
            {
                origin[0] = trace.hitPos[0];
                origin[1] = trace.hitPos[1];
                origin[2] = trace.hitPos[2];
                haveOrigin = true;
            }
        }

        if (haveOrigin)
        {
            Pistols_CreateExplosionDamage(origin, client, Pistols_g_flMagnumExplosionRadius, Pistols_g_flMagnumExplosionDamage);
            Pistols_DebugLog("Magnum explosion: attacker=%N radius=%.1f damage=%.1f", client, Pistols_g_flMagnumExplosionRadius, Pistols_g_flMagnumExplosionDamage);
        }
    }

    Pistols_g_bPendingMagnumExplosion[client] = false;
    Pistols_ClearPendingMagnumHit(client);

    if (target > 0)
    {
        Pistols_ProcessMagnumHitEffect(client, target, type);
    }

    return Plugin_Stop;
}




void Pistols_ProcessPistolRealHit(int client, int target, Pistols_TargetType type)
{
    if (Pistols_IsEnemyTarget(type))
    {
        int hp = GetClientHealth(client);
        float missing = 100.0 - float(hp);
        if (missing < 0.0)
        {
            missing = 0.0;
        }

        float bonusDamage = Pistols_g_flPistolBaseDamage + missing * Pistols_g_flPistolMissingHealthFactor;
        if (bonusDamage > 0.0)
        {
            Pistols_ApplyDamageSafe(target, bonusDamage, client, DMG_BULLET);
            Pistols_DebugLog("Pistol real-hit bonus damage: attacker=%N target=%d damage=%.1f hp=%d", client, target, bonusDamage, hp);
        }
    }
}

void Pistols_ProcessMagnumHitEffect(int client, int target, Pistols_TargetType type)
{
    if (type == Pistols_Target_SpecialInfected)
    {
        if (Pistols_Chance(Pistols_g_flMagnumUpgradeChance))
        {
            int upgradeType = Pistols_GiveRandomAmmoUpgrade(client);

            Pistols_PrintMagnumUpgradeMessage(client, "命中特感", upgradeType, true);
            Pistols_DebugLog("Magnum random ammo upgrade: attacker=%N target=%d type=%d upgradeType=%d", client, target, view_as<int>(type), upgradeType);
        }
    }
    else if (type == Pistols_Target_Tank || type == Pistols_Target_Witch)
    {
        int upgradeType = Pistols_GiveRandomAmmoUpgrade(client);
        Pistols_PrintMagnumUpgradeMessage(client, "命中 Tank/Witch", upgradeType, true);
        Pistols_DebugLog("Magnum Tank/Witch ammo upgrade: attacker=%N target=%d type=%d upgradeType=%d", client, target, view_as<int>(type), upgradeType);
    }
}


void Pistols_CachePendingMagnumHit(int attacker, int target, Pistols_TargetType type, bool headshot)
{
    if (attacker <= 0 || attacker > MaxClients)
    {
        return;
    }

    float now = GetGameTime();
    bool keepExistingHeadshot = Pistols_g_bPendingMagnumHeadshot[attacker]
        && Pistols_g_iPendingMagnumTarget[attacker] == target
        && now - Pistols_g_flPendingMagnumHitTime[attacker] <= Pistols_MAGNUM_HIT_CACHE_TIME;

    Pistols_g_iPendingMagnumTarget[attacker] = target;
    Pistols_g_iPendingMagnumTargetType[attacker] = view_as<int>(type);
    Pistols_g_flPendingMagnumHitTime[attacker] = now;
    Pistols_g_bPendingMagnumHeadshot[attacker] = headshot || keepExistingHeadshot;

    if (target > 0 && Pistols_IsValidDamageTarget(target))
    {
        Pistols_GetEntityPosition(target, Pistols_g_fPendingMagnumHitPos[attacker]);
        Pistols_g_bPendingMagnumHasHitPos[attacker] = true;
    }
}

void Pistols_ClearPendingMagnumHit(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    Pistols_g_iPendingMagnumTarget[client] = -1;
    Pistols_g_iPendingMagnumTargetType[client] = view_as<int>(Pistols_Target_Invalid);
    Pistols_g_flPendingMagnumHitTime[client] = 0.0;
    Pistols_g_bPendingMagnumHeadshot[client] = false;
    Pistols_g_bPendingMagnumHasHitPos[client] = false;
    Pistols_g_fPendingMagnumHitPos[client][0] = 0.0;
    Pistols_g_fPendingMagnumHitPos[client][1] = 0.0;
    Pistols_g_fPendingMagnumHitPos[client][2] = 0.0;
}


void Pistols_GetEntityPosition(int entity, float pos[3])
{
    if (entity > 0 && entity <= MaxClients && IsClientInGame(entity))
    {
        GetClientAbsOrigin(entity, pos);
        return;
    }

    if (entity > MaxClients && IsValidEntity(entity))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        return;
    }

    pos[0] = 0.0;
    pos[1] = 0.0;
    pos[2] = 0.0;
}

bool Pistols_Trace_FireRay(int client, Pistols_TraceResult result)
{
    float eyePos[3];
    float eyeAngles[3];
    float aimDir[3];

    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAngles);
    GetAngleVectors(eyeAngles, aimDir, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(aimDir, aimDir);

    result.endPos[0] = eyePos[0] + aimDir[0] * Pistols_TRACE_DISTANCE;
    result.endPos[1] = eyePos[1] + aimDir[1] * Pistols_TRACE_DISTANCE;
    result.endPos[2] = eyePos[2] + aimDir[2] * Pistols_TRACE_DISTANCE;

    Handle trace = TR_TraceRayFilterEx(eyePos, result.endPos, MASK_SHOT, RayType_EndPoint, Pistols_TraceFilter_NotSelf, client);
    result.hit = TR_DidHit(trace);
    result.entity = TR_GetEntityIndex(trace);
    TR_GetEndPosition(result.hitPos, trace);
    delete trace;

    if (!result.hit)
    {
        result.hitPos[0] = result.endPos[0];
        result.hitPos[1] = result.endPos[1];
        result.hitPos[2] = result.endPos[2];
        result.entity = -1;
    }

    return result.hit;
}

public bool Pistols_TraceFilter_NotSelf(int entity, int contentsMask, any data)
{
    int client = data;
    if (entity == client)
    {
        return false;
    }
    return true;
}

Pistols_TargetType Pistols_Target_GetType(int entity)
{
    if (entity <= 0)
    {
        return Pistols_Target_Invalid;
    }

    if (entity <= MaxClients)
    {
        if (!IsClientInGame(entity) || !IsPlayerAlive(entity))
        {
            return Pistols_Target_Invalid;
        }

        int team = GetClientTeam(entity);
        if (team == Pistols_TEAM_SURVIVOR)
        {
            return Pistols_Target_Survivor;
        }

        if (team == Pistols_TEAM_INFECTED)
        {
            int zombieClass = 0;
            if (HasEntProp(entity, Prop_Send, "m_zombieClass"))
            {
                zombieClass = GetEntProp(entity, Prop_Send, "m_zombieClass");
            }

            if (zombieClass == Pistols_ZOMBIECLASS_TANK)
            {
                return Pistols_Target_Tank;
            }

            if (zombieClass >= 1 && zombieClass <= 6)
            {
                return Pistols_Target_SpecialInfected;
            }
        }

        return Pistols_Target_Invalid;
    }

    if (!IsValidEntity(entity))
    {
        return Pistols_Target_Invalid;
    }

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (StrEqual(classname, "infected"))
    {
        return Pistols_Target_CommonInfected;
    }

    if (StrEqual(classname, "witch") || StrEqual(classname, "witch_bride"))
    {
        return Pistols_Target_Witch;
    }

    return Pistols_Target_Invalid;
}

bool Pistols_IsEnemyTarget(Pistols_TargetType type)
{
    return type == Pistols_Target_CommonInfected
        || type == Pistols_Target_SpecialInfected
        || type == Pistols_Target_Tank
        || type == Pistols_Target_Witch;
}

bool Pistols_IsMagnumForcedHeadshotTarget(Pistols_TargetType type)
{
    return type == Pistols_Target_SpecialInfected
        || type == Pistols_Target_Tank
        || type == Pistols_Target_Witch;
}

void Pistols_ApplyDamageSafe(int target, float damage, int attacker, int damageType)
{
    if (damage <= 0.0 || !Pistols_IsValidDamageTarget(target) || !Pistols_IsHumanSurvivor(attacker, true))
    {
        return;
    }

    Pistols_TargetType type = Pistols_Target_GetType(target);
    if (!Pistols_IsEnemyTarget(type))
    {
        return;
    }

    int inflictor = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
    if (inflictor <= MaxClients || !IsValidEntity(inflictor))
    {
        inflictor = attacker;
    }

    float finalDamage = damage * Pistols_g_flDamageMultiplier;
    Pistols_g_bApplyingPluginDamage[attacker] = true;
    MWE_SDKHooks_TakeDamage(target, inflictor, attacker, finalDamage, damageType);
    Pistols_g_bApplyingPluginDamage[attacker] = false;
}



bool Pistols_IsValidDamageTarget(int entity)
{
    if (entity <= 0)
    {
        return false;
    }

    if (entity <= MaxClients)
    {
        return IsClientInGame(entity) && IsPlayerAlive(entity);
    }

    return IsValidEntity(entity);
}

void Pistols_CreateExplosionDamage(float origin[3], int attacker, float radius, float damage)
{
    MWE_CreateUnifiedExplosionDamage(origin, attacker, radius, damage, Pistols_g_flDamageMultiplier);
}

void Pistols_ApplyExplosionToClassname(float origin[3], int attacker, float radius, float damage, const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!IsValidEntity(entity))
        {
            continue;
        }

        float pos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        if (MWE_IsWithinRadius(origin, pos, radius))
        {
            Pistols_ApplyDamageSafe(entity, damage, attacker, DMG_BLAST);
        }
    }
}

void Pistols_ShowExplosionEffect(float origin[3], float radius, float damage)
{
    if (Pistols_g_iExplosionSprite > 0)
    {
        TE_SetupExplosion(origin, Pistols_g_iExplosionSprite, 5.0, 1, 0, RoundToNearest(radius), RoundToNearest(damage));
        TE_SendToAll();
    }

    EmitAmbientSound(Pistols_SOUND_EXPLOSION, origin, SOUND_FROM_WORLD, SNDLEVEL_GUNFIRE);
}

bool Pistols_IsHumanSurvivor(int client, bool requireAlive)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    if (GetClientTeam(client) != Pistols_TEAM_SURVIVOR)
    {
        return false;
    }

    if (requireAlive && !IsPlayerAlive(client))
    {
        return false;
    }

    return true;
}

bool Pistols_GetClientActiveWeaponClass(int client, char[] weapon, int maxlen)
{
    weapon[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    int weaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        return false;
    }

    GetEntityClassname(weaponEnt, weapon, maxlen);
    return weapon[0] != '\0';
}

bool Pistols_Chance(float chance)
{
    if (chance <= 0.0)
    {
        return false;
    }

    if (chance >= 100.0)
    {
        return true;
    }

    return GetURandomFloat() * 100.0 < chance;
}

int Pistols_GiveRandomWeaponUpgrade(int client)
{
    // 用户要求取消沙鹰给予激光瞄准器；随机升级只保留燃烧弹/高爆弹。
    return Pistols_GiveRandomAmmoUpgrade(client);
}


int Pistols_GiveRandomAmmoUpgrade(int client)
{
    if (GetRandomInt(0, 1) == 0)
    {
        return Pistols_GiveWeaponUpgradeByType(client, Pistols_UPGRADE_INCENDIARY);
    }

    return Pistols_GiveWeaponUpgradeByType(client, Pistols_UPGRADE_EXPLOSIVE);
}

int Pistols_GiveWeaponUpgradeByType(int client, int upgradeType)
{
    switch (upgradeType)
    {
        case Pistols_UPGRADE_LASER:
        {
            // 用户要求取消沙鹰给予激光瞄准器。
            return Pistols_UPGRADE_NONE;
        }
        case Pistols_UPGRADE_INCENDIARY:
        {
            Pistols_GiveWeaponUpgrade(client, "incendiary_ammo");
            return Pistols_UPGRADE_INCENDIARY;
        }
        case Pistols_UPGRADE_EXPLOSIVE:
        {
            Pistols_GiveWeaponUpgrade(client, "explosive_ammo");
            return Pistols_UPGRADE_EXPLOSIVE;
        }
    }

    return Pistols_UPGRADE_NONE;
}


void Pistols_PrintMagnumUpgradeMessage(int client, const char[] reason, int upgradeType, bool hadLaserBefore)
{
    // 用户要求：运行中不提示任何升级获得消息。
    // Only weapon pickup descriptions are shown in chat.
}


void Pistols_GetUpgradeDisplayName(int upgradeType, char[] buffer, int maxlen)
{
    switch (upgradeType)
    {
        case Pistols_UPGRADE_LASER:
        {
            strcopy(buffer, maxlen, "激光瞄准");
        }
        case Pistols_UPGRADE_INCENDIARY:
        {
            strcopy(buffer, maxlen, "燃烧弹");
        }
        case Pistols_UPGRADE_EXPLOSIVE:
        {
            strcopy(buffer, maxlen, "高爆弹");
        }
        default:
        {
            strcopy(buffer, maxlen, "未知");
        }
    }
}

bool Pistols_PrimaryWeaponHasLaserSight(int client)
{
    if (!Pistols_IsHumanSurvivor(client, false))
    {
        return false;
    }

    int primary = GetPlayerWeaponSlot(client, 0);
    if (primary > MaxClients && IsValidEntity(primary) && HasEntProp(primary, Prop_Send, "m_upgradeBitVec"))
    {
        int primaryUpgradeBits = GetEntProp(primary, Prop_Send, "m_upgradeBitVec");
        if ((primaryUpgradeBits & Pistols_UPGRADE_BIT_LASER) != 0)
        {
            return true;
        }
    }

    // 兼容部分服务器/插件把升级标志挂在玩家实体上的情况。
    // Compatibility fallback for servers/plugins storing upgrade bits on the player entity.
    if (HasEntProp(client, Prop_Send, "m_upgradeBitVec"))
    {
        int playerUpgradeBits = GetEntProp(client, Prop_Send, "m_upgradeBitVec");
        return (playerUpgradeBits & Pistols_UPGRADE_BIT_LASER) != 0;
    }

    return false;
}

void Pistols_GiveWeaponUpgrade(int client, const char[] upgradeName)
{
    if (!Pistols_IsHumanSurvivor(client, true))
    {
        return;
    }

    Pistols_CheatCommand(client, "upgrade_add", upgradeName);
}

void Pistols_CheatCommand(int client, const char[] command, const char[] arguments)
{
    int flags = GetCommandFlags(command);
    bool changedFlags = false;

    if (flags != INVALID_FCVAR_FLAGS && (flags & FCVAR_CHEAT) != 0)
    {
        SetCommandFlags(command, flags & ~FCVAR_CHEAT);
        changedFlags = true;
    }

    FakeClientCommand(client, "%s %s", command, arguments);

    if (changedFlags)
    {
        SetCommandFlags(command, flags);
    }
}

void Pistols_DebugLog(const char[] format, any ...)
{
    if (!Pistols_g_bDebug)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogMessage("[MWE Pistols] %s", buffer);
}


// ============================================================================
// Module: Melee (from l4d2_mwe_melee.sp)
// ============================================================================

/**
 * l4d2_mwe_melee.sp
 *
 * 用法 / Usage:
 * 1. 将本文件放入: left4dead2/addons/sourcemod/scripting/l4d2_mwe_melee.sp
 * 2. 使用 SourceMod 编译器编译: spcomp l4d2_mwe_melee.sp
 * 3. 将生成的 l4d2_mwe_melee.smx 放入: left4dead2/addons/sourcemod/plugins/
 * 4. 启动服务器或执行: sm plugins load l4d2_mwe_melee
 * 5. 本整合版配置统一写入: left4dead2/cfg/sourcemod/l4d2_mwe_all.cfg
 *
 * 简介 / Description:
 * 这是 L4D2 多武器效果项目的“近战类”独立插件。
 * 覆盖 weapon_melee 与 weapon_chainsaw:
 * - 近战: 生命值低于阈值时概率回复实血；极低血时概率触发肾上腺素状态。
 * - 电锯: 攻击时范围治疗生还者；肾上腺素期间攻击会给使用者增加虚血。
 *
 * 设计取向:
 * - 不使用 witch_hurt 等不稳定事件。
 * - weapon_fire + SDKHook_OnTakeDamagePost 双路径触发，兼容 melee/chainsaw 事件差异。
 * - 使用冷却限制避免电锯持续伤害导致治疗刷屏或性能异常。
 */



#define Melee_PLUGIN_VERSION "1.0.0"
#define Melee_TEAM_SURVIVOR 2
#define Melee_WEAPON_MELEE "weapon_melee"
#define Melee_WEAPON_CHAINSAW "weapon_chainsaw"


ConVar Melee_g_hEnabled;
ConVar Melee_g_hShowNotify;
ConVar Melee_g_hDebug;

ConVar Melee_g_hEnableMelee;
ConVar Melee_g_hEnableChainsaw;

ConVar Melee_g_hMeleeHealThreshold;
ConVar Melee_g_hMeleeHealChance;
ConVar Melee_g_hMeleeHealAmount;
ConVar Melee_g_hMeleeAdrenThreshold;
ConVar Melee_g_hMeleeAdrenChance;
ConVar Melee_g_hMeleeAdrenDuration;
ConVar Melee_g_hMeleeCooldown;

ConVar Melee_g_hChainsawHealChance;
ConVar Melee_g_hChainsawHealRadius;
ConVar Melee_g_hChainsawHealAmount;
ConVar Melee_g_hChainsawTempAmount;
ConVar Melee_g_hChainsawCooldown;
ConVar Melee_g_hChainsawIncludeSelf;

ConVar Melee_g_hAdrenSpeedMultiplier;
ConVar Melee_g_hPainPillsDecayRate;

float Melee_g_flNextMeleeProc[MAXPLAYERS + 1];
float Melee_g_flNextChainsawProc[MAXPLAYERS + 1];
float Melee_g_flOurAdrenalineUntil[MAXPLAYERS + 1];
float Melee_g_flOurAdrenalineStart[MAXPLAYERS + 1];

public void Melee_OnPluginStart()
{
    Melee_CreateConVars();

    // Auto pickup descriptions disabled: use !mwe / !武器 menu instead.
    HookEvent("weapon_fire", Melee_Event_WeaponFire, EventHookMode_Post);

    RegAdminCmd("sm_mwe_melee_info", Melee_Cmd_Info, ADMFLAG_GENERIC, "显示近战类多武器效果插件状态");

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            SDKHook(client, SDKHook_OnTakeDamagePost, Melee_OnTakeDamagePost);
        }
    }

    Melee_HookExistingDamageEntities();

    // cfg 统一由整合版主入口生成。
}

public void Melee_OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamagePost, Melee_OnTakeDamagePost);
    Melee_ResetClientState(client);
}

public void Melee_OnClientDisconnect(int client)
{
    Melee_ResetClientState(client);
}

public void Melee_OnMapStart()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        Melee_ResetClientState(client);
    }
}

public void Melee_OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false))
    {
        RequestFrame(Melee_Frame_HookDamageEntity, EntIndexToEntRef(entity));
    }
}

public void Melee_Frame_HookDamageEntity(any ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return;
    }

    SDKHook(entity, SDKHook_OnTakeDamagePost, Melee_OnTakeDamagePost);
}

void Melee_HookExistingDamageEntities()
{
    int maxEntities = GetMaxEntities();
    char classname[64];

    for (int entity = MaxClients + 1; entity <= maxEntities; entity++)
    {
        if (!IsValidEntity(entity))
        {
            continue;
        }

        GetEntityClassname(entity, classname, sizeof(classname));
        if (StrEqual(classname, "infected", false) || StrEqual(classname, "witch", false))
        {
            SDKHook(entity, SDKHook_OnTakeDamagePost, Melee_OnTakeDamagePost);
        }
    }
}

void Melee_CreateConVars()
{
    Melee_g_hEnabled = CreateConVar(
        "sm_mwe_melee_enabled",
        "1",
        "近战类插件总开关 / Master switch for melee-category effects. 1=on, 0=off",
        0,
        true,
        0.0,
        true,
        1.0
    );

    Melee_g_hShowNotify = CreateConVar(
        "sm_mwe_melee_notify",
        "0",
        "DEPRECATED: pickup melee/chainsaw notices are disabled; use !mwe / !武器 menu.",
        0,
        true,
        0.0,
        true,
        1.0
    );

    Melee_g_hDebug = CreateConVar(
        "sm_mwe_melee_debug",
        "0",
        "调试日志开关 / Debug logging. 1=on, 0=off",
        0,
        true,
        0.0,
        true,
        1.0
    );

    Melee_g_hEnableMelee = CreateConVar(
        "sm_mwe_melee_weapon_melee",
        "1",
        "启用 weapon_melee 效果 / Enable weapon_melee effects.",
        0,
        true,
        0.0,
        true,
        1.0
    );

    Melee_g_hEnableChainsaw = CreateConVar(
        "sm_mwe_melee_weapon_chainsaw",
        "1",
        "启用 weapon_chainsaw 效果 / Enable weapon_chainsaw effects.",
        0,
        true,
        0.0,
        true,
        1.0
    );

    Melee_g_hMeleeHealThreshold = CreateConVar(
        "sm_mwe_melee_heal_threshold",
        "40.0",
        "近战实血回复触发总血量阈值 / Total HP threshold for melee real-health heal.",
        0,
        true,
        1.0,
        true,
        100.0
    );

    Melee_g_hMeleeHealChance = CreateConVar(
        "sm_mwe_melee_heal_chance",
        "30",
        "近战低血回复概率 / Chance percent for melee low-HP heal.",
        0,
        true,
        0.0,
        true,
        100.0
    );

    Melee_g_hMeleeHealAmount = CreateConVar(
        "sm_mwe_melee_heal_amount",
        "50",
        "近战低血回复实血量 / Real HP restored by melee low-HP heal.",
        0,
        true,
        1.0,
        true,
        100.0
    );

    Melee_g_hMeleeAdrenThreshold = CreateConVar(
        "sm_mwe_melee_adrenaline_threshold",
        "10.0",
        "近战肾上腺素触发总血量阈值 / Total HP threshold for melee adrenaline.",
        0,
        true,
        1.0,
        true,
        100.0
    );

    Melee_g_hMeleeAdrenChance = CreateConVar(
        "sm_mwe_melee_adrenaline_chance",
        "10",
        "近战极低血肾上腺素概率 / Chance percent for melee low-HP adrenaline.",
        0,
        true,
        0.0,
        true,
        100.0
    );

    Melee_g_hMeleeAdrenDuration = CreateConVar(
        "sm_mwe_melee_adrenaline_duration",
        "5.0",
        "近战触发肾上腺素持续时间 / Duration for melee adrenaline effect.",
        0,
        true,
        0.1,
        true,
        30.0
    );

    Melee_g_hMeleeCooldown = CreateConVar(
        "sm_mwe_melee_cooldown",
        "0.30",
        "近战效果最小触发间隔 / Minimum interval between melee effect checks.",
        0,
        true,
        0.0,
        true,
        5.0
    );

    Melee_g_hChainsawHealChance = CreateConVar(
        "sm_mwe_chainsaw_heal_chance",
        "100",
        "电锯范围治疗概率 / Chance percent for chainsaw area heal.",
        0,
        true,
        0.0,
        true,
        100.0
    );

    Melee_g_hChainsawHealRadius = CreateConVar(
        "sm_mwe_chainsaw_heal_radius",
        "60.0",
        "电锯范围治疗半径 / Chainsaw area heal radius.",
        0,
        true,
        0.0,
        true,
        500.0
    );

    Melee_g_hChainsawHealAmount = CreateConVar(
        "sm_mwe_chainsaw_heal_amount",
        "1",
        "电锯每次范围治疗实血量 / Real HP restored per chainsaw heal tick.",
        0,
        true,
        0.0,
        true,
        25.0
    );

    Melee_g_hChainsawTempAmount = CreateConVar(
        "sm_mwe_chainsaw_adrenaline_temp_amount",
        "1.0",
        "电锯在肾上腺素期间给使用者增加的虚血 / Temp HP granted to chainsaw user while adrenaline is active.",
        0,
        true,
        0.0,
        true,
        25.0
    );

    Melee_g_hChainsawCooldown = CreateConVar(
        "sm_mwe_chainsaw_cooldown",
        "0.35",
        "电锯效果最小触发间隔 / Minimum interval between chainsaw effect ticks.",
        0,
        true,
        0.0,
        true,
        5.0
    );

    Melee_g_hChainsawIncludeSelf = CreateConVar(
        "sm_mwe_chainsaw_include_self",
        "1",
        "电锯范围治疗是否包括使用者 / Include chainsaw user in area heal. 1=on, 0=off",
        0,
        true,
        0.0,
        true,
        1.0
    );

    Melee_g_hAdrenSpeedMultiplier = CreateConVar(
        "sm_mwe_melee_adrenaline_speed",
        "1.20",
        "无 Left4DHooks 时的肾上腺素移动速度模拟倍率 / Fallback speed multiplier for simulated adrenaline.",
        0,
        true,
        1.0,
        true,
        2.0
    );

    Melee_g_hPainPillsDecayRate = FindConVar("pain_pills_decay_rate");
}

public Action Melee_Cmd_Info(int client, int args)
{
    ReplyToCommand(client, "[MWE-Melee] version=%s enabled=%d melee=%d chainsaw=%d", Melee_PLUGIN_VERSION, Melee_g_hEnabled.BoolValue, Melee_g_hEnableMelee.BoolValue, Melee_g_hEnableChainsaw.BoolValue);
    return Plugin_Handled;
}

public void Melee_Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    // Pickup-triggered weapon descriptions are deleted. Use !mwe / !武器 menu only.
    return;
}

public Action Melee_Timer_DelayedPickupNotice(Handle timer, any userid)
{
    // Deleted pickup-description timer.
    return Plugin_Stop;
}

public void Melee_Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!Melee_g_hEnabled.BoolValue)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!Melee_IsHumanSurvivor(client, true))
    {
        return;
    }

    char weapon[64];
    if (!Melee_ResolveWeaponFromEvent(client, event, weapon, sizeof(weapon)))
    {
        return;
    }

    MWE_RecordWeaponFire(client, weapon);

    if (StrEqual(weapon, Melee_WEAPON_MELEE, false))
    {
        Melee_HandleMeleeAttack(client, "weapon_fire");
    }
    else if (StrEqual(weapon, Melee_WEAPON_CHAINSAW, false))
    {
        float center[3];
        GetClientAbsOrigin(client, center);
        Melee_HandleChainsawAttack(client, center, "weapon_fire");
    }
}

public void Melee_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
    if (!Melee_g_hEnabled.BoolValue || damage <= 0.0)
    {
        return;
    }

    if (!Melee_IsHumanSurvivor(attacker, true))
    {
        return;
    }

    char weapon[64];
    if (!Melee_GetClientActiveWeaponClass(attacker, weapon, sizeof(weapon)))
    {
        return;
    }

    if (StrEqual(weapon, Melee_WEAPON_MELEE, false))
    {
        Melee_HandleMeleeAttack(attacker, "damage_post");
    }
    else if (StrEqual(weapon, Melee_WEAPON_CHAINSAW, false))
    {
        float center[3];
        if (!Melee_GetEntityOriginSafe(victim, center))
        {
            GetClientAbsOrigin(attacker, center);
        }
        Melee_HandleChainsawAttack(attacker, center, "damage_post");
    }
}

void Melee_HandleMeleeAttack(int client, const char[] source)
{
    if (!Melee_g_hEnableMelee.BoolValue || !Melee_ConsumeMeleeCooldown(client))
    {
        return;
    }

    float totalHealthBefore = Melee_GetClientTotalHealth(client);

    if (totalHealthBefore < Melee_g_hMeleeAdrenThreshold.FloatValue && Melee_ProbabilityCheck(Melee_g_hMeleeAdrenChance.IntValue))
    {
        Melee_GiveAdrenaline(client, Melee_g_hMeleeAdrenDuration.FloatValue);
        Melee_DebugLog("melee adrenaline: client=%N total_hp=%.1f source=%s", client, totalHealthBefore, source);
    }

    if (totalHealthBefore < Melee_g_hMeleeHealThreshold.FloatValue && Melee_ProbabilityCheck(Melee_g_hMeleeHealChance.IntValue))
    {
        int amount = Melee_g_hMeleeHealAmount.IntValue;
        int healed = Melee_HealRealHealthSafe(client, amount);
        Melee_DebugLog("melee heal: client=%N total_hp=%.1f heal=%d source=%s", client, totalHealthBefore, healed, source);
    }
}

void Melee_HandleChainsawAttack(int client, const float center[3], const char[] source)
{
    if (!Melee_g_hEnableChainsaw.BoolValue || !Melee_ConsumeChainsawCooldown(client))
    {
        return;
    }

    if (Melee_ProbabilityCheck(Melee_g_hChainsawHealChance.IntValue))
    {
        int totalHealed = Melee_HealSurvivorsInRadius(client, center, Melee_g_hChainsawHealRadius.FloatValue, Melee_g_hChainsawHealAmount.IntValue, Melee_g_hChainsawIncludeSelf.BoolValue);
        Melee_DebugLog("chainsaw area heal: client=%N healed_total=%d source=%s", client, totalHealed, source);
    }

    if (Melee_IsAdrenalineActive(client))
    {
        float added = Melee_AddTempHealthSafe(client, Melee_g_hChainsawTempAmount.FloatValue);
        Melee_DebugLog("chainsaw adrenaline temp: client=%N temp_added=%.1f source=%s", client, added, source);
    }
}

bool Melee_ConsumeMeleeCooldown(int client)
{
    float now = GetGameTime();
    if (now < Melee_g_flNextMeleeProc[client])
    {
        return false;
    }

    Melee_g_flNextMeleeProc[client] = now + Melee_g_hMeleeCooldown.FloatValue;
    return true;
}

bool Melee_ConsumeChainsawCooldown(int client)
{
    float now = GetGameTime();
    if (now < Melee_g_flNextChainsawProc[client])
    {
        return false;
    }

    Melee_g_flNextChainsawProc[client] = now + Melee_g_hChainsawCooldown.FloatValue;
    return true;
}

int Melee_HealSurvivorsInRadius(int attacker, const float center[3], float radius, int amount, bool includeSelf)
{
    if (radius <= 0.0 || amount <= 0)
    {
        return 0;
    }

    int totalHealed = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!Melee_IsValidSurvivor(client, true))
        {
            continue;
        }

        if (!includeSelf && client == attacker)
        {
            continue;
        }

        float pos[3];
        GetClientAbsOrigin(client, pos);
        if (!MWE_IsWithinRadius(center, pos, radius))
        {
            continue;
        }

        totalHealed += Melee_HealRealHealthSafe(client, amount);
    }

    return totalHealed;
}

int Melee_HealRealHealthSafe(int client, int amount)
{
    if (!Melee_IsValidSurvivor(client, true) || amount <= 0)
    {
        return 0;
    }

    int health = GetClientHealth(client);
    float tempHealth = Melee_GetClientTempHealth(client);
    int maxRealHealth = RoundToFloor(100.0 - tempHealth);

    if (maxRealHealth > 100)
    {
        maxRealHealth = 100;
    }
    if (maxRealHealth <= health)
    {
        return 0;
    }

    int newHealth = health + amount;
    if (newHealth > maxRealHealth)
    {
        newHealth = maxRealHealth;
    }

    SetEntityHealth(client, newHealth);
    return newHealth - health;
}

float Melee_AddTempHealthSafe(int client, float amount)
{
    if (!Melee_IsValidSurvivor(client, true) || amount <= 0.0)
    {
        return 0.0;
    }

    int health = GetClientHealth(client);
    float currentTemp = Melee_GetClientTempHealth(client);
    float allowed = 100.0 - float(health) - currentTemp;

    if (allowed <= 0.0)
    {
        return 0.0;
    }

    float add = amount;
    if (add > allowed)
    {
        add = allowed;
    }

    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", currentTemp + add);
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
    return add;
}

float Melee_GetClientTotalHealth(int client)
{
    if (!Melee_IsValidSurvivor(client, true))
    {
        return 0.0;
    }

    return float(GetClientHealth(client)) + Melee_GetClientTempHealth(client);
}

float Melee_GetClientTempHealth(int client)
{
    if (!Melee_IsValidSurvivor(client, true))
    {
        return 0.0;
    }

    float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
    if (buffer <= 0.0)
    {
        return 0.0;
    }

    float bufferTime = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
    float decayRate = 0.27;
    if (Melee_g_hPainPillsDecayRate != null)
    {
        decayRate = Melee_g_hPainPillsDecayRate.FloatValue;
    }

    float tempHealth = buffer - ((GetGameTime() - bufferTime) * decayRate);
    if (tempHealth < 0.0)
    {
        tempHealth = 0.0;
    }

    return tempHealth;
}

void Melee_GiveAdrenaline(int client, float duration)
{
    if (!Melee_IsValidSurvivor(client, true) || duration <= 0.0)
    {
        return;
    }

    float now = GetGameTime();
    Melee_g_flOurAdrenalineStart[client] = now;
    Melee_g_flOurAdrenalineUntil[client] = now + duration;

    if (Melee_HasPlayerSendProp("m_bAdrenalineActive"))
    {
        SetEntProp(client, Prop_Send, "m_bAdrenalineActive", 1);
    }
    if (Melee_HasPlayerSendProp("m_flAdrenalineStartTime"))
    {
        SetEntPropFloat(client, Prop_Send, "m_flAdrenalineStartTime", now);
    }
    if (Melee_HasPlayerSendProp("m_flAdrenalineDuration"))
    {
        SetEntPropFloat(client, Prop_Send, "m_flAdrenalineDuration", duration);
    }

    if (Melee_HasPlayerSendProp("m_flLaggedMovementValue"))
    {
        SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", Melee_g_hAdrenSpeedMultiplier.FloatValue);
    }

    CreateTimer(duration, Melee_Timer_EndAdrenalineFallback, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Melee_Timer_EndAdrenalineFallback(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!Melee_IsValidSurvivor(client, true))
    {
        return Plugin_Stop;
    }

    float now = GetGameTime();
    if (Melee_g_flOurAdrenalineUntil[client] > now + 0.05)
    {
        return Plugin_Stop;
    }

    bool canResetAdrenalineFlag = true;
    if (Melee_HasPlayerSendProp("m_flAdrenalineStartTime"))
    {
        float propStart = GetEntPropFloat(client, Prop_Send, "m_flAdrenalineStartTime");
        if (propStart > Melee_g_flOurAdrenalineStart[client] + 0.10)
        {
            canResetAdrenalineFlag = false;
        }
    }

    if (canResetAdrenalineFlag && Melee_HasPlayerSendProp("m_bAdrenalineActive"))
    {
        SetEntProp(client, Prop_Send, "m_bAdrenalineActive", 0);
    }

    if (Melee_HasPlayerSendProp("m_flLaggedMovementValue"))
    {
        SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", 1.0);
    }

    return Plugin_Stop;
}

bool Melee_IsAdrenalineActive(int client)
{
    if (!Melee_IsValidSurvivor(client, true))
    {
        return false;
    }

    if (Melee_g_flOurAdrenalineUntil[client] > GetGameTime())
    {
        return true;
    }

    if (Melee_HasPlayerSendProp("m_bAdrenalineActive") && GetEntProp(client, Prop_Send, "m_bAdrenalineActive") != 0)
    {
        return true;
    }

    if (Melee_HasPlayerSendProp("m_flAdrenalineStartTime") && Melee_HasPlayerSendProp("m_flAdrenalineDuration"))
    {
        float start = GetEntPropFloat(client, Prop_Send, "m_flAdrenalineStartTime");
        float duration = GetEntPropFloat(client, Prop_Send, "m_flAdrenalineDuration");
        if (duration > 0.0 && start + duration > GetGameTime())
        {
            return true;
        }
    }

    return false;
}

bool Melee_ResolveWeaponFromEvent(int client, Event event, char[] weapon, int maxlen)
{
    weapon[0] = '\0';

    if (Melee_GetClientActiveWeaponClass(client, weapon, maxlen))
    {
        if (StrEqual(weapon, Melee_WEAPON_MELEE, false) || StrEqual(weapon, Melee_WEAPON_CHAINSAW, false))
        {
            return true;
        }
    }

    char eventWeapon[64];
    event.GetString("weapon", eventWeapon, sizeof(eventWeapon));

    if (StrEqual(eventWeapon, "melee", false) || StrContains(eventWeapon, "melee", false) != -1)
    {
        strcopy(weapon, maxlen, Melee_WEAPON_MELEE);
        return true;
    }

    if (StrEqual(eventWeapon, "chainsaw", false) || StrContains(eventWeapon, "chainsaw", false) != -1)
    {
        strcopy(weapon, maxlen, Melee_WEAPON_CHAINSAW);
        return true;
    }

    return false;
}

bool Melee_GetClientActiveWeaponClass(int client, char[] weapon, int maxlen)
{
    weapon[0] = '\0';

    if (!Melee_IsValidClientIndex(client) || !IsClientInGame(client))
    {
        return false;
    }

    int weaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weaponEnt <= MaxClients || !IsValidEntity(weaponEnt))
    {
        return false;
    }

    GetEntityClassname(weaponEnt, weapon, maxlen);
    return weapon[0] != '\0';
}

bool Melee_GetEntityOriginSafe(int entity, float origin[3])
{
    if (entity <= 0 || !IsValidEntity(entity))
    {
        return false;
    }

    if (entity <= MaxClients)
    {
        if (!IsClientInGame(entity))
        {
            return false;
        }
        GetClientAbsOrigin(entity, origin);
        return true;
    }

    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    return true;
}

bool Melee_ProbabilityCheck(int chance)
{
    if (chance <= 0)
    {
        return false;
    }
    if (chance >= 100)
    {
        return true;
    }

    return (GetURandomInt() % 100) < chance;
}

bool Melee_IsHumanSurvivor(int client, bool requireAlive)
{
    if (!Melee_IsValidSurvivor(client, requireAlive))
    {
        return false;
    }

    return !IsFakeClient(client);
}

bool Melee_IsValidSurvivor(int client, bool requireAlive)
{
    if (!Melee_IsValidClientIndex(client) || !IsClientInGame(client))
    {
        return false;
    }

    if (GetClientTeam(client) != Melee_TEAM_SURVIVOR)
    {
        return false;
    }

    if (requireAlive && !IsPlayerAlive(client))
    {
        return false;
    }

    return true;
}

bool Melee_IsValidClientIndex(int client)
{
    return client >= 1 && client <= MaxClients;
}

bool Melee_HasPlayerSendProp(const char[] prop)
{
    return FindSendPropInfo("CTerrorPlayer", prop) != -1;
}

void Melee_ResetClientState(int client)
{
    if (!Melee_IsValidClientIndex(client))
    {
        return;
    }

    Melee_g_flNextMeleeProc[client] = 0.0;
    Melee_g_flNextChainsawProc[client] = 0.0;
    Melee_g_flOurAdrenalineUntil[client] = 0.0;
    Melee_g_flOurAdrenalineStart[client] = 0.0;
}

void Melee_DebugLog(const char[] format, any ...)
{
    if (Melee_g_hDebug == null || !Melee_g_hDebug.BoolValue)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogMessage("[MWE-Melee] %s", buffer);
}
