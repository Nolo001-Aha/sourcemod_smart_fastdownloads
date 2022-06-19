#include <sourcemod>
#include <dhooks>
#include <sdktools>
#include <sxgeo>
#tryinclude <geoip>

#pragma semicolon 1
#pragma newdecls required

GameData gamedatafile; //Handle to the gamedata
Handle debugfile;
Handle hPlayerSlot = INVALID_HANDLE;
KeyValues nodeConfig; //main node file

char originalConVar[256]; //original sv_downloadurl value
char clientIPAddress[64]; //IP of the connecting client

ConVar downloadurl; // sv_downloadurl
ConVar sfd_lookup_method;
ConVar sfd_debug;

bool SxGeoAvailable = false;
#if defined _geoip_included
bool GeoIP2Available = false;
#endif

enum OSType{
	OS_Linux = 0,
	OS_Windows,
	OS_Unknown
}

OSType os; //Needed for OS-specific pointer fixes

public Plugin myinfo = 
{
	name        = "Smart Fast Downloads",
	description = "Routes clients to the closest Fast Download server available",
	author      = "Nolo001",
	url			= "https://github.com/Nolo001-Aha/sourcemod_smart_fastdownloads",
	version     = "1.1"
};

public void OnPluginStart()
{
	PrintToServer("[Smart Fast Downloads] Initializing...");
	CheckExtensions();
	sfd_lookup_method = CreateConVar("sfd_lookup", "0", "Which geolocation API should be used? 0 - SxGeo, 1 - GeoIP2 with SourceMod 1.11");
	sfd_debug = CreateConVar("sfd_debug", "1", "Enable connection states debug?");
	gamedatafile = LoadGameConfigFile("betterfastdl.games");
	
	if(gamedatafile == null)
		SetFailState("Cannot load betterfastdl.games.txt! Make sure you have it installed!");

	Handle detourSendServerInfo = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
	if(detourSendServerInfo == null)
		SetFailState("Failed to create detour for CBaseClient::SendServerInfo!");
		
	if(!DHookSetFromConf(detourSendServerInfo, gamedatafile, SDKConf_Signature, "CBaseClient::SendServerInfo"))
		SetFailState("Failed to load CBaseClient::SendServerInfo signature from gamedata!");
   
	if(!DHookEnableDetour(detourSendServerInfo, false, sendServerInfoDetCallback_Pre))
		SetFailState("Failed to detour CBaseClient::SendServerInfo PreHook!");

	Handle detourBuildConVarMessage = DHookCreateDetour(Address_Null, CallConv_CDECL, ReturnType_Void, ThisPointer_Ignore);
	if(detourBuildConVarMessage == null)
		SetFailState("Failed to create detour for Host_BuildConVarUpdateMessage!");
	
	if(!DHookSetFromConf(detourBuildConVarMessage, gamedatafile, SDKConf_Signature, "Host_BuildConVarUpdateMessage"))
		SetFailState("Failed to load Host_BuildConVarUpdateMessage signature from gamedata!");

	DHookAddParam(detourBuildConVarMessage, HookParamType_Unknown);
	DHookAddParam(detourBuildConVarMessage, HookParamType_Int);
	DHookAddParam(detourBuildConVarMessage, HookParamType_Bool);    
	
	if(!DHookEnableDetour(detourBuildConVarMessage, false, buildConVarMessageDetCallback_Pre))
		SetFailState("Failed to detour Host_BuildConVarUpdateMessage PreHook!");
  
	if(!DHookEnableDetour(detourBuildConVarMessage, true, buildConVarMessageDetCallback_Post))
		SetFailState("Failed to detour Host_BuildConVarUpdateMessage PostHook!");
		
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedatafile, SDKConf_Virtual, "CBaseClient::GetPlayerSlot");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	hPlayerSlot = EndPrepSDKCall();

	nodeConfig = new KeyValues("FastDL Settings"); //Load the main node config file
	char config[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, config, sizeof(config), "configs/fastdlmanager.cfg");
	nodeConfig.ImportFromFile(config);
	nodeConfig.Rewind();
	processnodeConfigurationFile();
	
	BuildPath(Path_SM, config, sizeof(config), "fastdl_debug.log");
	debugfile = OpenFile(config, "a+", false);
	
	checkOS(); //Figure out what OS we're in to apply fixes

	HookConVarChange(sfd_lookup_method, OnConVarChanged);
	AutoExecConfig(true, "SmartFastDownloads");
		
	downloadurl = FindConVar("sv_downloadurl"); //Save original downloadurl, so we can send it to clients who we can't locate
	downloadurl.GetString(originalConVar, sizeof(originalConVar));  
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if(strcmp(newValue, "1") && !SxGeoAvailable)
	{
		LogError("[Smart Fast Downloads] Attempted to switch to SxGeo extension without it being loaded. Reverting.");
		sfd_lookup_method.SetString("1");
	}
	#if defined _geoip_included
	if(strcmp(newValue, "0") && !GeoIP2Available)
	#else
	if(strcmp(newValue, "0"))
	#endif
	{
		LogError("[Smart Fast Downloads] Attempted to switch to GeoIP2 (SM 1.11) when the plugin was compiled without it or the extension is not loaded. Reverting.");
		sfd_lookup_method.SetString("0");
	}
	
}

public void OnConfigsExecuted()
{
	downloadurl = FindConVar("sv_downloadurl");
	downloadurl.GetString(originalConVar, sizeof(originalConVar));
}

public MRESReturn sendServerInfoDetCallback_Pre(Address pointer, Handle hReturn, Handle hParams) //First callback in chain, derive client and find their IP
{
	if(sfd_debug.BoolValue)
		WriteFileLine(debugfile, "------------------ START SENDING-------------------");
		
	int client;
	Address pointer2 = pointer + view_as<Address>(0x4);
	if(os == OS_Windows)
	{

		client = view_as<int>(SDKCall(hPlayerSlot, pointer2)) + 1;
	}
	else
	{
		client = view_as<int>(SDKCall(hPlayerSlot, pointer)) + 1;
	}
	GetClientIP(client, clientIPAddress, sizeof(clientIPAddress));
	return MRES_Ignored;
}

public MRESReturn buildConVarMessageDetCallback_Pre(Handle hParams) //Second callback in chain, call our main function and get a node link in response
{
	char url[256];
	getLocationSettings(url, sizeof(url));
	setConVarValue(url);
	return MRES_Ignored;
}

void getLocationSettings(char[] link, int size) //Main function
{
	nodeConfig.Rewind();
	float clientLongitude, clientLatitude;
	if(nodeConfig.JumpToKey("Nodes", false)) 
	{
		char nodeURL[256], finalurl[256];
		float distance, currentDistance; //1 - distance to the closest server, may change in iterations. 2 - distance between client and current iteration node 
		clientLatitude = GetLatitude(clientIPAddress); //clients coordinates
		clientLongitude = GetLongitude(clientIPAddress);
		char section[64];
		nodeConfig.GotoFirstSubKey(false);
		do
		{
			float nodeLongitude, nodeLatitude;
			nodeConfig.GetSectionName(section, sizeof(section));
			nodeLatitude = nodeConfig.GetFloat("latitude");
			nodeLongitude = nodeConfig.GetFloat("longitude");             
			if(clientLatitude == 0 || clientLongitude == 0)
			{
				if(sfd_debug.BoolValue)
					WriteFileLine(debugfile, "Failed distance calculation. Sending default values. Client(%f %f IP: %s).", clientLatitude, clientLongitude, clientIPAddress);
					
				strcopy(link, 256, "EMPTY");
				return;
			}
			currentDistance = GetDistance(nodeLatitude, nodeLongitude, clientLatitude, clientLongitude);    
			if((currentDistance < distance) || distance == 0)
			{
				nodeConfig.GetString("link", nodeURL, sizeof(nodeURL), "EMPTY");
				strcopy(finalurl, 256, nodeURL);
				distance = currentDistance;
			}                   
		}
		while(nodeConfig.GotoNextKey(false));
		strcopy(link, size, nodeURL);
		if(sfd_debug.BoolValue)
			WriteFileLine(debugfile, "Sending: Distance is %f. Client IP Address: %s", distance, clientIPAddress);  
	}
	
}

void setConVarValue(char[] value) //Sets the actual ConVar value
{
	int oldflags = GetConVarFlags(downloadurl);
	SetConVarFlags(downloadurl, oldflags &~ FCVAR_REPLICATED);
	if (StrEqual(value, "EMPTY", false))
	{
		SetConVarString(downloadurl, originalConVar, true, false);
		if(sfd_debug.BoolValue)
			WriteFileLine(debugfile, "Default value set.");
	}
	else
	{
		SetConVarString(downloadurl, value, true, false); 
		if(sfd_debug.BoolValue)
			WriteFileLine(debugfile, "New value set.");
	}
	FlushFile(debugfile);
	SetConVarFlags(downloadurl, oldflags|FCVAR_REPLICATED);
}

public MRESReturn buildConVarMessageDetCallback_Post(Handle hParams) //Reverts the ConVar to it's original value
{
	setConVarValue("EMPTY");
	if(sfd_debug.BoolValue)
		WriteDebugFile("-------------------- END---------------------"); 
		
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
				float nodeLatitude = GetLatitude(nodeclientIPAddress);
				float nodeLongitude = GetLongitude(nodeclientIPAddress);
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
//self-explanatory stuff
void WriteDebugFile(char[] string)
{
	WriteFileLine(debugfile, string);
	FlushFile(debugfile);
}

float GetLatitude(char[] lookupIP)
{
	#if defined _geoip_included
	if(!sfd_lookup_method.BoolValue)
		return SxGeoLatitude(lookupIP);
	else
		return GeoipLatitude(lookupIP);
	#else
	return SxGeoLatitude(lookupIP);
	#endif
}

float GetLongitude(char[] lookupIP)
{
	#if defined _geoip_included
	if(!sfd_lookup_method.BoolValue)
		return SxGeoLongitude(lookupIP);
	else
		return GeoipLongitude(lookupIP);  
	#else
	return SxGeoLongitude(lookupIP);
	#endif
}

float GetDistance(float nodeLatitude, float nodeLongitude, float clientLatitude, float clientLongitude)
{
	#if defined _geoip_included
	if(!sfd_lookup_method.BoolValue)
		return SxGeoDistance(nodeLatitude,  nodeLongitude,  clientLatitude, clientLongitude);
	else
		return GeoipDistance(nodeLatitude,  nodeLongitude,  clientLatitude, clientLongitude);  
	#else
	return SxGeoDistance(nodeLatitude,  nodeLongitude,  clientLatitude, clientLongitude);
	#endif
}

void CheckExtensions()
{
	SxGeoAvailable = LibraryExists("SxGeo");
	#if defined _geoip_included
	GeoIP2Available = GetFeatureStatus(FeatureType_Native, "GeoipDistance") == FeatureStatus_Available;
	#endif
}

void checkOS()
{
	char cmdline[256];
	GetCommandLine(cmdline, sizeof(cmdline));

	if (StrContains(cmdline, "./srcds_linux ", false) != -1)
	{
		os = OS_Linux;
	}
	else if (StrContains(cmdline, ".exe", false) != -1)
	{
		os = OS_Windows;
	}
	else
	{
		os = OS_Unknown;
	}
}
