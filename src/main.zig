const std = @import("std");

const Opts = struct {
    d: bool = false, // follow dot directories
    i: bool = false, // ignore files listed instead of directories (happens with globbing)
    v: bool = false, // verbose
    maxdepth: ?i8 = 0, // max depth when recursing
};

const OptsAndArgs = struct {
    opts: Opts,
    args: std.ArrayList([]const u8),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const al = gpa.allocator();
    defer _ = gpa.deinit();

    // call this outside processCommandline because the args are slices owned by what it returns
    const argsA = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, argsA);

    const oa = try parseCommandLine(al, argsA);
    defer oa.args.deinit();

    for (oa.args.items, 0..) |arg, i| {
        try processOnePath(al, oa.opts, std.fs.cwd(), i, arg);
    }
}

fn parseCommandLine(al: std.mem.Allocator, argsIn: []const []const u8) !OptsAndArgs {
    var opts: Opts = Opts{};
    var argsOut = std.ArrayList([]const u8).init(al);
    errdefer argsOut.deinit();

    for (argsIn[1..]) |arg| {
        if (arg[0] == '-') {
            var it = std.mem.split(u8, arg[1..arg.len], "=");
            var numParts: isize = 0;
            var key: []const u8 = "";
            var val: []const u8 = "";
            while (it.next()) |part| {
                numParts += 1;
                switch (numParts) {
                    1 => key = part,
                    2 => val = part,
                    else => {},
                }
            }

            if (numParts == 1) {
                switch (arg[1]) {
                    'd' => opts.d = true,
                    'i' => opts.i = true,
                    'v' => opts.v = true,
                    else => std.debug.print("* unknown switch: '{s}'\n", .{arg}),
                }
            } else if (numParts == 2) {
                if (std.mem.eql(u8, key, "m")) {
                    const md = std.fmt.parseInt(i8, val, 10) catch |err| blk: {
                        std.debug.print("** error: -m max depth argument is not an integer ({})\n", .{err});
                        break :blk -1;
                    };
                    opts.maxdepth = md;
                } else {
                    std.debug.print("* unknown switch/key: '{s}'\n", .{key});
                }
            } else {
                // note we also detected this above
                std.debug.print("* broken use of '=' in commandline switch ({} pieces)\n", .{numParts});
            }
        } else {
            try argsOut.append(arg);
        }
    }

    return OptsAndArgs{
        .opts = opts,
        .args = argsOut,
    };
}

const EntryKind = enum(u8) {
    err = '!',
    file = ' ',
    directory = '/',
    empty = '0',
    sym_link = '~',
    unknown = '?',
};

const EntryInfo = struct {
    kind: EntryKind,
    name: []const u8,
    size: ?u64,
};

fn EntryInfoLessThan(_: void, lhs: EntryInfo, rhs: EntryInfo) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

// handle one path, from only one source for now:
// a) on the commandline, in which case it might erroneously be a file or a nonexistent path
//    from main()
fn processOnePath(al: std.mem.Allocator, opts: Opts, cwd: std.fs.Dir, pathNum: usize, path: []const u8) !void {
    // equivalent of ts readdirAndStat
    // get the dirent of each entry in this directory
    // but we need to add more info: file sizes and errors. only the former will be used in matching

    var dir = cwd.openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.NotDir and opts.i) return;
        std.debug.print("processing arg {} '{s}' ...\n", .{ pathNum, path });
        const msg: ?[]const u8 = switch (err) {
            error.NotDir => "not a directory",
            error.FileNotFound => "doesn't exist",
            error.AccessDenied => "access denied",
            else => unreachable,
        };
        std.debug.print("* {s}: '{s}'\n", .{ msg.?, path });
        return;
    };
    defer dir.close();

    std.debug.print("processing arg {} '{s}' ...\n", .{ pathNum, path });

    var dirit = dir.iterate();

    var entry_info_list = std.ArrayList(EntryInfo).init(al);
    defer {
        for (entry_info_list.items) |entry| {
            al.free(entry.name);
        }
        entry_info_list.deinit();
    }

    // get a kind, a name, and a size for each entry
    while (try dirit.next()) |entry| {
        var info = EntryInfo{ .kind = .unknown, .name = try al.dupe(u8, entry.name), .size = null };
        info.kind = switch (entry.kind) {
            .file => blk: {
                const f: std.fs.File = dir.openFile(entry.name, .{}) catch {
                    break :blk EntryKind.err;
                };
                defer f.close();

                // if stat would fail openFile above would've errored already
                // break :blk switch ({info.size = (f.stat() catch unreachable).size}) {
                info.size = (f.stat() catch unreachable).size;
                break :blk switch (info.size.?) {
                    0 => EntryKind.empty,
                    else => EntryKind.file,
                };
            },
            .directory => EntryKind.directory,
            .sym_link => EntryKind.sym_link,
            else => EntryKind.unknown,
        };

        try entry_info_list.append(info);
    }

    // check for files that can appear in any kind of programming language project directory
    var looks_like_coding_project = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, ".gitignore")) {
                looks_like_coding_project = true;
            }
        } else if (info.kind == .directory) {
            if (std.mem.eql(u8, info.name, ".git") or std.mem.eql(u8, info.name, ".vscode")) {
                looks_like_coding_project = true;
            }
        }
    }

    // check for android studio or intellij idea:
    // dirs: .gradle, .idea, gradle
    // files: build.gradle.kts, gradle.properties, gradlew, gradlew.bat, settings.gradle.kts
    var looks_like_android_studio_or_intellij_idea = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .directory) {
            if (std.mem.eql(u8, info.name, ".gradle") or std.mem.eql(u8, info.name, ".idea") or
                std.mem.eql(u8, info.name, "gradle"))
            {
                looks_like_android_studio_or_intellij_idea = true;
            }
        } else if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "build.gradle.kts") or
                std.mem.eql(u8, info.name, "gradle.properties") or
                std.mem.eql(u8, info.name, "gradlew") or
                std.mem.eql(u8, info.name, "gradlew.bat") or
                std.mem.eql(u8, info.name, "settings.gradle.kts"))
            {
                looks_like_android_studio_or_intellij_idea = true;
            }
        }
    }

    // check for c and/or c++: a file called 'makefile' or 'Makefile'
    var looks_like_c_or_cpp = false;
    var looks_like_c = false;
    var looks_like_cpp = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "makefile") or std.mem.eql(u8, info.name, "Makefile")) {
                looks_like_c_or_cpp = true;
            } else if (std.mem.endsWith(u8, info.name, ".c") or std.mem.endsWith(u8, info.name, ".h")) {
                looks_like_c_or_cpp = true;
                looks_like_c = true;
            } else if (std.mem.endsWith(u8, info.name, ".cpp")) {
                looks_like_c_or_cpp = true;
                looks_like_cpp = true;
            }
        }
    }

    // check for dart: a directory called 'dart_tool'
    var looks_like_dart = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .directory) {
            if (std.mem.eql(u8, info.name, ".dart_tool")) {
                looks_like_dart = true;
            }
        } else if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "pubspec.yaml") or std.mem.eql(u8, info.name, "pubspec.lock") or std.mem.eql(u8, info.name, "analysis_options.yaml")) {
                looks_like_dart = true;
            }
        }
    }

    // check for go: a file called 'go.mod'
    // or any file with an '.go' extension
    var looks_like_go = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "go.mod")) {
                looks_like_go = true;
            } else if (std.mem.endsWith(u8, info.name, ".go")) {
                looks_like_go = true;
            }
        }
    }

    // check for typescript: a file called 'tsconfig.json'
    var looks_like_javascript_or_typescript = false;
    // var looks_like_javascript = false;
    var looks_like_typescript = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "tsconfig.json")) {
                looks_like_typescript = true;
            } else if (std.mem.eql(u8, info.name, "package.json") or std.mem.eql(u8, info.name, "package-lock.json")) {
                looks_like_javascript_or_typescript = true;
            } else if (std.mem.endsWith(u8, info.name, ".ts") or std.mem.endsWith(u8, info.name, ".js.map")) {
                looks_like_typescript = true;
            } else if (std.mem.endsWith(u8, info.name, ".js")) {
                looks_like_javascript_or_typescript = true;
            }
        } else if (info.kind == .directory) {
            if (std.mem.eql(u8, info.name, "node_modules")) {
                looks_like_javascript_or_typescript = true;
            }
        }
    }

    // check for lua: any file with an '.lua' extension
    var looks_like_lua = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.endsWith(u8, info.name, ".lua")) {
                looks_like_lua = true;
            }
        }
    }

    // check for odin: a file called 'ols.json'
    // or any file with an '.odin' extension
    var looks_like_odin = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "ols.json")) {
                looks_like_odin = true;
            } else if (std.mem.endsWith(u8, info.name, ".odin")) {
                looks_like_odin = true;
            }
        }
    }

    // check for python: any file with an '.py' extension
    var looks_like_python = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.endsWith(u8, info.name, ".py")) {
                looks_like_python = true;
            }
        }
    }

    // check for rust: a file called 'Cargo.toml' or a file called 'Cargo.lock'
    var looks_like_rust = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "Cargo.toml") or std.mem.eql(u8, info.name, "Cargo.lock")) {
                looks_like_rust = true;
            }
        }
        // also 'src' and 'target' directories, but those are not rust-specific
    }

    // typescript is handled together with javascript above

    // check for visual studio: a directory called '.vs'
    // or any file with an '.sln' extension
    var looks_like_visual_studio = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .directory) {
            if (std.mem.eql(u8, info.name, ".vs")) {
                looks_like_visual_studio = true;
            }
        } else if (info.kind == .file) {
            if (std.mem.endsWith(u8, info.name, ".sln")) {
                looks_like_visual_studio = true;
            }
        }
    }

    // check for xcode: a directory with a '.xcodeproj' extension
    var looks_like_xcode = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .directory) {
            if (std.mem.endsWith(u8, info.name, ".xcodeproj")) {
                looks_like_xcode = true;
            }
        }
    }

    // check for zig: a file kind called 'build.zig' or a dir kind called 'zig-cache' or a dir kind called 'zig-out'
    // or any file with a '.zon' extension
    var looks_like_zig = false;
    for (entry_info_list.items) |info| {
        if (info.kind == .file) {
            if (std.mem.eql(u8, info.name, "build.zig")) {
                looks_like_zig = true;
            } else if (std.mem.endsWith(u8, info.name, ".zon")) {
                looks_like_zig = true;
            }
        } else if (info.kind == .directory) {
            if (std.mem.eql(u8, info.name, "zig-cache") or std.mem.eql(u8, info.name, "zig-out")) {
                looks_like_zig = true;
            }
            // also 'src', but that's not zig-specific
        }
    }

    var guessed = false;

    if (looks_like_android_studio_or_intellij_idea) {
        std.debug.print("  LOOKS LIKE AN ANDROID STUDIO OR INTELLIJ IDEA PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_c_or_cpp) {
        if (looks_like_c) {
            std.debug.print("  LOOKS LIKE A C PROJECT DIRECTORY\n", .{});
            guessed = true;
        } else if (looks_like_cpp) {
            std.debug.print("  LOOKS LIKE A C++ PROJECT DIRECTORY\n", .{});
            guessed = true;
        } else {
            std.debug.print("  LOOKS LIKE A C/C++ PROJECT DIRECTORY\n", .{});
            guessed = true;
        }
    } else if (looks_like_dart) {
        std.debug.print("  LOOKS LIKE A DART PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_go) {
        std.debug.print("  LOOKS LIKE A GO PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_javascript_or_typescript) {
        if (looks_like_typescript) {
            std.debug.print("  LOOKS LIKE A TYPESCRIPT PROJECT DIRECTORY\n", .{});
            guessed = true;
        } else {
            std.debug.print("  LOOKS LIKE A JAVASCRIPT PROJECT DIRECTORY\n", .{});
            guessed = true;
        }
    } else if (looks_like_lua) {
        std.debug.print("  LOOKS LIKE A LUA PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_odin) {
        std.debug.print("  LOOKS LIKE AN ODIN PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_python) {
        std.debug.print("  LOOKS LIKE A PYTHON PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_rust) {
        std.debug.print("  LOOKS LIKE A RUST PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_visual_studio) {
        std.debug.print("  LOOKS LIKE A VISUAL STUDIO PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_xcode) {
        std.debug.print("  LOOKS LIKE AN XCODE PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_zig) {
        std.debug.print("  LOOKS LIKE A ZIG PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else if (looks_like_coding_project) {
        std.debug.print("  LOOKS LIKE A CODING PROJECT DIRECTORY\n", .{});
        guessed = true;
    } else {
        std.debug.print("  COULDN'T DETERMINE DIRECTORY TYPE\n", .{});
    }

    if (!guessed or opts.v) {
        std.mem.sort(EntryInfo, entry_info_list.items, {}, EntryInfoLessThan);
        for (entry_info_list.items) |info| {
            std.debug.print("{c} {s}\t{}\n", .{
                @intFromEnum(info.kind),
                info.name,
                optionalU64(info.size),
            });
        }
    }
}

// These formatting functions are not strictly necessary but they were a pain to learn and they make a more minimal example than
// I could find online, and they also result in nice small readable code
fn formatOptionalU64(val: ?u64, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    if (val) |v| try writer.print("{d}", .{v});
}

fn optionalU64(val: ?u64) std.fmt.Formatter(formatOptionalU64) {
    return .{ .data = val };
}
