// This library is based on https://github.com/AnthonyIacono/MoreRCON

#if defined __LIB_RCON__
#endinput
#endif
#define __LIB_RCON__

typedef LibRCON_Callback = function void (bool success, const char[] response, any data);

native void LibRCON_Send(const char[] host, int ip, const char[] password, const char[] command, any data=0, LibRCON_Callback callback=INVALID_FUNCTION);
native bool LibRCON_IsCmdFromRCon();

/**
Shared plugin information
**/
public SharedPlugin __pl_LibRCON = {
	name = "LibRCON",
	file = "librcon.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_LibRCON_SetNTVOptional() {
	MarkNativeAsOptional("LibRCON_Send");
	MarkNativeAsOptional("LibRCON_IsCmdFromRCon");
}
#endif