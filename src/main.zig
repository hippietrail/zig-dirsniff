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
    const opts = clr.opts;
    _ = opts;
    const args = clr.args;
    
    for (args) |arg| {
        try processFilename(arg);
    }
    
    al.free(args);
}

fn processCommandline(al: std.mem.Allocator) !CommandLineResults {
    // fn args() ArgIterator
    // fn argsAlloc(allocator: mem.Allocator) ![][:0]u8
    // fn argsWithAllocator(allocator: mem.Allocator) ArgIterator.InitError!ArgIterator

    var opts: Opts = Opts{};

    // os.argv
    //   no allocation, no iterator

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
                    std.debug.print("-{s} = follow dot\n", .{sw});
                } else if (std.mem.eql(u8, sw, "v")) {
                    opts.v = true;
                    std.debug.print("-{s} = verbose\n", .{sw});
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
                    std.debug.print("-m = max recursion depth: {}\n", .{md});
                } else {
                    std.debug.print("* unknown switch: {s} = {s}\n", .{key, val});
                }
            }
        } else {
            //std.debug.print("arg: {s}\n", .{arg});
            // convert the argument from c-style zero-terminated strings to native zig slices
            try arglist.append(arg[0..len]);
        }
    }

    return CommandLineResults{.opts = opts, .args = arglist.toOwnedSlice()};


    // process.args()
    //   no allocation, has iterator

    // std.debug.print("std.process.args\n", .{});
    // var args = std.process.args();
    // var i: usize = 0;
    // while (args.next()) |arg| {
    //     std.debug.print("args{}: {s}\n", .{i, arg});
    //     i += 1;
    // }
    // std.debug.print("\n", .{});


    // process.argsAlloc()
    //   has allocation, no iterator

    // std.debug.print("std.process.argsAlloc\n", .{});
    // const argsA = try std.process.argsAlloc(al);
    // defer std.process.argsFree(al, argsA);

    // std.debug.print("argsA: {}\n", .{argsA.len});
    // for (argsA) |arg, j| {
    //     std.debug.print("argsA{}: {s}\n", .{j, arg});
    // }
    // std.debug.print("\n", .{});


    // process.argsWithAllocator()
    //   has allocation, has iterator

    // std.debug.print("std.os.argsWithAllocator\n", .{});
    // var argsWA = try std.process.argsWithAllocator(al);
    // defer argsWA.deinit();

    // i = 0;
    // while (argsWA.next()) |arg| {
    //     std.debug.print("argsWA{}: {s}\n", .{i, arg});
    //     i += 1;
    // }
    // std.debug.print("\n", .{});
}

fn processFilename(path:[]const u8) !void {
    var dir = std.fs.cwd().openIterableDir(path, .{}) catch |err| {
        switch (err) {
            error.NotDir => {
                std.debug.print("* not a directory: '{s}'\n", .{path});
            },
            error.FileNotFound => {
                std.debug.print("* doesn't exist: '{s}'\n", .{path});
            },
            error.AccessDenied => {
                std.debug.print("* access denied: '{s}'\n", .{path});
            },
            else => {
                std.debug.print("** BANG: {s} {any}\n", .{path, err});
                @panic("unexpected error trying to open a directory");
            }
        }
        return;
    };

    std.debug.print("'{s}' -> dir result: {any}\n", .{path, dir});

    var diri = dir.iterate();
    while (try diri.next()) |necks| {
        std.debug.print("  iterated: {s} ({any})\n", .{necks.name, necks.kind});
    }
    //dir.walk(allocator: Allocator)

    dir.close();
}