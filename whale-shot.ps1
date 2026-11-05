<#
    whale-shot.ps1  —  桌面悬浮小鲸鱼：框选截图 -> 写字 -> 填进 DeepSeek Harness 输入框

    用法:
        powershell -STA -ExecutionPolicy Bypass -File whale-shot.ps1
        powershell -ExecutionPolicy Bypass -File whale-shot.ps1 -TestWindow
        powershell -ExecutionPolicy Bypass -File whale-shot.ps1 -TestCapture -OutFile shot.png

    坐标模型（本机实测）:
        该进程里 Win32 坐标是 DIP，系统会乘上缩放比（这台机器 150%）；
        而 Screen/SystemInformation 报的是物理像素。所以：
            布局一律用 DIP；位图按 DIP * 缩放 渲染；截图区域 DIP * 缩放 得到物理矩形。
#>
[CmdletBinding()]
param(
    [switch]$TestWindow,
    [switch]$TestCapture,
    [switch]$TestOverlay,
    [switch]$TestPanel,
    [switch]$TestClipboard,
    [switch]$TestSend,
    [switch]$TestToast,
    [switch]$TestFocus,
    [switch]$TestComposer,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

# 注意：System.Windows.Forms 必须等 EnsureDpi() 之后再加载，
# 否则 WinForms 会按「DPI 不感知」初始化，之后所有坐标空间都会漂移。
Add-Type -AssemblyName System.Drawing

$script:Root     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Assets   = Join-Path $script:Root 'assets'
$script:ShotsDir = Join-Path $script:Root 'shots'
$script:LogPath  = Join-Path $script:Root 'whale-shot.log'
$script:CfgPath  = Join-Path $script:Root 'config.json'

function Write-Log {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -ErrorAction SilentlyContinue `
            -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    } catch { }
}

# ---------------------------------------------------------------- Win32 ----------------------------------------------------------------

$csharp = @'
using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Threading;
using System.Runtime.InteropServices;

public static class Wh
{
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();

    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();

    public static bool InputKeysReleased() {
        foreach (int vk in new int[] { 0x0D, 0x10, 0x11, 0x12, 0x01 }) {
            if ((GetAsyncKeyState(vk) & 0x8000) != 0) return false;
        }
        return true;
    }
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int idx);
    [StructLayout(LayoutKind.Sequential)] public struct RECTW { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, ref RECTW rect, uint winIni);

    // 工作区，单位与窗口坐标一致（这台机器上就是 DIP），避免和 Screen 的物理像素混用
    public static int[] WorkArea() {
        RECTW r = new RECTW();
        bool ok = SystemParametersInfo(0x0030, 0, ref r, 0);
        if (!ok || r.R <= r.L || r.B <= r.T) {
            return new int[] { 0, 0, GetSystemMetrics(0), GetSystemMetrics(1) };
        }
        return new int[] { r.L, r.T, r.R - r.L, r.B - r.T };
    }

    public static int[] ScreenSize() {
        return new int[] { GetSystemMetrics(0), GetSystemMetrics(1) };
    }

    [StructLayout(LayoutKind.Sequential)] public struct RECTG { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECTG r);
    public static int[] RectOf(IntPtr h) {
        RECTG r;
        if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 };
        return new int[] { r.L, r.T, r.R - r.L, r.B - r.T };
    }

    [StructLayout(LayoutKind.Sequential)] public struct RECTD { public int L, T, R, B; }
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);
    // DESKTOPHORZRES / DESKTOPVERTRES：永远是物理像素，不受 DPI 虚拟化影响
    public static int[] PhysicalScreen() {
        IntPtr dc = GetDC(IntPtr.Zero);
        try {
            return new int[] { GetDeviceCaps(dc, 118), GetDeviceCaps(dc, 117) };
        } finally {
            ReleaseDC(IntPtr.Zero, dc);
        }
    }

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION {
        public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BMIH {
        public uint biSize; public int biWidth; public int biHeight; public ushort biPlanes; public ushort biBitCount;
        public uint biCompression; public uint biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public uint biClrUsed; public uint biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BMI { public BMIH h; public uint c; }

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BMI pbmi, uint usage, out IntPtr bits, IntPtr hSection, uint offset);
    [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")] public static extern void CopyMemory(IntPtr dest, IntPtr src, uint count);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst,
        ref POINT dst, ref SIZE size, IntPtr hdcSrc, ref POINT src, int crKey, ref BLENDFUNCTION blend, int flags);

    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION U; }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

    public static void EnsureDpi() {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { try { SetProcessDPIAware(); } catch { } }
    }

    public static int Dpi() {
        try { return (int)GetDpiForSystem(); } catch { return 96; }
    }

    public static string Title(IntPtr h) {
        int len = GetWindowTextLength(h);
        if (len <= 0) return "";
        StringBuilder sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static IntPtr FindWindowSuffix(string suffix, int excludePid) {
        IntPtr found = IntPtr.Zero;
        EnumProc cb = delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            if (GetWindowTextLength(h) <= 0) return true;
            if (!Title(h).EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if ((int)pid == excludePid) return true;
            found = h;
            return false;
        };
        EnumWindows(cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        return found;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECTW rcCaret;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);

    // 当前前台窗口所属线程的键盘焦点窗口
    public static IntPtr FocusWindow() {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return IntPtr.Zero;
        uint pid;
        uint tid = GetWindowThreadProcessId(fg, out pid);
        GUITHREADINFO g = new GUITHREADINFO();
        g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (!GetGUIThreadInfo(tid, ref g)) return IntPtr.Zero;
        return g.hwndFocus;
    }

    // Native routing guard only. The automation worker separately verifies the actual editor.
    public static bool InputGoesTo(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return false;
        if (GetForegroundWindow() != hwnd) return false;
        IntPtr foc = FocusWindow();
        if (foc == IntPtr.Zero) return false;
        uint a, b;
        GetWindowThreadProcessId(hwnd, out a);
        GetWindowThreadProcessId(foc, out b);
        return GetAncestor(foc, 2) == hwnd || a == b;
    }

    public static string FocusInfo() {
        IntPtr fg = GetForegroundWindow();
        IntPtr foc = FocusWindow();
        uint a = 0, b = 0;
        if (fg != IntPtr.Zero) GetWindowThreadProcessId(fg, out a);
        if (foc != IntPtr.Zero) GetWindowThreadProcessId(foc, out b);
        return String.Format("fg=0x{0:X}({1}) focus=0x{2:X}({3})", fg.ToInt64(), a, foc.ToInt64(), b);
    }

    public static bool Activate(IntPtr h, int tries) {
        if (IsIconic(h)) ShowWindow(h, 9);
        uint pid;
        uint targetThread = GetWindowThreadProcessId(h, out pid);
        uint myThread = GetCurrentThreadId();
        for (int i = 0; i < tries; i++) {
            if (GetForegroundWindow() == h) return true;
            IntPtr fg = GetForegroundWindow();
            uint fgPid;
            uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
            bool a1 = AttachThreadInput(myThread, fgThread, true);
            // Attach queues only while activating; preserve the target's existing child focus.
            bool a2 = false;
            if (targetThread != fgThread) a2 = AttachThreadInput(myThread, targetThread, true);
            try {
                // 伪 ALT：让系统认为刚有用户输入，从而解开前台锁
                keybd_event(0x12, 0, 0, UIntPtr.Zero);
                keybd_event(0x12, 0, 2, UIntPtr.Zero);
                BringWindowToTop(h);
                SetForegroundWindow(h);
                SwitchToThisWindow(h, true);
                // The UI Automation worker focuses the editor, never the top-level window.
            } finally {
                if (a2) AttachThreadInput(myThread, targetThread, false);
                if (a1) AttachThreadInput(myThread, fgThread, false);
            }
            Thread.Sleep(60);
        }
        return GetForegroundWindow() == h;
    }

    public static void MakeLayered(IntPtr h) {
        int ex = GetWindowLong(h, -20);
        SetWindowLong(h, -20, ex | 0x80000);
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
    }

    // 只挪位置：分层窗口移动时位图跟着走，不用重新 UpdateLayeredWindow
    public static void Move(IntPtr h, int x, int y) {
        SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);
    }

    public static void UnmakeLayered(IntPtr h) {
        int ex = GetWindowLong(h, -20);
        SetWindowLong(h, -20, ex & ~0x80000);
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
    }

    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);

    // Win11：无边框窗口也能拿到平滑圆角 + 1px 边框（attr 33 / 34）
    public static bool RoundCorners(IntPtr h) {
        int pref = 2;                     // DWMWCP_ROUND
        int r1 = DwmSetWindowAttribute(h, 33, ref pref, 4);
        int color = 0x00F4EBE7;           // COLORREF(BGR) of #E7EBF4
        int r2 = DwmSetWindowAttribute(h, 34, ref color, 4);
        return r1 == 0;
    }

    // 父窗口重绘时把子控件区域排除掉，否则原生 TextBox 会被擦一下再重画（闪）
    public static void ClipChildren(IntPtr h) {
        int style = GetWindowLong(h, -16);
        SetWindowLong(h, -16, style | 0x02000000);   // WS_CLIPCHILDREN
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
    }

    // bmp 是「DIP * DPI 缩放」的物理位图；sizeDip 是窗口的逻辑尺寸（ULW 会再乘一次缩放）。
    public static bool ApplyLayered(IntPtr hwnd, Bitmap bmp, int xdip, int ydip, int sizeDip) {
        int w = bmp.Width, h = bmp.Height;
        Bitmap src = bmp;
        bool converted = false;
        if (bmp.PixelFormat != PixelFormat.Format32bppPArgb) {
            src = bmp.Clone(new Rectangle(0, 0, w, h), PixelFormat.Format32bppPArgb);
            converted = true;
        }
        BitmapData bd = src.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        IntPtr sdc = GetDC(IntPtr.Zero);
        IntPtr mdc = CreateCompatibleDC(sdc);
        BMI bi = new BMI();
        bi.h.biSize = (uint)Marshal.SizeOf(typeof(BMIH));
        bi.h.biWidth = w; bi.h.biHeight = -h; bi.h.biPlanes = 1; bi.h.biBitCount = 32; bi.h.biCompression = 0;
        IntPtr bits;
        IntPtr dib = CreateDIBSection(mdc, ref bi, 0, out bits, IntPtr.Zero, 0);
        bool ok = false;
        if (dib != IntPtr.Zero && bits != IntPtr.Zero) {
            for (int r = 0; r < h; r++) {
                CopyMemory(new IntPtr(bits.ToInt64() + (long)r * w * 4),
                           new IntPtr(bd.Scan0.ToInt64() + (long)r * bd.Stride),
                           (uint)(w * 4));
            }
            IntPtr old = SelectObject(mdc, dib);
            SIZE sz = new SIZE(); sz.cx = sizeDip; sz.cy = sizeDip;
            POINT ps = new POINT(); ps.x = 0; ps.y = 0;
            POINT pd = new POINT(); pd.x = xdip; pd.y = ydip;
            BLENDFUNCTION bf = new BLENDFUNCTION();
            bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1;
            ok = UpdateLayeredWindow(hwnd, sdc, ref pd, ref sz, mdc, ref ps, 0, ref bf, 2);
            SelectObject(mdc, old);
            DeleteObject(dib);
        }
        src.UnlockBits(bd);
        DeleteDC(mdc);
        ReleaseDC(IntPtr.Zero, sdc);
        if (converted) src.Dispose();
        return ok;
    }

    private static INPUT Key(ushort vk, ushort scan, uint flags) {
        INPUT i = new INPUT();
        i.type = 1;
        i.U.ki.wVk = vk; i.U.ki.wScan = scan; i.U.ki.dwFlags = flags;
        i.U.ki.time = 0; i.U.ki.dwExtraInfo = IntPtr.Zero;
        return i;
    }

    public static uint CtrlV() {
        INPUT[] a = new INPUT[] { Key(0x11, 0, 0), Key(0x56, 0, 0), Key(0x56, 0, 2), Key(0x11, 0, 2) };
        uint r = SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        return r;
    }

    private static uint ShiftEnter() {
        INPUT[] a = new INPUT[] { Key(0x10, 0, 0), Key(0x0D, 0, 0), Key(0x0D, 0, 2), Key(0x10, 0, 2) };
        uint r = SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(8);
        return r;
    }

    public static int TypeText(string s, IntPtr target) {
        if (String.IsNullOrEmpty(s)) return 0;
        int sent = 0;
        foreach (char c in s) {
            if (c == '\r') continue;
            if (!InputGoesTo(target) || !InputKeysReleased()) break;
            if (c == '\n') {
                uint line = ShiftEnter();
                sent += (int)line;
                if (line != 4) break;
                continue;
            }
            INPUT[] a = new INPUT[] { Key(0, (ushort)c, 4), Key(0, (ushort)c, 6) };
            uint count = SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
            sent += (int)count;
            if (count != a.Length) break;
            Thread.Sleep(3);
        }
        return sent;
    }
}
'@

if (-not ('Wh' -as [type])) {
    Add-Type -TypeDefinition $csharp -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Drawing.dll')
}

[Wh]::EnsureDpi()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies @('System.dll', 'System.Windows.Forms.dll') -TypeDefinition @'
public class WhaleComposeBox : System.Windows.Forms.TextBox {
    public bool CompositionActive;
    public System.DateTime CompositionEnded = System.DateTime.MinValue;
    protected override void WndProc(ref System.Windows.Forms.Message m) {
        if (m.Msg == 0x010D) CompositionActive = true;
        if (m.Msg == 0x010E) { CompositionActive = false; CompositionEnded = System.DateTime.UtcNow; }
        base.WndProc(ref m);
    }
    public bool IsImeEnter() {
        return CompositionActive || (System.DateTime.UtcNow - CompositionEnded).TotalMilliseconds < 120;
    }
}
'@

# 运行时自校准：有的启动方式（例如 wscript 隐藏控制台）会让进程的 DPI 感知被提前固定，
# 此时窗口坐标是"虚拟"的 1707，而屏幕真实是 2560。用物理像素 / 窗口坐标求出比例，就不必猜。
$phys        = [Wh]::PhysicalScreen()
$script:PhysW = $phys[0]
$script:PhysH = $phys[1]
$script:WinW  = [Wh]::GetSystemMetrics(0)
$script:WinH  = [Wh]::GetSystemMetrics(1)
$script:R     = if ($script:WinW -gt 0) { [double]$script:PhysW / $script:WinW } else { 1.0 }

function To-Physical { param([double]$Win) return [int][Math]::Round($Win * $script:R) }
function To-Dip      { param([double]$Px)  return [int][Math]::Round($Px / $script:R) }

# 设计稿是 96 DPI 的 DIP，按实际缩放换算成物理像素
function Px { param([double]$Value) return [int][Math]::Round($Value * $script:Scale) }

# ---------------------------------------------------------------- 配置 ----------------------------------------------------------------

$script:Config = @{
    size         = 69          # 悬浮球画布，DIP
    ballX        = $null       # DIP
    ballY        = $null       # DIP
    keep         = 200
    targetSuffix = 'DeepSeek Harness'
    pasteDelayMs = 450
    hoverScale   = 1.06
}

function Load-Config {
    if (Test-Path -LiteralPath $script:CfgPath) {
        try {
            $raw = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($raw.PSObject.Properties.Name)) { $script:Config[$k] = $raw.$k }
        } catch { Write-Log "config 读取失败: $($_.Exception.Message)" }
    }
}

function Save-Config {
    try {
        $script:Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
    } catch { Write-Log "config 保存失败: $($_.Exception.Message)" }
}

Load-Config
if (-not (Test-Path -LiteralPath $script:ShotsDir)) { New-Item -ItemType Directory -Path $script:ShotsDir -Force | Out-Null }

# ---------------------------------------------------------------- 图像 ----------------------------------------------------------------

function Get-BallBitmap {
    param([int]$PixelSize)
    $path = Join-Path $script:Assets 'whale-chip.png'
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少素材: $path" }
    $src = [System.Drawing.Image]::FromFile($path)
    try {
        $bmp = New-Object System.Drawing.Bitmap($PixelSize, $PixelSize)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($src, 0, 0, $PixelSize, $PixelSize)
        } finally { $g.Dispose() }
        return $bmp
    } finally { $src.Dispose() }
}

function Save-Shot {
    param([System.Drawing.Bitmap]$Bitmap)
    $path = Join-Path $script:ShotsDir ('shot-{0}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Log "saved $path"
    try {
        $files = @(Get-ChildItem -LiteralPath $script:ShotsDir -Filter 'shot-*.png' | Sort-Object LastWriteTime)
        $keep = [int]$script:Config.keep
        if ($keep -gt 0 -and $files.Count -gt $keep) {
            $files | Select-Object -First ($files.Count - $keep) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        }
    } catch { }
    return $path
}

$script:ClipError = ''
function Copy-BitmapToClipboard {
    param([System.Drawing.Bitmap]$Bitmap)
    for ($i = 0; $i -lt 8; $i++) {
        # 快路径：CF_BITMAP，Chromium 的粘贴直接认
        try {
            [System.Windows.Forms.Clipboard]::SetImage($Bitmap)
            return $true
        } catch {
            $script:ClipError = $_.Exception.Message
        }
        # 慢路径：同时提供 PNG 流和位图
        try {
            $data = New-Object System.Windows.Forms.DataObject
            $ms = New-Object System.IO.MemoryStream
            $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $ms.Position = 0
            $data.SetData('PNG', $false, $ms)
            $data.SetImage($Bitmap)
            [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
            return $true
        } catch {
            $script:ClipError = $_.Exception.Message
        }
        Write-Log ("clipboard 第 {0} 次失败: {1}" -f ($i + 1), $script:ClipError)
        Start-Sleep -Milliseconds (120 + $i * 60)
    }
    return $false
}

# ---------------------------------------------------------------- 截图 ----------------------------------------------------------------

function Get-PhysicalScreen {
    return New-Object System.Drawing.Rectangle(0, 0, $script:PhysW, $script:PhysH)
}

function Capture-PhysicalRect {
    param([System.Drawing.Rectangle]$Rect)
    if ($Rect.Width -le 0 -or $Rect.Height -le 0) { throw '选区为空' }
    $bmp = New-Object System.Drawing.Bitmap($Rect.Width, $Rect.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($Rect.X, $Rect.Y, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
    } catch { $g.Dispose(); $bmp.Dispose(); throw }
    $g.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- 写入 DSH ----------------------------------------------------------------

# Bounded UI Automation worker: target accessibility providers can otherwise hang the UI.
function Invoke-ComposerWorker {
    param([hashtable]$Request, [int]$TimeoutMs = 4000)
    $helper = Join-Path $script:Root 'whale-input.ps1'
    if (-not (Test-Path -LiteralPath $helper)) { return @{ Ok=$false; Error='缺少 whale-input.ps1，请重新安装完整更新包' } }
    $requestPath = Join-Path ([IO.Path]::GetTempPath()) ('whale-input-' + [guid]::NewGuid().ToString('N') + '.json')
    $proc = $null
    try {
        [IO.File]::WriteAllText($requestPath, (ConvertTo-Json -InputObject $Request -Depth 4 -Compress), [Text.UTF8Encoding]::new($false))
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $helper + '" -RequestPath "' + $requestPath + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $info
        [void]$proc.Start()
        # Drain both pipes asynchronously, including long accessibility diagnostics.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            $proc.Kill()
            [void]$proc.WaitForExit(1000)
            return @{ Ok=$false; Error='DSH 输入框响应超时，请确认 DSH 没有卡住后重试' }
        }
        $output = $stdout.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0 -or -not $output.Trim()) {
            Write-Log ('composer worker failed: exit=' + $proc.ExitCode)
            return @{ Ok=$false; Error='输入框检查失败，截图和备注已保留' }
        }
        return ($output | ConvertFrom-Json)
    } catch {
        Write-Log ('composer worker exception: ' + $_.Exception.Message)
        return @{ Ok=$false; Error='输入框检查失败，截图和备注已保留' }
    } finally {
        if ($proc) { $proc.Dispose() }
        if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }
    }
}

function Send-ToDsh {
    param([System.Drawing.Bitmap]$Bitmap, [string]$Text, [string]$Trigger = 'button')

    $script:TransferStarted = $false
    $script:TransferNotice = '已执行填入，请在 DSH 核对图片和文字'
    $bmpInfo = if ($Bitmap) { '{0}x{1}' -f $Bitmap.Width, $Bitmap.Height } else { 'NULL' }
    Write-Log ("send: trigger={0} bitmap={1} textLen={2} {3}" -f $Trigger, $bmpInfo, $Text.Length, [Wh]::FocusInfo())
    if (-not $Bitmap) { return '图片丢失（内部错误），请重试一次' }
    if (-not [Wh]::InputKeysReleased()) { return '请先松开回车、鼠标及 Ctrl / Shift / Alt，再重试' }

    $hwnd = [Wh]::FindWindowSuffix([string]$script:Config.targetSuffix, $PID)
    if ($hwnd -eq [IntPtr]::Zero) { return '没找到 DeepSeek Harness 窗口，先把 DSH 打开' }
    if (-not [Wh]::Activate($hwnd, 8)) {
        Write-Log ('send failed: stage=activate ' + [Wh]::FocusInfo())
        return '切不到 DSH 窗口，请点一下 DSH 聊天输入框后重试'
    }

    $request = @{ Mode='Focus'; WindowHandle=$hwnd.ToInt64(); ExpectedText=$Text }
    $composer = Invoke-ComposerWorker $request
    if (-not $composer.Ok) {
        Write-Log ('send failed: stage=composer ' + $composer.Error)
        return [string]$composer.Error
    }
    Write-Log ('composer focused: readable={0} length={1} {2}' -f $composer.Readable, $composer.TextLength, [Wh]::FocusInfo())
    if (-not (Copy-BitmapToClipboard -Bitmap $Bitmap)) { return ('剪贴板被占用：' + $script:ClipError) }
    $clipSequence = [Wh]::GetClipboardSequenceNumber()

    # Check the same editor again after clipboard handling; never silently refocus midway.
    $request.Mode = 'Check'
    $request.RuntimeId = $composer.RuntimeId
    $ready = Invoke-ComposerWorker $request
    if (-not $ready.Ok) { return '粘贴前输入框失去焦点，尚未填入，请重试' }
    if (-not [Wh]::InputGoesTo($hwnd) -or -not [Wh]::InputKeysReleased()) { return '粘贴前焦点或按键状态发生变化，尚未填入，请重试' }
    if ([Wh]::GetClipboardSequenceNumber() -ne $clipSequence) { return '剪贴板内容被其他程序改动，尚未填入，请重试' }

    # Once any input is attempted, a retry could duplicate an attachment or partial text.
    $script:TransferStarted = $true
    $cv = [Wh]::CtrlV()
    Write-Log ('paste attempted: ctrlV={0} {1}' -f $cv, [Wh]::FocusInfo())
    if ($cv -ne 4) { return '粘贴未完整执行，请先到 DSH 核对，再关闭此面板' }
    Start-Sleep -Milliseconds ([Math]::Min(3000, [Math]::Max(100, [int]$script:Config.pasteDelayMs)))
    if (-not [Wh]::InputGoesTo($hwnd) -or -not [Wh]::InputKeysReleased()) { return '贴图后焦点或按键状态变化，已停止填字；请先到 DSH 核对' }

    if ($Text) {
        $ready = Invoke-ComposerWorker $request
        if (-not $ready.Ok) { return '贴图后输入框失去焦点，已停止填字；请先到 DSH 核对' }
        $expected = 0
        foreach ($ch in $Text.ToCharArray()) {
            if ($ch -eq "`r") { continue }
            if ($ch -eq "`n") { $expected += 4 } else { $expected += 2 }
        }
        $typed = [Wh]::TypeText($Text, $hwnd)
        Write-Log ('text attempted: expected={0} typed={1} {2}' -f $expected, $typed, [Wh]::FocusInfo())
        if ($typed -ne $expected) { return '文字未完整填入，已停止；请先到 DSH 核对，避免重复填入' }
        if (-not [Wh]::InputGoesTo($hwnd)) { return '填字过程中焦点变化，请先到 DSH 核对已有内容' }
        $request.Mode = 'VerifyText'
        $request.BeforeOccurrences = $ready.Occurrences
        $verified = $null
        for ($i = 0; $i -lt 3; $i++) {
            $verified = Invoke-ComposerWorker $request
            if (-not $verified.Ok -or -not $verified.Readable -or $verified.Verified) { break }
            Start-Sleep -Milliseconds 150
        }
        if (-not $verified.Ok) { return '填字后无法核对输入框，请先在 DSH 检查已有内容' }
        if ($verified.Readable -and -not $verified.Verified) { return '未在输入框读到新增备注，请先到 DSH 核对，避免重复填入' }
        Write-Log ('text checked: readable={0} verified={1}' -f $verified.Readable, $verified.Verified)
        if ($verified.Readable -and $verified.Verified) { $script:TransferNotice = '备注已核对；请在 DSH 确认图片后发送' }
    }
    Write-Log ('input dispatched: imageVerified=false ' + [Wh]::FocusInfo())
    return $null
}

# ---------------------------------------------------------------- 自检 ----------------------------------------------------------------

if ($TestWindow) {
    $h = [Wh]::FindWindowSuffix([string]$script:Config.targetSuffix, $PID)
    if ($h -eq [IntPtr]::Zero) { Write-Output 'NOT FOUND'; exit 1 }
    $wpid = [uint32]0
    [void][Wh]::GetWindowThreadProcessId($h, [ref]$wpid)
    Write-Output ('HWND=0x{0:X} PID={1} TITLE={2}' -f [int64]$h, $wpid, [Wh]::Title($h))
    exit 0
}

if ($TestComposer) {
    $h = [Wh]::FindWindowSuffix([string]$script:Config.targetSuffix, $PID)
    if ($h -eq [IntPtr]::Zero) { Write-Output 'NOT FOUND'; exit 1 }
    $result = Invoke-ComposerWorker @{ Mode='Inspect'; WindowHandle=$h.ToInt64() }
    $json = ConvertTo-Json -InputObject $result -Depth 5 -Compress
    Write-Output $json
    Write-Log ('composer inspection: ' + $json)
    if (-not $result.Ok) { exit 1 }
    exit 0
}

if ($TestFocus) {
    $h = [Wh]::FindWindowSuffix([string]$script:Config.targetSuffix, $PID)
    $dshPid = [uint32]0
    if ($h -ne [IntPtr]::Zero) { [void][Wh]::GetWindowThreadProcessId($h, [ref]$dshPid) }
    Write-Output ('TARGET hwnd=0x{0:X} pid={1}' -f [int64]$h, $dshPid)
    Write-Output ('NOW    ' + [Wh]::FocusInfo())
    Write-Output ('INPUT_GOES_TO_DSH=' + [Wh]::InputGoesTo($h))
    exit 0
}

if ($TestCapture) {
    $vs = Get-PhysicalScreen
    $bmp = Capture-PhysicalRect -Rect $vs
    $target = if ($OutFile) { $OutFile } else { Join-Path $script:ShotsDir 'test-capture.png' }
    $bmp.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ('CAPTURED {0}x{1} -> {2}' -f $vs.Width, $vs.Height, $target)
    exit 0
}

if ($TestSend) {
    $tb = New-Object System.Drawing.Bitmap(520, 180)
    $tg = [System.Drawing.Graphics]::FromImage($tb)
    $tg.Clear([System.Drawing.Color]::FromArgb(255, 28, 34, 52))
    $tg.DrawString('whale-shot self test', (New-Object System.Drawing.Font('Microsoft YaHei UI', 18)), [System.Drawing.Brushes]::White, 24, 60)
    $tg.Dispose()
    $e2 = Send-ToDsh -Bitmap $tb -Text 'whale-shot 自检：能看到这张图和这段字，就说明通路是通的（可以直接删掉这条草稿）。'
    $tb.Dispose()
    Write-Output ("SEND err='{0}'" -f $e2)
    exit 0
}

if ($TestClipboard) {
    $vs = Get-PhysicalScreen
    $bmp = Capture-PhysicalRect -Rect $vs
    $ok = Copy-BitmapToClipboard -Bitmap $bmp
    Write-Log ("testclipboard: {0}x{1} ok={2} err='{3}'" -f $bmp.Width, $bmp.Height, $ok, $script:ClipError)
    $bmp.Dispose()
    Write-Output ("CLIPBOARD ok={0} err='{1}'" -f $ok, $script:ClipError)
    exit 0
}

# ---------------------------------------------------------------- 单实例 ----------------------------------------------------------------

$script:Mutex = $null
try {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\WhaleShotDSH', [ref]$created)
    if (-not $created) {
        [System.Windows.Forms.MessageBox]::Show('小鲸鱼已经在跑了。', 'whale-shot') | Out-Null
        exit 0
    }
} catch { Write-Log "mutex: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 界面 ----------------------------------------------------------------

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    try {
        $ex = $e.Exception
        Write-Log ("UI 异常: " + $ex.Message)
        if ($ex.InvocationInfo) { Write-Log ("UI 位置: " + $ex.InvocationInfo.PositionMessage) }
        if ($ex.StackTrace) { Write-Log ("UI 托管堆栈: " + $ex.StackTrace) }
    } catch { }
})
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:State = 'idle'
$script:ShotBitmap = $null
$script:LastShotPath = $null
$script:Overlay = $null
$script:Panel = $null

# ---------- 悬浮球 ----------

# config.size 是 DIP；窗口坐标在 DPI 感知进程里就是物理像素
$script:Dpi   = [Wh]::Dpi()
$script:Scale = [double]$script:Dpi / 96.0
$ballPx = [int][Math]::Round([double]$script:Config.size * $script:Scale)
if ($ballPx -lt 48) { $ballPx = 48 }
$ballDip = $ballPx
$ballBmp = Get-BallBitmap -PixelSize $ballPx
$script:BallDip = $ballPx
$script:BallBmp = $ballBmp

# 用 Win32 的工作区（它的单位与窗口坐标一致），不要混用 Screen 的物理像素
$wa = [Wh]::WorkArea()                      # 已经是窗口坐标
$waX = $wa[0]; $waY = $wa[1]
$areaDipW = $wa[2]
$areaDipH = $wa[3]

$bx = $waX + $areaDipW - $ballPx - 12
$by = $waY + [int](($areaDipH - $ballPx) / 2)
if ($bx -lt $waX) { $bx = $waX }
if ($by -lt $waY) { $by = $waY }

$ball = New-Object System.Windows.Forms.Form
$ball.AutoScaleMode   = 'None'
$ball.FormBorderStyle = 'None'
$ball.StartPosition   = 'Manual'
$ball.ShowInTaskbar   = $false
$ball.TopMost         = $true
$ball.Text            = 'whale-shot'
$ball.ClientSize      = New-Object System.Drawing.Size($ballPx, $ballPx)
$ball.Location        = New-Object System.Drawing.Point($bx, $by)

$null = $ball.Handle          # 先建句柄，但先不显示
Start-Sleep -Milliseconds 60

# 首选：分层窗口 + 逐像素 alpha。圆角、阴影是真的，卡片外面透明。
[Wh]::MakeLayered($ball.Handle)
$script:LayerOk = if ([Wh]::ApplyLayered($ball.Handle, $ballBmp, $bx, $by, $ballPx)) { 'ulw' } else { 'paint+opaque' }

if ($script:LayerOk -ne 'ulw') {
    # 兜底：分层窗口失败时退回老方案（不透明窗口 + Region 圆角 + Paint）
    [Wh]::UnmakeLayered($ball.Handle)
    $script:BallTile = [System.Drawing.Image]::FromFile((Join-Path $script:Assets 'whale-tile.png'))
    $ball.BackColor   = [System.Drawing.Color]::White
    $script:BallDrawW = $ballPx
    $script:BallDrawH = $ballPx
    $ball.Add_Paint({
        param($s, $e)
        $tile = $script:BallTile
        if (-not $tile) { return }
        $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $e.Graphics.DrawImage($tile, 0, 0, $script:BallDrawW, $script:BallDrawH)
    })
    [void][Wh]::SetWindowPos($ball.Handle, [IntPtr]::Zero, $bx, $by, $ballPx, $ballPx, 0x14)
    $rad = [int]($ballPx * 0.26)
    if ($rad -lt 4) { $rad = 4 }
    $d2 = $rad * 2
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $d2, $d2, 180, 90)
    $gp.AddArc(($ballPx - $d2), 0, $d2, $d2, 270, 90)
    $gp.AddArc(($ballPx - $d2), ($ballPx - $d2), $d2, $d2, 0, 90)
    $gp.AddArc(0, ($ballPx - $d2), $d2, $d2, 90, 90)
    $gp.CloseFigure()
    $ball.Region = New-Object System.Drawing.Region($gp)
}

$rc = [Wh]::RectOf($ball.Handle)
$script:BallRect = @($rc[0], $rc[1], $rc[2], $rc[3])
$script:BallPosX = $rc[0]
$script:BallPosY = $rc[1]
$script:BallDrag  = $false
$script:BallMoved = $false
$script:DragGrab  = $null

$ball.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:BallDrag  = $true
        $script:BallMoved = $false
        $script:DragGrab  = $e.Location
    }
})

$ball.Add_MouseMove({
    param($s, $e)
    if (-not $script:BallDrag) { return }
    $cur = [System.Windows.Forms.Cursor]::Position
    $nx = $cur.X - $script:DragGrab.X
    $ny = $cur.Y - $script:DragGrab.Y
    if (-not $script:BallMoved -and ([Math]::Abs($nx - $script:BallPosX) + [Math]::Abs($ny - $script:BallPosY)) -lt 4) { return }
    $script:BallMoved = $true
    $script:BallPosX = $nx
    $script:BallPosY = $ny
    [Wh]::Move($s.Handle, $nx, $ny)
})

$ball.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:BallDrag = $false
    if ($script:BallMoved) { return }
    if ($script:State -eq 'idle') { Start-RegionSelect }
})

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShot = $menu.Items.Add('框选截图')
$miFull = $menu.Items.Add('整屏截图')
$miLast = $menu.Items.Add('上次的图')
$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = $menu.Items.Add('退出')
$miShot.Add_Click({ Start-RegionSelect })
$miFull.Add_Click({ Start-FullSelect })
$miLast.Add_Click({
    if ($script:LastShotPath -and (Test-Path -LiteralPath $script:LastShotPath)) {
        $img = [System.Drawing.Image]::FromFile($script:LastShotPath)
        $bmp = New-Object System.Drawing.Bitmap($img)
        $img.Dispose()
        Show-ComposePanel -Bitmap $bmp
    } else { Show-Toast '还没有截过图' }
})
$miQuit.Add_Click({ [System.Windows.Forms.Application]::Exit() })
$ball.ContextMenuStrip = $menu

# ---------- 托盘 ----------

$tray = New-Object System.Windows.Forms.NotifyIcon
try {
    $trayImg = [System.Drawing.Image]::FromFile((Join-Path $script:Assets 'whale-tray.png'))
    $trayBmp = New-Object System.Drawing.Bitmap($trayImg)
    $trayImg.Dispose()
    $tray.Icon = [System.Drawing.Icon]::FromHandle($trayBmp.GetHicon())
} catch { }
$tray.Text = 'whale-shot（小鲸鱼截图）'
$tray.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $trayMenu.Items.Add('框选截图', $null, { Start-RegionSelect })
$null = $trayMenu.Items.Add('整屏截图', $null, { Start-FullSelect })
$null = $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$null = $trayMenu.Items.Add('退出', $null, { [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-RegionSelect } })

# ---------------------------------------------------------------- 框选层 ----------------------------------------------------------------

$script:SelOrigin = $null
$script:SelRect = [System.Drawing.Rectangle]::Empty

function Start-RegionSelect {
    if ($script:State -ne 'idle') { return }
    $script:State = 'selecting'
    $script:SelOrigin = $null
    $script:SelRect = [System.Drawing.Rectangle]::Empty

    $scr = [Wh]::ScreenSize()
    $ov = New-Object System.Windows.Forms.Form
    $ov.AutoScaleMode   = 'None'
    $ov.FormBorderStyle = 'None'
    $ov.StartPosition   = 'Manual'
    $ov.ShowInTaskbar   = $false
    $ov.TopMost         = $true
    $ov.BackColor       = [System.Drawing.Color]::Black
    $ov.Opacity         = 0.38
    $ov.Cursor          = [System.Windows.Forms.Cursors]::Cross
    $ov.KeyPreview      = $true
    $ov.Text            = 'whale-shot-overlay'
    $ov.Bounds          = New-Object System.Drawing.Rectangle(0, 0, $scr[0], $scr[1])
    $script:Overlay = $ov

    $ov.Add_Paint({
        param($s, $e)
        $r = $script:SelRect
        if ($r.Width -lt 2) { return }
        # 边框按 DPI 缩放（150% 下 2 DIP = 3px），用四条矩形填充而不是画笔：
        # 笔画的抗锯齿会让 3px 线看起来"发虚"，填充出来是硬边。
        $bw = [int][Math]::Round(2.0 * $script:Scale)
        if ($bw -lt 2) { $bw = 2 }
        $edge = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        try {
            $e.Graphics.FillRectangle($edge, ($r.Left - $bw), ($r.Top - $bw), ($r.Width + 2 * $bw), $bw)
            $e.Graphics.FillRectangle($edge, ($r.Left - $bw), $r.Bottom, ($r.Width + 2 * $bw), $bw)
            $e.Graphics.FillRectangle($edge, ($r.Left - $bw), $r.Top, $bw, $r.Height)
            $e.Graphics.FillRectangle($edge, $r.Right, $r.Top, $bw, $r.Height)
        } finally { $edge.Dispose() }
        $label = '{0} × {1}' -f (To-Physical $r.Width), (To-Physical $r.Height)
        $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        try {
            $sz = $e.Graphics.MeasureString($label, $font)
            $tx = $r.Left + 4
            $ty = $r.Top + 4
            if ($ty + $sz.Height -gt $s.ClientSize.Height) { $ty = $r.Bottom - $sz.Height - 6 }
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 24, 30, 48))
            try { $e.Graphics.FillRectangle($brush, $tx, $ty, $sz.Width + 10, $sz.Height + 2) } finally { $brush.Dispose() }
            $e.Graphics.DrawString($label, $font, [System.Drawing.Brushes]::White, $tx + 5, $ty + 1)
        } finally { $font.Dispose() }
    })

    $ov.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $script:SelOrigin = New-Object System.Drawing.Point($e.X, $e.Y)
        $script:SelRect = New-Object System.Drawing.Rectangle($e.X, $e.Y, 0, 0)
    })

    $ov.Add_MouseMove({
        param($s, $e)
        if (-not $script:SelOrigin) { return }
        $x1 = [Math]::Min($script:SelOrigin.X, $e.X)
        $y1 = [Math]::Min($script:SelOrigin.Y, $e.Y)
        $x2 = [Math]::Max($script:SelOrigin.X, $e.X)
        $y2 = [Math]::Max($script:SelOrigin.Y, $e.Y)
        $script:SelRect = New-Object System.Drawing.Rectangle($x1, $y1, ($x2 - $x1), ($y2 - $y1))
        $s.Invalidate()
    })

    $ov.Add_MouseUp({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $r = $script:SelRect
        $script:SelOrigin = $null
        $s.Hide(); $s.Dispose()
        $script:Overlay = $null
        $script:State = 'idle'
        if ($r.Width -lt 4 -or $r.Height -lt 4) { return }
        $prX = To-Physical $r.X
        $prY = To-Physical $r.Y
        $prW = To-Physical $r.Width
        $prH = To-Physical $r.Height
        Complete-Shot -Rect (New-Object System.Drawing.Rectangle($prX, $prY, $prW, $prH))
    })

    $ov.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:State = 'idle'
            $script:Overlay = $null
            $s.Hide(); $s.Dispose()
        }
    })

    $ov.Show()
    $ov.Activate()
}

function Start-FullSelect {
    if ($script:State -ne 'idle') { return }
    $script:State = 'selecting'
    Complete-Shot -Rect (Get-PhysicalScreen)
}

function Complete-Shot {
    param([System.Drawing.Rectangle]$Rect)
    try { $bmp = Capture-PhysicalRect -Rect $Rect }
    catch {
        Write-Log "capture 失败: $($_.Exception.Message)"
        $script:State = 'idle'
        Show-Toast '截图失败'
        return
    }
    $script:LastShotPath = Save-Shot -Bitmap $bmp
    $script:State = 'idle'
    Show-ComposePanel -Bitmap $bmp
}

# ---------------------------------------------------------------- 编辑面板 ----------------------------------------------------------------

# 面板的「填入」统一走这里：按钮点击和回车都调它，行为必须完全一致。
# 关键顺序：先把面板藏掉，再去抢 DSH 的焦点。TopMost 面板留在前台会参与焦点竞争。
function Send-PanelContent {
    param([string]$Trigger = 'button')
    $f = $script:PanelForm
    if (-not $f -or $f.IsDisposed -or $script:PanelBusy) { return }
    if ($script:PanelTransferStarted) {
        $script:PanelStatusText = '这次已尝试填入。请先在 DSH 核对，关闭面板后再操作，避免重复贴图。'
        $f.Invalidate()
        return
    }
    $script:PanelBusy = $true
    $script:TransferStarted = $false
    $script:PendingSend = $false
    $script:SendTimer.Stop()
    $script:PanelStatusText = ''
    $textSnapshot = $script:PanelBox.Text
    $f.Refresh()
    $f.Hide()
    $err = $null
    try {
        $err = Send-ToDsh -Bitmap $script:ShotBitmap -Text $textSnapshot -Trigger $Trigger
    } catch {
        Write-Log ("panel send 异常: " + $_.Exception.Message)
        $err = '内部错误：' + $_.Exception.Message
    }
    $script:PanelTransferStarted = $script:TransferStarted
    if ($err) {
        Write-Log ('panel retained: started={0} error={1}' -f $script:PanelTransferStarted, $err)
        $script:PanelBusy = $false
        $script:PanelStatusText = $err
        $f.Show()
        $f.Activate()
        $f.Invalidate()
        return
    }
    $f.Close()
    Show-Toast $script:TransferNotice -Ms 3200
}

# Both entry points wait for actual key/button release while the panel keeps focus.
$script:PendingSend = $false
$script:PendingTrigger = 'button'
$script:SendWaitStarted = [DateTime]::MinValue
$script:SendTimer = New-Object System.Windows.Forms.Timer
$script:SendTimer.Interval = 50
$script:SendTimer.Add_Tick({
    if (-not $script:PendingSend -or -not $script:PanelForm -or $script:PanelForm.IsDisposed) {
        $script:SendTimer.Stop()
        return
    }
    if (([DateTime]::UtcNow - $script:SendWaitStarted).TotalSeconds -gt 5) {
        $script:SendTimer.Stop()
        $script:PendingSend = $false
        $script:PanelStatusText = '等待松键超时，请松开回车、鼠标及 Ctrl / Shift / Alt 后重试'
        $script:PanelForm.Invalidate()
        Write-Log 'send cancelled: stage=wait-release timeout'
        return
    }
    if (-not [Wh]::InputKeysReleased()) { return }
    $script:SendTimer.Stop()
    $script:PendingSend = $false
    if (-not $script:PanelForm.ContainsFocus) {
        $script:PanelStatusText = '面板已失去焦点，本次未填入；请回到面板重试'
        $script:PanelForm.Invalidate()
        return
    }
    Send-PanelContent -Trigger $script:PendingTrigger
})

function Request-PanelSend {
    param([string]$Trigger)
    if ($script:PanelBusy -or $script:PendingSend) { return }
    $script:PendingSend = $true
    $script:PendingTrigger = $Trigger
    $script:SendWaitStarted = [DateTime]::UtcNow
    $script:SendTimer.Start()
}

# 圆角矩形路径（GDI+ 没有现成的）
function New-RoundPath {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($W -le 0 -or $H -le 0) { return $p }
    if ($R -le 0) {
        $p.AddRectangle([System.Drawing.RectangleF]::new([single]$X, [single]$Y, [single]$W, [single]$H))
        return $p
    }
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $x2 = $X + $W - $d
    $y2 = $Y + $H - $d
    $p.AddArc([single]$X,  [single]$Y,  [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]$x2, [single]$Y,  [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]$x2, [single]$y2, [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$X,  [single]$y2, [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Test-PanelHot {
    param([System.Drawing.Point]$Pt)
    if ($script:BtnClose   -and $script:BtnClose.Contains($Pt))   { return 'close' }
    if ($script:BtnPrimary -and $script:BtnPrimary.Contains($Pt)) { return 'primary' }
    if ($script:BtnGhost   -and $script:BtnGhost.Contains($Pt))   { return 'ghost' }
    return ''
}

# 只重绘聚焦环那一圈，别整面板刷一遍
function New-PanelRingRect {
    $P = $script:Pnl
    if (-not $P) { return [System.Drawing.Rectangle]::Empty }
    return [System.Drawing.Rectangle]::new(($P.TaX - (Px 4)), ($P.TaY - (Px 4)), ($P.TaW + (Px 8)), ($P.TaH + (Px 8)))
}

function Show-ComposePanel {
    param([System.Drawing.Bitmap]$Bitmap)

    if ($script:State -eq 'composing' -and $script:Panel -and -not $script:Panel.IsDisposed) {
        $script:Panel.Activate()
        return
    }
    if ($script:Panel -and -not $script:Panel.IsDisposed) {
        $script:Panel.Close(); $script:Panel.Dispose()
    }
    $script:State = 'composing'
    $script:ShotBitmap = $Bitmap
    $script:PanelBusy = $false
    $script:PanelTransferStarted = $false
    $script:PanelStatusText = ''
    $script:PanelHot = ''
    $script:PanelPressed = ''
    $script:PanelDragging = $false
    $script:PanelFocus = $true
    if ($script:PanelPh) { $script:PanelPh.Visible = $false }

    $P = @{}
    $P.W = Px 480
    $P.H = Px 352
    $P.Pad = Px 24
    $P.HeadY = Px 18
    $P.IconSize = Px 24
    $P.HeadDragH = Px 54
    $P.ThumbX = $P.Pad
    $P.ThumbY = Px 62
    $P.ThumbW = Px 168
    $P.ThumbH = Px 112
    $P.TaX = $P.Pad
    $P.TaY = Px 194
    $P.TaW = $P.W - 2 * $P.Pad
    $P.TaH = Px 86
    $P.FootY = Px 300
    $P.FootH = Px 36
    $P.PrimaryW = Px 124
    $P.GhostW = Px 64
    $P.CloseW = Px 28

    $P.CText       = [System.Drawing.Color]::FromArgb(31, 36, 48)
    $P.CLead       = [System.Drawing.Color]::FromArgb(91, 100, 121)
    $P.CHint       = [System.Drawing.Color]::FromArgb(139, 147, 167)
    $P.CBorder     = [System.Drawing.Color]::FromArgb(231, 235, 244)
    $P.CField      = [System.Drawing.Color]::FromArgb(247, 249, 253)
    $P.CFieldEdge  = [System.Drawing.Color]::FromArgb(229, 234, 243)
    $P.CPrimary    = [System.Drawing.Color]::FromArgb(77, 107, 254)
    $P.CPrimaryHot = [System.Drawing.Color]::FromArgb(96, 123, 255)
    $P.CPrimaryDn  = [System.Drawing.Color]::FromArgb(63, 90, 232)
    $P.CPrimaryDim = [System.Drawing.Color]::FromArgb(150, 168, 255)
    $P.CGhost      = [System.Drawing.Color]::FromArgb(92, 101, 122)
    $P.CClose      = [System.Drawing.Color]::FromArgb(154, 163, 182)
    $P.CMuted      = [System.Drawing.Color]::FromArgb(163, 171, 188)
    $P.CErr        = [System.Drawing.Color]::FromArgb(200, 60, 70)

    $P.FontTitle     = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $P.FontLead      = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $P.FontHint      = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $P.FontMeta      = New-Object System.Drawing.Font('Microsoft YaHei UI', 7.5)
    $P.FontBtn       = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $P.FontBtnNormal = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $P.FontEsc       = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    try { $P.Icon = [System.Drawing.Image]::FromFile((Join-Path $script:Assets 'whale-float.png')) } catch { $P.Icon = $null }
    $script:Pnl = $P

    $f = New-Object System.Windows.Forms.Form
    $f.AutoScaleMode   = 'None'
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.KeyPreview      = $true
    $f.Text            = '发到 DeepSeek Harness'
    $f.ClientSize      = New-Object System.Drawing.Size($P.W, $P.H)
    $f.BackColor       = [System.Drawing.Color]::White
    $f.ShowIcon        = $false
    $script:Panel = $f
    $script:PanelForm = $f

    $null = $f.Handle
    [Wh]::ClipChildren($f.Handle)
    # 双缓冲：面板里的自绘（缩略图、圆角、聚焦环）必须整帧画完再上屏，否则会闪
    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($dbProp) { try { $dbProp.SetValue($f, $true, $null) } catch { } }
    $P.Dwm = [Wh]::RoundCorners($f.Handle)
    if (-not $P.Dwm) {
        $gp = New-RoundPath 0 0 $P.W $P.H (Px 14)
        $f.Region = New-Object System.Drawing.Region($gp)
        $gp.Dispose()
    }

    $script:BtnClose   = [System.Drawing.Rectangle]::new(($P.W - $P.Pad - $P.CloseW), $P.HeadY, $P.CloseW, $P.CloseW)
    $script:BtnPrimary = [System.Drawing.Rectangle]::new(($P.W - $P.Pad - $P.PrimaryW), $P.FootY, $P.PrimaryW, $P.FootH)
    $script:BtnGhost   = [System.Drawing.Rectangle]::new(($P.W - $P.Pad - $P.PrimaryW - (Px 10) - $P.GhostW), $P.FootY, $P.GhostW, $P.FootH)

    # 缩略图只缩一次，Paint 里 1:1 贴图（否则每次重绘都要缩 2560×1600，卡 + 闪）
    $thumbBmp = New-Object System.Drawing.Bitmap($P.ThumbW, $P.ThumbH)
    $tg = [System.Drawing.Graphics]::FromImage($thumbBmp)
    try {
        $tg.Clear([System.Drawing.Color]::FromArgb(21, 26, 38))
        $tg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $tg.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        if ($Bitmap) {
            $k = [Math]::Min($P.ThumbW / $Bitmap.Width, $P.ThumbH / $Bitmap.Height)
            $dw = $Bitmap.Width * $k
            $dh = $Bitmap.Height * $k
            $tg.DrawImage($Bitmap, [single](($P.ThumbW - $dw) / 2), [single](($P.ThumbH - $dh) / 2), [single]$dw, [single]$dh)
        }
    } finally { $tg.Dispose() }
    $script:PnlThumb = $thumbBmp

    # ---- 真实输入框（必须留着原生 TextBox，输入法/中文才正常）----
    $box = New-Object WhaleComposeBox
    $box.BorderStyle   = 'None'
    $box.Multiline     = $true
    $box.AcceptsReturn = $true
    $box.ScrollBars    = 'None'
    $box.BackColor     = $P.CField
    $box.ForeColor     = $P.CText
    $box.Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $box.Location      = New-Object System.Drawing.Point(($P.TaX + (Px 12)), ($P.TaY + (Px 11)))
    $box.Size          = New-Object System.Drawing.Size(($P.TaW - (Px 24)), ($P.TaH - (Px 22)))
    $f.Controls.Add($box)
    $script:PanelBox = $box

    $ph = New-Object System.Windows.Forms.Label
    $ph.Text      = '补充说明（可选）…'
    $ph.ForeColor = [System.Drawing.Color]::FromArgb(154, 163, 181)
    $ph.BackColor = $P.CField
    $ph.AutoSize  = $false
    $ph.Location  = New-Object System.Drawing.Point(($P.TaX + (Px 14)), ($P.TaY + (Px 12)))
    $ph.Size      = New-Object System.Drawing.Size(($P.TaW - (Px 28)), (Px 20))
    $ph.Cursor    = [System.Windows.Forms.Cursors]::IBeam
    $f.Controls.Add($ph)
    $ph.BringToFront()
    $script:PanelPh = $ph

    # ---- 绘制 ----
    $f.Add_Paint({
        param($s, $e)
        $P = $script:Pnl
        if (-not $P) { return }
        $g = $e.Graphics
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        # 没有 DWM 圆角时自己画一圈边框
        if (-not $P.Dwm) {
            $bp = New-RoundPath 0.5 0.5 ($P.W - 1) ($P.H - 1) (Px 14)
            $pen = New-Object System.Drawing.Pen($P.CBorder, [single]1)
            try { $g.DrawPath($pen, $bp) } finally { $pen.Dispose(); $bp.Dispose() }
        }

        # 图标 + 标题
        $tx = $P.Pad + $P.IconSize + (Px 10)
        if ($P.Icon) { $g.DrawImage($P.Icon, $P.Pad, $P.HeadY, $P.IconSize, $P.IconSize) }
        $br = New-Object System.Drawing.SolidBrush($P.CText)
        try {
            $g.DrawString('发到 DeepSeek Harness', $P.FontTitle, $br,
                [single]$tx, [single]($P.HeadY + (Px 2)))
        } finally { $br.Dispose() }

        # 缩略图（预缩放好的小图，1:1 贴，不在重绘里缩大图）
        $path = New-RoundPath $P.ThumbX $P.ThumbY $P.ThumbW $P.ThumbH (Px 10)
        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(21, 26, 38))
        try { $g.FillPath($bg, $path) } finally { $bg.Dispose() }
        $bmp = $script:ShotBitmap
        if ($script:PnlThumb) {
            $state = $g.Save()
            try {
                $g.SetClip($path)
                $g.DrawImage($script:PnlThumb, $P.ThumbX, $P.ThumbY, $P.ThumbW, $P.ThumbH)
            } finally { $g.Restore($state) }
        }
        $path.Dispose()

        # 尺寸角标
        if ($bmp) {
            $chip = '{0} × {1} px' -f $bmp.Width, $bmp.Height
            $cs = $g.MeasureString($chip, $P.FontMeta)
            $cw = [double]$cs.Width + (Px 12)
            $chh = [double]$cs.Height + (Px 2)
            $cx = $P.ThumbX + $P.ThumbW - $cw - (Px 6)
            $cy = $P.ThumbY + $P.ThumbH - $chh - (Px 6)
            $cp = New-RoundPath $cx $cy $cw $chh (Px 5)
            $cb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 13, 18, 32))
            $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            try {
                $g.FillPath($cb, $cp)
                $g.DrawString($chip, $P.FontMeta, $tb, [single]($cx + (Px 6)), [single]($cy + (Px 1)))
            } finally { $cb.Dispose(); $tb.Dispose(); $cp.Dispose() }
        }

        # 提示 / 错误
        $hx = $P.ThumbX + $P.ThumbW + (Px 20)
        $hy = $P.ThumbY + (Px 2)
        if ($script:PanelStatusText) {
            $sf = New-Object System.Drawing.StringFormat
            $rf = [System.Drawing.RectangleF]::new([single]$hx, [single]$hy,
                    [single]($P.W - $P.Pad - $hx), [single](Px 116))
            $sb = New-Object System.Drawing.SolidBrush($P.CErr)
            try { $g.DrawString($script:PanelStatusText, $P.FontHint, $sb, $rf, $sf) }
            finally { $sb.Dispose(); $sf.Dispose() }
        } else {
            $b1 = New-Object System.Drawing.SolidBrush($P.CLead)
            try { $g.DrawString('写点什么（可留空）', $P.FontLead, $b1, [single]$hx, [single]$hy) } finally { $b1.Dispose() }
            $b2 = New-Object System.Drawing.SolidBrush($P.CHint)
            try {
                $g.DrawString('Enter 填入 DSH · Shift+Enter 换行', $P.FontHint, $b2, [single]$hx, [single]($hy + (Px 26)))
                $g.DrawString('填入后自己在 DSH 里按 Enter 发送', $P.FontHint, $b2, [single]$hx, [single]($hy + (Px 48)))
            } finally { $b2.Dispose() }
        }

        # 输入框容器 + 聚焦环
        $tp = New-RoundPath $P.TaX $P.TaY $P.TaW $P.TaH (Px 12)
        $fb = New-Object System.Drawing.SolidBrush($P.CField)
        try { $g.FillPath($fb, $tp) } finally { $fb.Dispose() }
        $fp = New-Object System.Drawing.Pen($P.CFieldEdge, [single](Px 1))
        try { $g.DrawPath($fp, $tp) } finally { $fp.Dispose() }
        if ($script:PanelFocus) {
            $rp = New-RoundPath ($P.TaX - 1) ($P.TaY - 1) ($P.TaW + 2) ($P.TaH + 2) (Px 13)
            $rpen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(95, 77, 107, 254), [single](1.6 * $script:Scale))
            try { $g.DrawPath($rpen, $rp) } finally { $rpen.Dispose(); $rp.Dispose() }
        }
        $tp.Dispose()

        # 底部说明
        $sb2 = New-Object System.Drawing.SolidBrush($P.CMuted)
        try { $g.DrawString('Esc 取消', $P.FontEsc, $sb2, [single]$P.Pad, [single]($P.FootY + (Px 11))) }
        finally { $sb2.Dispose() }

        # 主按钮
        $pr = $script:BtnPrimary
        $fill = $P.CPrimary
        if ($script:PanelBusy) { $fill = $P.CPrimaryDim }
        elseif ($script:PanelPressed -eq 'primary') { $fill = $P.CPrimaryDn }
        elseif ($script:PanelHot -eq 'primary') { $fill = $P.CPrimaryHot }
        $pp = New-RoundPath $pr.X $pr.Y $pr.Width $pr.Height (Px 9)
        $pb = New-Object System.Drawing.SolidBrush($fill)
        try { $g.FillPath($pb, $pp) } finally { $pb.Dispose() }
        $label = if ($script:PanelBusy) { '正在填…' } elseif ($script:PanelTransferStarted) { '请先核对' } else { '填入 DSH' }
        $ls = $g.MeasureString($label, $P.FontBtn)
        $lb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        try {
            $g.DrawString($label, $P.FontBtn, $lb,
                [single]($pr.X + ($pr.Width - $ls.Width) / 2),
                [single]($pr.Y + ($pr.Height - $ls.Height) / 2))
        } finally { $lb.Dispose(); $pp.Dispose() }

        # 取消
        $gr = $script:BtnGhost
        if ($script:PanelHot -eq 'ghost' -or $script:PanelPressed -eq 'ghost') {
            $gp2 = New-RoundPath $gr.X $gr.Y $gr.Width $gr.Height (Px 9)
            $gb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(241, 244, 250))
            try { $g.FillPath($gb, $gp2) } finally { $gb.Dispose(); $gp2.Dispose() }
        }
        $gs = $g.MeasureString('取消', $P.FontBtnNormal)
        $gt = New-Object System.Drawing.SolidBrush($P.CGhost)
        try {
            $g.DrawString('取消', $P.FontBtnNormal, $gt,
                [single]($gr.X + ($gr.Width - $gs.Width) / 2),
                [single]($gr.Y + ($gr.Height - $gs.Height) / 2))
        } finally { $gt.Dispose() }

        # 关闭
        $cr = $script:BtnClose
        if ($script:PanelHot -eq 'close') {
            $cp2 = New-RoundPath $cr.X $cr.Y $cr.Width $cr.Height (Px 8)
            $cb2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 245, 250))
            try { $g.FillPath($cb2, $cp2) } finally { $cb2.Dispose(); $cp2.Dispose() }
        }
        $mx = $cr.X + $cr.Width / 2.0
        $my = $cr.Y + $cr.Height / 2.0
        $dd = Px 5
        $xpen = New-Object System.Drawing.Pen($P.CClose, [single](Px 1.4))
        try {
            $g.DrawLine($xpen, [single]($mx - $dd), [single]($my - $dd), [single]($mx + $dd), [single]($my + $dd))
            $g.DrawLine($xpen, [single]($mx + $dd), [single]($my - $dd), [single]($mx - $dd), [single]($my + $dd))
        } finally { $xpen.Dispose() }
    })

    # ---- 交互 ----
    $box.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return -and -not $e.Shift) {
            if ($s.IsImeEnter()) { return }
            $e.SuppressKeyPress = $true
            Request-PanelSend -Trigger 'enter' 
        }
    })
    $box.Add_Enter({
        $script:PanelFocus = $true
        if ($script:PanelPh) { $script:PanelPh.Visible = $false }
        if ($script:PanelForm) { $script:PanelForm.Invalidate((New-PanelRingRect)) }
    })
    $box.Add_Leave({
        $script:PanelFocus = $false
        if ($script:PanelPh) { $script:PanelPh.Visible = [string]::IsNullOrEmpty($script:PanelBox.Text) }
        if ($script:PanelForm) { $script:PanelForm.Invalidate((New-PanelRingRect)) }
    })
    $box.Add_TextChanged({
        if ($script:PanelPh -and $script:PanelBox -and -not $script:PanelBox.Focused) {
            $script:PanelPh.Visible = [string]::IsNullOrEmpty($script:PanelBox.Text)
        }
    })
    $ph.Add_Click({ if ($script:PanelBox) { $script:PanelBox.Focus() } })

    $f.Add_MouseMove({
        param($s, $e)
        if ($script:PanelDragging) {
            $cur = [System.Windows.Forms.Cursor]::Position
            $s.Location = New-Object System.Drawing.Point(($cur.X - $script:PanelDragOff.X), ($cur.Y - $script:PanelDragOff.Y))
            return
        }
        $hot = Test-PanelHot $e.Location
        if ($hot -ne $script:PanelHot) {
            $script:PanelHot = $hot
            if ($hot) { $s.Cursor = [System.Windows.Forms.Cursors]::Hand }
            else { $s.Cursor = [System.Windows.Forms.Cursors]::Default }
            $s.Invalidate()
        }
    })
    $f.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $hot = Test-PanelHot $e.Location
        if ($hot) { $script:PanelPressed = $hot; $s.Invalidate(); return }
        $PP = $script:Pnl
        if ($e.Y -le $PP.HeadDragH) {
            $script:PanelDragging = $true
            $script:PanelDragOff = New-Object System.Drawing.Point($e.X, $e.Y)
        }
    })
    $f.Add_MouseUp({
        param($s, $e)
        $script:PanelDragging = $false
        $hot = Test-PanelHot $e.Location
        $pressed = $script:PanelPressed
        $script:PanelPressed = ''
        $s.Invalidate()
        if (-not $pressed -or $hot -ne $pressed) { return }
        if ($pressed -eq 'primary') { Request-PanelSend -Trigger 'button' }
        elseif ($pressed -eq 'ghost' -or $pressed -eq 'close') {
            if ($script:PanelForm) { $script:PanelForm.Close() }
        }
    })
    $f.Add_MouseLeave({
        param($s, $e)
        if ($script:PanelHot) { $script:PanelHot = ''; $s.Invalidate() }
    })
    $f.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            if ($script:PanelForm) { $script:PanelForm.Close() }
        }
    })
    $f.Add_FormClosed({
        param($s, $e)
        $script:State = 'idle'
        $script:Panel = $null
        $script:PendingSend = $false
        if ($script:SendTimer) { $script:SendTimer.Stop() }
        $PP = $script:Pnl
        if ($PP) {
            foreach ($k in @('FontTitle', 'FontLead', 'FontHint', 'FontMeta', 'FontBtn', 'FontBtnNormal', 'FontEsc', 'Icon')) {
                try { if ($PP[$k]) { $PP[$k].Dispose() } } catch { }
            }
        }
        $script:Pnl = $null
        try { if ($script:PnlThumb) { $script:PnlThumb.Dispose() } } catch { }
        $script:PnlThumb = $null
        $script:PanelForm = $null
        $script:PanelBox = $null
        $script:PanelPh = $null
    })

    # ---- 定位并显示 ----
    $waA = [Wh]::WorkArea()
    $cur = [System.Windows.Forms.Cursor]::Position
    $px = [Math]::Min([Math]::Max($waA[0] + (Px 8), $cur.X - (Px 150)), $waA[0] + $waA[2] - $P.W - (Px 8))
    $py = [Math]::Min([Math]::Max($waA[1] + (Px 8), $cur.Y + (Px 20)), $waA[1] + $waA[3] - $P.H - (Px 8))
    $f.Location = New-Object System.Drawing.Point([int]$px, [int]$py)

    $f.Show()
    $f.Activate()
    $box.Focus()
    $f.Invalidate()
}

function Show-Toast {
    param([string]$Text, [int]$Ms = 1600)
    $t = New-Object System.Windows.Forms.Form
    $t.FormBorderStyle = 'None'
    $t.StartPosition   = 'Manual'
    $t.ShowInTaskbar   = $false
    $t.TopMost         = $true
    $t.BackColor       = [System.Drawing.Color]::FromArgb(26, 32, 48)
    $t.ClientSize      = New-Object System.Drawing.Size(320, 44)
    $t.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $waT = [Wh]::WorkArea()
    $tw = $waT[2]; $th = $waT[3]
    $t.Location = New-Object System.Drawing.Point(
        ($waT[0] + [int](($tw - $t.Width) / 2)),
        ($waT[1] + $th - 96))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock      = 'Fill'
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Text      = $Text
    $t.Controls.Add($lbl)

    $script:Toast = $t
    $t.Show()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Ms
    $timer.Add_Tick({
        # 必须走 $script:：函数局部变量在这个事件触发时已经不存在了
        if ($script:ToastTimer) { $script:ToastTimer.Stop() }
        if ($script:Toast -and -not $script:Toast.IsDisposed) {
            $script:Toast.Close()
            $script:Toast = $null
        }
    })
    $timer.Start()
    $script:ToastTimer = $timer
}

# ---------------------------------------------------------------- 启动 ----------------------------------------------------------------

Write-Log ("start: phys={0}x{1} win={2}x{3} R={4} ballDip={5} ballPx={6} pos=({7},{8}) layer={9}" -f `
    $script:PhysW, $script:PhysH, $script:WinW, $script:WinH, $script:R, $ballDip, $ballPx, $bx, $by, $script:LayerOk)
Write-Log ("ball rect: {0}" -f ($script:BallRect -join ','))
if ($TestToast) { Show-Toast '测试提示条：1.6 秒后自动消失' }
$ball.Add_Shown({
    Write-Log 'ball shown'
    if ($TestPanel) { Start-FullSelect }
    elseif ($TestOverlay) { Start-RegionSelect }
})

$main = New-Object System.Windows.Forms.Form
$main.FormBorderStyle = 'None'
$main.ShowInTaskbar   = $false
$main.StartPosition   = 'Manual'
$main.ClientSize      = New-Object System.Drawing.Size(1, 1)
$main.Location        = New-Object System.Drawing.Point(-30000, -30000)
$main.Add_Shown({
    # 消息循环已经在跑：这时候再显示球，走的是和面板/遮罩一样的路径
    Start-Sleep -Milliseconds 80
    $ball.Show()
    [void][Wh]::ShowWindow($ball.Handle, 5)
    Write-Log ("ball shown in loop, rect={0}" -f ([Wh]::RectOf($ball.Handle) -join ','))
})

try {
    [System.Windows.Forms.Application]::Run($main)
} finally {
    Write-Log 'exit'
    try { $tray.Visible = $false; $tray.Dispose() } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
}
