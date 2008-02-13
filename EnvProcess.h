/*
    EnvProcess.h
    Used by EnvProcess.x and EnvProcessDll.c
*/

#ifndef ENVPROCESS_DEFINED
#define ENVPROCESS_DEFINED

#define FMONAME  "mmPerlTempEnvVar"

#define MAXSIZE          4096
#define MAXITEMS          254

#define SETCMD           0x00
#define GETCMD           0x01
#define DELCMD           0x02
#define INVALID_CMD      0xf0
#define VALUE_TOO_BIG    0xf1
#define ENVVAR_NOT_FOUND 0xf2

#endif   /* ENVPROCESS_DEFINED */