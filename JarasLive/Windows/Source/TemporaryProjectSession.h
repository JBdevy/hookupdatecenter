#pragma once
#include "Common.h"
#include <set>
namespace catlive {
// The root is exclusive across tabs and processes. A crash releases the OS
// lock; its leftover files are removed only on the next temporary creation.
class TemporaryProjectSession {
    inline static CriticalSection registryLock;
    inline static std::set<String> activeRoots;
    InterProcessLock processLock;
    bool owned = false;
    void verify() const {
        if (directory.isSymbolicLink() || (directory.exists() && !directory.isDirectory()))
            throw std::runtime_error("The temporary project folder must be a real directory.");
    }
  public:
    const File directory;
    explicit TemporaryProjectSession(File documents = File::getSpecialLocation(File::userDocumentsDirectory))
        : processLock("CatLiveTemporary-" + String::toHexString(documents.getFullPathName().hashCode64())),
          directory(documents.getChildFile("catlive-temp")) {
        const ScopedLock guard(registryLock);
        if (activeRoots.count(directory.getFullPathName()) || !processLock.enter(0))
            throw std::runtime_error("Close the other temporary session before creating a new one.");
        try {
            verify();
            if (directory.createDirectory().failed()) throw std::runtime_error("Could not prepare the temporary project folder.");
            clear(); activeRoots.insert(directory.getFullPathName()); owned = true;
        } catch (...) { processLock.exit(); throw; }
    }
    ~TemporaryProjectSession() {
        if (!owned) return;
        try { clear(); } catch (...) {} // Retry stale cleanup on the next launch.
        const ScopedLock guard(registryLock);
        activeRoots.erase(directory.getFullPathName()); processLock.exit();
    }
    bool contains(const File &file) const { return file.isAChildOf(directory); }
    void clear() {
        verify();
        for (const auto &entry : directory.findChildFiles(File::findFilesAndDirectories, false))
            if (!(entry.isSymbolicLink() ? entry.deleteFile() : entry.deleteRecursively()))
                throw std::runtime_error("Could not clean the temporary project folder.");
    }
};
}
