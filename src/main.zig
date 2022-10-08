const std = @import("std");

const Opts = struct {
    d: bool = false,    // follow dot directories
    v: bool = false,    // verbose
    maxdepth: ?i8 = 0,  // max depth when recursing
};

const CommandLineResults = struct {
    opts: Opts,
    args: [][]const u8,
};

pub fn main() !void {
    const al = std.heap.c_allocator;

    const clr = try processCommandline(al);
    const opts = clr.opts; _ = opts;
    const args = clr.args;
    
    for (args) |arg| {
        try processFilename(al, std.fs.cwd(), arg);
    }
    
    al.free(args);
}

fn processCommandline(al: std.mem.Allocator) !CommandLineResults {
    // fn args() ArgIterator
    // fn argsAlloc(allocator: mem.Allocator) ![][:0]u8
    // fn argsWithAllocator(allocator: mem.Allocator) ArgIterator.InitError!ArgIterator

    var opts: Opts = Opts{};

    // os.argv = no allocation, no iterator

    var arglist = std.ArrayList([]const u8).init(al);

    const argv = std.os.argv;
    for (argv[1..]) |arg| {
        const len = std.mem.len(arg);

        if (arg[0] == '-') {
            var spl = std.mem.split(u8, arg[1..len], "=");
            
            var splnum: usize = 0; while (spl.next()) |_| { splnum += 1; }

            if (splnum == 1) {
                // zig can't switch on strings or slices

                const sw = arg[1..len];
                if (std.mem.eql(u8, sw, "d")) {
                    opts.d = true;
                    //std.debug.print("-{s} = follow dot\n", .{sw});
                } else if (std.mem.eql(u8, sw, "v")) {
                    opts.v = true;
                    //std.debug.print("-{s} = verbose\n", .{sw});
                } else {
                    std.debug.print("* unknown switch: '{s}'\n", .{sw});
                }
            } else if (splnum != 2) {
                std.debug.print("* broken use of '=' in commandline switch ({} pieces)\n", .{splnum});
            } else {
                spl.reset();
                const key = spl.next().?;
                const val = spl.next().?;
                if (std.mem.eql(u8, key, "m")) {
                    const md = try std.fmt.parseInt(i8, val, 10);
                    opts.maxdepth = md;
                    //std.debug.print("-m = max recursion depth: {}\n", .{md});
                } else {
                    std.debug.print("* unknown switch: {s} = {s}\n", .{key, val});
                }
            }
        } else {
            // convert the argument from c-style zero-terminated strings to native zig slices
            try arglist.append(arg[0..len]);
        }
    }

    return CommandLineResults{.opts = opts, .args = arglist.toOwnedSlice()};
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
fn processFilename(al: std.mem.Allocator, cwd: std.fs.Dir, path:[]const u8) !void {
    // equivalent of ts readdirAndStat
    // get the dirent of each entry in this directory
    // but we need to add more info: file sizes and errors. only the former will be used in matching

    var dir = cwd.openIterableDir(path, .{}) catch |err| {
        var msg: ?[]const u8 = switch (err) {
            error.NotDir => "not a directory",
            error.FileNotFound => "doesn't exist",
            error.AccessDenied => "access denied",
            else => {
                std.debug.print("** BANG: {s} {any}\n", .{path, err});
                @panic("unexpected error trying to open a directory");
            },
        };
        std.debug.print("* {s}: '{s}'\n", .{msg.?, path});
        return;
    };
    defer dir.close();

    var dirit = dir.iterate();

    var dirent_list = std.ArrayList([]const u8).init(al);

    while (try dirit.next()) |entry| {
        // check for zero-length files and unopenable files
        var kindSymbol: ?u8 = null;
        if (entry.kind == .File) blk: {
            const f: std.fs.File = dir.dir.openFile(entry.name, .{}) catch {
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
                .Directory => '/',
                .SymLink => '~',
                else => '?',
            };
        }

        const str = try std.fmt.allocPrint(al, "{c} {s}", .{kindSymbol.?, entry.name});
        try dirent_list.append(str);
    }

    std.sort.sort([]const u8, dirent_list.items, {}, myLessThan);

    for (dirent_list.items) |dirent| {
        std.debug.print("{s}\n", .{dirent});
    }

    for (dirent_list.items) |dirent| {
        al.free(dirent);
    }
    dirent_list.deinit();
}