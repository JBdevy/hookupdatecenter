#pragma once
#include "Common.h"
#include <windns.h>
#include <mutex>
namespace catlive::remote {
// Native Windows 10/11 mDNS. Each asynchronous request owns its context until
// Windows invokes its completion, including when the panel/application closes.
// https://learn.microsoft.com/windows/win32/api/windns/nf-windns-dnsserviceregister
class Discovery final {
  public:
    ~Discovery() { stop(); }
    void start(const String &name, int port, const String &service="_jaras-live._tcp", ULONG interfaceIndex = 0) {
        stop();
        auto next = std::make_shared<State>();
        next->interfaceIndex = interfaceIndex;
        auto host = SystemStats::getComputerName().retainCharacters(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-");
        if (host.isEmpty())
            host = "CatLive";
        auto label = name.replaceCharacters(".\\", "--").substring(0, 60);
        while (label.getNumBytesAsUTF8() > 60)
            label = label.dropLastCharacters(1);
        if (label.isEmpty())
            label = "CatLive";
        const auto instance = label + "." + service + ".local";
        host += ".local";
        next->instance =
            DnsServiceConstructInstance(instance.toWideCharPointer(), host.toWideCharPointer(),
                                        nullptr, nullptr, (WORD)port, 0, 0, 0, nullptr, nullptr);
        if (!next->instance)
            throw std::runtime_error("Não foi possível anunciar o Remote na rede.");
        state = next;
        submit(next, false);
    }
    void stop() {
        auto old = std::move(state);
        if (!old)
            return;
        bool remove = false;
        {
            std::lock_guard<std::mutex> lock(old->mutex);
            old->stopped = true;
            if (old->registered) {
                old->registered = false;
                remove = true;
            }
        }
        if (remove)
            submit(old, true);
    }
    DWORD status() const { return state ? state->status.load() : ERROR_CANCELLED; }

  private:
    struct State {
        ~State() {
            if (instance)
                DnsServiceFreeInstance(instance);
        }
        PDNS_SERVICE_INSTANCE instance = nullptr;
        ULONG interfaceIndex = 0;
        std::mutex mutex;
        bool stopped = false, registered = false;
        std::atomic<DWORD> status{DNS_REQUEST_PENDING};
    };
    struct Operation {
        std::shared_ptr<State> state;
        bool remove;
        DNS_SERVICE_REGISTER_REQUEST request{};
    };
    std::shared_ptr<State> state;
    static void WINAPI completed(DWORD status, void *context, PDNS_SERVICE_INSTANCE instance) {
        std::unique_ptr<Operation> operation(static_cast<Operation *>(context));
        const auto state = operation->state;
        if (operation->remove) {
            if (instance)
                DnsServiceFreeInstance(instance);
            return;
        }
        bool remove = false;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (instance && status == ERROR_SUCCESS) {
                DnsServiceFreeInstance(state->instance);
                state->instance = instance;
                instance = nullptr;
            }
            state->status = status;
            if (status == ERROR_SUCCESS) {
                if (state->stopped)
                    remove = true;
                else
                    state->registered = true;
            }
        }
        if (instance)
            DnsServiceFreeInstance(instance);
        if (remove)
            submit(state, true);
    }
    static void submit(const std::shared_ptr<State> &state, bool remove) {
        auto operation = std::make_unique<Operation>();
        operation->state = state;
        operation->remove = remove;
        auto &request = operation->request;
        request.Version = DNS_QUERY_REQUEST_VERSION1;
        request.InterfaceIndex = state->interfaceIndex;
        request.pServiceInstance = state->instance;
        request.pQueryContext = operation.get();
        request.pRegisterCompletionCallback = completed;
        // Release before entering Windows: completion can race the API return.
        auto *context = operation.release();
        const DWORD result = remove ? DnsServiceDeRegister(&context->request, nullptr)
                                    : DnsServiceRegister(&context->request, nullptr);
        if (result != DNS_REQUEST_PENDING) {
            if (!remove)
                state->status = result;
            delete context;
        }
    }
};
} // namespace catlive::remote
