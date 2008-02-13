#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "const-c.inc"

#include "EnvProcess.h"

/* Limitations:

   Total size of variable names and values: MAXSIZE
   Total number of environment variables: MAXITEMS/2
   
   Locking: the entire sequence is serial because a named FMO is used.  
        Creating the File Mapping Object(FMO), writing to it,
        and running the DLL in the other process, is protected by a Mutex.
        
        It is therefore possible that calls may block.
        
   If an odd number of items are supplied in the list,  
   the final variable name specified will have no value.
   
   The format of the FMO is 
      Command byte (SETCMD or GETCMD)
      Number of items
      Items
      
   FreeLibrary?  
   This could mean implementing using OO, so a destructor can be used.
   or, is this an issue nly with the copy in tests?
   
   Vista

*/

static void ProcessError(const char *szMessage);
static BOOL FindDll(void);
static int iGetPid (const char *pszExeName);
static int GetProcessNameAndID( DWORD processID, const char *pszExeName);
static char * strtolower (char * szIn);

#define DLLNAME      "EnvProcessDll.dll"
#define MUTEXNAME    "mutexPerlTempEnvVar"
#define MAXPROCESSES 1024
/* ------------------------------------------------------------------ */

static void ProcessError(const char *szMessage)
{
    char* buffer;
    DWORD dwErr = GetLastError();
    
    /* DEBUG */
    PerlIO * debug = PerlIO_open ("debug.txt", "a");
    
    FormatMessage( 
                FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM,
                0,
                dwErr,
                MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), // Default language
                (LPTSTR) &buffer,
                0,
                0);
    
    if (dwErr != ERROR_SUCCESS) 
       PerlIO_printf(debug, "%s: %s", szMessage, buffer);
    else
       PerlIO_printf(debug, "%s\n", szMessage);
    
    PerlIO_close (debug);
    
    LocalFree(buffer);
    
    /* APIs above would have reset it */
    SetLastError(dwErr);

}  

/* ------------------------------------------------------------------ */

static DWORD dwGetOS ()
{
   OSVERSIONINFO OsVer = {0};
   OsVer.dwOSVersionInfoSize = sizeof (OsVer);
   GetVersionEx (&OsVer);

   return OsVer.dwMajorVersion;
}

/* ------------------------------------------------------------------ */

static char * strtolower (char * szIn) {
    char * p;
    
    for (p = szIn; *p; p++) {
        *p = toLOWER(*p);         // perlapi
    }
    return szIn;
}

/* ------------------------------------------------------------------ */

static int GetProcessNameAndID( DWORD processID, const char *pszExeName )
{
    char szProcessName[MAX_PATH] = "unknown";
    HANDLE hProcess;
     
    /* DEBUG
    char wk[80] = {0};
    sprintf (wk, "processID: %d", processID);
    ProcessError (wk);
    */
    
    if (processID == 0) return 0;   // We get this, why?
    
    // Get a handle to the process.

    hProcess = OpenProcess( PROCESS_QUERY_INFORMATION |
                            PROCESS_VM_READ,
                            FALSE, processID );

    // Get the process name.

    if (NULL != hProcess )
    {
        HMODULE hMod;    // We only want the first module
        DWORD cbNeeded;

        if ( EnumProcessModules( hProcess, &hMod, sizeof(hMod), 
             &cbNeeded) )
        {
            GetModuleBaseName( hProcess, hMod, szProcessName, 
                               sizeof(szProcessName) );
        }
        else {
            //ProcessError ("EnumProcessModules");
            return 0;
        }
    }
    else {
        //ProcessError ("OpenProcess");
        return 0;
    }
    
    CloseHandle( hProcess );
    
    // We expect lots of 'Access is denied'
    SetLastError(ERROR_SUCCESS);

    strtolower (szProcessName);
    
    if (!strcmp(szProcessName, pszExeName)) {
       //ProcessError ("Found!");
       return 1;
    }
    else {
       return 0;
    }   
}

/* ------------------------------------------------------------------ */

static BOOL FindDll(void) 
{
    /* Can we find the DLL? 
       This is not useful for production, since it only tells
       us if Perl can find the Dll, not the other process, 
       which may have a different PATH
    */
    
    BOOL bRetn = TRUE;
    TCHAR tcBuffer[MAX_PATH];
    LPTSTR lpFilePart;
    DWORD dwLen = 
             SearchPath(NULL, DLLNAME, NULL, MAX_PATH, tcBuffer, &lpFilePart);
         
    if ( dwLen == 0 )
    {
       /* ProcessError (DLLNAME);  */
       bRetn = FALSE;
    }
    
    return bRetn;
}

/* ------------------------------------------------------------------ */

BOOL ConnectToProcess(int nPid) {

   DWORD  dwTid;
   HANDLE hProcess;
   HANDLE hThread;
   void * Remotep = NULL;
   int    cb = strlen(DLLNAME) + 1;
   
   hProcess = OpenProcess (PROCESS_ALL_ACCESS, // PROCESS_CREATE_THREAD,
                           FALSE, nPid);

   if ( hProcess == NULL )
   {
      /* ProcessError ("OpenProcess"); */
      return FALSE;
   }

   Remotep = VirtualAllocEx (hProcess, NULL, cb, MEM_COMMIT, 
                             PAGE_READWRITE);

   if ( Remotep == NULL )
   {
      /* ProcessError ("VirtualAllocEx"); */
      CloseHandle(hProcess);
      return FALSE;
   }

   if (!WriteProcessMemory (hProcess, Remotep, DLLNAME, cb, NULL))
   {
      /* ProcessError ("WriteProcessMemory"); */
      CloseHandle(hProcess);
      return NULL;
   }
  
   hThread = CreateRemoteThread (hProcess, NULL, 0, 
                        (LPTHREAD_START_ROUTINE)LoadLibraryA, Remotep, 0, 
                        &dwTid);

   if ( hThread == NULL )
   {
      /* ProcessError ("CreateRemoteThread"); */
      CloseHandle(hProcess);
      return FALSE;
   }

   WaitForSingleObject (hThread, INFINITE);
   CloseHandle(hThread);
   CloseHandle(hProcess);

   return TRUE;

}  /* ConnectToProcess */

/* ------------------------------------------------------------------ */


MODULE = Win32::EnvProcess		PACKAGE = Win32::EnvProcess		

int 
SetEnvProcess(nPid, ...)
    int nPid;
   
    PROTOTYPE: $@

    CODE:

    DWORD  dwRetn;
    HANDLE hMutex; 
    HANDLE hMap; 
    char *p;
    char *p2;
    int i;
    int NumVars = 0;   /* Used for a return code */
    int NumSent;
    
    /* Default return value - false (On error) */
    RETVAL = 0; 

    /* 'items' is the number of arguments, placed by perl */
   
    if ( items < 2 ) {
       XSRETURN_UNDEF;
    }
      
    /* Can we find the DLL? */
    if (!FindDll())
        XSRETURN_UNDEF;

        
    /* Create and grab the mutex */
    hMutex = CreateMutex (NULL, FALSE, MUTEXNAME);
   
    if (hMutex == NULL) {
       /* ProcessError ("CreateMutex"); */
       XSRETURN_UNDEF;
    }
  
    dwRetn = WaitForSingleObject (hMutex, INFINITE);
    
    if (dwRetn != WAIT_OBJECT_0) {
       /* If we get back WAIT_ABANDONED then we exit anyway */
       /* Any others waiting will also get WAIT_ABANDONED   */
       CloseHandle (hMutex);
       XSRETURN_UNDEF;
    }
  
    /* Create the shared memory area */

    p = NULL;

    hMap = CreateFileMapping (INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                              0, MAXSIZE, FMONAME);

    if (hMap)
        p = MapViewOfFile (hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);

    if (p == NULL) {
        /* ProcessError ("MapViewOfFile"); */
        CloseHandle (hMap);

        ReleaseMutex(hMutex);     
        CloseHandle(hMutex);
        XSRETURN_UNDEF;
    }

    p2 = p+2;   /* Reserve the first two bytes */
    
    for (i = 1; i < items; i++) {
       STRLEN n_a;
       strcpy (p2, (char *)SvPV(ST(i), n_a));       
       p2 += strlen(p2)+1;
       
       /* avoid overflowing the shared area */
       if ((p2 - p) >= MAXSIZE || i >= MAXITEMS) {   
          break;
       }
    }
    
    /* Tweek the number of items */
    NumVars = i - 1;
    if ( NumVars > MAXITEMS )
       NumVars = MAXITEMS;
    
    /* Check for variables with no value */
    if (NumVars % 2) {
        /* Add an extra NULL value */
        p2 = '\0';
        NumVars++;
    }
    
    /* Set the command in the first byte  */
    p[0] = SETCMD;
    /* Place the count in the second byte */
    p[1] = NumVars;
       
    /* Loose the arguments on the stack */
    for ( i = 0; i < items; i++)
        POPs;  
         
   /* Find the other process */
   if (!ConnectToProcess(nPid))
   {
      /* ProcessError ("ConnectToProcess"); */
      UnmapViewOfFile (p);
      CloseHandle (hMap);

      ReleaseMutex(hMutex);     
      CloseHandle(hMutex);
      XSRETURN_UNDEF;
   }

   ReleaseMutex(hMutex);
   CloseHandle(hMutex);

   /* Read the results */
   p2 = p + 2;
   NumVars /= 2;
   NumSent = NumVars;
   
   for (i = 0; i < NumSent; i++) {
      BOOL bResult = (BOOL)*p2;
      
      if (!bResult) NumVars--;
      p2 += sizeof(BOOL);
   }

   UnmapViewOfFile (p);
   CloseHandle (hMap);

   RETVAL = (int)NumVars;
   
   OUTPUT:
         RETVAL



SV * 
GetEnvProcess(nPid, ...)
    int nPid;
   
    PROTOTYPE: $@

    CODE:

    DWORD  dwRetn;
    HANDLE hMutex; 
    HANDLE hMap; 
    char *p;
    char *p2;
    int i;
    int NumVars = 0;   /* Used for a return code */

    /* Default return value - false (On error) */
    RETVAL = 0; 
      
    /* Can we find the DLL? */
    if (!FindDll())
        XSRETURN_UNDEF;
   
    /* Create and grab the mutex */
    hMutex = CreateMutex (NULL, FALSE, MUTEXNAME);
   
    if (hMutex == NULL) {
       /* ProcessError ("CreateMutex"); */
       XSRETURN_UNDEF;
    }
  
    dwRetn = WaitForSingleObject (hMutex, INFINITE);
    
    if (dwRetn != WAIT_OBJECT_0) {
       /* If we get back WAIT_ABANDONED then we exit anyway */
       /* Any others waiting will also get WAIT_ABANDONED   */
       CloseHandle (hMutex);
       XSRETURN_UNDEF;
    }
  
    /* Create the shared memory area */

    p = NULL;

    hMap = CreateFileMapping (INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                 0, MAXSIZE, FMONAME);

    if (hMap)
        p = MapViewOfFile (hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);

    if (p == NULL) {
        /* ProcessError ("MapViewOfFile"); */
        CloseHandle (hMap);

        ReleaseMutex(hMutex);     
        CloseHandle(hMutex);
        XSRETURN_UNDEF;
    }

    p2 = p+2;   /* Reserve the first two bytes */
    
    for (i = 1; i < items; i++) {
       STRLEN n_a;
       strcpy (p2, (char *)SvPV(ST(i), n_a));       
       p2 += strlen(p2)+1;
       
       /* avoid overflowing the shared area */
       if ((p2 - p) >= MAXSIZE || i >= MAXITEMS) {   
          break;
       }
    }
    
    /* Tweek the number of items */
    NumVars = i - 1;
    if ( NumVars > MAXITEMS )
       NumVars = MAXITEMS;
        
    /* Set the command in the first byte  */
    p[0] = GETCMD;
    /* Place the count in the second byte */
    p[1] = NumVars;
       
    /* Loose the arguments on the stack */
    for ( i = 0; i < items; i++)
        POPs;  
         
   /* Find the other process */
   if (!ConnectToProcess(nPid))
   {
      /* ProcessError ("ConnectToProcess"); */
      UnmapViewOfFile (p);
      CloseHandle (hMap);

      ReleaseMutex(hMutex);     
      CloseHandle(hMutex);
      XSRETURN_UNDEF;
   }
   
   /* DEBUG 
   if (p[0] != GETCMD) {
       char err[42];
       sprintf (err, "Error: 0x%x\n", p[0]);
       ProcessError (err);
   }
   */
   
   /* Read the returned variables and place them on the stack */
   p2 = p + 2;
      
   for (i = 0; i < NumVars; i++) {
      int iLen = strlen(p2);
      
      XPUSHs(sv_2mortal(newSVpvn (p2, iLen))); 
      p2 += iLen + 1;
   }
   
   ReleaseMutex(hMutex);   
   CloseHandle(hMutex);

   UnmapViewOfFile (p);
   CloseHandle (hMap);
   
   /* Return the list on the stack */
   XSRETURN(NumVars);

   OUTPUT:
         RETVAL

int 
DelEnvProcess (nPid, ...)
    int nPid;
   
    PROTOTYPE: $@

    CODE:

    DWORD  dwRetn;
    HANDLE hMutex;
    HANDLE hMap; 
    char *p;
    char *p2;
    int i;
    int NumVars = 0;   /* Used for a return code */
    int NumSent;
    
    /* Default return value - false (On error) */
    RETVAL = 0; 

    /* 'items' is the number of arguments, placed by perl */
   
    if ( items < 2 ) {
       XSRETURN_UNDEF;
    }
      
    /* Can we find the DLL? */
    if (!FindDll())
        XSRETURN_UNDEF;
        
    /* Create and grab the mutex */
    hMutex = CreateMutex (NULL, FALSE, MUTEXNAME);
   
    if (hMutex == NULL) {
       /* ProcessError ("CreateMutex"); */
       XSRETURN_UNDEF;
    }
  
    dwRetn = WaitForSingleObject (hMutex, INFINITE);
    
    if (dwRetn != WAIT_OBJECT_0) {
       /* If we get back WAIT_ABANDONED then we exit anyway */
       /* Any others waiting will also get WAIT_ABANDONED   */
       CloseHandle (hMutex);
       XSRETURN_UNDEF;
    }
  
    /* Create the shared memory area */

    p = NULL;

    hMap = CreateFileMapping (INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                              0, MAXSIZE, FMONAME);

    if (hMap)
        p = MapViewOfFile (hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);

    if (p == NULL) {
        /* ProcessError ("MapViewOfFile"); */
        CloseHandle (hMap);

        ReleaseMutex(hMutex);     
        CloseHandle(hMutex);
        XSRETURN_UNDEF;
    }

    p2 = p+2;   /* Reserve the first two bytes */
    
    for (i = 1; i < items; i++) {
       STRLEN n_a;
       strcpy (p2, (char *)SvPV(ST(i), n_a));       
       p2 += strlen(p2)+1;
       
       /* avoid overflowing the shared area */
       if ((p2 - p) >= MAXSIZE || i >= MAXITEMS) {   
          break;
       }
    }
    
    /* Tweek the number of items */
    NumVars = i - 1;
    if ( NumVars > MAXITEMS )
       NumVars = MAXITEMS;
    
    /* Set the command in the first byte  */
    p[0] = DELCMD;
    /* Place the count in the second byte */
    p[1] = NumVars;
       
    /* Loose the arguments on the stack */
    for ( i = 0; i < items; i++)
        POPs;  
         
   /* Find the other process */
   if (!ConnectToProcess(nPid))
   {
      /* ProcessError ("ConnectToProcess"); */
      UnmapViewOfFile (p);
      CloseHandle (hMap);

      ReleaseMutex(hMutex);     
      CloseHandle(hMutex);
      XSRETURN_UNDEF;
   }

   ReleaseMutex(hMutex);   
   CloseHandle(hMutex);

   /* Read the results */
   p2 = p + 2;
   NumSent = NumVars;
   
   for (i = 0; i < NumSent; i++) {
      BOOL bResult = (BOOL)*p2;
      
      if (!bResult) NumVars--;
      p2 += sizeof(BOOL);
   }

   UnmapViewOfFile (p);
   CloseHandle (hMap);

   RETVAL = (int)NumVars;
   
   OUTPUT:
         RETVAL


SV * 
GetPids(InszExeName, ...)
    const char *InszExeName;
   
    PROTOTYPE: $

    CODE:

    DWORD dwProcs[MAXPROCESSES] = {0};
    DWORD dwRetn = 0;
    int PIDs = 0;
    size_t numProcesses;
    size_t i;
    char szExeName[MAX_PATH];

    /* Loose the arguments on the stack */
    for ( i = 0; i < (size_t)items; i++)
        POPs;  

    if (!EnumProcesses (dwProcs, MAXPROCESSES, &dwRetn)) {
	//ProcessError("EnumProcesses");
	XSRETURN_UNDEF;
    }

    strcpy (szExeName, InszExeName);
    strtolower (szExeName);
    
    numProcesses = dwRetn / sizeof(DWORD);

    for ( i = 0; i < numProcesses; i++ ) {
         
        if (GetProcessNameAndID( dwProcs[i], szExeName)) {
	         
	   /* Place the PID on the stack */
           XPUSHs(sv_2mortal(newSVuv(dwProcs[i]))); 
           PIDs++;
        }
    }

    XSRETURN(PIDs);
    
    /* RETVAL=PIDs; */

    OUTPUT:
         RETVAL
