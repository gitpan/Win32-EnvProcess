/*
    EnvProcess.h
    Used by EnvProcess.x and EnvProcessDll.c
    Version 0.04
*/

#ifndef ENVPROCESS_DEFINED
#define ENVPROCESS_DEFINED

#define FMONAME  "mmPerlTempEnvVar"

#define MAXSIZE          4096
#define MAXITEMS          254

#define SETCMD           ((char)0x00)
#define GETCMD           ((char)0x01)
#define DELCMD           ((char)0x02)
#define GETALLCMD        ((char)0x03)
#define INVALID_CMD      ((char)0xf0)
#define VALUE_TOO_BIG    ((char)0xf1)
#define ENVVAR_NOT_FOUND ((char)0xf2)
#define ENV_TOO_MANY     ((char)0xf3)

#endif   /* ENVPROCESS_DEFINED */
