#include "Auth.h"
#include "LicenseProof.h"
#include <wincrypt.h>
#include <windows.h>
namespace catlive {
namespace {
struct BackendFailure final : std::runtime_error {
    String code;
    BackendFailure(String value, String message) : std::runtime_error(utf8(message)), code(std::move(value)) {}
};
String hardwareID(const String& fallback) {
    auto machine=WindowsRegistry::getValue("HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\\MachineGuid").trim();
    if(machine.isEmpty())machine=fallback;
    auto bytes=machine.toUTF8();return "windows-"+SHA256(bytes.getAddress(),(size_t)machine.getNumBytesAsUTF8()).toHexString();
}
String failure(const String &code) {
    const std::map<String, String> errors{
        {"invalidCredentials", String::fromUTF8("E-mail ou CPF inválidos.")},
        {"invalidSession", "Entre novamente na sua conta."},
        {"invalidDevice", String::fromUTF8("A identificação deste computador é inválida. Atualize o CatLive e tente novamente.")},
        {"trialConsumed", String::fromUTF8("O teste deste computador foi encerrado. Faça login.")},
        {"revoked", "Este dispositivo foi revogado."},
        {"blocked", String::fromUTF8("Esta conta está bloqueada.")},
        {"quarantined", "Acesso bloqueado. Entre em contato com o administrador."},
        {"deviceLimit",
         String::fromUTF8("Todas as licenças estão em uso. Gerencie os dispositivos para liberar uma vaga.")},
        {"rateLimited", "Muitas tentativas. Aguarde alguns minutos."}};
    auto i = errors.find(code);
    return i == errors.end() ? String::fromUTF8("O serviço de licenças não conseguiu validar a solicitação.") : i->second;
}
MemoryBlock dpapi(const MemoryBlock &bytes, bool encrypt) {
    DATA_BLOB input{(DWORD)bytes.getSize(), (BYTE *)bytes.getData()}, output{};
    BOOL ok = encrypt ? CryptProtectData(&input, L"CatLive session", nullptr, nullptr, nullptr,
                                         CRYPTPROTECT_UI_FORBIDDEN, &output)
                      : CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                                           CRYPTPROTECT_UI_FORBIDDEN, &output);
    if (!ok)
        throw std::runtime_error("Windows could not unlock the CatLive credentials.");
    MemoryBlock result(output.pbData, output.cbData);
    SecureZeroMemory(output.pbData, output.cbData);
    LocalFree(output.pbData);
    return result;
}
} // namespace
MemoryBlock Auth::protect(const MemoryBlock &b) { return dpapi(b, true); }
MemoryBlock Auth::unprotect(const MemoryBlock &b) { return dpapi(b, false); }
File Auth::dataDirectory() const {
    return File::getSpecialLocation(File::userApplicationDataDirectory)
        .getChildFile("Hook Developer/CatLive");
}
String Auth::canonicalInstallationID(const String &value) {
    const auto compact = value.removeCharacters("-");
    if (compact.length() != 32 || !compact.containsOnly("0123456789abcdefABCDEF") ||
        (value.length() != 32 && value.length() != 36))
        throw std::runtime_error("Installation identity is damaged.");
    return Uuid(compact).toDashedString().toUpperCase();
}
Auth::Auth() {
    auto dir = dataDirectory();
    dir.createDirectory();
    auto file = dir.getChildFile("installation.dat");
    if (file.existsAsFile()) {
        MemoryBlock b;
        if (!file.loadFileAsData(b))
            throw std::runtime_error("Could not read installation identity.");
        auto v = JSON::parse(unprotect(b).toString());
        const auto savedID = str(v, "id");
        installationId = canonicalInstallationID(savedID);
        deviceName = str(v, "name");
        if (installationId != savedID) {
            put(v, "id", installationId);
            const auto json = JSON::toString(v, true);
            const auto encoded = protect(MemoryBlock(json.toRawUTF8(), json.getNumBytesAsUTF8()));
            if (!file.replaceWithData(encoded.getData(), encoded.getSize()))
                throw std::runtime_error("Could not update installation identity.");
        }
    } else {
        installationId = text(uuid());
        deviceName = SystemStats::getComputerName();
        auto v = object();
        put(v, "id", installationId);
        put(v, "name", deviceName);
        auto b =
            protect(MemoryBlock(JSON::toString(v).toRawUTF8(), JSON::toString(v).getNumBytesAsUTF8()));
        if (!file.replaceWithData(b.getData(), b.getSize()))
            throw std::runtime_error("Could not save installation identity.");
    }
    startTimer(30000);
}
Auth::~Auth() {
    stopTimer();
    alive.reset();
    worker.removeAllJobs(true, 10000);
}
var Auth::device() const {
    auto v = object();
    put(v, "installationId", installationId);
    put(v, "deviceName", deviceName);
    put(v, "platform", "Windows");
    put(v, "platformVersion", SystemStats::getOperatingSystemName());
    put(v, "appVersion", JUCE_APPLICATION_VERSION_STRING);
    return v;
}
var Auth::request(const String &route, const var &body, const String &token) {
    auto json = JSON::toString(body.isObject() ? body : object(), true);
    int status = 0;
    auto options =
        URL::InputStreamOptions(URL::ParameterHandling::inPostData)
            .withConnectionTimeoutMs(8000)
            .withNumRedirectsToFollow(0)
            .withStatusCode(&status)
            .withExtraHeaders("Content-Type: application/json\r\n" +
                              (token.isEmpty() ? String() : "Authorization: Bearer " + token + "\r\n"));
    auto stream = URL("https://backcatlive.up.railway.app/api/" + route)
                      .withPOSTData(json)
                      .createInputStream(options);
    if (!stream)
        throw std::runtime_error("Não foi possível conectar ao serviço.");
    MemoryBlock bytes;
    stream->readIntoMemoryBlock(bytes, 1024 * 1024);
    var response;
    if (JSON::parse(bytes.toString(), response).failed())
        throw std::runtime_error("Resposta inválida do serviço.");
    if (status < 200 || status >= 300)
        throw BackendFailure(str(response, "error"), failure(str(response, "error")));
    return response;
}
bool Auth::verifyEntitlement(const var &entitlement, const String &account, const String &installation) {
    return license::verify(entitlement, account, installation,
                            "eKtq54IOoeNi6MEagLPmAmT1AoEauwuzJotpLysRp+o=");
}
void Auth::accept(var data, bool online) {
    auto entitlement = get(data, "entitlement");
    const auto account = str(get(data, "account"), "id");
    if (!verifyEntitlement(entitlement, account, installationId))
        throw std::runtime_error("Assinatura da licença inválida.");
    if (str(get(data, "device"), "status") != "active" ||
        !str(get(data, "device"), "installationId").equalsIgnoreCase(installationId))
        throw std::runtime_error("Dispositivo sem autorização.");
    const auto now = Time::getCurrentTime();
    auto serverTime = Time::fromISO8601(str(entitlement, "serverTime"));
    if (now < serverTime - RelativeTime::minutes(5))
        throw std::runtime_error("Corrija a data do Windows e valide sua licença.");
    expiry = Time::fromISO8601(str(entitlement, "expiresAt"));
    const auto graceStart = Time::fromISO8601(str(entitlement, "graceStartsAt")),
               graceEnd = Time::fromISO8601(str(entitlement, "graceUntil"));
    const auto status = str(entitlement, "status"), plan = str(entitlement, "planId");
    bool grace = plan != "trial" && (status == "active" || status == "expired" || status == "overdue") &&
                 graceEnd > graceStart && (graceEnd - graceStart) <= RelativeTime::days(7) &&
                 now >= graceStart && now < graceEnd;
    if (grace)
        expiry = graceEnd;
    if ((status != "active" && !grace) || now >= expiry ||
        !list(get(entitlement, "features")).contains(var("desktop")))
        throw std::runtime_error("A licença não permite acesso ao CatLive desktop.");
    offlineUntil = Time::fromISO8601(str(entitlement, "offlineValidUntil"));
    if (!online && now >= offlineUntil)
        throw std::runtime_error("Conecte à internet para revalidar sua licença.");
    loginData = data;
    authorised = true;
    pendingRevocation = false;
    lastWall = now;
    validatedMonotonic = Time::getMillisecondCounterHiRes();
    int days = (int)std::ceil((expiry - now).inDays());
    title = plan == "trial" ? String::fromUTF8("Trial Mode — ") + String(days) + " dias restantes"
                            : str(get(data, "account"), "name") + String::fromUTF8(" — ") +
                                  (plan == "vitalicio" ? String(String::fromUTF8("Acesso Vitalício"))
                                                       : "Acesso " + String(days) + " dias");
    if (!online)
        title += String::fromUTF8(" · Offline");
    message.clear();
    persist();
}
void Auth::persist() {
    auto identity=object();put(identity,"id",installationId);put(identity,"name",deviceName);auto identityJSON=JSON::toString(identity,true);auto protectedIdentity=protect(MemoryBlock(identityJSON.toRawUTF8(),identityJSON.getNumBytesAsUTF8()));
    if(!dataDirectory().getChildFile("installation.dat").replaceWithData(protectedIdentity.getData(),protectedIdentity.getSize()))throw std::runtime_error("Could not save device name.");
    auto cache = object();
    put(cache, "login", loginData);
    put(cache, "lastWall", Time::getCurrentTime().toISO8601(true));
    auto json = JSON::toString(cache, true);
    auto b = protect(MemoryBlock(json.toRawUTF8(), json.getNumBytesAsUTF8()));
    if (!dataDirectory().getChildFile("session.dat").replaceWithData(b.getData(), b.getSize()))
        throw std::runtime_error("Não foi possível guardar a sessão no Windows.");
}
void Auth::begin(const String &route, var body) {
    if (busy)
        return;
    busy = true;
    message.clear();
    if (changed)
        changed();
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, route, body] {
        var response;
        String error;
        try {
            response = request(route, body);
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([this, weak, response, error] {
            if (weak.expired())
                return;
            busy = false;
            try {
                if (error.isNotEmpty())
                    throw std::runtime_error(utf8(error));
                accept(response, true);
            } catch (const std::exception &e) {
                authorised = false;
                message = String::fromUTF8(e.what());
            }
            if (changed)
                changed();
        });
    });
}
void Auth::login(String email, String cpf, String name) {
    if (name.trim().isEmpty()) {
        message = "Informe o nome deste computador.";
        if (changed)
            changed();
        return;
    }
    deviceName = name.trim().substring(0, 64);
    auto body = object();
    put(body, "email", email.trim());
    put(body, "cpf", cpf);
    put(body, "device", device());
    put(body, "hardwareID", hardwareID(installationId));
    begin("login", body);
}
void Auth::trial(String name) {
    deviceName = name.trim().isEmpty() ? SystemStats::getComputerName() : name.trim().substring(0, 64);
    auto body = object();
    put(body, "device", device());
    put(body, "hardwareID", hardwareID(installationId));
    begin("trial", body);
}
void Auth::restore() {
    auto file = dataDirectory().getChildFile("session.dat");
    if (!file.existsAsFile())
        return;
    try {
        MemoryBlock b;
        if (!file.loadFileAsData(b))
            return;
        auto cache = JSON::parse(unprotect(b).toString());
        auto wall = Time::fromISO8601(str(cache, "lastWall"));
        if (Time::getCurrentTime() < wall - RelativeTime::minutes(5))
            throw std::runtime_error("A data do Windows mudou. Corrija o relógio.");
        accept(get(cache, "login"), false);
        validate();
    } catch (const std::exception &e) {
        authorised = false;
        message = String::fromUTF8(e.what());
    }
}
void Auth::validate() {
    if (busy || !loginData.isObject())
        return;
    busy = true;
    if (changed) changed();
    auto saved = loginData.clone();
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, saved] {
        var updated = saved;
        String error;
        bool networkFailure = false;
        try {
            auto body = object();
            put(body, "refreshToken", str(get(saved, "session"), "refreshToken"));
            put(body, "activationProof", get(get(saved, "entitlement"), "proof"));
            request("access-status", body);
            auto session = request("refresh", body);
            put(updated, "session", session);
            put(updated, "entitlement", request("entitlement", {}, str(session, "accessToken")));
            auto d = object();
            put(d, "installationId", installationId);
            put(updated, "device", request("device", d, str(session, "accessToken")));
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
            networkFailure = error == String::fromUTF8("Não foi possível conectar ao serviço.");
        }
        MessageManager::callAsync([this, weak, updated, error, networkFailure] {
            if (weak.expired())
                return;
            busy = false;
            try {
                if (error.isNotEmpty() && !networkFailure)
                    throw std::runtime_error(utf8(error));
                accept(updated, !networkFailure);
            } catch (const std::exception &e) {
                message = String::fromUTF8(e.what());
                dataDirectory().getChildFile("session.dat").deleteFile();
                if (isPlaying && isPlaying())
                    pendingRevocation = true;
                else
                    authorised = false;
            }
            if (changed)
                changed();
        });
    });
}
void Auth::logout() {
    if (busy || (isPlaying && isPlaying()))
        return;
    if (!loginData.isObject()) { message = "Entre na sua conta primeiro."; if (changed) changed(); return; }
    busy = true;
    message = String::fromUTF8("Liberando este dispositivo…");
    if (changed) changed();
    auto saved = loginData;
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([this, weak, saved] {
        String error;
        try {
            auto b = object();
            put(b, "refreshToken", str(get(saved, "session"), "refreshToken"));
            request("logout", b);
        } catch (const BackendFailure &e) {
            if (e.code != "invalidSession") error = String::fromUTF8(e.what());
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([this, weak, error] {
            if (weak.expired())
                return;
            busy = false;
            if (error.isEmpty()) {
                authorised = false;
                loginData = var();
                pendingRevocation = false;
                message.clear();
                title = "Sem acesso";
                dataDirectory().getChildFile("session.dat").deleteFile();
            } else
                message = error;
            if (changed)
                changed();
        });
    });
}
void Auth::credentialDevices(String email, String cpf, std::function<void(var, String)> done) {
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([weak, email, cpf, done] {
        var result;
        String error;
        try {
            auto b = object();
            put(b, "email", email);
            put(b, "cpf", cpf);
            result = request("login/devices", b);
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([weak, done, result, error] {
            if (!weak.expired())
                done(result, error);
        });
    });
}
void Auth::revokeCredentialDevice(String email, String cpf, String id,
                                  std::function<void(String)> done) {
    auto weak = std::weak_ptr<int>(alive);
    worker.addJob([weak, email, cpf, id, done] {
        String error;
        try {
            auto b = object();
            put(b, "email", email);
            put(b, "cpf", cpf);
            put(b, "installationId", id);
            request("login/revoke-device", b);
        } catch (const std::exception &e) {
            error = String::fromUTF8(e.what());
        }
        MessageManager::callAsync([weak, done, error] {
            if (!weak.expired())
                done(error);
        });
    });
}
void Auth::timerCallback() {
    if (pendingRevocation && (!isPlaying || !isPlaying())) {
        authorised = false;
        pendingRevocation = false;
        if (changed)
            changed();
        return;
    }
    const auto now = Time::getCurrentTime();
    if (authorised && (now >= expiry || now < lastWall - RelativeTime::minutes(5))) {
        if (isPlaying && isPlaying())
            pendingRevocation = true;
        else
            authorised = false;
        if (changed)
            changed();
    }
    lastWall = now;
    if (authorised && Time::getMillisecondCounterHiRes() - validatedMonotonic > 120000)
        validate();
}
} // namespace catlive
