Convars.SetValue("survivor_friendly_fire_factor_easy", 0.0)
Convars.SetValue("survivor_friendly_fire_factor_normal", 0.0)
Convars.SetValue("survivor_friendly_fire_factor_hard", 0.0)
Convars.SetValue("survivor_friendly_fire_factor_expert", 0.0)
Convars.SetValue("grenadelauncher_ff_scale", 0.0)
Convars.SetValue("grenadelauncher_ff_scale_self", 0.0)

/*
function OnGameEvent_adrenaline_used( event ) 
{
    local DIO = GetPlayerFromUserID(event.userid)
	if(DIO.GetZombieType() == 9)
    {
		//DIO.GiveItem("weapon_pain_pills"); 
		//DIO.GiveItem("weapon_defibrillator");
		//DIO.GiveItem("weapon_first_aid_kit");
		
    }
}



function OnGameEvent_pills_used(event) 
{
    local DIO0 = GetPlayerFromUserID(event.subject);
    if (DIO0.GetZombieType() == 9) 
	{
		//DIO0.GiveItem("weapon_pain_pills"); 
		//DIO0.GiveItem("weapon_defibrillator");
        //DIO0.GiveItem("weapon_first_aid_kit"); 
    }

}
*/

function OnGameEvent_heal_success( event ) 
{
    local DIO1 = GetPlayerFromUserID(event.userid)
	if(DIO1.GetZombieType() == 9)
    {	
		//DIO1.GiveItem("weapon_pain_pills"); 
		//DIO1.GiveItem("weapon_defibrillator");
		DIO1.GiveItem("weapon_first_aid_kit"); 
    }
}

function OnGameEvent_item_pickup(params)//获得物品
{
	local DIO2 = GetPlayerFromUserID(params.userid);

	if(DIO2.GetZombieType() == 9)
	{	
			if(DIO2.GetActiveWeapon().GetClassname() == "weapon_pistol")///手枪
			{
				DIO2.GiveItem("weapon_pistol");
			}	
		
	}
}

function OnGameEvent_player_jump(params)
{
	local DIO3 = GetPlayerFromUserID(params.userid);
	local mask = DIO3.GetButtonMask();
	if ((mask & 28) == 28)  ///前后蹲跳
	{
		DIO3.GiveItem("weapon_upgradepack_explosive");
		DIO3.GiveItem("weapon_first_aid_kit"); 
		//DIO3.GiveItem("weapon_pain_pills");
		DIO3.GiveItem("weapon_pistol");
		DIO3.GiveItem("weapon_chainsaw");
		DIO3.GiveItem("fireaxe");
		DIO3.GiveItem("crowbar");
		DIO3.GiveItem("weapon_pistol_magnum");
		DIO3.GiveItem("katana");
		DIO3.GiveItem("machete");
		DIO3.GiveItem("knife");
		DIO3.GiveItem("weapon_rifle_sg552");
		DIO3.GiveItem("weapon_autoshotgun");
		DIO3.GiveItem("weapon_hunting_rifle");
		DIO3.GiveItem("weapon_pumpshotgun");
		DIO3.GiveItem("weapon_rifle");
		DIO3.GiveItem("weapon_rifle_desert");
		DIO3.GiveItem("weapon_rifle_m60");
		DIO3.GiveItem("weapon_rifle_sg552");
		DIO3.GiveItem("weapon_shotgun_chrome");
		DIO3.GiveItem("weapon_shotgun_spas");
		DIO3.GiveItem("weapon_smg");
		DIO3.GiveItem("weapon_smg_mp5");
		DIO3.GiveItem("weapon_smg_silenced");
		DIO3.GiveItem("weapon_sniper_awp");
		DIO3.GiveItem("weapon_sniper_military");
		DIO3.GiveItem("weapon_sniper_scout");
		DIO3.GiveItem("weapon_rifle_ak47");
	}

}


function OnGameEvent_weapon_fire(event)///开枪事件
{	
		//全自动开火
		local DIO4 = GetPlayerFromUserID(event.userid);
	    if (!(DIO4 && DIO4.IsValid())) {return;}
		if(DIO4.IsSurvivor() && !IsPlayerABot(DIO4))
		{
			local wep = event["weapon"];
			if(wep == "pistol" || wep == "pistol_magnum" || wep == "pumpshotgun" || wep == "shotgun_chrome" || wep == "autoshotgun" || wep == "shotgun_spas" || wep == "hunting_rifle" || wep == "sniper_military" || wep == "sniper_awp" || wep == "sniper_scout" || wep == "grenade_launcher")
			{
				NetProps.SetPropInt(DIO4.GetActiveWeapon(), "m_isHoldingFireButton", 0);
				//NetProps.SetPropInt(DIO4, "m_afButtonDisabled", NetProps.GetPropInt(DIO4, "m_afButtonDisabled") | 1);
				//DoEntFire("!self", "RunScriptCode", "RestoreFire()", 0, DIO4, DIO4);
			}
		}
		//概率給物品
		if(DIO4.IsSurvivor())
		{
			if(RandomInt(0, 250) <= 1 )
			{
				local inv = {};           // 创建一个空表
				GetInvTable(DIO4, inv); // 填充玩家的物品表

				// 检查 slot2 （投掷物）
				if (!("slot4" in inv))    // 如果 inv 表里没有 slot4，说明玩家没有物品
				{
					DIO4.GiveItem("weapon_pain_pills");  // 给药
				}
			}
			if(RandomInt(0, 500) <= 1 ) // 给肾上腺素
			{
				DIO4.GiveItem("weapon_adrenaline");
			}
			if(RandomInt(0, 100) <= 16 )
			{
				local inv = {};           // 创建一个空表
				GetInvTable(DIO4, inv); // 填充玩家的物品表

				// 检查 slot2 （投掷物）
				if (!("slot2" in inv))    // 如果 inv 表里没有 slot2，说明玩家没有投掷物
				{
					DIO4.GiveItem("weapon_pipe_bomb");  // 给土雷
				}
			}
			if(RandomInt(0, 100) <= 8 )
			{
				local inv = {};          
				GetInvTable(DIO4, inv); 
				if (!("slot2" in inv))   
				{
					DIO4.GiveItem("weapon_vomitjar");  // 给胆汁
				}
			}
			if(RandomInt(0, 100) <= 4 )
			{
				local inv = {};          
				GetInvTable(DIO4, inv); 
				if (!("slot2" in inv))   
				{
					DIO4.GiveItem("weapon_molotov");  // 给燃烧瓶
				}
			}

		}
}


//去除开枪抖动和增强
Msg("Automatic guns script by RF\n");

/*
RF_AUTOGUNS <-
{
	OnGameEvent_weapon_fire = function(event)
	{
	}
}
*/

//::RestoreFire <- function()
//{
//	NetProps.SetPropInt(self, "m_afButtonDisabled", NetProps.GetPropInt(self, "m_afButtonDisabled") & ~1);
//}

__CollectEventCallbacks(RF_AUTOGUNS, "OnGameEvent_", "GameEventCallbacks", RegisterScriptGameEventListener);
