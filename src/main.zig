const std = @import("std");

const Opts = struct {
    d: bool = false, // follow dot directories
    v: bool = false, // verbose
    maxdepth: ?i8 = 0, // max depth when recursing
};

const CommandLineResults = struct {
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
    const clr = try processCommandLine(al, argsA);
    defer clr.args.deinit();

    for (clr.args.items) |arg| {
        std.debug.print("new trying to process arg {s} ...\n", .{arg});
        try processFilename(al, std.fs.cwd(), arg);
    }
}

fn processCommandLine(al: std.mem.Allocator, argsIn: []const []const u8) !CommandLineResults {
    var opts: Opts = Opts{};
    var argsOut = std.ArrayList([]const u8).init(al);
    errdefer argsOut.deinit();

    for (argsIn[1..]) |arg| {
        std.debug.print("arg {s}\n", .{arg});

        if (arg[0] == '-') {
            var it = std.mem.split(u8, arg[1..arg.len], "=");
            var numParts: isize = 0;
            var key: []const u8 = "";
            var val: []const u8 = "";
            while (it.next()) |sw| {
                numParts += 1;
                if (numParts == 1) {
                    key = sw;
                } else if (numParts == 2) {
                    val = sw;
                } else {
                    std.debug.print("* broken use of '=' in commandline switch ({} pieces)\n", .{numParts});
                    // how do we make our own error type??
                    return error.BrokenCommandLine;
                }
            }

            if (numParts == 1) {
                if (arg[1] == 'd') {
                    opts.d = true;
                } else if (arg[1] == 'v') {
                    opts.v = true;
                } else {
                    std.debug.print("* unknown switch: '{s}'\n", .{arg});
                }
            } else if (numParts == 2) {
                if (std.mem.eql(u8, key, "m")) {
                    const md = std.fmt.parseInt(i8, val, 10) catch |err| blk: {
                        std.debug.print("** error: {any}\n", .{err});
                        break :blk -1;
                    };
                    opts.maxdepth = md;
                } else {
                    std.debug.print("* unknown switch/key: '{s}'\n", .{key});
                }
            } else {
                std.debug.print("* broken use of '=' in commandline switch ({} pieces)\n", .{numParts});
            }
        } else {
            try argsOut.append(arg);
        }
    }

    return CommandLineResults{
        .opts = opts,
        .args = argsOut,
    };
}

fn myLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    // hmm our text is really UTF-8 not ASCII
    // std.ascii.lessThanIgnoreCase
    //return std.ascii.lessThanIgnoreCase(lhs, rhs);

    return std.mem.order(u8, lhs[2..], rhs[2..]) == .lt;
}

// handle one path, from only one source for now:
// a) on the commandline, in which case it might erroneously be a file or a nonexistent path
//    from main()
fn processFilename(al: std.mem.Allocator, cwd: std.fs.Dir, path: []const u8) !void {
    // equivalent of ts readdirAndStat
    // get the dirent of each entry in this directory
    // but we need to add more info: file sizes and errors. only the former will be used in matching

    var dir = cwd.openDir(path, .{ .iterate = true }) catch |err| {
        const msg: ?[]const u8 = switch (err) {
            error.NotDir => "not a directory",
            error.FileNotFound => "doesn't exist",
            error.AccessDenied => "access denied",
            else => {
                std.debug.print("** BANG: {s} {any}\n", .{ path, err });
                @panic("unexpected error trying to open a directory");
            },
        };
        std.debug.print("* {s}: '{s}'\n", .{ msg.?, path });
        return;
    };
    defer dir.close();

    var dirit = dir.iterate();

    var dirent_list = std.ArrayList([]const u8).init(al);

    while (try dirit.next()) |entry| {
        // check for zero-length files and unopenable files
        var kindSymbol: ?u8 = null;
        if (entry.kind == .file) blk: {
            const f: std.fs.File = dir.openFile(entry.name, .{}) catch {
                kindSymbol = '!';
                break :blk;
            };
            defer f.close();

            if ((try f.stat()).size == 0) {
                kindSymbol = '0';
            } else {
                kindSymbol = ' ';
            }
        } else {
            kindSymbol = switch (entry.kind) {
                .directory => '/',
                .sym_link => '~',
                else => '?',
            };
        }

        const str = try std.fmt.allocPrint(al, "{c} {s}", .{ kindSymbol.?, entry.name });
        try dirent_list.append(str);
    }

    std.mem.sort([]const u8, dirent_list.items, {}, myLessThan);

    for (dirent_list.items) |dirent| {
        std.debug.print("{s}\n", .{dirent});
    }

    for (dirent_list.items) |dirent| {
        al.free(dirent);
    }
    dirent_list.deinit();
}
