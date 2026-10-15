#pragma once
#include "Common.h"
namespace catlive {
class Auth final : private Timer {
  public:
    Auth();
    ~Auth() override;
    std::function<void()> changed;
    bool allowed() const { return authorised && (expiry > Time::getCurrentTime() || pendingRevocation); }
    bool busy = false, pendingRevocation = false;
    String message, title = "Sem acesso", installationId, deviceName;
    var loginData;
    std::function<bool()> isPlaying;
    void login(String email, String cpf, String name);
    void trial(String name);
    void restore();
    void logout();
    void validate();
    void credentialDevices(String email, String cpf, std::function<void(var, String)>);
    void revokeCredentialDevice(String email, String cpf, String id, std::function<void(String)>);
    static bool verifyEntitlement(const var &, const String &account, const String &installation);
    static String canonicalInstallationID(const String &);
    static MemoryBlock protect(const MemoryBlock &);
    static MemoryBlock unprotect(const MemoryBlock &);
    static var request(const String &route, const var &body = {}, const String &token = {});
    File dataDirectory() const;

  private:
    ThreadPool worker{1};
    bool authorised = false;
    Time expiry, offlineUntil, lastWall;
    double validatedMonotonic = 0;
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    void timerCallback() override;
    void begin(const String &route, var body);
    void accept(var, bool online);
    void persist();
    var device() const;
};
} // namespace catlive
