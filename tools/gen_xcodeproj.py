#!/usr/bin/env python3
"""
Generates DualCamRecorder.xcodeproj/project.pbxproj from the files under DualCamRecorder/.

Usage (from the repository root):  python3 tools/gen_xcodeproj.py

Re-run after adding/removing source files. Object IDs are derived from file paths, so the output is
stable and diffs stay small.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = "DualCamRecorder"
PROJECT = "DualCamRecorder"
BUNDLE_ID = "sk.dualcam.DualCamRecorder"
DEPLOYMENT = "14.0"
FRAMEWORKS = ["AVFoundation", "CoreMedia", "CoreVideo", "VideoToolbox", "CoreFoundation"]

SOURCE_EXT = {".swift": "sourcecode.swift", ".mm": "sourcecode.cpp.objcpp", ".m": "sourcecode.c.objc",
              ".cpp": "sourcecode.cpp.cpp"}
HEADER_EXT = {".h": "sourcecode.c.h"}
OTHER_EXT = {".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements", ".md": "net.daringfireball.markdown"}
# Copied into the app (the asset catalog holds the app icon).
RESOURCE_EXT = {".xcassets": "folder.assetcatalog"}


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(s):
    """Quote a pbxproj string when needed."""
    if s and all(c.isalnum() or c in "._/$" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def collect():
    tree = {}  # dir -> (subdirs, files)
    base = os.path.join(ROOT, SRC_DIR)
    for dirpath, dirnames, filenames in os.walk(base):
        # Asset catalogs are one item, not a group.
        catalogs = [d for d in dirnames if os.path.splitext(d)[1] in RESOURCE_EXT]
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in catalogs)
        rel = os.path.relpath(dirpath, ROOT)
        files = sorted([f for f in filenames if not f.startswith(".")
                        and os.path.splitext(f)[1] in {**SOURCE_EXT, **HEADER_EXT, **OTHER_EXT}] + catalogs)
        tree[rel] = (dirnames, files)
    return tree


def existing_setting(key, default):
    """Value of `key` in the current project.pbxproj (version and build number survive a regeneration)."""
    path = os.path.join(ROOT, f"{PROJECT}.xcodeproj", "project.pbxproj")
    try:
        text = open(path).read()
    except OSError:
        return default
    import re
    match = re.search(r"\b" + key + r" = ([^;]+);", text)
    return match.group(1).strip().strip('"') if match else default


def main():
    tree = collect()
    objects = []
    sources_build = []
    resources_build = []
    file_refs = {}

    def add(section_lines):
        objects.append(section_lines)

    # File references + build files
    build_files = []
    file_ref_lines = []
    for d, (_, files) in tree.items():
        for f in files:
            path = os.path.join(d, f)
            ext = os.path.splitext(f)[1]
            ftype = SOURCE_EXT.get(ext) or HEADER_EXT.get(ext) or OTHER_EXT.get(ext) or RESOURCE_EXT.get(ext)
            ref = oid("ref", path)
            file_refs[path] = ref
            file_ref_lines.append(
                f"\t\t{ref} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {q(f)}; sourceTree = \"<group>\"; }};")
            if ext in SOURCE_EXT:
                bf = oid("build", path)
                build_files.append(f"\t\t{bf} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {f} */; }};")
                sources_build.append((bf, f))
            elif ext in RESOURCE_EXT:
                bf = oid("build", path)
                build_files.append(f"\t\t{bf} /* {f} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {f} */; }};")
                resources_build.append((bf, f))

    fw_build = []
    for fw in FRAMEWORKS:
        ref = oid("fwref", fw)
        bf = oid("fwbuild", fw)
        file_ref_lines.append(
            f"\t\t{ref} /* {fw}.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {fw}.framework; path = System/Library/Frameworks/{fw}.framework; sourceTree = SDKROOT; }};")
        build_files.append(f"\t\t{bf} /* {fw}.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref} /* {fw}.framework */; }};")
        fw_build.append((bf, fw))

    product_ref = oid("product")
    file_ref_lines.append(
        f"\t\t{product_ref} /* {PROJECT}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJECT}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

    # Groups
    group_lines = []
    main_group = oid("group", "main")
    products_group = oid("group", "products")
    frameworks_group = oid("group", "frameworks")

    def group_id(d):
        return oid("group", d)

    for d, (subdirs, files) in tree.items():
        children = [f"\t\t\t\t{group_id(os.path.join(d, s))} /* {s} */," for s in subdirs]
        children += [f"\t\t\t\t{file_refs[os.path.join(d, f)]} /* {f} */," for f in files]
        name = os.path.basename(d)
        group_lines.append(
            f"\t\t{group_id(d)} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" + "\n".join(children) +
            f"\n\t\t\t);\n\t\t\tpath = {q(name)};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")

    group_lines.append(
        f"\t\t{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
        f"\t\t\t\t{group_id(SRC_DIR)} /* {SRC_DIR} */,\n"
        f"\t\t\t\t{frameworks_group} /* Frameworks */,\n"
        f"\t\t\t\t{products_group} /* Products */,\n"
        f"\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    group_lines.append(
        f"\t\t{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
        f"\t\t\t\t{product_ref} /* {PROJECT}.app */,\n"
        f"\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    group_lines.append(
        f"\t\t{frameworks_group} /* Frameworks */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" +
        "\n".join(f"\t\t\t\t{oid('fwref', fw)} /* {fw}.framework */," for fw in FRAMEWORKS) +
        f"\n\t\t\t);\n\t\t\tname = Frameworks;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")

    target = oid("target")
    project = oid("project")
    sources_phase = oid("phase", "sources")
    frameworks_phase = oid("phase", "frameworks")
    resources_phase = oid("phase", "resources")
    proj_cfg_list = oid("cfglist", "project")
    tgt_cfg_list = oid("cfglist", "target")
    proj_debug = oid("cfg", "project", "Debug")
    proj_release = oid("cfg", "project", "Release")
    tgt_debug = oid("cfg", "target", "Debug")
    tgt_release = oid("cfg", "target", "Release")

    def settings_block(d):
        lines = []
        for k in sorted(d):
            v = d[k]
            if isinstance(v, list):
                lines.append(f"\t\t\t\t{k} = (\n" + "".join(f"\t\t\t\t\t{q(x)},\n" for x in v) + "\t\t\t\t);")
            else:
                lines.append(f"\t\t\t\t{k} = {q(str(v))};")
        return "\n".join(lines)

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
        "SDKROOT": "macosx",
        "ARCHS": "arm64",
        "SWIFT_VERSION": "5.0",
    }
    proj_debug_s = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    proj_release_s = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "GCC_OPTIMIZATION_LEVEL": "s",
    })
    target_s = {
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "MARKETING_VERSION": existing_setting("MARKETING_VERSION", "1.0"),
        "CURRENT_PROJECT_VERSION": existing_setting("CURRENT_PROJECT_VERSION", "1"),
        "GENERATE_INFOPLIST_FILE": "YES",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "INFOPLIST_KEY_CFBundleDisplayName": "DualCamRecorder",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.video",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "",
        "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "Phones on the same Wi-Fi can watch the cameras live.",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": "Sound from the audio interface (sound mixer) is recorded into the camera files.",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_IDENTITY": "-",
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "NO",
        "SWIFT_OBJC_BRIDGING_HEADER": f"{SRC_DIR}/Bridge/{PROJECT}-Bridging-Header.h",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "HEADER_SEARCH_PATHS": [
            "$(inherited)",
            "$(SRCROOT)/DeckLinkSDK/Mac/include",
            "$(SRCROOT)/DeckLinkSDK/include",
            "$(SRCROOT)/DeckLinkSDK",
        ],
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    }

    def cfg(id_, name, s):
        return (f"\t\t{id_} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
                f"{settings_block(s)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")

    out = []
    out.append("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")
    out.append("/* Begin PBXBuildFile section */\n" + "\n".join(build_files) + "\n/* End PBXBuildFile section */\n")
    out.append("\n/* Begin PBXFileReference section */\n" + "\n".join(file_ref_lines) + "\n/* End PBXFileReference section */\n")
    out.append("\n/* Begin PBXFrameworksBuildPhase section */\n"
               f"\t\t{frameworks_phase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" +
               "\n".join(f"\t\t\t\t{bf} /* {fw}.framework in Frameworks */," for bf, fw in fw_build) +
               "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXFrameworksBuildPhase section */\n")
    out.append("\n/* Begin PBXGroup section */\n" + "\n".join(group_lines) + "\n/* End PBXGroup section */\n")
    out.append("\n/* Begin PBXNativeTarget section */\n"
               f"\t\t{target} /* {PROJECT} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {tgt_cfg_list} /* Build configuration list for PBXNativeTarget \"{PROJECT}\" */;\n"
               f"\t\t\tbuildPhases = (\n\t\t\t\t{sources_phase} /* Sources */,\n\t\t\t\t{frameworks_phase} /* Frameworks */,\n\t\t\t\t{resources_phase} /* Resources */,\n\t\t\t);\n"
               f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {PROJECT};\n\t\t\tproductName = {PROJECT};\n"
               f"\t\t\tproductReference = {product_ref} /* {PROJECT}.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n"
               "/* End PBXNativeTarget section */\n")
    out.append("\n/* Begin PBXProject section */\n"
               f"\t\t{project} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
               f"\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{target} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n"
               f"\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject \"{PROJECT}\" */;\n"
               f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n"
               f"\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\tsk,\n\t\t\t);\n"
               f"\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products_group} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
               f"\t\t\ttargets = (\n\t\t\t\t{target} /* {PROJECT} */,\n\t\t\t);\n\t\t}};\n/* End PBXProject section */\n")
    out.append("\n/* Begin PBXResourcesBuildPhase section */\n"
               f"\t\t{resources_phase} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" +
               "".join(f"\t\t\t\t{bf} /* {f} in Resources */,\n" for bf, f in resources_build) +
               "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n"
               "/* End PBXResourcesBuildPhase section */\n")
    out.append("\n/* Begin PBXSourcesBuildPhase section */\n"
               f"\t\t{sources_phase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" +
               "\n".join(f"\t\t\t\t{bf} /* {f} in Sources */," for bf, f in sources_build) +
               "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXSourcesBuildPhase section */\n")
    out.append("\n/* Begin XCBuildConfiguration section */\n" +
               "\n".join([cfg(proj_debug, "Debug", proj_debug_s), cfg(proj_release, "Release", proj_release_s),
                          cfg(tgt_debug, "Debug", target_s), cfg(tgt_release, "Release", target_s)]) +
               "\n/* End XCBuildConfiguration section */\n")
    out.append("\n/* Begin XCConfigurationList section */\n"
               f"\t\t{proj_cfg_list} /* Build configuration list for PBXProject \"{PROJECT}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
               f"\t\t\t\t{proj_debug} /* Debug */,\n\t\t\t\t{proj_release} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n"
               f"\t\t{tgt_cfg_list} /* Build configuration list for PBXNativeTarget \"{PROJECT}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
               f"\t\t\t\t{tgt_debug} /* Debug */,\n\t\t\t\t{tgt_release} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n"
               "/* End XCConfigurationList section */\n")
    out.append(f"\t}};\n\trootObject = {project} /* Project object */;\n}}\n")

    proj_dir = os.path.join(ROOT, f"{PROJECT}.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as fh:
        fh.write("".join(out))

    # Shared scheme so `xcodebuild -scheme DualCamRecorder` works on a fresh clone.
    scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    ref = (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" '
           f'BuildableName = "{PROJECT}.app" BlueprintName = "{PROJECT}" ReferencedContainer = "container:{PROJECT}.xcodeproj">'
           f'</BuildableReference>')
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    with open(os.path.join(scheme_dir, f"{PROJECT}.xcscheme"), "w") as fh:
        fh.write(scheme)
    print(f"Wrote {proj_dir}/project.pbxproj ({len(sources_build)} sources)")


if __name__ == "__main__":
    sys.exit(main())
