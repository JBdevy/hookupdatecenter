fn main() {
    let source = "../Source";
    let core = "../../Core";
    let mut build = cc::Build::new();
    build.cpp(true).std("c++17").opt_level(2)
        .include(source).include("../ThirdParty").include(core)
        .file(format!("{source}/ProjectCodec.cpp"))
        .file(format!("{source}/NativeSession.cpp"))
        .file(format!("{source}/SessionActions.cpp"))
        .file(format!("{source}/NativeBridge.cpp"))
        .file(format!("{source}/TrackDuplication.cpp"))
        .file(format!("{source}/ProjectCreation.cpp"))
        .file(format!("{core}/Project/Models.cpp"))
        .file(format!("{core}/Transport/Engine.cpp"))
        .file(format!("{core}/Import/TrackTaxonomy.cpp"));
    if build.get_compiler().is_like_msvc() {
        build.flag("/EHsc").flag("/utf-8").flag("/bigobj").define("NOMINMAX", None);
    }
    build.compile("catlive_documents");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        println!("cargo:rustc-link-lib=bcrypt");
        println!("cargo:rustc-link-lib=normaliz");
    }
    for path in [source, "../ThirdParty/nlohmann", core] {
        println!("cargo:rerun-if-changed={path}");
    }
}
