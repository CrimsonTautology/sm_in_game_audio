/**
 * vim: set ts=4 :
 * =============================================================================
 * in_game_audio
 * TODO - Add your project's description
 *
 * Copyright 2013 ???
 * =============================================================================
 *
 */


#pragma semicolon 1

#include <sourcemod>
#include <clientprefs>
#include <steamtools>
#include <base64>
#include <smjansson>
#undef REQUIRE_PLUGIN
#include <donator>

#define PLUGIN_VERSION "0.1"

public Plugin:myinfo =
{
    name = "In Game Audio",
    author = "CrimsonTautology",
    description = "Interact with the In Game Audio web api",
    version = PLUGIN_VERSION,
    url = "https://github.com/CrimsonTautology/sm_in_game_audio"
};

#define QUERY_SONG_ROUTE "/v1/api/query_song"
#define MAP_THEME_ROUTE "/v1/api/map_theme"
#define USER_THEME_ROUTE "/v1/api/user_theme"
#define AUTHORIZE_USER_ROUTE "/v1/api/authorize_user"
#define SONGS_ROUTE "/songs"
#define DIRECTORIES_ROUTE "/directories"

#define MAX_STEAMID_LENGTH 21 
#define MAX_COMMUNITYID_LENGTH 18 
#define MAX_SONG_LENGTH 64

new Handle:g_Cvar_IGAApiKey = INVALID_HANDLE;
new Handle:g_Cvar_IGAUrl = INVALID_HANDLE;
new Handle:g_Cvar_IGADonatorsOnly = INVALID_HANDLE;
new Handle:g_Cvar_IGAEnabled = INVALID_HANDLE;
new Handle:g_Cvar_IGARequestCooldownTime = INVALID_HANDLE;

new Handle:g_Cookie_PallEnabled = INVALID_HANDLE;
new Handle:g_Cookie_Volume = INVALID_HANDLE;

new bool:g_IsInCooldown[MAXPLAYERS+1];
new bool:g_IsPallEnabled[MAXPLAYERS+1];
new bool:g_IsDonator[MAXPLAYERS+1];
new String:g_CurrentPallDescription[64];
new String:g_CurrentPallPath[64];
new String:g_CurrentPlastSongId[64];
new g_PNextFree[MAXPLAYERS+1];
new g_PallNextFree = 0;
new g_Volume[MAXPLAYERS+1];

new bool:g_DonatorLibrary = false;
public OnPluginStart()
{
    
    g_Cvar_IGAApiKey = CreateConVar("sm_iga_api_key", "", "API Key for your IGA webpage");
    g_Cvar_IGAUrl = CreateConVar("sm_iga_url", "", "URL to your IGA webpage");
    g_Cvar_IGADonatorsOnly = CreateConVar("sm_iga_donators_only", "1", "Whether or not only donators have access to pall");
    g_Cvar_IGAEnabled = CreateConVar("sm_iga_enabled", "1", "Whether or not pall is enabled");
    g_Cvar_IGARequestCooldownTime = CreateConVar("sm_iga_request_cooldown_time", "2.0", "How long in seconds before a client can send another http request");
    
    RegConsoleCmd("sm_p", Command_P, "Play a song for yourself");
    RegConsoleCmd("sm_pall", Command_Pall, "Play a song for everyone");
    RegConsoleCmd("sm_plist", Command_Plist, "Pop-up the song list");
    RegConsoleCmd("sm_stop", Command_Stop, "Stop the current song");
    RegAdminCmd("sm_fstop", Command_Fstop, ADMFLAG_VOTE, "[ADMIN] Stop the current pall for everyone");
    RegAdminCmd("sm_fpall", Command_Fpall, ADMFLAG_VOTE, "[ADMIN] Force everyone to listen to a song");
    RegConsoleCmd("sm_vol", Command_Vol, "Adjust your play volume");
    RegConsoleCmd("sm_nopall", Command_Nopall, "Turn off pall for yourself");
    RegConsoleCmd("sm_yespall", Command_Yespall, "Turn on pall for yourself");
    RegConsoleCmd("sm_plast", Command_Plast, "Play the last played song for yourself");
    RegConsoleCmd("sm_authorize_iga", Command_AuthorizeIGA, "Declare that you want to upload songs to the website.  This will set you as an uploader.");

    g_Cookie_Volume = RegClientCookie("iga_volume", "Volume to play at [0-10]; 0 muted, 10 loudest", CookieAccess_Private);
    g_Cookie_PallEnabled = RegClientCookie("iga_pall_enabled", "Whether you want pall enabled or not. If yes, you will hear music when other players call !pall", CookieAccess_Private);

    g_DonatorLibrary = LibraryExists("donators");
    
    HookEvent("teamplay_game_over", Event_MapChange);
    //TODO hook pre-rtv map change
    //HookEvent("map_change", Event_MapChange);
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "donators"))
	{
		g_DonatorLibrary = false;
	}
}
 
public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "donators"))
	{
		g_DonatorLibrary = true;
	}
}

public OnClientConnected(client)
{
    g_IsInCooldown[client] = false;
    g_PNextFree[client] = 0;
    g_Volume[client] = 10;
    g_IsPallEnabled[client] = true;

}
public OnClientCookiesCached(client)
{
    new String:buffer[11];

    GetClientCookie(client, g_Cookie_Volume, buffer, sizeof(buffer));
    if (strlen(buffer) > 0){
        g_Volume[client] = StringToInt(buffer);
    }

    GetClientCookie(client, g_Cookie_PallEnabled, buffer, sizeof(buffer));
    if (strlen(buffer) > 0){
        g_IsPallEnabled[client] = bool:StringToInt(buffer);
    }

    if (DonatorCheck(client)){
        UserTheme(client);
    }
}

public OnPostDonatorCheck(client)
{
    g_IsDonator[client] = true;
}

public OnClientDisconnect(client)
{
    g_IsDonator[client] = false;
}


public Action:Command_P(client, args)
{
    if(IsClientInCooldown(client))
    {
        ReplyToCommand(client, "[IGA] User in cooldown.");
        return Plugin_Handled;
    }

    if(!GetConVarBool(g_Cvar_IGAEnabled))
    {
        ReplyToCommand(client, "[IGA] IGA not enabled.");
        return Plugin_Handled;
    }

    if(client && IsClientAuthorized(client)){
        decl String:path[MAX_SONG_LENGTH];
        GetCmdArgString(path, sizeof(path));
        QuerySong(client, path, false);
    }

    return Plugin_Handled;
}

public Action:Command_Pall(client, args)
{
    if(IsClientInCooldown(client))
    {
        ReplyToCommand(client, "[IGA] User in cooldown.");
        return Plugin_Handled;
    }

    if(!GetConVarBool(g_Cvar_IGAEnabled))
    {
        ReplyToCommand(client, "[IGA] IGA not enabled.");
        return Plugin_Handled;
    }

    if(!DonatorCheck(client))
    {
        ReplyToCommand(client, "[IGA] Only donators can use this command.");
        return Plugin_Handled;
    }

    if(client && IsClientAuthorized(client)){
        decl String:path[MAX_SONG_LENGTH];
        GetCmdArgString(path, sizeof(path));
        QuerySong(client, path, true);
    }

    return Plugin_Handled;
}

public Action:Command_Plist(client, args)
{
    if(client && IsClientAuthorized(client)){
        SongList(client);
    }

    return Plugin_Handled;
}

public Action:Command_Stop(client, args)
{
    StopSong(client);
    return Plugin_Handled;
}

public Action:Command_Fstop(client, args)
{
    StopSongAll();
    return Plugin_Handled;
}

public Action:Command_Fpall(client, args)
{
    if(client && IsClientAuthorized(client)){
        decl String:path[MAX_SONG_LENGTH];
        GetCmdArgString(path, sizeof(path));
        QuerySong(client, path, true, true);
    }

    return Plugin_Handled;
}

public Action:Command_Vol(client, args)
{
    if (client && args != 1)
    {
        ReplyToCommand(client, "[IGA] usage \"!vol [0-10]\".  Currently %d.", g_Volume[client]);
        return Plugin_Handled;
    }

    if(client && IsClientAuthorized(client))
    {
        decl String:buffer[11];
        new volume;
        GetCmdArgString(buffer, sizeof(buffer));
        volume = StringToInt(buffer);
        if (volume >=0 && volume <= 10)
        {
            SetClientCookie(client, g_Cookie_Volume, buffer);
            g_Volume[client] = volume;
            ReplyToCommand(client, "[IGA] Set volume to %d.", volume);
        }else{
            ReplyToCommand(client, "[IGA] usage \"!vol [0-10]\".");
        }
    }

    return Plugin_Handled;
}

public Action:Command_Nopall(client, args)
{
    if (client && IsClientAuthorized(client))
    {
        SetClientCookie(client, g_Cookie_PallEnabled, "0");
        g_IsPallEnabled[client] = false;
        ReplyToCommand(client, "[IGA] Disabled pall.  Type !yespall to renable it.");
    }
    return Plugin_Handled;
}

public Action:Command_Yespall(client, args)
{
    if (client && IsClientAuthorized(client))
    {
        SetClientCookie(client, g_Cookie_PallEnabled, "1");
        g_IsPallEnabled[client] = true;
        ReplyToCommand(client, "[IGA] Enabled pall.  Type !nopall to disable it.");
    }
    return Plugin_Handled;
}

public Action:Command_Plast(client, args)
{
    if (client && IsClientAuthorized(client))
    {
        PlaySong(client, g_CurrentPlastSongId);
    }
    return Plugin_Handled;
}

public Action:Command_AuthorizeIGA(client, args)
{
    if (client && IsClientAuthorized(client))
    {
        AuthorizeUser(client);
    }
    return Plugin_Handled;
}


public Action:Event_MapChange(Handle:event, const String:name[], bool:dontBroadcast)
{
    //TODO get current map
    MapTheme("current_map");
    return Plugin_Continue;
}

public Steam_SetHTTPRequestGetOrPostParameterInt(&HTTPRequestHandle:request, const String:param[], value)
{
    new String:tmp[64];
    IntToString(value, tmp, sizeof(tmp));
    Steam_SetHTTPRequestGetOrPostParameter(request, param, tmp);
}

public SetAccessCode(&HTTPRequestHandle:request)
{
    decl String:api_key[128];
    GetConVarString(g_Cvar_IGAApiKey, api_key, sizeof(api_key));
    Steam_SetHTTPRequestGetOrPostParameter(request, "access_token", api_key);
}

public HTTPRequestHandle:CreateIGARequest(const String:route[])
{
    decl String:base_url[256], String:url[512];
    GetConVarString(g_Cvar_IGAUrl, base_url, sizeof(base_url));
    TrimString(base_url);
    new trim_length = strlen(base_url) - 1;

    if(trim_length < 0)
    {
        //IGA Url not set
        return INVALID_HTTP_HANDLE;
    }

    //check for forward slash after base_url;
    if(base_url[trim_length] == '/')
    {
        strcopy(base_url, trim_length + 1, base_url);
    }

    Format(url, sizeof(url),
            "%s%s", base_url, route);

    new HTTPRequestHandle:request = Steam_CreateHTTPRequest(HTTPMethod_POST, url);
    SetAccessCode(request);

    return request;
}

public StartCooldown(client)
{
    //Ignore the server console
    if (client == 0)
        return;

    g_IsInCooldown[client] = true;
    CreateTimer(GetConVarFloat(g_Cvar_IGARequestCooldownTime), RemoveCooldown, client);
}

public bool:IsClientInCooldown(client)
{
    if(client == 0)
        return false;
    else
        return g_IsInCooldown[client];
}

public Action:RemoveCooldown(Handle:timer, any:client)
{
    g_IsInCooldown[client] = false;
}

public bool:IsInPall()
{
    return GetTime() < g_PallNextFree;
}
public bool:IsInP(client)
{
    return GetTime() < g_PNextFree[client];
}

//True if client can use a donator action. If donations are not enabled this
//will always be true, otherwise check if client is a donator.
public bool:DonatorCheck(client)
{
    if(!g_DonatorLibrary || !GetConVarBool(g_Cvar_IGADonatorsOnly))
        return true;
    else
        return g_IsDonator[client];
}

stock QuerySong(client, String:path[MAX_SONG_LENGTH], bool:pall = false, bool:force=false)
{
    new HTTPRequestHandle:request = CreateIGARequest(QUERY_SONG_ROUTE);
    new player = client > 0 ? GetClientUserId(client) : 0;

    if(request == INVALID_HTTP_HANDLE)
    {
        ReplyToCommand(client, "[IGA] sm_iga_url invalid; cannot create HTTP request");
        return;
    }

    Steam_SetHTTPRequestGetOrPostParameterInt(request, "pall", pall);
    Steam_SetHTTPRequestGetOrPostParameterInt(request, "force", force);
    Steam_SetHTTPRequestGetOrPostParameter(request, "path", path);

    Steam_SendHTTPRequest(request, ReceiveQuerySong, player);

    StartCooldown(client);
}


public ReceiveQuerySong(HTTPRequestHandle:request, bool:successful, HTTPStatusCode:code, any:userid)
{
    new client = GetClientOfUserId(userid);
    if(!successful || code != HTTPStatusCode_OK)
    {
        LogError("[IGA] Error at RecivedQuerySong (HTTP Code %d; success %d)", code, successful);
        Steam_ReleaseHTTPRequest(request);
        return;
    }

    decl String:data[4096];
    Steam_GetHTTPResponseBodyData(request, data, sizeof(data));
    Steam_ReleaseHTTPRequest(request);

    new Handle:json = json_load(data);
    new bool:found = json_object_get_bool(json, "found");

    if(found)
    {
        new duration = json_object_get_int(json, "duration");
        new bool:pall = json_object_get_bool(json, "pall");
        new bool:force = json_object_get_bool(json, "force");
        new String:song_id[64], String:full_path[64], String:description[64], String:duration_formated[64];
        json_object_get_string(json, "song_id", song_id, sizeof(song_id));
        json_object_get_string(json, "full_path", full_path, sizeof(full_path));
        json_object_get_string(json, "description", description, sizeof(description));
        json_object_get_string(json, "duration_formated", duration_formated, sizeof(duration_formated));

        if(pall)
        {
            if(!IsInPall())
            {
                g_PallNextFree = duration + GetTime();

                PrintToChatAll("[IGA] Started Playing \"%s\" to all.", description);
                PrintToChatAll("Duration %s.", duration_formated);
                PrintToChatAll("Type !stop to cancel or !nopall to mute.");

                strcopy(g_CurrentPallPath, 64, full_path);
                strcopy(g_CurrentPallDescription, 64, description);

                PlaySongAll(song_id, force);
            }else{
                PrintToChat(client, "[IGA] pall currently playing %s \"%s\".", g_CurrentPallPath, g_CurrentPallDescription);
            }
        }else if(client > 0){
            decl String:name[64];
            GetClientName(client, name, sizeof(name));

            g_PNextFree[client] = duration + GetTime();

            //PrintToChat(client, "[IGA] Started Playing \"%s\"", description);
            PrintToChatAll("[IGA] %s is currently playing \"%s\", type !p %s to play for yourself.", name, description, full_path);
            PrintToChat(client, "Duration %s.", duration_formated);
            PrintToChat(client, "Type !stop to cancel.");

            strcopy(g_CurrentPlastSongId, 64, song_id);

            PlaySong(client, song_id);
        }
    }else{
        PrintToChat(client, "[IGA] Could not find specified sound or directory.");
    }

    CloseHandle(json);
}

stock UserTheme(client)
{
    new HTTPRequestHandle:request = CreateIGARequest(USER_THEME_ROUTE);

    if(request == INVALID_HTTP_HANDLE)
    {
        PrintToConsole(0, "[IGA] sm_iga_url invalid; cannot create HTTP request");
        return;
    }

    //Find the user's theme
    decl String:uid[MAX_COMMUNITYID_LENGTH];
    Steam_GetCSteamIDForClient(client, uid, sizeof(uid));
    Steam_SetHTTPRequestGetOrPostParameter(request, "uid", uid);

    Steam_SendHTTPRequest(request, ReceiveTheme, 0);
}

stock MapTheme(String:map_theme[] ="")
{
    new HTTPRequestHandle:request = CreateIGARequest(MAP_THEME_ROUTE);

    if(request == INVALID_HTTP_HANDLE)
    {
        PrintToConsole(0, "[IGA] sm_iga_url invalid; cannot create HTTP request");
        return;
    }

    Steam_SetHTTPRequestGetOrPostParameter(request, "map", map_theme);
    Steam_SendHTTPRequest(request, ReceiveTheme, 0);
}

public ReceiveTheme(HTTPRequestHandle:request, bool:successful, HTTPStatusCode:code, any:userid)
{
    if(!successful || code != HTTPStatusCode_OK)
    {
        LogError("[IGA] Error at RecivedTheme (HTTP Code %d; success %d)", code, successful);
        Steam_ReleaseHTTPRequest(request);
        return;
    }

    decl String:data[4096];
    Steam_GetHTTPResponseBodyData(request, data, sizeof(data));
    Steam_ReleaseHTTPRequest(request);

    new Handle:json = json_load(data);
    new bool:found = json_object_get_bool(json, "found");

    if(found)
    {
        new bool:force = json_object_get_bool(json, "force");
        new String:song_id[64];
        json_object_get_string(json, "song_id", song_id, sizeof(song_id));

        if(force || !IsInPall())
        {
            g_PallNextFree = 0;
            PlaySongAll(song_id, force);
        }
    }

    CloseHandle(json);
}

stock AuthorizeUser(client)
{
    new HTTPRequestHandle:request = CreateIGARequest(AUTHORIZE_USER_ROUTE);
    new player = client > 0 ? GetClientUserId(client) : 0;

    if(request == INVALID_HTTP_HANDLE)
    {
        ReplyToCommand(client, "[IGA] sm_iga_url invalid; cannot create HTTP request");
        return;
    }

    decl String:uid[MAX_COMMUNITYID_LENGTH];
    Steam_GetCSteamIDForClient(client, uid, sizeof(uid));
    Steam_SetHTTPRequestGetOrPostParameter(request, "uid", uid);

    Steam_SendHTTPRequest(request, ReceiveAuthorizeUser, player);

    StartCooldown(client);
}

public ReceiveAuthorizeUser(HTTPRequestHandle:request, bool:successful, HTTPStatusCode:code, any:userid)
{
    new client = GetClientOfUserId(userid);
    if(!successful || code != HTTPStatusCode_OK)
    {
        LogError("[IGA] Error at RecivedAuthorizeUser (HTTP Code %d; success %d)", code, successful);
        Steam_ReleaseHTTPRequest(request);
        return;
    }

    Steam_ReleaseHTTPRequest(request);
    if(client)
    {
        PrintToChat(client, "[IGA] You are now authorized to upload songs.");
    }
}



public PlaySongAll(String:song[], bool:force)
{
    for (new client=1; client <= MaxClients; client++)
    {
        if ( ClientHasPallEnabled(client) && (force || !IsInP(client)) )
        {
            PlaySong(client, song);
        }
    }
}

public PlaySong(client, String:song_id[])
{
    if(!IsClientInGame(client))
    {
        return;
    }
    decl String:url[256], String:base_url[128];
    GetConVarString(g_Cvar_IGAUrl, base_url, sizeof(base_url));

    TrimString(base_url);
    new trim_length = strlen(base_url) - 1;

    if(base_url[trim_length] == '/')
    {
        strcopy(base_url, trim_length + 1, base_url);
    }

    decl String:api_key[128];
    GetConVarString(g_Cvar_IGAApiKey, api_key, sizeof(api_key));

    Format(url, sizeof(url),
            "%s%s/%s/play?access_token=%s&volume=%f", base_url, SONGS_ROUTE, song_id, api_key, (g_Volume[client] / 10.0));

    new Handle:panel = CreateKeyValues("data");
    KvSetString(panel, "title", "In Game Audio");
    KvSetNum(panel, "type", MOTDPANEL_TYPE_URL);
    KvSetString(panel, "msg", url);

    ShowVGUIPanel(client, "info", panel, false);
    CloseHandle(panel);
    return;
}

public StopSong(client)
{
    g_PNextFree[client] = 0;
    PlaySong(client, "stop");//TODO
}
public StopSongAll()
{
    g_PallNextFree = 0;
    PlaySongAll("stop", true);//TODO
}

public bool:ClientHasPallEnabled(client)
{
    return g_IsPallEnabled[client];
}

public SongList(client)
{
    decl String:url[256], String:base_url[128];
    GetConVarString(g_Cvar_IGAUrl, base_url, sizeof(base_url));

    TrimString(base_url);
    new trim_length = strlen(base_url) - 1;

    if(base_url[trim_length] == '/')
    {
        strcopy(base_url, trim_length + 1, base_url);
    }

    Format(url, sizeof(url),
            "%s%s", base_url, DIRECTORIES_ROUTE);

    ShowMOTDPanel(client, "Song List", url, MOTDPANEL_TYPE_URL);

}
