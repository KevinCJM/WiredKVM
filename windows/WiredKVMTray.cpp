// WiredKVM Windows tray *settings prototype*.
// This does not implement Windows keyboard/mouse capture yet.
// No input hooks or background auto-connection will be started.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <array>

namespace {
constexpr UINT kTrayEvent = WM_APP + 101;
constexpr UINT kTrayId = 61;
constexpr UINT kTargetIphone = 1001;
constexpr UINT kTargetMac = 1002;
constexpr UINT kTargetWindows = 1003;
constexpr UINT kLeft = 1011;
constexpr UINT kRight = 1012;
constexpr UINT kSpeedFirst = 1020;
constexpr UINT kAutoReturn = 1040;
constexpr UINT kAutoConnect = 1041;
constexpr UINT kStart = 1050;
constexpr UINT kQuit = 1051;
constexpr auto kClassName = L"WiredKVMTrayWindowV1";
constexpr std::array<double, 5> kSpeeds{0.75, 1.0, 1.25, 1.5, 2.0};

struct Settings {
    int target = 0;      // 0 iPhone, 1 Mac, 2 Windows
    bool left = true;
    int speed = 1;
    bool autoReturn = true;
    bool autoConnect = false; // Stored only. Worker not available.
};
Settings config;
std::wstring settingsPath;
NOTIFYICONDATAW icon{};
HWND window = nullptr;

std::wstring configurePath() {
    wchar_t path[MAX_PATH]{};
    DWORD length = GetEnvironmentVariableW(L"APPDATA", path, MAX_PATH);
    if (!length || length >= MAX_PATH) return L"";
    std::wstring dir = std::wstring(path) + L"\\WiredKVM";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\settings.ini";
}

int readInt(const wchar_t* key, int fallback) {
    return settingsPath.empty() ? fallback :
        static_cast<int>(GetPrivateProfileIntW(L"WiredKVM", key,
                                              fallback, settingsPath.c_str()));
}

void writeInt(const wchar_t* key, int value) {
    if (settingsPath.empty()) return;
    const std::wstring number = std::to_wstring(value);
    WritePrivateProfileStringW(L"WiredKVM", key, number.c_str(), settingsPath.c_str());
}

void load() {
    settingsPath = configurePath();
    config.target = readInt(L"target", 0);
    if (config.target < 0 || config.target > 2) config.target = 0;
    config.left = readInt(L"left", 1) != 0;
    config.speed = readInt(L"speed", 1);
    if (config.speed < 0 || config.speed >= static_cast<int>(kSpeeds.size())) config.speed = 1;
    config.autoReturn = readInt(L"autoReturn", 1) != 0;
    config.autoConnect = readInt(L"autoConnect", 0) != 0;
}

void save() {
    writeInt(L"target", config.target);
    writeInt(L"left", config.left);
    writeInt(L"speed", config.speed);
    writeInt(L"autoReturn", config.autoReturn ? 1 : 0);
    writeInt(L"autoConnect", config.autoConnect ? 1 : 0);
}

void appendChecked(HMENU menu, UINT id, const wchar_t* text, bool checked) {
    AppendMenuW(menu, MF_STRING | (checked ? MF_CHECKED : 0), id, text);
}

HMENU buildMenu() {
    HMENU top = CreatePopupMenu();
    HMENU target = CreatePopupMenu();
    appendChecked(target, kTargetIphone, L"iPhone", config.target == 0);
    appendChecked(target, kTargetMac, L"Mac / MacBook / Mac mini", config.target == 1);
    appendChecked(target, kTargetWindows, L"Windows", config.target == 2);
    HMENU position = CreatePopupMenu();
    appendChecked(position, kLeft, L"左侧", config.left);
    appendChecked(position, kRight, L"右侧", !config.left);
    HMENU speed = CreatePopupMenu();
    const wchar_t* names[] = {L"0.75×", L"1.00×", L"1.25×", L"1.50×", L"2.00×"};
    for (size_t i = 0; i < kSpeeds.size(); ++i)
        appendChecked(speed, kSpeedFirst + static_cast<UINT>(i), names[i],
                      config.speed == static_cast<int>(i));

    AppendMenuW(top, MF_STRING | MF_GRAYED, 0, L"WiredKVM — Windows 主控尚未完成");
    AppendMenuW(top, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(top, MF_POPUP, reinterpret_cast<UINT_PTR>(target), L"被控设备");
    AppendMenuW(top, MF_POPUP, reinterpret_cast<UINT_PTR>(position), L"被控机位置");
    AppendMenuW(top, MF_POPUP, reinterpret_cast<UINT_PTR>(speed), L"鼠标灵敏度");
    appendChecked(top, kAutoReturn, L"iPhone 自动返回", config.autoReturn);
    appendChecked(top, kAutoConnect, L"插入后自动连接（准备选项）", config.autoConnect);
    AppendMenuW(top, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(top, MF_STRING | MF_GRAYED, kStart, L"开始控制（待 Windows 输入捕获实现）");
    AppendMenuW(top, MF_STRING, kQuit, L"退出");
    return top;
}

void showMenu() {
    if (!window) return;
    POINT p{};
    GetCursorPos(&p);
    HMENU menu = buildMenu();
    SetForegroundWindow(window);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                   p.x, p.y, 0, window, nullptr);
    PostMessageW(window, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    if (msg == kTrayEvent) {
        if (l == WM_RBUTTONUP || l == WM_LBUTTONUP || l == WM_CONTEXTMENU) showMenu();
        return 0;
    }
    if (msg == WM_COMMAND) {
        const UINT id = LOWORD(w);
        if (id >= kTargetIphone && id <= kTargetWindows) config.target = int(id - kTargetIphone);
        else if (id == kLeft) config.left = true;
        else if (id == kRight) config.left = false;
        else if (id >= kSpeedFirst && id < kSpeedFirst + kSpeeds.size())
            config.speed = int(id - kSpeedFirst);
        else if (id == kAutoReturn) config.autoReturn = !config.autoReturn;
        else if (id == kAutoConnect) config.autoConnect = !config.autoConnect;
        else if (id == kQuit) { DestroyWindow(hwnd); return 0; }
        save();
        return 0;
    }
    if (msg == WM_DESTROY) {
        Shell_NotifyIconW(NIM_DELETE, &icon);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, w, l);
}
}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    const HANDLE unique = CreateMutexW(nullptr, TRUE, L"Local\\WiredKVM-WinTray-Protype");
    if (unique && GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(unique);
        return 0;
    }
    load();
    WNDCLASSW type{};
    type.lpfnWndProc = wndProc;
    type.hInstance = instance;
    type.lpszClassName = kClassName;
    if (!RegisterClassW(&type)) return 1;
    window = CreateWindowExW(0, kClassName, L"WiredKVM", WS_OVERLAPPEDWINDOW,
                             0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    if (!window) return 2;
    icon.cbSize = sizeof(icon);
    icon.hWnd = window;
    icon.uID = kTrayId;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    icon.uCallbackMessage = kTrayEvent;
    icon.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    lstrcpynW(icon.szTip, L"WiredKVM — Windows 设置原型", ARRAYSIZE(icon.szTip));
    Shell_NotifyIconW(NIM_ADD, &icon);
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (unique) { ReleaseMutex(unique); CloseHandle(unique); }
    return static_cast<int>(msg.wParam);
}
