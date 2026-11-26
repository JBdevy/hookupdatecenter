#pragma once
#include "Common.h"

namespace catlive {
class TemporaryProjectSession {
    const File root;
    static void verifyDirectory(const File &folder) {
        if (folder.isSymbolicLink() || (folder.exists() && !folder.isDirectory()))
            throw std::runtime_error("The temporary project folder must be a real directory.");
    }
  public:
    const File directory;
    explicit TemporaryProjectSession(File documents = File::getSpecialLocation(File::userDocumentsDirectory))
        : root(documents.getChildFile("catlive-temp")),
          directory(root.getChildFile("session-" + Uuid().toString())) {
        verifyDirectory(root);
        if (root.createDirectory().failed())
            throw std::runtime_error("Could not prepare the temporary project folder.");
        verifyDirectory(root);
        if (directory.createDirectory().failed())
            throw std::runtime_error("Could not prepare the temporary project folder.");
    }
    ~TemporaryProjectSession() {
        try { clear(); } catch (...) {} // Leave media on disk if cleanup fails.
    }
    bool contains(const File &file) const { return file.isAChildOf(directory); }
    bool insideTemporaryRoot(const File &file) const { return file == root || file.isAChildOf(root); }
    void clear() {
        verifyDirectory(root);
        verifyDirectory(directory);
        if (directory.exists() && !directory.deleteRecursively())
            throw std::runtime_error("Could not clean the temporary project folder.");
    }
};
}
