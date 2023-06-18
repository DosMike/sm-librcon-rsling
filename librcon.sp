// Based on https://github.com/AnthonyIacono/MoreRCON

#include <socket>
#include <dhooks>

#define RCON_PACKET_MAX_SIZE 4096

#define RCON_STATE_AUTHING 0
#define RCON_STATE_COMMANDEXEC 1

#define RCON_SERVERDATA_AUTH 3
#define RCON_SERVERDATA_AUTH_RESPONSE 2
#define RCON_SERVERDATA_EXECCOMMAND 2
#define RCON_SERVERDATA_RESPONSE_VALUE 0

//typedef LibRCON_Callback = function void (bool success, const char[] response, any data);
#include "librcon.inc"

#pragma newdecls required
#pragma semicolon 1

//#define DEBUG
#define PLUGIN_VERSION "23w24b"

public Plugin myinfo = {
	name = "LibRCON",
	author = "reBane",
	description = "Singleshot RCON library for inter-server com",
	version = PLUGIN_VERSION,
	url = "https://github.com/DosMike"
}

// ===== section: send rcon requests =====

stock void PrintBuffer(const char[] buffer, int buffersize) {
	for (int i; i<buffersize; i+=16) {
		char line[256];
		int lineoff=FormatEx(line, sizeof(line), "%04X  ", i);
		int c;
		for (c=0; c<16 && i+c<buffersize; c++) {
			lineoff+=FormatEx(line[lineoff], sizeof(line)-lineoff, "%02X ", (buffer[i+c]&0xff));
			if ((c+1)%8 == 0) line[lineoff++] = ' ';
		}
		for (;c<16; c++) {
			lineoff+=FormatEx(line[lineoff], sizeof(line)-lineoff, "   ");
			if ((c+1)%8 == 0) line[lineoff++] = ' ';
		}
		for (c=0; c<16 && i+c<buffersize; c++) {
			line[lineoff++] = ((buffer[i+c]<' '||buffer[i+c]>'~')?'.':(buffer[i+c]));
			if ((c+1)%8 == 0) line[lineoff++] = ' ';
		}
		PrintToServer("%s", line);
	}
}

static void ProduceLittleEndian(any value, char[] output) {
	output[0] = ((value << 24) >> 24) & 0x000000FF;
	output[1] = ((value << 16) >> 24) & 0x000000FF;
	output[2] = ((value << 8) >> 24) & 0x000000FF;
	output[3] = (value >> 24) & 0x000000FF;
}

static any LittleEndianToValue(char[] p_LittleEndian) {
	return (p_LittleEndian[0] & 0x000000FF) |
		((p_LittleEndian[1] << 8) & 0x0000FF00) |
		((p_LittleEndian[2] << 16) & 0x00FF0000) |
		((p_LittleEndian[3] << 24) & 0xFF000000);
}

static int TbpcLengthString(int bytecount) {
	return RoundToCeil(bytecount/3.0);
}
//static int StringLengthTbpc(int cellcount) {
//	return cellcount*3;
//}
static int StringLengthCells(any[] cells, int maxCells) {
	int count;
	int c;
	for (;c < maxCells && cells[c]; c++) {
//		PrintToServer("Len %i +%i -> %i", c, ((cells[c] >> 24) & 0x03), count+((cells[c] >> 24) & 0x03));
		count += (cells[c] >> 24) & 0x03;
	}
	return count;
}
///3 byte per cell encoding
///@returns cells written
static int StringToCells(any[] dest, int destLen, const char[] src, int srcLen) {
	int numCells = RoundToCeil(srcLen/3.0);
	if (destLen < numCells) numCells = destLen; // if we have less cells available than src requires, dont exceed
	int s;
	int c;
	for (; c<numCells; c++) {
		int cell=0;
		int cc=0;
		for (;cc<3 && s<srcLen;cc++,s++) {
			cell = ((cell<<8)|(src[s]&0x0FF));
		}
		dest[c] = cell | (cc<<24);
//		PrintToServer("Pack %i +%i", c, cc);
		if (cc < 3) { c++; break; }
	}
	if (c+1 < destLen) dest[c+1]=0; //write a terminator, if there's space
	return c;
}
///3 byte per cell decoding
///terminates with src/dest len or the first empty cell (0x0)
///@returns number of bytes written
static int CellsToString(char[] dest, int destLen, const any[] src, int srcLen) {
	int s;
	int c;
	for (; s<srcLen && src[s]; s++) {
		int cell = src[s];
		int cc = ((cell>>24)&0x03);
		cell <<= (3-cc)*8;
		while ((--cc)>=0) {
			//PrintToServer("c%i cc%i cell%08X", c, cc, cell);
			dest[c++] = ((cell & 0x00ff0000)>>16);
			if (c >= destLen) return c;
			cell <<= 8;
		}
	}
	return c;
}

static int GetNextPacketID() {
	static int g_NextPacketID;
	g_NextPacketID++;
	
	return g_NextPacketID;
}

static void Rcon_SendPacketRaw(Socket socket, int type, const char[] payload) {
	int payloadlen = strlen(payload);
	int packetid = GetNextPacketID(); // This can be any int above zero, doesn't have to be unique
	int packetlen = 10 + payloadlen;
	int packettype = type;
	
	char packetBuffer[RCON_PACKET_MAX_SIZE];
	
	ProduceLittleEndian(packetlen, packetBuffer);
	ProduceLittleEndian(packetid, packetBuffer[4]);
	ProduceLittleEndian(packettype, packetBuffer[8]);
	
	strcopy(packetBuffer[12], payloadlen+1, payload);
	
	// should already be 0 but better safe then sorry
	packetBuffer[payloadlen + 12] = '\0';
	packetBuffer[payloadlen + 13] = '\0';
#if defined DEBUG
	PrintToServer("Transmit (%i)", packetlen+4);
	PrintBuffer(packetBuffer, packetlen+4);
#endif
	socket.Send(packetBuffer, packetlen + 4);
}

static void LibRCON_SendCommand(Socket socket, DataPack requestParam) {
	char cmdString[RCON_PACKET_MAX_SIZE];
	requestParam.Reset();
	requestParam.WriteCell(RCON_STATE_COMMANDEXEC); //update state
	requestParam.ReadCell();//skip data
	requestParam.ReadCell(); //skip callback plugin
	requestParam.ReadFunction(); //skip callback
	requestParam.ReadString(cmdString, 0);//skip pw
	requestParam.ReadString(cmdString, RCON_PACKET_MAX_SIZE);
	requestParam.WriteCell(0);//push rx len to 0
	requestParam.WriteCellArray({0},0); //drop old data
	
	Rcon_SendPacketRaw(socket, RCON_SERVERDATA_EXECCOMMAND, cmdString);
}

static void LibRCON_OnSocketConnected(Socket socket, DataPack requestParam) {
	char password[256];
	requestParam.Reset();
	requestParam.ReadCell(); //skip state
	requestParam.ReadCell(); //skip data
	requestParam.ReadCell(); //skip callback plugin
	requestParam.ReadFunction(); //skip callback
	requestParam.ReadString(password, sizeof(password));
	
	Rcon_SendPacketRaw(socket, RCON_SERVERDATA_AUTH, password);
}

static void LibRCON_OnSocketReceive(Socket socket, char[] p_Data, int p_DataSize, DataPack requestParam) {
	char skipBuffer[4];
	requestParam.Reset();
	int rconState = requestParam.ReadCell();
	int usrdata = requestParam.ReadCell();
	Handle cbPlugin = requestParam.ReadCell();
	Function callback = requestParam.ReadFunction();
	requestParam.ReadString(skipBuffer, 0); //skip pw
	requestParam.ReadString(skipBuffer, 0); //skip cmd
	DataPackPos rxBufPos = requestParam.Position;
	int prevCells = requestParam.ReadCell();
	
#if defined DEBUG
	PrintToServer("Received (%i, state %i)", p_DataSize, rconState);
	PrintBuffer(p_Data, p_DataSize);
#endif
	
	int newCells = TbpcLengthString(p_DataSize);
	int totalCells = prevCells + newCells;
	any[] cells = new any[totalCells];
	if(prevCells == 0) {
		StringToCells(cells, newCells, p_Data, p_DataSize);
	} else {
		requestParam.ReadCellArray(cells, prevCells);
		StringToCells(cells[prevCells], newCells, p_Data, p_DataSize);
	}
	requestParam.Position = rxBufPos;
	requestParam.WriteCell(totalCells);
	requestParam.WriteCellArray(cells, totalCells);
	
	int totalReceivedBytes = StringLengthCells(cells, totalCells);
	if(totalReceivedBytes < 12) return;
	
	char[] receiveBuffer = new char[totalReceivedBytes];
	int test = CellsToString(receiveBuffer, totalReceivedBytes, cells, totalCells);
#if defined DEBUG
	PrintToServer("Rx Buffer (%i)", totalReceivedBytes);
	PrintBuffer(receiveBuffer, totalReceivedBytes);
#endif
	if (test != totalReceivedBytes) SetFailState("DEBUG VALIDATION FAILED %i != %i", test, totalReceivedBytes);
	
	int expectedSize = LittleEndianToValue(receiveBuffer);
	if(totalReceivedBytes < expectedSize) return;
	
	int packetid = LittleEndianToValue(receiveBuffer[4]);
	int packettype = LittleEndianToValue(receiveBuffer[8]);
	
	int payloadlen = expectedSize - 10;
	char[] payload = new char[payloadlen + 1];
	strcopy(payload, payloadlen+1, receiveBuffer[12]);
	payload[payloadlen] = 0;
	
	if (rconState == RCON_STATE_AUTHING) {
		// We might get a bogus packet first (if type == 0)
		if (packettype == RCON_SERVERDATA_RESPONSE_VALUE) {
			// We need to read another packet. It's the actual response.
			// First ensure that we have enough bytes to merit operating
			requestParam.Position = rxBufPos;
			requestParam.WriteCell(0);
			requestParam.WriteCellArray({0}, 0);
			return;
			
		} else if (packettype != RCON_SERVERDATA_AUTH_RESPONSE) {
			char buffer[100];
			FormatEx(buffer, sizeof(buffer), "ERROR: Expected auth packet after bogus packet, but didn't find it. (%d != 2)", packettype);
			if (callback != INVALID_FUNCTION) {
				Call_StartFunction(cbPlugin, callback);
				Call_PushCell(false);
				Call_PushString(buffer);
				Call_PushCell(usrdata);
				Call_Finish();
			}
			return;
		}
		
		if (packetid == -1) {
			if (callback != INVALID_FUNCTION) {
				Call_StartFunction(cbPlugin, callback);
				Call_PushCell(false);
				Call_PushString("Invalid RCON password");
				Call_PushCell(usrdata);
				Call_Finish();
			}
		} else {
			LibRCON_SendCommand(socket, requestParam);
		}
	} else if (rconState == RCON_STATE_COMMANDEXEC) {
		TrimString(payload);
		
		if (callback != INVALID_FUNCTION) {
			Call_StartFunction(cbPlugin, callback);
			Call_PushCell(true);
			Call_PushString(payload);
			Call_PushCell(usrdata);
			Call_Finish();
		}
		
		socket.Disconnect();
		delete socket;
		requestParam.Reset(true);
		delete requestParam;
	}
}

static void LibRCON_OnSocketDisconnected(Socket socket, DataPack requestParam) {
	requestParam.Reset();
	requestParam.ReadCell();
	int usrdata = requestParam.ReadCell();
	Handle cbPlugin = requestParam.ReadCell();
	Function callback = requestParam.ReadFunction();
	if (callback != INVALID_FUNCTION) {
		Call_StartFunction(cbPlugin, callback);
		Call_PushCell(false);
		Call_PushString("Socket closed by remote");
		Call_PushCell(usrdata);
		Call_Finish();
	}
	
	socket.Disconnect();
	delete socket;
	requestParam.Reset(true);
	delete requestParam;
}

static void LibRCON_OnSocketError(Socket socket, int errorType, int errorNum, DataPack requestParam) {
	requestParam.Reset();
	int rconState = requestParam.ReadCell();
	int usrdata = requestParam.ReadCell();
	Handle cbPlugin = requestParam.ReadCell();
	Function callback = requestParam.ReadFunction();
	char error[128];
	FormatEx(error, sizeof(error), "Socket error %i (%i) durring %s", errorType, errorNum, (rconState==0?"auth":"cmd"));
	if (callback != INVALID_FUNCTION) {
		Call_StartFunction(cbPlugin, callback);
		Call_PushCell(false);
		Call_PushString(error);
		Call_PushCell(usrdata);
		Call_Finish();
	}
	
	socket.Disconnect();
	delete socket;
	requestParam.Reset(true);
	delete requestParam;
}

// const char[] host, int port, const char[] password, const char[] command, any data=0, LibRCON_Callback callback = INVALID_FUNCTION
public any LibRCON_Send_Native(Handle plugin, int numParams) {
	// Create an ADT for the request information
	char buffer[RCON_PACKET_MAX_SIZE];
	char host[16];
	DataPack requestParam = new DataPack();
	requestParam.WriteCell(RCON_STATE_AUTHING);
	requestParam.WriteCell(GetNativeCell(5)); //usr data
	requestParam.WriteCell(plugin); //plugin handle
	requestParam.WriteFunction(GetNativeFunction(6)); //callback
	GetNativeString(3, buffer, 256); //password
	requestParam.WriteString(buffer);
	GetNativeString(4, buffer, RCON_PACKET_MAX_SIZE); //command
	requestParam.WriteString(buffer);
	requestParam.WriteCell(0); // response buffer received length
	requestParam.WriteCellArray({0},0);
	GetNativeString(1, host, 256); //host
	int port = GetNativeCell(2); //port
	
	PrintToServer("LibRCON Query (to %s:%i): %s", host, port, buffer);
	
	// Setup our socket connection
	Socket socket = SocketCreate(SOCKET_TCP, LibRCON_OnSocketError);
	socket.SetArg(requestParam);
	socket.Connect(LibRCON_OnSocketConnected, LibRCON_OnSocketReceive, LibRCON_OnSocketDisconnected, host, port);
	return 0;
}

// ===== section: dhooks/Is in WriteDataRequest =====

static bool g_IsInWriteDataRequest;
public MRESReturn OnEnterRconWriteRequest(DHookParam hParams) {
	g_IsInWriteDataRequest = true;
	return MRES_Ignored;
}

public MRESReturn OnLeaveRconWriteRequest(DHookParam hParams) {
	g_IsInWriteDataRequest = false;
	return MRES_Ignored;
}

public any LibRCON_IsCmdFromRCon_Native(Handle plugin, int numParams) {
	return g_IsInWriteDataRequest;
}

// ===== section: test suite =====

static void TestSuite() {
	
	PrintToServer("3ByteCell buffer...");
	char buffer[128];
	any cells[16];
	int count;
	
	if (TbpcLengthString(9) != 3) {
		PrintToServer("> Length check failed"); SetFailState("SelfTest failed");
	}
	
	cells[0]=cells[1]=cells[2]=cells[3]=cells[4]=0;
	count=StringToCells(cells, 16, "HelloWorld", 10); //strlen
	if (count!=4 || cells[0] != 0x0348656c || cells[1] != 0x036c6f57 || cells[2] != 0x036f726c || cells[3] != 0x01000064 || cells[4] != 0) {
		PrintToServer("> Write string failed (%i: %08X %08X %08X %08X %08X)", count, cells[0], cells[1], cells[2], cells[3], cells[4]);
		SetFailState("SelfTest failed");
	}
	
	cells[0]=cells[1]=cells[2]=cells[3]=cells[4]=0;
	count=StringToCells(cells, 16, "HelloWorld", 11); //+null
	if (count!=4 || cells[0] != 0x0348656c || cells[1] != 0x036c6f57 || cells[2] != 0x036f726c || cells[3] != 0x02006400 || cells[4] != 0) {
		PrintToServer("> Write string+null failed (%i: %08X %08X %08X %08X %08X)", count, cells[0], cells[1], cells[2], cells[3], cells[4]);
		SetFailState("SelfTest failed");
	}
	
	cells[0]=cells[1]=cells[2]=cells[3]=cells[4]=0;
	count=StringToCells(cells, 16, "HelloWorld", 9); //exactly 3
	if (count!=3 || cells[0] != 0x0348656c || cells[1] != 0x036c6f57 || cells[2] != 0x036f726c || cells[3] != 0) {
		PrintToServer("> Write full cells failed (%i: %08X %08X %08X %08X %08X)", count, cells[0], cells[1], cells[2], cells[3], cells[4]);
		SetFailState("SelfTest failed");
	}
	
	cells[0] = 0x0348656c;
	cells[1] = 0x036c6f20;
	cells[2] = 0x03576f72;
	cells[3] = 0x02006c64;
	cells[4] = 0;
	count=CellsToString(buffer, 16, cells, 16);
	if (count!=11 || buffer[12] != 0 || !StrEqual(buffer, "Hello World")) {
		PrintToServer("> Read string failed (%i: %s)", count, buffer);
		SetFailState("SelfTest failed");
	}
	
	PrintToServer("> OK");
	
	PrintToServer("MessageID increment...");
	cells[0] = GetNextPacketID();
	cells[1] = GetNextPacketID();
	if (cells[1] != cells[0]+1) {
		PrintToServer("> Packed id increment failed (%i -> %i, %i expected)", cells[0], cells[1], cells[0]+1);
		SetFailState("SelfTest failed");
	}
	
	PrintToServer("> OK");
	
	PrintToServer("RCON self status...");
	
	char myip[16];
	FindConVar("hostip").GetString(buffer, sizeof(buffer));
	int number = StringToInt(buffer);
	FormatEx(myip, sizeof(myip), "%i.%i.%i.%i", (number>>24)&0xff, (number>>16)&0xff, (number>>8)&0xff, number&0xff);
	FindConVar("hostport").GetString(buffer, sizeof(buffer));
	number = StringToInt(buffer);
	FindConVar("rcon_password").GetString(buffer, sizeof(buffer));
	//PrintToServer("Binding to %s:%i (%s)", myip, number, buffer);
	LibRCON_Send(myip, number, buffer, "status", _, SelfTestResult);
	
}

void SelfTestResult(bool success, const char[] response, any data) {
	if (!success) {
		PrintToServer("> Request failed: %s", response);
		SetFailState("SelfTest failed");
	}
	PrintToServer("> OK");
	PrintToServer("[LibRCON] SelfTest complete!");
}

// ===== section: actual library/plugin stuff =====

bool gLate;
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	CreateNative("LibRCON_Send", LibRCON_Send_Native);
	CreateNative("LibRCON_IsCmdFromRCon", LibRCON_IsCmdFromRCon_Native);
	RegPluginLibrary("LibRCON");
	gLate=late;
	return APLRes_Success;
}

static ConVar cvTarget;
static ConVar cvPasswd;
static char strHost[16];
static int iPort;

public void OnPluginStart() {
	cvTarget = CreateConVar("librcon_host", "", "Target for outgoing rcon request as ipv4:port", FCVAR_UNLOGGED|FCVAR_PROTECTED);
	cvTarget.AddChangeHook(OnCvarTargetChange);
	cvPasswd = CreateConVar("librcon_password", "", "Password for outgoing rcon request", FCVAR_UNLOGGED|FCVAR_PROTECTED);
	AddCommandListener(OnCommandRcon, "rcon");
	RegAdminCmd("librcon", OnCommandLibRcon, ADMFLAG_RCON, "LibRCON mirror command for rcon on servers");
	
	GameData gdata = new GameData("librcon.games");
	DynamicDetour detour = DynamicDetour.FromConf(gdata, "CServerRemoteAccess::WriteDataRequest()");
	if (detour == null) {
		PrintToServer("[LibRCON] Could not hook RCON commands, some stuff will not work");
	} else {
		detour.Enable(Hook_Pre, OnEnterRconWriteRequest);
		detour.Enable(Hook_Post, OnLeaveRconWriteRequest);
	}
	delete gdata;
}
public void OnCvarTargetChange(ConVar convar, const char[] oldValue, const char[] newValue) {
	char buffer[64];
	convar.GetString(buffer, sizeof(buffer));
	TrimString(buffer);
	if (buffer[0]==0) {
		strHost="";
		iPort=0;
		PrintToServer("[LibRCON] Command target empty, disabling");
	} else {
		int group;
		int number;
		int cig; //chars in group
		int maxpos = strlen(buffer);
		for (int i; i<maxpos; i++) {
			if ((buffer[i] == '.' && group < 3) || (buffer[i] == ':' && group == 3)) {
				if (cig == 0 || number < 0 || number > 255) { PrintToServer("[LibRCON] Invalid ip address for rcon target"); strHost=""; iPort=0; return; }
				if (group == 3) {
					buffer[i]=0;
					strcopy(strHost, sizeof(strHost), buffer);
				}
				group += 1; cig = 0; number = 0;
			} else if ('0' <= buffer[i] <= '9') {
				number = number*10+(buffer[i]-'0');
				cig += 1;
			} else {
				PrintToServer("[LibRCON] Invalid char in rcon target"); strHost=""; iPort=0; return;
			}
		}
		if (cig == 0 || number <= 0 || number > 65535) { PrintToServer("[LibRCON] Invalid port for rcon target (%i)", number); strHost=""; iPort=0; return; }
		iPort = number;
		PrintToServer("[LibRCON] Command target: %s : %i", strHost, iPort);
	}
}
public Action OnCommandRcon(int client, const char[] command, int argc) {
	char cmd[256];
	GetCmdArgString(cmd, sizeof(cmd));
	svRcon(client, cmd);
	return Plugin_Handled;
}
public Action OnCommandLibRcon(int client, int args) {
	char cmd[256];
	GetCmdArgString(cmd, sizeof(cmd));
	svRcon(client, cmd);
	return Plugin_Handled;
}
static void svRcon(int client, const char[] command) {
	if (strHost[0] == 0) {
		ReplyToCommand(client, "[LibRCON] Invalid target in librcon_host");
		return;
	}
	char passwd[256];
	cvPasswd.GetString(passwd, sizeof(passwd));
	int uid;
	if (client) uid = GetClientUserId(client);
	DataPack pack = new DataPack();
	pack.WriteCell(uid);
	pack.WriteCell(GetCmdReplySource());
	
	LibRCON_Send(strHost, iPort, passwd, command, pack, CmdRconCallback);
}
void CmdRconCallback(bool success, const char[] response, any data) {
	DataPack pack = data;
	pack.Reset();
	int client = pack.ReadCell();
	ReplySource source = pack.ReadCell();
	delete pack;
	
	if (client) {
		client = GetClientOfUserId(client);
		if (!client) return; //client disconnected
	}
	if (success) {
		if (response[0]) {
			if (!client) PrintToServer("[LibRCON] Response: %s", response);
			else {
				PrintToConsole(client, "[LibRCON] Response: %s", response);
				if (source == SM_REPLY_TO_CHAT) PrintToChat(client, "Check console for RCON response");
			}
		} else {
			if (!client) PrintToServer("[LibRCON] OK");
			else if (source == SM_REPLY_TO_CHAT) PrintToChat(client, "[LibRCON] OK");
			else PrintToConsole(client, "[LibRCON] OK");
		}
	} else {
		if (response[0]) {
			if (!client) PrintToServer("[LibRCON] Error: %s", response);
			else {
				PrintToConsole(client, "[LibRCON] Error: %s", response);
				if (source == SM_REPLY_TO_CHAT) PrintToChat(client, "RCON failed, check console for error");
			}
		} else {
			if (!client) PrintToServer("[LibRCON] Error");
			else if (source == SM_REPLY_TO_CHAT) PrintToChat(client, "[LibRCON] Error");
			else PrintToConsole(client, "[LibRCON] Error");
		}
	}
}
public void OnAllPluginsLoaded() {
	if (gLate) {
		PrintToServer("[LibRCON] Late load - running test suite");
		TestSuite();
	}
}
public void OnConfigsExecuted() {
	OnCvarTargetChange(cvTarget, "", "");
}



#undef RCON_PACKET_MAX_SIZE

#undef RCON_STATE_AUTHING
#undef RCON_STATE_COMMANDEXEC

#undef RCON_SERVERDATA_AUTH
#undef RCON_SERVERDATA_AUTH_RESPONSE
#undef RCON_SERVERDATA_EXECCOMMAND
#undef RCON_SERVERDATA_RESPONSE_VALUE
