#include <sourcemod>

#include <dhooks>
#include <sdktools>

#include <sxgeo>
#tryinclude <geoip>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = 
{
	name        = "Smart Fast Downloads",
	description = "Routes clients to the closest Fast Download server available",
	author      = "Nolo001",
	url			= "https://github.com/Nolo001-Aha/sourcemod_smart_fastdownloads",
	version     = "1.2"
};

File debugfile;

KeyValues nodeConfig; //main node file

Handle hPlayerSlot;

char originalConVar[256]; //original sv_downloadurl value
char clientIPAddress[64]; //IP of the connecting client

ConVar downloadurl; // sv_downloadurl
ConVar sfd_lookup_method;
ConVar sfd_debug;

bool SxGeoAvailable = false;
#if defined _geoip_included
bool GeoIP2Available = false;
#endif

enum OSType
{
	OS_Unknown = 0,
	OS_Windows,
	OS_Linux
};

OSType os; // Needed for OS-specific pointer fixes

public void OnPluginStart()
{
	PrintToServer("[Smart Fast Downloads] Initializing...");
	
	sfd_lookup_method =  CreateConVar("sfd_lookup", "0", "Which geolocation API should be used? 0 - SxGeo, 1 - GeoIP2 with SourceMod 1.11");
	sfd_debug         =  CreateConVar("sfd_debug", "1", "Enable connection states debug?");

	CheckExtensions();

	char config[PLATFORM_MAX_PATH];
	
	BuildPath(Path_SM, config, sizeof(config), "configs/fastdlmanager.cfg");

	if(!FileExists(config))
		SetFailState("Couldn't find file: %s", config);

	nodeConfig = new KeyValues("FastDL Settings"); // Load the main node config file

	nodeConfig.ImportFromFile(config);

	BuildPath(Path_SM, config, sizeof(config), "fastdl_debug.log");

	if(!FileExists(config))
		SetFailState("Couldn't find file: %s", config);

	debugfile = OpenFile(config, "a+", false);

	checkOS(); //Figure out what OS we're in to apply fixes

	HookConVarChange(sfd_lookup_method, OnConVarChanged);
	AutoExecConfig(true, "SmartFastDownloads");

	processnodeConfigurationFile();
		
	downloadurl = FindConVar("sv_downloadurl"); //Save original downloadurl, so we can send it to clients who we can't locate
	downloadurl.GetString(originalConVar, sizeof(originalConVar));

	GameData gamedatafile = new GameData("betterfastdl.games");

	if(!gamedatafile)
		SetFailState("Cannot load betterfastdl.games.txt! Make sure you have it installed!");

	// CBaseClient::SendServerInfo()
	DynamicDetour detourSendServerInfo = DynamicDetour.FromConf(gamedatafile, "CBaseClient::SendServerInfo()"); 
	
	if(!detourSendServerInfo)
		SetFailState("Failed to setup detour for: CBaseClient::SendServerInfo()");

	detourSendServerInfo.Enable(Hook_Pre, OnSendServerInfo_Pre);

	// Host_BuildConVarUpdateMessage()
	DynamicDetour detourBuildConVarMessage = DynamicDetour.FromConf(gamedatafile, "Host_BuildConVarUpdateMessage()");
	
	if(!detourBuildConVarMessage)
		SetFailState("Failed to setup detour for: Host_BuildConVarUpdateMessage()");
	
	detourBuildConVarMessage.Enable(Hook_Pre, HostBuildConVarUpdateMessage_Pre);
	detourBuildConVarMessage.Enable(Hook_Pre, HostBuildConVarUpdateMessage_Post);

	// CBaseClient::GetPlayerSlot()
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedatafile, SDKConf_Virtual, "CBaseClient::GetPlayerSlot()");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	hPlayerSlot = EndPrepSDKCall();

	if(!hPlayerSlot)
		SetFailState("Failed to setup SDKCall for: CBaseClient::GetPlayerSlot()");

	delete gamedatafile;
}

public void OnConfigsExecuted()
{
	downloadurl = FindConVar("sv_downloadurl");
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

// bool CBaseClient::SendServerInfo( void )
public MRESReturn OnSendServerInfo_Pre(Address pointer, Handle hReturn, Handle hParams) //First callback in chain, derive client and find their IP
{
	if(sfd_debug.BoolValue)
		debugfile.WriteLine("------------------ START SENDING-------------------");

	int client;

	if(os == OS_Windows)
		client = view_as<int>(GetPlayerSlot(pointer + view_as<Address>(0x4))) + 1;
	else
		client = view_as<int>(GetPlayerSlot(pointer)) + 1;

	GetClientIP(client, clientIPAddress, sizeof(clientIPAddress));

	return MRES_Ignored;
}

// void Host_BuildConVarUpdateMessage( NET_SetConVar *cvarMsg, int flags, bool nonDefault )
public MRESReturn HostBuildConVarUpdateMessage_Pre(Handle hParams) //Second callback in chain, call our main function and get a node link in response
{
	char url[256];
	getLocationSettings(url, sizeof(url));

	setConVarValue(url);

	return MRES_Ignored;
}

// void Host_BuildConVarUpdateMessage( NET_SetConVar *cvarMsg, int flags, bool nonDefault )
public MRESReturn HostBuildConVarUpdateMessage_Post(Handle hParams) //Reverts the ConVar to it's original value
{
	setConVarValue("EMPTY");
	if(sfd_debug.BoolValue)
		WriteDebugFile("-------------------- END---------------------");
		
	return MRES_Ignored;
}

void getLocationSettings(char[] link, int size) //Main function
{
	nodeConfig.Rewind();

	float clientLongitude, clientLatitude;

	if(!nodeConfig.JumpToKey("Nodes", false))
		return;

	char nodeURL[256], finalurl[256];
	
	float distance, currentDistance; //1 - distance to the closest server, may change in iterations. 2 - distance between client and current iteration node 
	
	clientLatitude = GetLatitude(clientIPAddress); //clients coordinates
	clientLongitude = GetLongitude(clientIPAddress);

	char section[64];

	nodeConfig.GotoFirstSubKey(false);

	float nodeLongitude, nodeLatitude;

	do
	{
		nodeConfig.GetSectionName(section, sizeof(section));

		nodeLatitude = nodeConfig.GetFloat("latitude");
		nodeLongitude = nodeConfig.GetFloat("longitude");   

		if(!clientLatitude || !clientLongitude)
		{
			if(sfd_debug.BoolValue)
				debugfile.WriteLine("Failed distance calculation. Sending default values. Client(%f %f IP: %s).", clientLatitude, clientLongitude, clientIPAddress);
				
			strcopy(link, 256, "EMPTY");

			return;
		}

		currentDistance = GetDistance(nodeLatitude, nodeLongitude, clientLatitude, clientLongitude);   

		if((currentDistance < distance) || !distance)
		{
			nodeConfig.GetString("link", nodeURL, sizeof(nodeURL), "EMPTY");
			strcopy(finalurl, 256, nodeURL);
			distance = currentDistance;
		}                   
	}
	while(nodeConfig.GotoNextKey(false));
	
	strcopy(link, size, nodeURL);

	if(sfd_debug.BoolValue)
		debugfile.WriteLine("Sending: Distance is %f. Client IP Address: %s", distance, clientIPAddress);
	
}

void setConVarValue(char[] value) // Sets the actual ConVar value
{
	int oldflags = downloadurl.Flags;
	downloadurl.Flags = oldflags &~ FCVAR_REPLICATED;

	if(StrEqual(value, "EMPTY", false))
	{
		downloadurl.SetString(originalConVar, true, false);
		if(sfd_debug.BoolValue)
			debugfile.WriteLine("Default value set.");
	}
	else
	{
		downloadurl.SetString(value, true, false); 
		if(sfd_debug.BoolValue)
			debugfile.WriteLine("New value set.");
	}

	debugfile.Flush();

	downloadurl.Flags = oldflags | FCVAR_REPLICATED;
}



void processnodeConfigurationFile() //Traverse all nodes and save their latitude/longitude in memory
{
	if(!nodeConfig.JumpToKey("Nodes", true))
		return;

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
	} while(nodeConfig.GotoNextKey(false));

	PrintToServer("[Smart Fast Downloads] All nodes processed successfully.");

	nodeConfig.Rewind();

	char config[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, config, sizeof(config), "configs/fastdlmanager.cfg");

	nodeConfig.ExportToFile(config);
}
//self-explanatory stuff
stock void WriteDebugFile(char[] string)
{
	debugfile.WriteLine(string);
	debugfile.Flush();
}

stock Address GetPlayerSlot(Address pointer)
{
	return SDKCall(hPlayerSlot, pointer);
}

stock float GetLatitude(char[] lookupIP)
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

stock float GetLongitude(char[] lookupIP)
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

stock float GetDistance(float nodeLatitude, float nodeLongitude, float clientLatitude, float clientLongitude)
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

stock void CheckExtensions()
{
	SxGeoAvailable = LibraryExists("SxGeo");
	#if defined _geoip_included
	GeoIP2Available = GetFeatureStatus(FeatureType_Native, "GeoipDistance") == FeatureStatus_Available;
	#endif
}

stock void checkOS()
{
	char cmdline[256];
	GetCommandLine(cmdline, sizeof(cmdline));

	if(StrContains(cmdline, "./srcds_linux ", false) != -1)
	{
		os = OS_Linux;
	}
	else if(StrContains(cmdline, ".exe", false) != -1)
	{
		os = OS_Windows;
	}
	else
	{
		os = OS_Unknown;

		SetFailState("Couldn't detect any OS.");
	}
}