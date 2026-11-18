# toolkit-census.ps1 — read-only census of the visible desktop, by toolkit family.
#
# WHY THIS IS THE LAST P0 NUMBER. The gate asks whether measured coverage supports the
# product claim. The neutrality experiment answers "which channels are focus-neutral on
# THESE targets"; the claim is about the user's desktop in general, so the share of the
# desktop each family represents is part of the verdict, and it is the one number that
# cannot be argued from intuition.
#
# It is deliberately observational: EnumWindows + class names + titles. No UIA pattern
# calls, no writes, no activation, nothing that could disturb the user's session.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class Census {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP c, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
  [DllImport("shcore.dll")] static extern int GetWindowDpiAwarenessContext(IntPtr h, out IntPtr ctx);

  public class Row {
    public string hwnd; public string cls; public string title; public int pid;
    public string proc; public string family; public string processName;
    public int w, h; public bool real; public int dpi;
  }

  static string Family(string cls, string title, string proc) {
    if (cls == "Chrome_WidgetWin_1" || cls == "Chrome_WidgetWin_0") {
      // Chromium and Electron share the class; the process name tells them apart.
      if (proc == "msedge" || proc == "chrome") return "chromium-browser";
      return "electron/chromium-app";
    }
    // WinUI 3 desktop apps: this is the family the desktop is increasingly made of, and
    // it was silently landing in "other" on the first run of this census.
    if (cls == "WinUIDesktopWin32WindowClass") return "winui3-desktop";
    // UWP/WinUI content host, and its frame window. Both XAML-provider families.
    if (cls == "Windows.UI.Core.CoreWindow") return "uwp-corewindow";
    if (cls == "ApplicationFrameWindow" || cls == "ApplicationFrameHost") return "uap-framed";
    if (cls == "CabinetWClass" || cls == "ExploreWClass") return "win32-shell";
    if (cls == "Notepad" || cls == "Pizenet_WindowClass") return "winui-notepad";
    if (cls.StartsWith("WindowsForms")) return "winforms";
    if (cls.StartsWith("HwndWrapper")) return "wpf";
    if (cls == "CASCADIA_HOSTING_WINDOW_CLASS" || cls == "ConsoleWindowClass") return "terminal";
    if (cls == "MozillaWindowClass") return "gecko";
    if (cls.StartsWith("Qt")) return "qt";
    // GPU-native / raw-input apps (Zed, winit/glfw/sdl): they often own their input
    // surface directly, which is the family PostMessage cannot address.
    if (cls.EndsWith("::Window") || cls.StartsWith("SDL") || cls.StartsWith("GLFW") ||
        cls.StartsWith("winit")) return "native/raw-input";
    if (cls.StartsWith("CEF-") || cls == "CefBrowserWindow") return "embedded-cef";
    if (cls == "wxWindowClassNR" || cls == "wxWindowClass") return "wxwidgets";
    if (cls.StartsWith("TK")) return "tk";
    if (cls == "Auto-Save Document Window" || cls == "OpusApp") return "office-win32";
    if (cls == "Progman" || cls == "WorkerW") return "shell-desktop";
    return "other:" + cls;
  }

  public static List<Row> Run() {
    List<Row> acc = new List<Row>();
    EP cb = delegate (IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      int n = GetWindowTextLengthW(h);
      StringBuilder sb = new StringBuilder(512);
      GetWindowTextW(h, sb, sb.Capacity);
      string title = sb.ToString();
      StringBuilder cls = new StringBuilder(512);
      GetClassNameW(h, cls, cls.Capacity);
      RECT r; GetWindowRect(h, out r);
      int w = r.r - r.l, hh = r.b - r.t;
      uint pid; GetWindowThreadProcessId(h, out pid);
      string procName = "";
      try { procName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
      // Filter: a real app window has a title and a reasonable size, and is not a tool
      // window or an invisible shell helper. Inclusion criteria are stated rather than
      // hidden so the census denominator can be audited.
      bool real = n > 0 && w >= 120 && hh >= 80 && cls.ToString() != "Tooltip" &&
                  !cls.ToString().StartsWith("MSCTF") && cls.ToString() != "#32770";
      Row row = new Row();
      row.hwnd = h.ToInt64().ToString();
      row.cls = cls.ToString();
      row.title = title.Length > 60 ? title.Substring(0, 60) : title;
      row.pid = (int)pid;
      row.proc = procName;
      row.processName = procName;
      row.family = Family(cls.ToString(), title, procName);
      row.w = w; row.h = hh; row.real = real;
      acc.Add(row);
      return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    return acc;
  }
}
'@

$all = [Census]::Run()
$real = @($all | Where-Object { $_.real })
$byProc = $real | Group-Object processName | Sort-Object Count -Descending
$byFamily = $real | Group-Object family | Sort-Object Count -Descending

# Deduplicate by process for the per-app read: Chromium apps report many windows per
# process, and counting each would over-weight exactly the family under examination.
$appsByProc = @{}
foreach ($r in $real) {
  if (-not $appsByProc.ContainsKey($r.proc)) { $appsByProc[$r.proc] = @{ name = $r.proc; family = $r.family; windows = 0 } }
  $appsByProc[$r.proc].windows += 1
}
$appList = @($appsByProc.Values)
# Accumulated by hand rather than `Group-Object family`: over an array of hashtables the
# property lookup yields nothing, so every app collapsed into ONE empty-named group --
# "17 apps in a family called ''", which would have been quoted as a headline number.
$famApps = @{ }
foreach ($a in $appList) {
  $k = [string]$a.family
  if (-not $famApps.ContainsKey($k)) { $famApps[$k] = 0 }
  $famApps[$k] = $famApps[$k] + 1
}
$familyAppCount = @($famApps.Keys | Sort-Object { $famApps[$_] } -Descending | ForEach-Object {
  @{ family = $_; apps = $famApps[$_] }
})

[ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  visibleTopLevel = $all.Count
  realAppWindows = $real.Count
  distinctAppProcesses = $appList.Count
  byFamilyWindows = @($byFamily | ForEach-Object { @{ family = $_.Name; windows = $_.Count } })
  byFamilyApps = @($familyAppCount | ForEach-Object { @{ family = $_.Name; apps = $_.Count } })
  apps = @($appList | Sort-Object -Property windows -Descending | ForEach-Object { @{ proc = $_.name; family = $_.family; windows = $_.windows } })
  # The share the verdict needs: window count and app count for the families where the
  # measured focus-neutral envelope does NOT hold (chromium/electron, uap-xaml writes).
  shareWindowsNeutralEnvelope = if ($real.Count) { [math]::Round(100 * @($real | Where-Object { $_.family -in 'winforms', 'wpf', 'win32-shell', 'terminal' }).Count / $real.Count, 1) } else { 0 }
  shareWindowsChromiumFamily = if ($real.Count) { [math]::Round(100 * @($real | Where-Object { $_.family -match 'chromium|electron' }).Count / $real.Count, 1) } else { 0 }
  shareAppsChromiumFamily = if ($appList.Count) { [math]::Round(100 * @($appList | Where-Object { $_.family -match 'chromium|electron' }).Count / $appList.Count, 1) } else { 0 }
} | ConvertTo-Json -Depth 5
