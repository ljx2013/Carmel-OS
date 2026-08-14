#!/usr/bin/env python3
"""
Generate Build-CarmelOS.exe — a native Windows executable that
embeds Build-CarmelOS.ps1 and runs it through powershell.exe.
"""
import sys
import os

PS1_FILE = "Build-CarmelOS.ps1"
C_FILE   = "build-carmelos-exe.c"
EXE_FILE = "Build-CarmelOS.exe"

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ps1_path = os.path.join(script_dir, PS1_FILE)

    if not os.path.exists(ps1_path):
        print(f"ERROR: {ps1_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(ps1_path, "rb") as f:
        ps1_bytes = f.read()

    # Generate C source with embedded PS1 as a byte array
    hex_lines = []
    for i in range(0, len(ps1_bytes), 12):
        chunk = ps1_bytes[i:i+12]
        hex_vals = ", ".join(f"0x{b:02x}" for b in chunk)
        hex_lines.append(f"    {hex_vals},")

    hex_data = "\n".join(hex_lines)

    c_source = f'''/*
 * Build-CarmelOS.exe - Windows console launcher for CarmelOS ISO build.
 *
 * Embeds Build-CarmelOS.ps1 and executes it via powershell.exe.
 * Cross-compiled with mingw-w64 (x86_64-w64-mingw32-gcc).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Embedded PowerShell script ({len(ps1_bytes)} bytes) */
static const unsigned char ps_script[{len(ps1_bytes) + 1}] = {{
{hex_data}
    0x00
}};

static char* get_temp_dir(void) {{
    static char tmp[MAX_PATH];
    DWORD len = GetTempPathA(MAX_PATH, tmp);
    if (len == 0 || len >= MAX_PATH) {{
        strcpy(tmp, "C:\\\\Temp\\\\");
    }}
    return tmp;
}}

int main(int argc, char* argv[])
{{
    (void)argc; (void)argv;

    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    /* Orange-ish text (FOREGROUND_RED|GREEN|INTENSITY = yellow) */
    SetConsoleTextAttribute(hOut, FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_INTENSITY);

    printf("\\n");
    printf("============================================================\\n");
    printf("  CarmelOS Build Tool v1.0\\n");
    printf("============================================================\\n");
    printf("  Orange & White  -  Xfce Live ISO\\n");
    printf("\\n");

    SetConsoleTextAttribute(hOut, FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE);

    /* Write the embedded PS1 to a temp file */
    char ps1_path[MAX_PATH];
    char* tmp_dir = get_temp_dir();
    snprintf(ps1_path, MAX_PATH, "%sCarmelOS_build_%lu.ps1", tmp_dir, GetCurrentProcessId());

    printf("[CarmelOS] Extracting build script to: %s\\n", ps1_path);

    HANDLE hFile = CreateFileA(ps1_path, GENERIC_WRITE, 0, NULL,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {{
        fprintf(stderr, "[ERROR] Cannot create temp file: %s\\n", ps1_path);
        return 1;
    }}

    DWORD written;
    if (!WriteFile(hFile, ps_script, {len(ps1_bytes)}, &written, NULL)) {{
        fprintf(stderr, "[ERROR] WriteFile failed\\n");
        CloseHandle(hFile);
        return 1;
    }}
    CloseHandle(hFile);

    /* Build the powershell.exe command line, passing through any user args */
    char powershell_cmd[32768];
    char* full_cmd = GetCommandLineA();

    /* Skip the exe name in the command line to get user args */
    char* user_args = "";
    if (full_cmd) {{
        if (full_cmd[0] == '"') {{
            char* end = strchr(full_cmd + 1, '"');
            if (end && *(end + 1)) user_args = end + 2;
        }} else {{
            char* space = strchr(full_cmd, ' ');
            if (space && *(space + 1)) user_args = space + 1;
        }}
    }}

    snprintf(powershell_cmd, sizeof(powershell_cmd),
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \\"%s\\" %s",
        ps1_path, user_args);

    /* Execute */
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    SetConsoleTextAttribute(hOut, FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_INTENSITY);
    printf("[CarmelOS] Launching PowerShell build script...\\n\\n");
    SetConsoleTextAttribute(hOut, FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE);

    if (!CreateProcessA(NULL, powershell_cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {{
        fprintf(stderr, "[ERROR] CreateProcess failed (error %lu). Is PowerShell installed?\\n",
                GetLastError());
        DeleteFileA(ps1_path);
        printf("\\nPress Enter to exit...\\n");
        getchar();
        return 1;
    }}

    /* Wait for PowerShell to finish */
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD exit_code = 1;
    GetExitCodeProcess(pi.hProcess, &exit_code);

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    /* Clean up temp file */
    DeleteFileA(ps1_path);

    /* Print result */
    printf("\\n");
    if (exit_code == 0) {{
        SetConsoleTextAttribute(hOut, FOREGROUND_GREEN | FOREGROUND_INTENSITY);
        printf("[OK] CarmelOS build completed successfully!\\n");
    }} else {{
        SetConsoleTextAttribute(hOut, FOREGROUND_RED | FOREGROUND_INTENSITY);
        printf("[ERROR] Build failed (exit code %lu).\\n", exit_code);
    }}
    SetConsoleTextAttribute(hOut, FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE);

    printf("\\nPress Enter to exit...\\n");
    getchar();

    return (int)exit_code;
}}
'''

    c_path = os.path.join(script_dir, C_FILE)
    with open(c_path, "w") as f:
        f.write(c_source)

    print(f"Generated {C_FILE} ({len(c_source)} bytes)")

    # Compile with mingw cross-compiler
    exe_path = os.path.join(script_dir, EXE_FILE)
    import subprocess
    result = subprocess.run(
        ["x86_64-w64-mingw32-gcc", "-O2", "-o", exe_path, c_path,
         "-mconsole", "-lkernel32", "-luser32"],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f"ERROR: Compilation failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    exe_size = os.path.getsize(exe_path)
    print(f"Compiled {EXE_FILE} ({exe_size} bytes)")

if __name__ == "__main__":
    main()
