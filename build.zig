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

pub const Options = struct {
    optimize: OptimizeMode,
    target: ResolvedTarget,
    shared: bool,
    reentrant: bool,
    compat_5_3: bool,
    compat_mathlib: bool,
    compat_apiintcasts: bool,
    compat_lt_le: bool,
    path_default: ?[]const []const u8,
    cpath_default: ?[]const []const u8,
    dirsep: ?[]const u8,
    use_apicheck: bool,
    use_c89: bool,
    use_dlopen: bool,
    use_ios: bool,
    use_linux: bool,
    use_macosx: bool,
    use_posix: bool,
    use_readline: bool,
    luaconf_h: ?Build.LazyPath,
};

pub fn buildOptions(b: *Build, opts: struct {
    optimize: OptimizeMode,
    target: ResolvedTarget,
}) Options {
    const optimize = opts.optimize;
    const target = opts.target.result;
    return .{
        .optimize = optimize,
        .target = opts.target,

        .shared = b.option(bool, "shared", "build as shared library") orelse target.isMinGW(),
        .reentrant = b.option(bool, "reentrant", "enable reentrant lua") orelse (target.os.tag == .solaris),

        .compat_5_3 = b.option(bool, "compat_5_3", "enable deprecated lua 5.3 apis") orelse false,
        .compat_mathlib = b.option(bool, "compat_mathlib", "enable deprecated math apis") orelse false,
        .compat_apiintcasts = b.option(bool, "compat_apiintcasts", "enable deprecated int manipulation macros") orelse false,
        .compat_lt_le = b.option(bool, "compat_lt_le", "enable emulation of the __le metamethod using __lt") orelse false,

        .path_default = b.option([]const []const u8, "path_default", "default PATH in Lua runtime"),
        .cpath_default = b.option([]const []const u8, "cpath_default", "default CPATH in Lua runtime"),
        .dirsep = b.option([]const u8, "dirsep", "directory separator for submodules"),

        .use_apicheck = b.option(bool, "use_apicheck", "enable consistency checks in the C API") orelse
            switch (optimize) {
                .Debug, .ReleaseSafe => true,
                .ReleaseFast, .ReleaseSmall => false,
            },
        .use_c89 = b.option(bool, "use_c89", "limit lua to c89 apis") orelse false,
        .use_dlopen = b.option(bool, "use_dlopen", "enable dlopen support") orelse
            switch (target.os.tag) {
                .aix, .solaris => true,
                else => false,
            },
        .use_ios = b.option(bool, "use_ios", "enable ios apis") orelse (target.os.tag == .ios),
        .use_linux = b.option(bool, "use_linux", "enable linux apis") orelse
            switch (target.os.tag) {
                .linux, .freebsd, .netbsd, .openbsd => true,
                else => false,
            },
        .use_macosx = b.option(bool, "use_macosx", "enable macos apis") orelse (target.os.tag == .macos),
        .use_posix = b.option(bool, "use_posix", "enable posix apis") orelse
            switch (target.os.tag) {
                .aix, .solaris => true,
                else => false,
            },
        .use_readline = b.option(bool, "use_readline", "enable readline apis") orelse
            switch (target.os.tag) {
                .freebsd, .netbsd, .openbsd, .macos => true,
                else => false,
            },

        .luaconf_h = b.option(Build.LazyPath, "luaconf", "path to luaconf.h"),
    };
}

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = buildOptions(b, .{ .optimize = optimize, .target = target });

    const lua_src = b.dependency("lua", .{});

    const headers = b.addNamedWriteFiles("headers");
    const luaconf_h = options.luaconf_h orelse lua_src.path("src/luaconf.h");
    _ = headers.addCopyFile(luaconf_h, "luaconf.h");
    _ = headers.addCopyDirectory(lua_src.path("src"), "", .{
        .include_extensions = &lua_inc,
        .exclude_extensions = &.{"luaconf.h"},
    });

    var cflags: std.ArrayList([]const u8) = .empty;
    try cflags.appendSlice(b.allocator, &base_cflags);
    try cflags.appendSlice(b.allocator, &.{
        if (options.use_c89) "-std=c89" else "-std=gnu99",
        switch (optimize) {
            .Debug, .ReleaseFast, .ReleaseSafe => "-O2",
            .ReleaseSmall => "-Os",
        },
    });

    const lib_name = if (options.shared)
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
            .strip = if (options.shared and target.result.os.tag == .windows) true else null,
        }),
    });
    lib.addCSourceFiles(.{
        .root = lua_src.path("src"),
        .files = &base_src,
        .flags = cflags.items,
    });
    lib.installHeadersDirectory(headers.getDirectory(), "", .{});
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
        .flags = cflags.items,
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
        .flags = cflags.items,
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

        const link = obj != lib or !options.shared;
        if (link) {
            obj.linkSystemLibrary("m");
        }

        const mod = obj.root_module;
        if (options.reentrant) mod.addCMacro("_REENTRANT", "");
        if (options.compat_5_3) mod.addCMacro("LUA_COMPAT_5_3", "");
        if (options.compat_mathlib) mod.addCMacro("LUA_COMPAT_MATHLIB", "");
        if (options.compat_apiintcasts) mod.addCMacro("LUA_COMPAT_APIINTCASTS", "");
        if (options.compat_lt_le) mod.addCMacro("LUA_COMPAT_LT_LE", "");
        if (options.dirsep) |lua_dirsep| mod.addCMacro("LUA_DIRSEP", lua_dirsep);
        if (options.use_apicheck) mod.addCMacro("LUA_USE_APICHECK", "");
        if (options.use_c89) mod.addCMacro("LUA_USEC89", "");
        if (options.use_ios) mod.addCMacro("LUA_USE_IOS", "");
        if (options.use_linux) mod.addCMacro("LUA_USE_LINUX", "");
        if (options.use_macosx) mod.addCMacro("LUA_USE_MACOSX", "");
        if (options.use_posix) mod.addCMacro("LUA_USE_POSIX", "");

        if (options.path_default) |default_path| {
            const path = try std.mem.join(b.allocator, ";", default_path);
            mod.addCMacro("LUA_PATH_DEFAULT", path);
        }

        if (options.cpath_default) |default_cpath| {
            const cpath = try std.mem.join(b.allocator, ";", default_cpath);
            mod.addCMacro("LUA_CPATH_DEFAULT", cpath);
        }

        if (options.use_dlopen) {
            mod.addCMacro("LUA_USE_DLOPEN", "");
            if (link) obj.linkSystemLibrary("dl");
        }

        if (options.use_readline) {
            mod.addCMacro("LUA_USE_READLINE", "");
            if (link) obj.linkSystemLibrary("readline");
        }

        switch (target.result.os.tag) {
            .freebsd, .netbsd, .openbsd => {
                obj.addIncludePath(.{ .cwd_relative = "/usr/include/edit" });
                if (link) {
                    obj.linkSystemLibrary("edit");
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

const base_cflags = [_][]const u8{
    // "-std=gnu99",
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
