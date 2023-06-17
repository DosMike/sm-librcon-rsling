# Scratch repo for LibRCON and RSling

Broadcast commands between servers in the same network

This is just tinkering

RCon stuff is based on [MoreRCon](https://github.com/AnthonyIacono/MoreRCON)

Dependencies:
 + [SMRCon](https://github.com/psychonic/smrcon)
 + [Socket](https://github.com/JoinedSenses/sm-ext-socket/)
 + [SteamWorks](https://github.com/KyleSanderson/SteamWorks)

For RSling itself:
 + The config goes into addons/sourcemod/configs/rsling.txt
 + Each line consists of `servername serverip:port rconpasswd`
    + I one contains spaces, quote the thing
    + Empty lines, lines starting with # and broken lines are ignored

LibRCon only has one native: `LibRCON`, have fun with it
