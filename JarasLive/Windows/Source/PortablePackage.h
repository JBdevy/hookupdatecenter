#pragma once
#include "ProjectCodec.h"
namespace catlive {
inline File importPortablePackage(const File &archive, const File &parent) {
    ZipFile zip(archive);
    auto fail = [](const char *reason) { throw std::runtime_error(reason); };
    if (zip.getNumEntries() < 2 || zip.getNumEntries() > 100000)
        fail("Invalid CatLive package.");
    std::set<String> names;
    for (int i = 0; i < zip.getNumEntries(); ++i) {
        auto *entry = zip.getEntry(i);
        auto path = entry->filename;
        if (entry->isSymbolicLink || entry->uncompressedSize < 0 || path.containsChar('\\') ||
            path.containsChar(':') || path.startsWithChar('/') || path.endsWithChar('/') ||
            !names.insert(path.toLowerCase()).second)
            fail("Invalid or duplicate package path.");
        for (auto &part : StringArray::fromTokens(path, "/", ""))
            if (part.isEmpty() || part == "." || part == ".." || part.endsWithChar('.') ||
                part.endsWithChar(' '))
                fail("Invalid package path.");
    }
    auto *metadata = zip.getEntry("manifest.json");
    if (!metadata || metadata->uncompressedSize > 16777216)
        fail("Invalid package manifest.");
    std::unique_ptr<InputStream> stream(
        zip.createStreamForEntry(zip.getIndexOfFileName("manifest.json")));
    if (!stream)
        fail("Cannot read package manifest.");
    auto manifest = JSON::parse(stream->readEntireStreamAsString());
    auto records = list(get(manifest, "files"));
    if (str(manifest, "format") != "catlive-ziplive" || num(manifest, "version") != 1 ||
        str(manifest, "document") != "Project.jl" || records.size() + 1 != zip.getNumEntries())
        fail("Unsupported CatLive package.");
    std::set<String> inventory;
    int64 total = 0;
    for (auto &record : records) {
        auto path = str(record, "path");
        auto *entry = zip.getEntry(path);
        if (!entry || path == "manifest.json" || !inventory.insert(path).second ||
            entry->uncompressedSize != (int64)get(record, "bytes") ||
            str(record, "sha256").length() != 64)
            fail("Invalid package inventory.");
        total += entry->uncompressedSize;
        if (total > 1099511627776LL)
            fail("Package exceeds supported size.");
    }
    if (!inventory.count("Project.jl"))
        fail("Project document is missing.");
    if (parent.getBytesFreeOnVolume() < total)
        fail("There is not enough disk space to import the project.");
    auto staging = parent.getChildFile(".catlive-import-" + Uuid().toString());
    if (staging.createDirectory().failed())
        fail("Cannot create project directory.");
    struct Cleanup {
        File folder, parent;
        ~Cleanup() {
            if (folder.getParentDirectory() == parent &&
                folder.getFileName().startsWith(".catlive-import-"))
                folder.deleteRecursively();
        }
    } cleanup{staging, parent};
    std::array<char, 65536> buffer;
    for (auto &record : records) {
        auto path = str(record, "path");
        auto target = ProjectCodec::resolveMedia(staging, utf8(path));
        if (target.getParentDirectory().createDirectory().failed())
            fail("Cannot create media directory.");
        std::unique_ptr<InputStream> input(zip.createStreamForEntry(zip.getIndexOfFileName(path)));
        FileOutputStream output(target);
        if (!input || output.failedToOpen())
            fail("Cannot extract project file.");
        int64 remaining = (int64)get(record, "bytes");
        while (remaining > 0) {
            int count =
                input->read(buffer.data(), (int)std::min<int64>(remaining, (int64)buffer.size()));
            if (count <= 0 || !output.write(buffer.data(), (size_t)count))
                fail("Incomplete package file.");
            remaining -= count;
        }
        output.flush();
        char extra;
        if (output.getStatus().failed() || input->read(&extra, 1) != 0)
            fail("Invalid package file size.");
        FileInputStream verify(target);
        if (SHA256(verify).toHexString() != str(record, "sha256").toLowerCase())
            fail("Package integrity check failed.");
    }
    auto document = staging.getChildFile("Project.jl");
    auto project = ProjectCodec::decode(ProjectCodec::read(document));
    if (!text(project.id).equalsIgnoreCase(str(manifest, "projectID")))
        fail("Package project identity mismatch.");
    auto name = File::createLegalFileName(text(project.name)).substring(0, 80);
    if (name.isEmpty())
        name = "CatLive";
    auto destination = parent.getNonexistentChildFile(name, "", true);
    if (!staging.moveFileTo(destination))
        fail("Cannot finish project import.");
    return destination.getChildFile("Project.jl");
}
} // namespace catlive
