#pragma once
#include "Common.h"
#include <condition_variable>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <thread>

namespace catlive {
// Windows delivers lid transitions to a message-only window. CIM work stays on
// one worker, so a close/open burst always ends with the newest requested state.
class ShowLidBrightness final {
public:
    explicit ShowLidBrightness(File backupFile) : backup(std::move(backupFile)) {
        WNDCLASSW type{};type.lpfnWndProc=windowProcedure;type.hInstance=GetModuleHandleW(nullptr);
        type.lpszClassName=L"CatLiveShowLidBrightness";RegisterClassW(&type);
        window=CreateWindowExW(0,type.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,type.hInstance,this);
        if(window)notification=RegisterPowerSettingNotification(window,&lidState,DEVICE_NOTIFY_WINDOW_HANDLE);
        worker=std::thread([this]{run();});
    }
    ~ShowLidBrightness() { stop(); }
    void setEnabled(bool value) { enabled=value;request(enabled&&closed); }
    void stop() {
        if(notification){UnregisterPowerSettingNotification(notification);notification=nullptr;}
        if(window){DestroyWindow(window);window=nullptr;}
        if(!worker.joinable())return;
        {std::lock_guard<std::mutex> guard(mutex);pending=false;stopping=true;}
        ready.notify_one();worker.join();
    }
private:
    static inline const GUID lidState{0xba3e0f4d,0xb817,0x4094,{0xa2,0xd1,0xd5,0x63,0x79,0xe6,0xa0,0xf3}};
    File backup;
    HWND window=nullptr;HPOWERNOTIFY notification=nullptr;
    bool enabled=false,closed=false;
    std::mutex mutex;std::condition_variable ready;std::thread worker;
    std::optional<bool> pending;bool stopping=false;
    void request(bool dim) {{std::lock_guard<std::mutex> guard(mutex);pending=dim;}ready.notify_one();}
    static LRESULT CALLBACK windowProcedure(HWND hwnd,UINT message,WPARAM w,LPARAM l) {
        auto* self=reinterpret_cast<ShowLidBrightness*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
        if(message==WM_NCCREATE){self=static_cast<ShowLidBrightness*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
        if(self && message==WM_POWERBROADCAST && w==PBT_POWERSETTINGCHANGE) {
            const auto* setting=reinterpret_cast<const POWERBROADCAST_SETTING*>(l);
            if(setting && IsEqualGUID(setting->PowerSetting,lidState) && setting->DataLength==sizeof(DWORD)) {
                DWORD value=1;memcpy(&value,setting->Data,sizeof(value));self->closed=value==0;
                self->request(self->enabled&&self->closed);return TRUE;
            }
        }
        if(self && (message==WM_DISPLAYCHANGE || (message==WM_POWERBROADCAST && w==PBT_APMRESUMEAUTOMATIC)))self->request(self->enabled&&self->closed);
        return DefWindowProcW(hwnd,message,w,l);
    }
    void run() {
        for(;;) {
            bool dim=false,finish=false;
            {std::unique_lock<std::mutex> guard(mutex);ready.wait(guard,[this]{return pending.has_value()||stopping;});dim=pending.value_or(false);pending.reset();finish=stopping;}
            apply(dim);
            if(finish)return;
        }
    }
    void apply(bool dim) {
        if (!dim && !backup.existsAsFile()) return;
        // Preserve each built-in panel independently. Offline/failed restores
        // remain on disk for the next open/resume/startup instead of being lost.
        auto path=backup.getFullPathName().replace("'","''");
        auto script=String("$ErrorActionPreference='Stop';$backup='")+path+"';$dim="+(dim?"$true;":"$false;")+R"ps(
try {
 $saved=@();if(Test-Path -LiteralPath $backup){$saved=@(Get-Content -LiteralPath $backup -Raw|ConvertFrom-Json)}
 $internal=@(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorConnectionParams|Where-Object {$_.Active -and $_.VideoOutputTechnology -in @(6,11,13,2147483648)}|ForEach-Object {$_.InstanceName})
 $panels=@(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness|Where-Object {$_.Active -and $_.InstanceName -in $internal})
 if($dim){
  foreach($panel in $panels){
   if(-not @($saved|Where-Object {$_.InstanceName -eq $panel.InstanceName}).Count){
    $minimum=0;if(@($panel.Level).Count){$minimum=[int]($panel.Level|Measure-Object -Minimum).Minimum}
    $saved+= [pscustomobject]@{InstanceName=$panel.InstanceName;Original=[int]$panel.CurrentBrightness;Minimum=$minimum}
   }
  }
  if($saved.Count){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))|Out-Null;[IO.File]::WriteAllText($backup,(ConvertTo-Json -InputObject $saved -Compress))}
 }
 $remaining=@();$methods=@(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods)
 foreach($record in $saved){
  $panel=@($panels|Where-Object {$_.InstanceName -eq $record.InstanceName})|Select-Object -First 1
  $method=@($methods|Where-Object {$_.InstanceName -eq $record.InstanceName})|Select-Object -First 1
  if(-not $panel -or -not $method){$remaining+=$record;continue}
  if(-not $dim -and [int]$panel.CurrentBrightness -gt [int]$record.Minimum+1){continue}
  $target=[byte]$record.Original;if($dim){$target=[byte]$record.Minimum}
  try {$answer=Invoke-CimMethod -InputObject $method -MethodName WmiSetBrightness -Arguments @{Timeout=[uint32]0;Brightness=$target};if($answer.ReturnValue -ne 0){throw 'Brightness write failed'};if($dim){$remaining+=$record}}
  catch {$remaining+=$record}
 }
 if($remaining.Count){[IO.File]::WriteAllText($backup,(ConvertTo-Json -InputObject $remaining -Compress))}
 elseif(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup}
} catch {exit 1}
)ps";
        const auto* wide=script.toWideCharPointer();MemoryBlock bytes(wide,std::wcslen(wide)*sizeof(wchar_t));
        const auto powershell=File::getSpecialLocation(File::windowsSystemDirectory).getChildFile("WindowsPowerShell/v1.0/powershell.exe");
        ChildProcess process;
        if(process.start(StringArray{powershell.getFullPathName(),"-NoLogo","-NoProfile","-NonInteractive","-WindowStyle","Hidden","-EncodedCommand",Base64::toBase64(bytes.getData(),bytes.getSize())}))
            if(!process.waitForProcessToFinish(8000))process.kill();
    }
};
}
