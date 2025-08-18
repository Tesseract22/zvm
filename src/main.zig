const public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
const official_download = "https://ziglang.org/download";
const official_builds = "https://ziglang.org/builds";

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const json = std.json;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const print = std.debug.print;

const Cli = @import("cli.zig");

const Latency = struct {i64, []const u8};

const Index = json.ArrayHashMap(Release);


const Release = struct {
    version: []const u8 = "", // only available when its is a master
    date: []const u8 = "",
    docs: []const u8 = "",
    stdDocs: []const u8 = "",
    src: ?Download = null,
    bootstrap: ?Download = null,
    notes: []const u8 = "", // only available when its is not master

    platforms: std.StringArrayHashMapUnmanaged(Download) = .empty,
    
    const Token = json.Token;
    pub fn jsonParse(a: Allocator, source: anytype, options: json.ParseOptions) !Release {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        var r = Release {};
        const info = @typeInfo(Release).@"struct";
        while (true) {
            var name_token: ?Token = try source.nextAllocMax(a, .alloc_always, options.max_value_len.?);
            const field_name = switch (name_token.?) {
                inline .string, .allocated_string => |slice| slice,
                .object_end => { // No more fields.
                    break;
                },
                else => {
                    return error.UnexpectedToken;
                },
            };

            inline for (info.fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "platforms")) continue;
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Free the name token now in case we're using an allocator that optimizes freeing the last allocated object.
                    // (Recursing into innerParse() might trigger more allocations.)
                    a.free(field_name);
                    name_token = null;
                    @field(r, field.name) = try json.innerParse(field.type, a, source, options);
                    break;
                }
            } else {
                const download = try json.innerParse(Download, a, source, options);  
                try r.platforms.put(a, field_name, download);

            }
        }
        return r;
    }

    pub fn deinit(self: *Release, a: Allocator) void {
       a.free(self.version); 
       a.free(self.date); 
       a.free(self.docs); 
       a.free(self.stdDocs); 
       if (self.src) |src| src.deinit(a);
       if (self.bootstrap) |bootstrap| bootstrap.deinit(a);
       a.free(self.notes); 
       var it = self.platforms.iterator();
       while (it.next()) |kv| {
           a.free(kv.key_ptr.*);
           kv.value_ptr.deinit(a);
       }
       self.platforms.deinit(a);
    }
};

const Src = json.ArrayHashMap(Download);

const Download = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: []const u8,

    pub fn deinit(self: Download, a: Allocator) void {
        a.free(self.tarball);
        a.free(self.shasum);
        a.free(self.size);
    }
};
fn latency_less_than(_: void, lhs: Latency, rhs: Latency) bool {
    return lhs[0] < rhs[0];
}

const Error = error {
    UnknownRelease,
    UnknownPlatform,
    DownloadError,
    DecompressionError,
    SignatureError,
    NetworkError,
};

const Options = struct {
    install: struct {
        release: []const u8,
        mirror: []const u8,
        fetch: bool,
    },

    release: struct {
        fetch: bool, 
        name: []const u8
    },

    list: struct {
        valididate: bool,
    },
    
    mirror: struct {
        fetch: bool,
    },
};

// fn parse_index(scanner: *json.Scanner) !Index {
// 
// }

fn free_index(index: *Index, a: Allocator) void {
    var index_it = index.map.iterator();
    while (index_it.next()) |entry| {
        a.free(entry.key_ptr.*);
        entry.value_ptr.deinit(a);
    }
    index.deinit(a);

}

fn cal_fastest_mirror(client: *std.http.Client, mirror_list: []const u8, a: Allocator) !struct {i64, []const u8} {
    var mirror_it = std.mem.tokenizeScalar(u8, mirror_list, '\n');
    var latencies = std.ArrayListUnmanaged(Latency) {};
    defer latencies.deinit(a);
    while (mirror_it.next()) |mirror| {
        const start_t = std.time.milliTimestamp();
        _ = client.fetch(.{
            .location = .{.url = mirror},
            .keep_alive = false,
        }) catch |e| {
            std.log.err("{} cannot connect to mirror {s}. skipping.", .{e, mirror});
            continue;
        };
        const end_t = std.time.milliTimestamp();
        const latency = end_t-start_t;
        try latencies.append(a, .{latency, mirror});
        std.log.debug("mirror: {s} {}ms", .{mirror, latency});
    }
    const start_t = std.time.milliTimestamp();
    if (client.fetch(.{
        .location = .{.url = official_builds},
        .keep_alive = false,
    })) |_| {
        const end_t = std.time.milliTimestamp();
        const latency = end_t-start_t;
        try latencies.append(a, .{latency, official_builds});
        std.log.debug("mirror: {s} {}ms", .{official_builds, latency});
    } else |e| {
        std.log.err("{} cannot connect to mirror {s}. skipping.", .{e, official_builds});
    }
    assert(latencies.items.len > 0);
    std.mem.sort(Latency, latencies.items, void{}, latency_less_than);
    const fastest = latencies.items[0];
    return fastest;
}

fn download_tarball(url: []const u8, output_path: []const u8, a: Allocator) !void {
    var wget = std.process.Child.init(&.{"wget", url, "-O", output_path}, a);    

    const wget_term = try wget.spawnAndWait();

    errdefer std.fs.deleteFileAbsolute(output_path) catch {};
    switch (wget_term) {
        .Exited => |exit_code| {
            std.log.info("wget exited with {}", .{exit_code});
            if (exit_code != 0) return Error.DownloadError;
        },
        else => |other| {
            std.log.err("wget terminated unxpectedly {}", .{other});
            return Error.DownloadError;
        }
    }
}

fn verify_tarball(tarball_path: []const u8, tarball_name: []const u8, client: *std.http.Client, a: Allocator) !void {
    const sig_url = try allocPrint(a, "{s}/{s}.minisig", .{official_builds, tarball_name});
    defer a.free(sig_url);
    var buf: [1024]u8 = undefined;
    var storage = std.ArrayListUnmanaged(u8) {.items = &buf, .capacity = buf.len};
    storage.shrinkRetainingCapacity(0);
    const resp = try client.fetch(.{
        .location = .{.url = sig_url},
        .method = .GET,
        .response_storage = .{ .static = &storage },
    });
    if (resp.status != .ok) return Error.SignatureError;
    const sig_path = try allocPrint(a, "/tmp/{s}.minisig", .{tarball_name});
    defer a.free(sig_path);
    {
        var sig_f = try std.fs.createFileAbsolute(sig_path, .{.truncate = true});
        defer sig_f.close();
        try sig_f.writeAll(storage.items);
    }

    var minisign = std.process.Child.init(&.{"minisign", "-Vm", tarball_path, "-P", public_key, "-x", sig_path}, a);
    minisign.stdin_behavior = .Pipe;
    try minisign.spawn();
    try minisign.stdin.?.writeAll(storage.items);
    switch (try minisign.wait()) {
        .Exited => |exit_code| {
            std.log.info("minisign exited with {}", .{exit_code});
            if (exit_code != 0) return Error.SignatureError;
        },
        else => |other| {
            std.log.err("minisign terminated unxpectedly {}", .{other});
            return Error.SignatureError;
        }
    }
}
// https://ziglang.org/builds/zig-0.15.0-dev.1519+dd4e25cf4.tar.xz.minisig
fn decompress_tarball(tarball_path: []const u8, output_dir: []const u8, a: Allocator) !void {
    var tar = std.process.Child.init(&.{"tar", "xf", tarball_path, "-C", output_dir}, a);
    const tar_term = try tar.spawnAndWait();
    switch (tar_term) {
        .Exited => |exit_code| {
            std.log.info("tar exited with {}", .{exit_code});
            if (exit_code != 0) return Error.DecompressionError;
        },
        else => |other| {
            std.log.err("tar terminated unxpectedly {}", .{other});
            return Error.DecompressionError;
        }
    }
}

fn fetch_mirror_list(client: *std.http.Client, a: Allocator) ![]u8 {
    var mirror_list_storage = std.ArrayListUnmanaged(u8) {};
    defer mirror_list_storage.deinit(a);
    try mirror_list_storage.ensureTotalCapacity(a, 256);
    const resp = try client.fetch(.{
        .location = .{.url = official_download ++ "/community-mirrors.txt"},
        .response_storage = .{ .static = &mirror_list_storage, },
    });
    if (resp.status != .ok) return Error.NetworkError;
    return mirror_list_storage.toOwnedSlice(a);
}


fn read_list(str: []const u8, a: Allocator) !std.StringArrayHashMapUnmanaged(void) {
    var map = std.StringArrayHashMapUnmanaged(void) {};
    var it = std.mem.tokenizeScalar(u8, str, '\n');
    while (it.next()) |line| {
        try map.putNoClobber(a, line, void{});
    }
    return map;
}


fn ask_for_yes(stdin: *std.fs.File, comptime fmt: []const u8, args: anytype) bool {
    print(fmt ++ "\n", args);
    print("y[es], n[o]?\n", .{});
    var buf: [32]u8 = undefined;
    var reader = stdin.reader(&buf);
    var buf2: [32]u8 = undefined;
    const yes_or_no = reader.interface.takeSentinel('\n') catch |e| {
        if (e == error.StreamTooLong) return ask_for_yes(stdin, fmt, args);
        std.log.err("{}: you mean no? fine.", .{e});
        return false;
    };
    const lower = std.ascii.lowerString(&buf2, yes_or_no);
    if (std.mem.eql(u8, lower, "y") or std.mem.eql(u8, lower, "yes")) return true;
    if (std.mem.eql(u8, lower, "n") or std.mem.eql(u8, lower, "no")) return false;
    return ask_for_yes(stdin, fmt, args);

}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var stdin = std.fs.File.stdin();

    //
    // cli
    //
    var opts: Options = undefined;
    var args = try std.process.argsWithAllocator(a);
    var arg_parser = Cli.ArgParser {};
    arg_parser.init(a, args.next().?, "zig package manager");
    defer arg_parser.deinit();

    const release_cmd = 
        arg_parser.sub_command("release", "(fetch and) list the currently avaiable releases")
        .add_opt(bool, &opts.release.fetch, &false, .{.prefix = "--fetch"}, "", "update the index of releases")
        .add_opt([]const u8, &opts.release.name, &"", .positional, "<release-name>", "print details for this specific release");

    const install_cmd = 
        arg_parser.sub_command("install", "install a release")
        .add_opt([]const u8, &opts.install.release, null, .positional, "<release>", "the releaset to download, see `zvm list`")
        .add_opt([]const u8, &opts.install.mirror, &"", .{.prefix = "--mirror"}, "<mirror>", "the mirror to use")
        .add_opt(bool, &opts.install.fetch, &false, .{.prefix = "--fetch"}, "", "fetch the latest index and mirrors before install");

    const uninstall_cmd = 
        arg_parser.sub_command("uninstall", "uninstall a release")
        .add_opt([]const u8, &opts.install.release, null, .positional, "<release>", "the releaset to uninstall, see `zvm list`");

    const mirror_cmd = 
        arg_parser.sub_command("mirror", "fetch and list all the known mirrors")
        .add_opt(bool, &opts.mirror.fetch, &false, .{.prefix = "--fetch"}, "", "update the list of mirror");

    const list_cmd = arg_parser.sub_command("list", "list all current installation");
    // list_cmd.add_opt(bool, &opts.list.valididate, &false, .{.prefix = "--valid"}, "validate and fix the current installation", a);

    const use_cmd = 
        arg_parser.sub_command("use", "use an installation")
        .add_opt([]const u8, &opts.install.release, null, .positional, "<release>", "the release to use");

    try arg_parser.parse(&args);
    opts.mirror.fetch = opts.mirror.fetch or opts.install.fetch;
    opts.release.fetch = opts.release.fetch or opts.install.fetch;

    if (arg_parser.root_command.occur) {
        arg_parser.print_help();
        return;
    }
    const is_master = std.mem.eql(u8, opts.install.release, "master");
    // 
    // create zvm config path if not eixst
    //
    
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    const home = env.get("HOME").?;
    const zvm_path = try std.fs.path.resolvePosix(a, &.{home, ".zvm"});
    defer a.free(zvm_path);
        var zvm_dir = std.fs.openDirAbsolute(zvm_path, .{.iterate = true}) catch |e| 
        if (e == error.FileNotFound) blk: {
            if (!ask_for_yes(&stdin, "creating {s}. You can delete it anytime", .{zvm_path})) return;
            try std.fs.makeDirAbsolute(zvm_path);
            break :blk try std.fs.openDirAbsolute(zvm_path, .{.iterate = true});
        } else return e
    ;
    defer zvm_dir.close();

    
    var client = std.http.Client {.allocator = a};
    defer client.deinit();

    //
    // fetch or read index from cached
    //
    var index_f = try zvm_dir.createFile("index.json", .{.truncate = false, .read = true});
    defer index_f.close();

    const index_str = if (opts.release.fetch or (try zvm_dir.statFile("index.json")).size == 0) blk: {
        std.log.debug("fetch index...", .{});
        var index_storage = std.ArrayList(u8).init(a);
        defer index_storage.deinit();
        const resp = try client.fetch(.{
            .location = .{.url = official_download ++ "/index.json"},
            .response_storage = .{.dynamic = &index_storage},
        });
        if (resp.status != .ok) {
            std.log.err("failed to fetch index from {s}", .{official_download ++ "/index.json"});
            return Error.NetworkError;
        }
        try index_f.seekTo(0);
        try index_f.setEndPos(0);
        try index_f.writeAll(index_storage.items);
        break :blk try index_storage.toOwnedSlice();
    } else blk: {
        std.log.debug("reading index from cached...", .{});
        break :blk try index_f.readToEndAlloc(a, 1024*1024);
    };
    defer a.free(index_str);
    var json_obj = json.Scanner.initCompleteInput(a, index_str); 
    defer json_obj.deinit();
    var index = Index.jsonParse(a, &json_obj, .{.ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = 1024}) catch |e| {
        std.log.err("unxpected error occur while parsing index: {}", .{e});
        return e;
    };

    defer free_index(&index, a);

    
    
    // The file containing the commit of the current installation of the `master` release, if any.
    // When its empty, it means no master is instsalled, or something went terribly wrong.
    var master_f = try zvm_dir.createFile("master.txt", .{.truncate = false, .read = true});
    defer master_f.close();
    const master_locked = try master_f.readToEndAlloc(a, 1024);
    defer a.free(master_locked);

   
    //
    // read the list of installation
    //
    var list_f = try zvm_dir.createFile("list.txt", .{.truncate = false, .read = true});
    defer list_f.close();
    const list_str = try list_f.readToEndAlloc(a, 1024);
    defer a.free(list_str);
    var list_map = try read_list(list_str, a);
    defer list_map.deinit(a);


    //
    // read the current installation in use 
    var use_f = try zvm_dir.createFile("use.txt", .{.truncate = false, .read = true});
    defer use_f.close();
    const use_str = try use_f.readToEndAlloc(a, 1024);
    defer a.free(use_str);
    

    //
    // detect the current platform
    //
    const double_str = try allocPrint(a, "{s}-{s}", .{@tagName(builtin.cpu.arch), @tagName(builtin.target.os.tag)});
    defer a.free(double_str);
    std.log.info("Detected system: {s}", .{double_str});
    // for `install`, this is the release to 
    

    // 
    // get mirror and calculate the fastest
    //
    var mirror_f = try zvm_dir.createFile("mirror.txt", .{.truncate = false, .read = true});
    const mirror_list = if ((try mirror_f.stat()).size == 0 or opts.mirror.fetch) blk: {
        const mirror_list = fetch_mirror_list(&client, a) catch |e| {
            std.log.err("{}: failed to fetch mirror", .{e});
            return e;
        };
        try mirror_f.writeAll(mirror_list);
        break :blk mirror_list;
    } else try mirror_f.readToEndAlloc(a, 1024); 
    defer a.free(mirror_list);


    // handle different command
    if (mirror_cmd.occur) {
        var mirror_it = std.mem.tokenizeScalar(u8, mirror_list, '\n');
        while (mirror_it.next()) |mirror| {
            print("{s}\n", .{mirror});
        }
        return;
    } else if (list_cmd.occur) {
        // if (opts.list.valididate) {
        //     var installed_it = zvm.iterate();
        //     while (try installed_it.next()) |entry| {
        //         if (entry.kind != .directory) continue;
        //         
        //     }
        // }
        var it = list_map.iterator();
        print("installed zig:\n", .{});
        while (it.next()) |entry| {
            print("{s}\n", .{entry.key_ptr.*});
        }
        return;
    } else if (release_cmd.occur) {
        if (opts.release.name.len == 0) {
            var index_it = index.map.iterator();
            while (index_it.next()) |entry| {
                print("{s} {s}\n", .{entry.key_ptr.*, entry.value_ptr.version});
            }
        } else {
            const release = index.map.get(opts.release.name) orelse {
                std.log.err("Unknown release {s}, try with `--fetch`", .{opts.release.name});
                return Error.UnknownRelease;
            };
            if (std.mem.eql(u8, opts.release.name, "master")) {
                print("{s}\n", .{release.version});
            } else {
                print("{s}\n", .{release.notes});
            }
            print("date: {s}\n\n", .{release.date});
            var platform_it = release.platforms.iterator();
            while (platform_it.next()) |platform| {
                const download = platform.value_ptr;
                print("{s}: {s}\n", .{platform.key_ptr.*, download.tarball});
            }
        }

        return;
    } else if (use_cmd.occur) {
        // this is the name of the release the to used. 
        // A symlink would be created targeting the folder named `installed_name`.
        // For `master`, we need to retreive its commit
        const installed_name = try allocPrint(a, "zig-{s}-{s}", 
            .{double_str, if (is_master) master_locked else opts.install.release});
        defer a.free(installed_name);
        list_map.get(installed_name) orelse {
            std.log.err("{s} is not installed", .{installed_name});
            return Error.UnknownRelease;
        };
        if (std.mem.eql(u8, use_str, opts.install.release)) {
            std.log.info("{s} already in use", .{installed_name});
        }

        zvm_dir.deleteFile("zig") catch {};
        try zvm_dir.symLink(installed_name, "zig", .{.is_directory = true});
        try use_f.seekTo(0);
        try use_f.setEndPos(0);
        try use_f.writeAll(opts.install.release);
        return;
    } else if (uninstall_cmd.occur) {
        const installed_name = try allocPrint(a, "zig-{s}-{s}", 
            .{double_str, if (is_master) master_locked else opts.install.release});
        defer a.free(installed_name);
      
        _ = list_map.get(installed_name) orelse {
            std.log.err("{s} is not installed", .{installed_name});
            return Error.UnknownRelease;
        };
        if (!ask_for_yes(&stdin, "removing installation {s}", .{installed_name})) return;
        zvm_dir.deleteTree(installed_name) catch |e| {
            std.log.err("{}: failed to delete installation {s}", .{e, installed_name});
            return e;
        };
        assert(list_map.swapRemove(installed_name));
        try list_f.seekTo(0);
        try list_f.setEndPos(0);
        var list_it = list_map.iterator();
        while (list_it.next()) |entry| {
           try list_f.writeAll(entry.key_ptr.*);
           try list_f.writeAll("\n");
        }

        if (std.mem.eql(u8, use_str, installed_name)) {
            std.log.info("{s} is no longer in use", .{use_str});
            zvm_dir.deleteFile("zig") catch {};
            try use_f.seekTo(0);
            try use_f.setEndPos(0); 
        }
        
        if (is_master) {
            try master_f.setEndPos(0);
        }
        return; 
    } else if (install_cmd.occur) {
        const latest_master = index.map.get("master").?.version;
        const installed_name = try allocPrint(a, "zig-{s}-{s}", 
            .{double_str, if (is_master) latest_master else opts.install.release});
        defer a.free(installed_name);

        std.log.debug("installing {s}...", .{installed_name});
        if (list_map.get(installed_name)) |_| {
            std.log.info("{s} is already installed, do `zvm use {s}` to use it", .{installed_name, opts.install.release});
            return;
        }
        // if we are install a master, and there is a master already installed, that this different from the latest master.
        if (is_master and master_locked.len != 0) {
            if (std.mem.eql(u8, master_locked, latest_master)) @panic("Something went wrong: the latest master should not have been installed.");
            if (!ask_for_yes(&stdin, 
                    "Trying to installed latest master {s}, but master {s} already installed, do you want to overwiter it?",
                    .{latest_master, master_locked})) return;
        }

        const release = index.map.get(opts.install.release) orelse { std.log.err("Unknown release {s}", .{opts.install.release});
            return Error.UnknownRelease;
        };
        const download = release.platforms.get(double_str) orelse {
            std.log.err("No {s} found for {s}, try building from src or bootstrap", .{double_str, opts.install.release});
            return Error.UnknownPlatform;
        };

        std.log.info("tarball: {s}", .{download.tarball});

        // get the last component of tarball, i.e. the name of the tarball
        const tarball_uri = try std.Uri.parse(download.tarball);
        var alloc_writer = std.io.Writer.Allocating.init(a);
        defer alloc_writer.deinit();
        try tarball_uri.path.formatPath(&alloc_writer.writer);
        const path = try alloc_writer.toOwnedSlice();
        defer a.free(path);

        const tarball_name = std.fs.path.basename(path);


        const fastest = if (opts.install.mirror.len == 0) try cal_fastest_mirror(&client, mirror_list, a) else .{@as(i64, 0), opts.install.mirror};
        std.log.debug("{s} has the lowest latency {}ms", .{fastest[1], fastest[0]});

        const final_url = try allocPrint(a, "{s}/{s}", .{fastest[1], tarball_name});
        defer a.free(final_url);
        std.log.debug("final url {s}", .{final_url});


        // TODO: use temporary location
        const output_path = try std.fs.path.resolve(a, &.{"/tmp", tarball_name});
        defer a.free(output_path);
        try download_tarball(final_url, output_path, a);
        verify_tarball(output_path, tarball_name, &client, a) catch |e| {
            std.log.err("{} failed to verify signature of {s}", .{e, output_path});
            return Error.SignatureError;
        };
        std.log.info("decompressing...", .{});
        try decompress_tarball(output_path, zvm_path, a);


        try master_f.seekTo(0);
        try master_f.setEndPos(0);
        try master_f.writeAll(latest_master);

        const master_locked_installed_name = try allocPrint(a, "zig-{s}-{s}", .{double_str, master_locked});
        defer a.free(master_locked_installed_name);
        try zvm_dir.deleteTree(master_locked_installed_name);

        try list_map.putNoClobber(a, opts.install.release, void{});
        std.log.info("{s} installed! do `zvm use` to use it", .{installed_name});
        try list_f.writeAll(installed_name);
        try list_f.writeAll("\n");


        // const symlink_path = try std.fs.path.resolve(a, &.{zvm_path, "zig"});
        // defer a.free(symlink_path);
    // std.fs.deleteFileAbsolute(symlink_path) catch {};
    // try std.fs.symLinkAbsolute(output_path[0..output_path.len-7], symlink_path, .{.is_directory = true});
    } else unreachable;
}
