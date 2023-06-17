#include <sourcemod>
#include <socket>
#include <smrcon>
#include <steamworks>
#include "librcon.inc"

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w24a"

public Plugin myinfo = {
	name = "RSling",
	author = "reBane",
	description = "Sling commands between servers",
	version = PLUGIN_VERSION,
	url = "https://github.com/DosMike"
}

enum struct ServerConfig {
	char ipaddr[16];
	int port;
	char passwd[64];
	
	void Send(const char[] query, any data=0, LibRCON_Callback callback=INVALID_FUNCTION) {
		LibRCON(this.ipaddr, this.port, this.passwd, query, data, callback);
	}
}
ArrayList servers;
char selfip_cvar[16];
char selfip_public[16];
int selfport;
char selfname[32];

int netSayColor[3]={200,0,255};

// validate and break up a string in the form ipv4:port
// special ips are obviously not checked
stock bool ParseIpPort(const char[] definition, char[] ip, int ipsize, int& port) {
	int group;
	int number;
	int cig; //chars in group
	int maxpos = strlen(definition);
	for (int i; i<maxpos; i++) {
		if ((definition[i] == '.' && group < 3) || (definition[i] == ':' && group == 3)) {
			if (cig == 0 || number < 0 || number > 255) return false;
			if (group == 3) {
				definition[i]=0;
				strcopy(ip, ipsize, definition);
			}
			group += 1; cig = 0; number = 0;
		} else if ('0' <= definition[i] <= '9') {
			number = number*10+(definition[i]-'0');
			cig += 1;
		} else return false;
	}
	if (cig == 0 || number <= 0 || number > 65535) return false;
	port = number;
	return true;
}

stock int Base64Encode(char[] dest, int destLen, const char[] src, int srcLen=-1) {
	static char b64[66]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=";
	if (srcLen < 0) srcLen = strlen(src);
	int destReq = RoundToCeil(srcLen / 3.0) * 4;
	if (destLen < destReq) return -1; //does not fit
	int accu;
	int bits;
	int d;
	for (int i; i<srcLen; i++) {
		accu = (accu << 8) | (src[i] & 0xff);
		bits += 8;
		while (bits >= 6) {
			bits -= 6;
			int next = (accu >> bits) & 0x3f;
			dest[d++] = b64[next];
		}
	}
	if (bits == 2) {
		int next = (accu & 0x3) << 4;
		dest[d++] = b64[next];
		dest[d++] = b64[64];
		dest[d++] = b64[64];
	}
	else if (bits == 4) {
		int next = (accu & 0x0f) << 2;
		dest[d++] = b64[next];
		dest[d++] = b64[64];
	}
	return d;
}
stock int Base64Decode(char[] dest, int destLen, const char[] src, int srcLen=-1) {
	if (srcLen < 0) srcLen = strlen(src);
	int destReq = RoundToCeil(srcLen * 3.0 / 4.0) + 1;
	if (destLen < destReq) return -1;
	int accu;
	int bits;
	int d;
	bool padded;
	for (int i; i < srcLen; i++) {
		int next;
		if (src[i] == '=') {
			padded = true;
			accu <<= 2;
			bits += 2;
		} else if (padded) {
			break;
		} else if (src[i] == '_') {
			next = 63;
		} else if (src[i] == '-') {
			next = 62;
		} else if ('0' <= src[i] <= '9') {
			next = src[i]-'0'+52;
		} else if ('a' <= src[i] <= 'z') {
			next = src[i]-'a'+26;
		} else if ('A' <= src[i] <= 'Z') {
			next = src[i]-'A';
		} else break;
		if (!padded) {
			accu = (accu << 6) | next;
			bits += 6;
		}
		if (bits >= 8) {
			bits -= 8;
			dest[d++] = (accu >> bits) & 0xff;
		}
	}
	if (bits) return -1;
	dest[d++] = 0;
	return d;
}

public void OnPluginStart() {
	servers = new ArrayList(sizeof(ServerConfig));
	RegAdminCmd("rsling", OnRSlingCmd, ADMFLAG_RCON, "Sling a command to all servers on your network, like a multi-rcon");
	RegAdminCmd("netsay", OnNetSayCmd, ADMFLAG_CHAT, "Broadcast a message to all servers in your network");
	
	//get our ips
	char buffer[32];
	FindConVar("hostip").GetString(buffer, sizeof(buffer));
	int number = StringToInt(buffer);
	FormatEx(selfip_cvar, sizeof(selfip_cvar), "%i.%i.%i.%i", (number>>24)&0xff, (number>>16)&0xff, (number>>8)&0xff, number&0xff);
	FindConVar("hostport").GetString(buffer, sizeof(buffer));
	selfport = StringToInt(buffer);
	int ipaddr[4];
	if (SteamWorks_GetPublicIP(ipaddr)) {
		FormatEx(selfip_public, sizeof(selfip_public), "%i.%i.%i.%i", ipaddr[0], ipaddr[1], ipaddr[2], ipaddr[3]);
	}
	FindConVar("hostname").GetString(selfname, sizeof(selfname));
//	PrintToServer("[RSling] I am %s aka %s at %i", selfip_cvar, selfip_public, selfport);
}

public void OnConfigsExecuted() {
	servers.Clear();
	FindConVar("hostname").GetString(selfname, sizeof(selfname));
	char buffer[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, buffer, sizeof(buffer), "configs/rsling.txt");
	File file = OpenFile(buffer, "rt");
	if (file == null) {
		PrintToServer("[RSling] Could not load remotes from \"%s\"", buffer);
		return;
	}
	ServerConfig server;
	char arg[256];
	char firstarg[32];
	while (file.ReadLine(buffer, sizeof(buffer))) {
		TrimString(buffer);
		if (buffer[0]==0 || buffer[0]=='#') continue;
		int at = BreakString(buffer, firstarg, sizeof(firstarg));
		if (at == -1) continue;
		at += BreakString(buffer[at], arg, sizeof(arg));
		if (at == -1 || !ParseIpPort(arg, server.ipaddr, sizeof(ServerConfig::ipaddr), server.port)) continue;
		int more = BreakString(buffer[at], arg, sizeof(arg));
		if (more == -1) strcopy(server.passwd, sizeof(ServerConfig::passwd), arg);
		else strcopy(server.passwd, sizeof(ServerConfig::passwd), buffer[at]);
		
		PrintToServer("Added server %s at %s:%i (PW %s)", firstarg, server.ipaddr, server.port, server.passwd);
		if ((StrEqual(server.ipaddr, selfip_cvar) || StrEqual(server.ipaddr, selfip_public)) && server.port == selfport) {
			strcopy(selfname, sizeof(selfname), firstarg);
		} else {
			servers.PushArray(server);
		}
	}
	delete file;
	PrintToServer("[RSling] Loaded %i target servers from config", servers.Length);
}

void RconResponse(bool success, const char[] response, any data) {
	int client = data;
	if (client) { 
		client = GetClientOfUserId(client);
		if (!client) return; //client gone
	}
	if (success) {
		if (client) PrintToConsole(client, "[RSling] Response: %s", response);
		else PrintToServer("[RSling] Response: %s", response);
	} else {
		if (client) PrintToConsole(client, "[RSling] Failed: %s", response);
		else PrintToServer("[RSling] Failed: %s", response);
	}
}

//without this callback we're not getting "IsCmdFromRCon"-Guarded
public Action SMRCon_OnCommand(int rconId, const char[] address, const char[] command, bool &allow) {
	return Plugin_Continue;
}


public Action OnRSlingCmd(int client, int args) {
	char buffer[PLATFORM_MAX_PATH];
	char reply[PLATFORM_MAX_PATH];
	GetCmdArgString(buffer, sizeof(buffer));
	StripQuotes(buffer);
	for (int i; buffer[i]; i++) if (buffer[i]==';') buffer[i]='\0'; //no multi
	
	if (SMRCon_IsCmdFromRCon()) {
		ReplyToCommand(client, "Can not rsling recusively!");
	} else {
		//run command on this server
		ServerCommandEx(reply, sizeof(reply), "%s", buffer);
		ReplyToCommand(client, "%s", reply);
		//and all others
		int user;
		if (client) user = GetClientUserId(client);
		ServerConfig server;
		for (int i; i<servers.Length; i++) {
			servers.GetArray(i, server);
			server.Send(buffer, user, RconResponse);
		}
	}
	
	return Plugin_Handled;
}

public Action OnNetSayCmd(int client, int args) {
	char buffer[PLATFORM_MAX_PATH];
	char reply[PLATFORM_MAX_PATH];
	GetCmdArgString(buffer, sizeof(buffer));
	TrimString(buffer);
	int len = strlen(buffer);
	if (buffer[0] == buffer[len-1] && (buffer[0] == '"' || buffer[0] == '\'')) {
		Format(buffer, sizeof(buffer), "%s", buffer[1]);
		buffer[len-2]=0;
		TrimString(buffer);
	}
	
	if (SMRCon_IsCmdFromRCon()) {
		
		PrintToChatAll("\x01\x04\07%02X%02X%02X%s", netSayColor[0], netSayColor[1], netSayColor[2], buffer);
		SetHudTextParams(-1.0, 0.3, 5.0, netSayColor[0], netSayColor[1], netSayColor[2], 0, 2, 0.0, 0.0, 0.0);
		for (int c=1; c<=MaxClients; c++) if (IsClientInGame(c)) ShowHudText(c, -1, "%s", buffer);
		
		ReplyToCommand(client, "Notified \"%s\"", selfname);
		
	} else {
		
		if (client) Format(buffer, sizeof(buffer), "[%s] %N: %s", selfname, client, buffer);
		else Format(buffer, sizeof(buffer), "[%s]: %s", selfname, buffer);
		for (int i; buffer[i]; i++) {
			if (buffer[i]=='"') buffer[i]='\'';
		}
		
		PrintToChatAll("\x01\x04\07%02X%02X%02X%s", netSayColor[0], netSayColor[1], netSayColor[2], buffer);
		SetHudTextParams(-1.0, 0.3, 5.0, netSayColor[0], netSayColor[1], netSayColor[2], 0, 2, 0.0, 0.0, 0.0);
		for (int c=1; c<=MaxClients; c++) if (IsClientInGame(c)) ShowHudText(c, -1, "%s", buffer);
		
		FormatEx(reply, sizeof(reply), "netsay \"%s\"", buffer);
		int user;
		if (client) user = GetClientUserId(client);
		ServerConfig server;
		for (int i; i<servers.Length; i++) {
			servers.GetArray(i, server);
			server.Send(reply, user, RconResponse);
		}
		
	}
	
	return Plugin_Handled;
}
