#pragma once
#include "Common.h"
#include <thread>

namespace catlive {
// The same single-file backup envelope as SMK37FirmwareBackup.swift.
struct SMK37FirmwareBackup {
    MemoryBlock flash;
    var metadata;
    static void require(bool ok, const char *message) {
        if (!ok) throw std::runtime_error(message);
    }
    void validate() const {
        require(flash.getSize() == 1048576 && str(metadata,"model") == "SMK-37 Pro / Elite" &&
                str(metadata,"sha256") == SHA256(flash).toHexString() &&
                str(metadata,"unit id").isNotEmpty() && str(metadata,"unit id") != String::fromUTF8("–"),
                "Invalid or damaged SMK backup.");
    }
    void requirePro() const {
        require(str(metadata,"firmware").startsWith("SMK-37 Pro "),
                "The connected firmware could not be identified as SMK-37 Pro. Nothing was installed.");
    }
    static SMK37FirmwareBackup read(const File &file) {
        require(file.existsAsFile() && file.getSize() <= 2000000, "Invalid or damaged SMK backup.");
        SMK37FirmwareBackup result;
        if (file.hasFileExtension("bin")) {
            require(file.loadFileAsData(result.flash), "Cannot read the firmware backup.");
            result.metadata = JSON::parse(file.withFileExtension("json"));
        } else {
            const auto envelope = JSON::parse(file);
            require(str(envelope,"format") == "CatLive SMK37 Backup" && (int)get(envelope,"version") == 1,
                    "Invalid or damaged SMK backup.");
            result.metadata = get(envelope,"metadata");
            MemoryOutputStream decoded;
            require(Base64::convertFromBase64(decoded,str(envelope,"flash")), "Invalid or damaged SMK backup.");
            result.flash = decoded.getMemoryBlock();
        }
        result.validate(); return result;
    }
    void save(const File &file) const {
        validate();
        auto envelope = object(); put(envelope,"format","CatLive SMK37 Backup"); put(envelope,"version",1);
        put(envelope,"metadata",metadata); put(envelope,"flash",Base64::toBase64(flash.getData(),flash.getSize()));
        // Never truncate an existing backup until its replacement is complete.
        TemporaryFile temporary(file);
        {
            FileOutputStream out(temporary.getFile());
            require(out.openedOk(), "Cannot save the firmware backup.");
            require(out.writeText(JSON::toString(envelope),false,false,nullptr), "Cannot save the firmware backup.");
            out.flush(); require(out.getStatus().wasOk(), "Cannot save the firmware backup.");
        }
        require(temporary.overwriteTargetFileWithTemporary(), "Cannot save the firmware backup.");
        require(read(file).flash == flash, "The saved backup could not be verified.");
    }
    static void validatePackageModel(const MemoryBlock &bytes) {
        require(bytes.getSize() >= 4096 && bytes.getSize() <= 16777216,
                "Choose a compatible SMK-37 Pro .fwsc firmware file.");
        String identity;
        const auto *data = static_cast<const uint8_t *>(bytes.getData());
        for (size_t i = 0; i < std::min(size_t(64),bytes.getSize()/48); ++i) {
            const auto byte = data[i*48+47]; if (byte == 0x7d) break;
            identity += String::charToString((juce_wchar)(uint8_t)(byte-(i+1)));
        }
        const auto split = identity.lastIndexOfChar('_');
        require(split > 0 && identity.substring(0,split) == "SMK-37 Pro" && split < identity.length()-1,
                "Choose a compatible SMK-37 Pro .fwsc firmware file.");
    }
};

struct SMK37FirmwareFlow {
    enum Operation { backup, install, installFile };
    File resources, work;
    std::function<String(const StringArray &)> run;
    std::function<void(String)> status;
    static StringArray endpoints(const String &output) {
        StringArray result;
        for (const auto &line : StringArray::fromLines(output)) if (line.containsChar('\t')) result.add(line);
        return result;
    }
    void execute(Operation operation, const File &destination, const File &source = {}) const {
        using B = SMK37FirmwareBackup;
        const auto manifest = JSON::parse(resources.getChildFile("manifest.json"));
        auto package = resources.getChildFile("SMK37-CatLive.fwsc");
        MemoryBlock bundled;
        B::require((int)get(manifest,"schema") == 1 && str(manifest,"model") == "SMK-37 Pro" &&
                   package.loadFileAsData(bundled) && str(manifest,"sha256") == SHA256(bundled).toHexString(),
                   "The bundled SMK firmware is missing or damaged.");
        B::require(work.createDirectory().wasOk(), "Cannot create the firmware workspace.");
        std::optional<SMK37FirmwareBackup> restoring;
        if (operation == installFile) {
            B::require(source != destination, "Choose a different file for the current firmware backup.");
            if (source.hasFileExtension("fwsc")) {
                B::require(source.existsAsFile() && source.getSize() <= 16777216,
                           "Choose a compatible SMK-37 Pro .fwsc firmware file.");
                MemoryBlock bytes; B::require(source.loadFileAsData(bytes), "Cannot read the firmware file.");
                B::validatePackageModel(bytes);
                package = work.getChildFile("selected.fwsc");
                B::require(package.replaceWithData(bytes.getData(),bytes.getSize()), "Cannot copy the firmware file.");
            } else restoring = B::read(source);
        }
        B::require(run({"--version"}).trim() == "0.11.0", "The SMK firmware utility is not compatible.");
        const auto probe = destination.getParentDirectory().getNonexistentChildFile(".catlive-smk-probe", ".tmp");
        B::require(probe.create().wasOk(), "Cannot save the firmware backup at this location.");
        probe.deleteFile();
        const auto found = endpoints(run({"find"}));
        B::require(found.size() == 1, "Connect only one SMK-37 Pro using a USB data cable.");
        if (found[0].startsWith("midi\t")) {
            B::require(found[0].containsIgnoreCase("smk") && !found[0].containsIgnoreCase("elite"),
                       "Connect only one SMK-37 Pro using a USB data cable.");
            status("Connecting to SMK-37 Pro…"); run({"download-mode"});
        }
        const auto devices = endpoints(run({"find"}));
        B::require(devices.size() == 1 && !devices[0].startsWith("midi\t"),
                   "The keyboard did not enter USB download mode. Reconnect it and try again.");
        const auto device = devices[0].upToFirstOccurrenceOf("\t",false,false);
        status("Reading and verifying the current firmware…");
        run({"backup",work.getFullPathName(),"--device",device});
        const auto files = work.findChildFiles(File::findFiles,false,"*.bin");
        B::require(files.size() == 1, "The saved backup could not be verified.");
        const auto current = B::read(files[0]);
        current.save(destination);
        if (operation == backup) {
            status("Backup saved. Restarting the keyboard…");
            run({"restart","--device",device});
        } else if (restoring) {
            B::require(str(restoring->metadata,"unit id") == str(current.metadata,"unit id"),
                       "This backup belongs to another keyboard. Nothing was restored.");
            const auto image = work.getChildFile("restore.bin");
            B::require(image.replaceWithData(restoring->flash.getData(),restoring->flash.getSize()) &&
                       image.withFileExtension("json").replaceWithText(JSON::toString(restoring->metadata)),
                       "Cannot prepare the firmware backup.");
            status("Restoring the backup. Keep the USB cable connected…");
            run({"restore",image.getFullPathName(),"--backup-dir",work.getFullPathName(),"--yes","--restart","--device",device});
        } else {
            current.requirePro();
            status("Installing firmware. Keep the USB cable connected…");
            run({"firmware",package.getFullPathName(),"--backup-dir",work.getFullPathName(),"--yes","--restart","--device",device});
        }
    }
};

// Singleton survives closing/reopening Settings; never kill the helper midway
// through a write. Application quit is deferred until the operation finishes.
class SMK37FirmwareTask : public std::enable_shared_from_this<SMK37FirmwareTask> {
public:
    static std::shared_ptr<SMK37FirmwareTask> shared() {
        static auto task = std::make_shared<SMK37FirmwareTask>(); return task;
    }
    bool busy = false;
    String message, error;
    File saved, log;
    std::map<void *, std::function<void()>> beforeStart;
    void start(SMK37FirmwareFlow::Operation operation, const File &destination, const File &source = {}) {
        if (busy) return;
        const auto folder = File::getSpecialLocation(File::currentExecutableFile).getParentDirectory();
        const auto helper = folder.getChildFile("SMK37Tools/M-Flasher.exe");
        if (!helper.existsAsFile()) { error = "The SMK firmware utility is missing. Reinstall CatLive."; return; }
        busy = true; error.clear(); saved = {}; message = "Preparing firmware backup…";
        for (const auto &entry : beforeStart) entry.second();
        const auto work = File::getSpecialLocation(File::userApplicationDataDirectory)
            .getChildFile("CatLive/SMK37/"+Uuid().toString());
        log = work.getChildFile("operation.log");
        const auto self = shared_from_this();
        std::thread([self,operation,destination,source,folder,helper,work] {
            String failure;
            try {
                SMK37FirmwareBackup::require(work.createDirectory().wasOk(), "Cannot create the firmware workspace.");
                auto logStream = self->log.createOutputStream();
                SMK37FirmwareBackup::require(logStream && logStream->openedOk(), "Cannot create the firmware log.");
                auto run = [&](const StringArray &args) {
                    StringArray command{helper.getFullPathName()}; command.addArray(args);
                    ChildProcess process;
                    SMK37FirmwareBackup::require(process.start(command), "Cannot start the SMK firmware utility.");
                    String output; char buffer[4096];
                    for (;;) {
                        const auto count = process.readProcessOutput(buffer,sizeof buffer);
                        if (count > 0) { logStream->write(buffer,(size_t)count); output += String::fromUTF8(buffer,count); }
                        else if (!process.isRunning()) break;
                        else Thread::sleep(20);
                    }
                    logStream->flush();
                    if (process.getExitCode() != 0) throw std::runtime_error(output.isEmpty() ? "The SMK firmware utility failed." : utf8(output.substring(std::max(0,output.length()-2400))));
                    return output;
                };
                auto progress = [self](String value) { MessageManager::callAsync([self,value]{self->message=value;}); };
                SMK37FirmwareFlow{folder.getChildFile("SMK37"),work,run,progress}.execute(operation,destination,source);
            } catch (const std::exception &e) { failure = String::fromUTF8(e.what()); }
            bool valid = false; try { SMK37FirmwareBackup::read(destination); valid = true; } catch (...) {}
            MessageManager::callAsync([self,failure,destination,valid] {
                self->busy = false; self->error = failure; self->saved = valid ? destination : File{};
                self->message = failure.isEmpty() ? "Operation completed. The firmware backup is saved." : "Operation stopped. See the details below.";
            });
        }).detach();
    }
};
} // namespace catlive
