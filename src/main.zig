const std = @import("std");

const Opts = struct {
    d: bool = false, // follow dot directories
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
        std.debug.print("processing arg {} '{s}' ...\n", .{ i, arg });
        try processOnePath(al, std.fs.cwd(), arg);
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

fn myLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    // not ignoring case since these are UTF-8
    return std.mem.order(u8, lhs[2..], rhs[2..]) == .lt;
}

// handle one path, from only one source for now:
// a) on the commandline, in which case it might erroneously be a file or a nonexistent path
//    from main()
fn processOnePath(al: std.mem.Allocator, cwd: std.fs.Dir, path: []const u8) !void {
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
    defer {
        for (dirent_list.items) |dirent| {
            al.free(dirent);
        }
        dirent_list.deinit();
    }

    // get a symbol for each file: !=broken, 0=empty file, /=directory, ~=symlink, ' '=file, ?=unknown
    const EntryKind = enum(u8) {
        broken = '!',
        file = ' ',
        directory = '/',
        empty = '0',
        sym_link = '~',
        unknown = '?',
    };

    const EntryInfo = struct {
        size: ?u64,
        kind: EntryKind,
    };

    while (try dirit.next()) |entry| {
        var info = EntryInfo{ .size = null, .kind = .unknown };
        info.kind = switch (entry.kind) {
            .file => blk: {
                const f: std.fs.File = dir.openFile(entry.name, .{}) catch {
                    break :blk EntryKind.broken;
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

        // const sizeAsString = if (info.size) |s| blk: {
        //     break :blk try std.fmt.allocPrint(al, "{d}", .{s});
        // } else "";
        // defer al.free(sizeAsString);
        // const str = try std.fmt.allocPrint(al, "{c} {s}\t{s}", .{
        //     @intFromEnum(info.kind),
        //     entry.name,
        //     sizeAsString,
        // });
        // var str: []const u8 = undefined;
        // if (info.size) |s| {
        //     str = try std.fmt.allocPrint(al, "{c} {s}\t{d}", .{
        //         @intFromEnum(info.kind),
        //         entry.name,
        //         s,
        //     });
        // } else {
        //     str = try std.fmt.allocPrint(al, "{c} {s}", .{
        //         @intFromEnum(info.kind),
        //         entry.name,
        //     });
        // }
        const osize = optionalU64(info.size);
        const str = try std.fmt.allocPrint(al, "{c} {s}\t{}", .{
            @intFromEnum(info.kind),
            entry.name,
            osize,
        });
        try dirent_list.append(str);
    }

    std.mem.sort([]const u8, dirent_list.items, {}, myLessThan);

    for (dirent_list.items) |dirent| {
        std.debug.print("{s}\n", .{dirent});
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
