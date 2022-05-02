#include <sourcemod>
#include <dhooks>
#include <sdktools>
#include <sxgeo>
#pragma semicolon 1
#pragma newdecls required


GameData gamedatafile; //Handle to the gamedata
Handle debugfile;

KeyValues nodeConfig; //main node file

char originalConVar[256]; //original sv_downloadurl value
char os[32]; //OS string. Needed for OS-specific pointer fixes
char clientIPAddress[32]; //IP of the connecting client

ConVar downloadurl; // sv_downloadurl ConVar


public Plugin myinfo = 
{
	name        = "Smart Fast Downloads",
	description = "Redirects clients to the best FastDL depending on their location",
	author      = "Nolo001",
	version     = "1.0"
};

public void OnPluginStart()
{
	PrintToServer("[Smart Fast Downloads] Initializing...");
    gamedatafile = LoadGameConfigFile("betterfastdl.games");
    
    if(gamedatafile == null)
        SetFailState("Cannot load betterfastdl.games.txt! Make sure you have it installed!");

    Handle detourSendServerInfo = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
    if(detourSendServerInfo==null)
        SetFailState("Failed to create detour for CBaseClient::SendServerInfo!");
        
    if(!DHookSetFromConf(detourSendServerInfo, gamedatafile, SDKConf_Signature, "CBaseClient::SendServerInfo"))
        SetFailState("Failed to load CBaseClient::SendServerInfo signature from gamedata!");
   
    if(!DHookEnableDetour(detourSendServerInfo, false, sendServerInfoDetCallback_Pre))
        SetFailState("Failed to detour CBaseClient::SendServerInfo PreHook!");

    Handle detourBuildConVarMessage = DHookCreateDetour(Address_Null, CallConv_CDECL, ReturnType_Void, ThisPointer_Ignore);
    if(detourBuildConVarMessage == null)
        SetFailState("Failed to create detour for Host_BuildConVarUpdateMessage!");
    
    if(!DHookSetFromConf(detourBuildConVarMessage, gamedatafile, SDKConf_Signature, "CBaseClient::SendServerInfo"))
    	SetFailState("Failed to load Host_BuildConVarUpdateMessage signature from gamedata!");

	DHookAddParam(detourBuildConVarMessage, HookParamType_Unknown);
	DHookAddParam(detourBuildConVarMessage, HookParamType_Int);
	DHookAddParam(detourBuildConVarMessage, HookParamType_Bool);	
	
    if(!DHookEnableDetour(detourBuildConVarMessage, false, buildConVarMessageDetCallback_Pre))
        SetFailState("Failed to detour Host_BuildConVarUpdateMessage PreHook!");
  
    if(!DHookEnableDetour(detourBuildConVarMessage, true, buildConVarMessageDetCallback_Post))
        SetFailState("Failed to detour Host_BuildConVarUpdateMessage PostHook!");

    nodeConfig = new KeyValues("FastDL Settings"); //Load the main node config file
	char config[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, config, sizeof(config), "configs/fastdlmanager.cfg");
	nodeConfig.ImportFromFile(config);
	nodeConfig.Rewind();
	processnodeConfigurationFile();
	
	BuildPath(Path_SM, config, sizeof(config), "fastdl_debug.log"); //Open debug file
	debugfile = OpenFile(config, "a+", false);
	
	checkOS(); //Figure out what OS we're in to apply fixes
	
	downloadurl = FindConVar("sv_downloadurl"); //Save original downloadurl, so we can send it to clients who we can't locate
	downloadurl.GetString(originalConVar, sizeof(originalConVar));	
}


public void OnConfigsExecuted()
{
	downloadurl = FindConVar("sv_downloadurl"); //Save original downloadurl, so we can send it to clients who we can't locate
	downloadurl.GetString(originalConVar, sizeof(originalConVar));
}


public MRESReturn sendServerInfoDetCallback_Pre(Address pointer, Handle hReturn, Handle hParams) //First callback in chain, derive client and find their IP
{
	WriteFileLine(debugfile, "------------------ START SENDING DATA (Frame %f)-------------------", GetGameTime());

	int client;
	Address pointer2 = pointer + view_as<Address>(0x4);
	if(StrEqual(os, "windows", false))
	{

		client = view_as<int>(GetPlayerSlot(pointer2)) + 1;
	}
	else
	{
		client = view_as<int>(GetPlayerSlot(pointer)) + 1;
	}
	GetClientIP(client, clientIPAddress, sizeof(clientIPAddress));   
	return MRES_Ignored;
}

public MRESReturn buildConVarMessageDetCallback_Pre(Handle hParams) //Second callback in chain, call our main function and get a node link in response
{
	char url[256];
	getLocationSettings(url);
	setConVarValue(url);
	return MRES_Ignored;
}

void getLocationSettings(char[] link) //Main function
{
	nodeConfig.Rewind();
	float clientLongitude, clientLatitude;
	if(nodeConfig.JumpToKey("Nodes", false)) 
	{
		char nodeURL[256], nodeName[64], finalurl[256];
		float distance, currentDistance; //1 - distance to the closest server, may change in iterations. 2 - distance between client and current iteration node	
		clientLatitude = SxGeoLatitude(clientIPAddress); //clients coordinates
		clientLongitude = SxGeoLongitude(clientIPAddress);
		char section[64];
		nodeConfig.GotoFirstSubKey(false);
		do
		{
			float nodeLongitude, nodeLatitude;
			nodeConfig.GetSectionName(section, sizeof(section));
				
					
			nodeLatitude = nodeConfig.GetFloat("latitude");
			nodeLongitude = nodeConfig.GetFloat("longitude");
										
			if(clientLatitude == 0 || clientLongitude == 0 || nodeLatitude == 0 || nodeLongitude == 0)
			{
				WriteFileLine(debugfile, "No coordinates found for node %s. Aborting and sending default values. GPS: %f %f %f %f", nodeName, clientLatitude, clientLongitude, nodeLatitude, nodeLongitude);
				strcopy(link, 256, "EMPTY");
				return;
			}
			currentDistance = SxGeoDistance(nodeLatitude, nodeLongitude, clientLatitude, clientLongitude);	
			if((currentDistance < distance) || distance == 0)
			{
				nodeConfig.GetString("link", nodeURL, sizeof(nodeURL), "EMPTY");
				strcopy(finalurl, 256, nodeURL);
				distance = currentDistance;
			}					
		}
		while(nodeConfig.GotoNextKey(false));
		strcopy(link, 256, nodeURL);
		WriteFileLine(debugfile, "Sending: Distance is %f. Client IP Address: %s",  finalurl, distance, clientIPAddress);	
	}
	
}

void setConVarValue(char[] value) //Sets the actual ConVar value
{
	int oldflags = GetConVarFlags(downloadurl);
	SetConVarFlags(downloadurl, oldflags &~ FCVAR_REPLICATED);
	if (StrEqual(value, "EMPTY", false))
	{
		SetConVarString(downloadurl, originalConVar, true, false);	
		WriteFileLine(debugfile, "Sending old value %s", originalConVar);
	}
	else
	{
		SetConVarString(downloadurl, value, true, false);	
		WriteFileLine(debugfile, "Sending new value %s", value);
	}
	FlushFile(debugfile);
	SetConVarFlags(downloadurl, oldflags|FCVAR_REPLICATED);
}

public MRESReturn buildConVarMessageDetCallback_Post(Handle hParams) //Reverts the ConVar to it's original value
{
	setConVarValue("EMPTY");
	WriteFileLine(debugfile, "-------------------- END OF DATA (Frame %f)---------------------", GetGameTime());	
	return MRES_Ignored;
}

void processnodeConfigurationFile() //Traverse all nodes and save their latitude/longitude in memory
{
	if(nodeConfig.JumpToKey("Nodes", true))
	{
			char section[64], nodeclientIPAddress[64];
			nodeConfig.GotoFirstSubKey(false);	
			do
			{
				nodeConfig.GetSectionName(section, sizeof(section));
				nodeConfig.GetString("ip", nodeclientIPAddress, sizeof(nodeclientIPAddress));
				float nodeLatitude = SxGeoLatitude(nodeclientIPAddress);
				float nodeLongitude = SxGeoLongitude(nodeclientIPAddress);
				nodeConfig.SetFloat("latitude", nodeLatitude);	
				nodeConfig.SetFloat("longitude", nodeLongitude);	
				PrintToServer("[Smart Fast Downloads] Processed GPS location of node \"%s\".", section);
			}
			while(nodeConfig.GotoNextKey(false));
			PrintToServer("[Smart Fast Downloads] All nodes processed successfully.");
			nodeConfig.Rewind();
			char config[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, config, sizeof(config), "configs/fastdlmanager.cfg");
			nodeConfig.ExportToFile(config);
	}
}
//TempEnts
any GetPlayerSlot(Address pIClient)
{
    static Handle hPlayerSlot = INVALID_HANDLE;
    if (hPlayerSlot == INVALID_HANDLE)
    {
        StartPrepSDKCall(SDKCall_Raw);
        PrepSDKCall_SetFromConf(gamedatafile, SDKConf_Virtual, "CBaseClient::GetPlayerSlot");
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        hPlayerSlot = EndPrepSDKCall();
    }

    return SDKCall(hPlayerSlot, pIClient);
}
// TempEnts
void checkOS()
{
    char cmdline[256];
    GetCommandLine(cmdline, sizeof(cmdline));

    if (StrContains(cmdline, "./srcds_linux ", false) != -1)
    {
        os = "linux";
    }
    else if (StrContains(cmdline, ".exe", false) != -1)
    {
        os = "windows";
    }
    else
    {
        os = "unknown";
    }
}