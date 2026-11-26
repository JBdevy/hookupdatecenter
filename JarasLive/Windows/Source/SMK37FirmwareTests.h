#pragma once
#include "SMK37Firmware.h"
namespace catlive::smk37FirmwareTests {
template<class Test> void run(const File &directory, Test test) {
    test("SMK firmware backup and install safeguards", [&] {
        using B = SMK37FirmwareBackup;
        auto require = [](bool ok){ B::require(ok,"SMK firmware safety test failed"); };
        const auto root = directory.getNonexistentChildFile("smk-firmware",{});
        root.createDirectory();
        MemoryBlock bytes(1048576); std::memset(bytes.getData(),0x5a,bytes.getSize());
        auto metadata=object(); put(metadata,"model","SMK-37 Pro / Elite");put(metadata,"firmware","SMK-37 Pro 016 (stock)");
        put(metadata,"unit id","TEST-UNIT");put(metadata,"sha256",SHA256(bytes).toHexString());
        B original{bytes,metadata};
        const auto saved=root.getChildFile("backup com espaços.smkbackup");original.save(saved);
        require(B::read(saved).flash==bytes);
        const auto exchange=SystemStats::getEnvironmentVariable("CATLIVE_SMK_BACKUP_EXCHANGE",{});
        if(exchange.isNotEmpty()) {
            require(B::read(File(exchange).getChildFile("swift.smkbackup")).flash==bytes);
            original.save(File(exchange).getChildFile("windows.smkbackup"));
        }
        auto corrupt=metadata.clone();put(corrupt,"sha256","bad");
        bool rejected=false;try{B{bytes,corrupt}.validate();}catch(...){rejected=true;}require(rejected);
        const auto resources=File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("SMK37");
        MemoryBlock package;require(resources.getChildFile("SMK37-CatLive.fwsc").loadFileAsData(package));B::validatePackageModel(package);
        for(int scenario=0;scenario<6;++scenario) {
            const auto work=root.getChildFile("work-"+String(scenario));work.createDirectory();
            const auto destination=root.getChildFile("destination-"+String(scenario)+".smkbackup");
            bool download=false,wrote=false;StringArray commands;
            auto runner=[&](const StringArray &args)->String {
                commands.add(args[0]);
                if(args[0]=="--version")return "0.11.0\n";
                if(args[0]=="find")return scenario==4?"usb1\tdisk\nusb2\tdisk\n":download?"usb1\tWL82 UBOOT\n":"midi\tSMK-37 Pro (running)\n";
                if(args[0]=="download-mode"){download=true;return {};}
                if(args[0]=="backup") {
                    if(scenario==3)throw std::runtime_error("Cancelled authorization");
                    require(work.getChildFile("read.bin").replaceWithData(bytes.getData(),bytes.getSize()));
                    require(work.getChildFile("read.json").replaceWithText(JSON::toString(scenario==2?corrupt:metadata)));return {};
                }
                if(args[0]=="firmware"||args[0]=="restore") {
                    require(B::read(destination).flash==bytes);require(args.contains("--device")&&args.contains("usb1"));
                    require(!args.contains("--board")&&!args.contains("--with-bootloader"));wrote=true;return {};
                }
                require(args[0]=="restart");return {};
            };
            bool failed=false;
            try{SMK37FirmwareFlow{resources,work,runner,[](String){}}.execute(scenario==0?SMK37FirmwareFlow::backup:scenario==5?SMK37FirmwareFlow::installFile:SMK37FirmwareFlow::install,destination,scenario==5?saved:File{});}
            catch(...){failed=true;}
            require(failed==(scenario>=2&&scenario<=4));require(wrote==(scenario==1||scenario==5));
        }
        root.deleteRecursively();
    });
}
}
