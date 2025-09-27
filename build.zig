const std = @import("std");
const Build = std.Build;
const StringList = std.ArrayList([]const u8);
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const version = std.SemanticVersion{
    .major = 5,
    .minor = 4,
    .patch = 8,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const build_shared = b.option(bool, "shared", "build as shared library") orelse target.result.isMinGW();
    const use_readline =
        if (target.result.os.tag == .linux)
            b.option(bool, "use_readline", "readline support for linux") orelse false
        else
            null;

    const lua_src = b.dependency("lua", .{});

    const lib_name = if (build_shared)
        b.fmt("lua{d}{d}", .{ version.major, version.minor })
    else
        "lua";
    const lib = b.addLibrary(.{
        .name = lib_name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .link_libc = true,
            .optimize = optimize,
            .target = target,
            .strip = if (build_shared and target.result.os.tag == .windows) true else null,
        }),
    });
    lib.addCSourceFiles(.{
        .root = lua_src.path("src"),
        .files = &base_src,
        .flags = &cflags,
    });
    lib.installHeadersDirectory(
        lua_src.path("src"),
        "",
        .{ .include_extensions = &lua_inc },
    );
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "lua_exe",
        .root_module = b.createModule(.{
            .link_libc = true,
            .optimize = optimize,
            .target = target,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = lua_src.path("src/lua.c"),
        .flags = &cflags,
    });
    exe.root_module.linkLibrary(lib);
    b.installArtifact(exe);

    const exec = b.addExecutable(.{
        .name = "luac",
        .root_module = b.createModule(.{
            .link_libc = true,
            .optimize = optimize,
            .target = target,
        }),
    });
    exec.root_module.addCSourceFile(.{
        .file = lua_src.path("src/luac.c"),
        .flags = &cflags,
    });
    exec.root_module.linkLibrary(lib);
    b.installArtifact(exec);

    const build_targets = [_]*Build.Step.Compile{
        lib,
        exe,
        exec,
    };
    // Common compile flags
    for (&build_targets) |obj| {
        obj.addIncludePath(lua_src.path("src"));

        const link = obj != lib or !build_shared;
        if (link) {
            obj.linkSystemLibrary("m");
        }

        switch (target.result.os.tag) {
            .aix => {
                obj.root_module.addCMacro("LUA_USE_POSIX", "");
                obj.root_module.addCMacro("LUA_USE_DLOPEN", "");
                if (link) {
                    obj.linkSystemLibrary("dl");
                }
            },
            .freebsd, .netbsd, .openbsd => {
                obj.root_module.addCMacro("LUA_USE_LINUX", "");
                obj.root_module.addCMacro("LUA_USE_READLINE", "");
                obj.addIncludePath(.{ .cwd_relative = "/usr/include/edit" });
                if (link) {
                    obj.linkSystemLibrary("edit");
                }
            },
            .ios => {
                obj.root_module.addCMacro("LUA_USE_IOS", "");
            },
            .linux => {
                obj.root_module.addCMacro("LUA_USE_LINUX", "");
                obj.linkSystemLibrary("dl");
                if (use_readline.?) {
                    obj.root_module.addCMacro("LUA_USE_READLINE", "");
                    if (link) {
                        obj.linkSystemLibrary("readline");
                    }
                }
            },
            .macos => {
                obj.root_module.addCMacro("LUA_USE_MACOSX", "");
                obj.root_module.addCMacro("LUA_USE_READLINE", "");
                if (link) {
                    obj.linkSystemLibrary("readline");
                }
            },
            .solaris => {
                obj.root_module.addCMacro("LUA_USE_POSIX", "");
                obj.root_module.addCMacro("LUA_USE_DLOPEN", "");
                obj.root_module.addCMacro("_REENTRANT", "");
                if (link) {
                    obj.linkSystemLibrary("dl");
                }
            },
            else => {},
        }
    }

    if (target.result.isMinGW()) {
        lib.root_module.addCMacro("LUA_BUILD_AS_DLL", "");
        exe.root_module.addCMacro("LUA_BUILD_AS_DLL", "");
    }

    b.installDirectory(.{
        .source_dir = lua_src.path("doc"),
        .include_extensions = &.{".1"},
        .install_dir = .{ .custom = "man" },
        .install_subdir = "man1",
    });

    const run_step = b.step("run", "run lua interpreter");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    const unpack_step = b.step("unpack", "unpack source");
    const unpack_cmd = b.addInstallDirectory(.{
        .source_dir = lua_src.path(""),
        .install_dir = .prefix,
        .install_subdir = "",
    });
    unpack_step.dependOn(&unpack_cmd.step);
}

const cflags = [_][]const u8{
    "-std=gnu99",
    "-Wall",
    "-Wextra",
};

const core_src = [_][]const u8{
    "lapi.c",
    "lcode.c",
    "lctype.c",
    "ldebug.c",
    "ldo.c",
    "ldump.c",
    "lfunc.c",
    "lgc.c",
    "llex.c",
    "lmem.c",
    "lobject.c",
    "lopcodes.c",
    "lparser.c",
    "lstate.c",
    "lstring.c",
    "ltable.c",
    "ltm.c",
    "lundump.c",
    "lvm.c",
    "lzio.c",
};
const lib_src = [_][]const u8{
    "lauxlib.c",
    "lbaselib.c",
    "lcorolib.c",
    "ldblib.c",
    "liolib.c",
    "lmathlib.c",
    "loadlib.c",
    "loslib.c",
    "lstrlib.c",
    "ltablib.c",
    "lutf8lib.c",
    "linit.c",
};
const base_src = core_src ++ lib_src;

const lua_inc = [_][]const u8{
    "lua.h",
    "luaconf.h",
    "lualib.h",
    "lauxlib.h",
    "lua.hpp",
};
