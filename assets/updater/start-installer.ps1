param([Parameter(Mandatory=$true)][string]$ConfigurationPath)
# ASCII-only broker. The worker must explicitly leave Mumpa's kill-on-close
# job. Start-Process and Dart detached modes still inherit that job.
$ErrorActionPreference = 'Stop'
try {
    $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding utf8 | ConvertFrom-Json
    $literalPath = $ConfigurationPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$configuration = Get-Content -LiteralPath '$literalPath' -Raw -Encoding utf8 | ConvertFrom-Json
`$parameters = @{}
foreach (`$property in `$configuration.Parameters.PSObject.Properties) {
    `$parameters[`$property.Name] = `$property.Value
}
& `$configuration.RunnerPath @parameters 1> `$configuration.StdoutPath 2> `$configuration.StderrPath
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class MumpaInstallerProcess {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
        public short showWindow, reservedSize;
        public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo {
        public IntPtr process, thread;
        public int processId, threadId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string application, StringBuilder command,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo info);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    public static int Start(string executable, string arguments) {
        var startup = new StartupInfo();
        startup.cb = Marshal.SizeOf(startup);
        ProcessInfo info;
        // Explicit job breakaway and no console. Never inherit Dart pipes or
        // Mumpa's job handle, which would keep its service processes alive.
        if (!CreateProcessW(executable,
            new StringBuilder("\"" + executable + "\" " + arguments),
            IntPtr.Zero, IntPtr.Zero, false, 0x01000000 | 0x08000000,
            IntPtr.Zero, null, ref startup, out info)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        CloseHandle(info.thread);
        CloseHandle(info.process);
        return info.processId;
    }
}
'@
    $workerId = [MumpaInstallerProcess]::Start((Join-Path $PSHOME 'powershell.exe'),
        ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded))
    [ordered]@{ processId=$workerId } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}
