using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyVersion("1.2.27.35")]
[assembly: AssemblyInformationalVersion("1.2.27+35")]
public class MumpaUpdateJobHost {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long processTime, jobTime;
        public uint flags;
        public UIntPtr minimum, maximum;
        public uint active;
        public UIntPtr affinity;
        public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits basic;
        public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int type,
        ref ExtendedLimits limits, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    public static void Main(string[] args) {
        if (args.Length > 1) {
            // Same limits as windows/runner/main.cpp. A normal service child
            // must die, while the installer must survive this host exiting.
            var job = CreateJobObject(IntPtr.Zero, null);
            var limits = new ExtendedLimits();
            limits.basic.flags = 0x2000 | 0x800; // KILL_ON_CLOSE | BREAKAWAY_OK
            if (job == IntPtr.Zero ||
                !SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(limits)) ||
                !AssignProcessToJobObject(job, Process.GetCurrentProcess().Handle))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var service = Process.Start(new ProcessStartInfo {
                FileName = Assembly.GetExecutingAssembly().Location,
                Arguments = "\"" + args[0] + ".never\"",
                UseShellExecute = false, CreateNoWindow = true
            });
            File.WriteAllText(args[0] + ".service", service.Id.ToString());
            var broker = Process.Start(new ProcessStartInfo {
                FileName = args[1], Arguments = args[2],
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            });
            // Legacy workers inherit the pipe handles. Match Dart's one-line
            // acknowledgement rather than waiting for EOF from the installer.
            var output = broker.StandardOutput.ReadLine();
            broker.WaitForExit();
            var error = broker.ExitCode == 0 ? "" : broker.StandardError.ReadToEnd();
            File.WriteAllText(args[0] + ".broker", output + error);
            if (broker.ExitCode != 0) Environment.Exit(broker.ExitCode);
            // Keep the job handle open until process exit.
            GC.KeepAlive(job);
        }
        while (!File.Exists(args[0])) Thread.Sleep(25);
    }
}
