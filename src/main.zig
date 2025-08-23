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
const fatal = std.process.fatal;

const temp_folder = if (builtin.target.os.tag == .windows) "~/AppData/Local/Temp/" else "/tmp/";

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
        mirror: ?[]const u8,
        fetch: bool,
    },

    release: struct {
        fetch: bool, 
        name: ?[]const u8
    },

    list: struct {
        valididate: bool,
    },
    
    mirror: struct {
        fetch: bool,
    },
};

fn free_index(index: *Index, a: Allocator) void {
    var index_it = index.map.iterator();
    while (index_it.next()) |entry| {
        a.free(entry.key_ptr.*);
        entry.value_ptr.deinit(a);
    }
    index.deinit(a);

}

fn cal_fastest_mirror(client: *std.http.Client, mirror_cfg: FileConfigSet, a: Allocator) !struct {i64, []const u8} {
    var mirror_it = mirror_cfg.set.iterator();
    var latencies = std.ArrayListUnmanaged(Latency) {};
    defer latencies.deinit(a);
    while (mirror_it.next()) |mirror| {
        const start_t = std.time.milliTimestamp();
        _ = client.fetch(.{
            .location = .{.url = mirror.key_ptr.*},
            .keep_alive = false,
        }) catch |e| {
            std.log.err("{} cannot connect to mirror {s}. skipping.", .{e, mirror.key_ptr.*});
            continue;
        };
        const end_t = std.time.milliTimestamp();
        const latency = end_t-start_t;
        try latencies.append(a, .{latency, mirror.key_ptr.*});
        std.log.debug("mirror: {s} {}ms", .{mirror.key_ptr.*, latency});
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

fn verify_tarball(tarball_path: []const u8, tarball_name: []const u8, sig_url: []const u8, client: *std.http.Client, a: Allocator) !void {
    var buf: [1024]u8 = undefined;
    var storage = std.ArrayListUnmanaged(u8) {.items = &buf, .capacity = buf.len};
    storage.shrinkRetainingCapacity(0);
    const resp = try client.fetch(.{
        .location = .{.url = sig_url},
        .method = .GET,
        .response_storage = .{ .static = &storage },
    });
    if (resp.status != .ok) return Error.SignatureError;
    const sig_path = try allocPrint(a, temp_folder ++ "/{s}.minisig", .{tarball_name});
    defer a.free(sig_path);
    {
        var sig_f = try std.fs.createFileAbsolute(sig_path, .{.truncate = true});
        defer sig_f.close();
        try sig_f.writeAll(storage.items);
    }

    var minisign = std.process.Child.init(&.{"minisign", "-Vm", tarball_path, "-P", public_key, "-x", sig_path}, a);
    minisign.stdin_behavior = .Pipe;
    minisign.spawn() catch |e| {
        if (e == error.FileNotFound) std.log.err("program `minisign` is not installed or available in $PATH", .{});
        return e;
    };
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

const FileConfig = struct {
    file: std.fs.File,
    buf: []const u8,
    dirty: bool, // if dirty, commit will overwrite the file.

    const MAX_FETCH_SIZE = 1024 * 100;
    pub fn init(zvm_dir: *std.fs.Dir, name: []const u8, arena: Allocator) !FileConfig {
        var file = try zvm_dir.createFile(name, .{ .truncate = false, .read = true });
        var buf: [256]u8 = undefined;
        var reader = file.reader(&buf);
        const buf2 = try reader.interface.allocRemaining(arena, .unlimited);
        return .{ .file = file, .buf = buf2, .dirty = false };
    }

    pub fn fetch(self: *FileConfig, url: []const u8, client: *std.http.Client, arena: Allocator) !void {
        var buf: [MAX_FETCH_SIZE]u8 = undefined;
        var storage = std.ArrayListUnmanaged(u8).initBuffer(&buf);
        const resp = try client.fetch(.{
            .location = .{.url = url},
            .response_storage = .{.static = &storage },
        });
        if (resp.status != .ok) return Error.NetworkError;
        std.log.debug("storage: {}", .{storage.items.len});
        self.overwrite(try arena.dupe(u8, storage.items));
        self.dirty = true;
    }

    pub fn fetch_if_empty_or_force(self: *FileConfig, url: []const u8, client: *std.http.Client, force_fetch: bool, arena: Allocator) !void {
        if (force_fetch or self.buf.len == 0) return self.fetch(url, client, arena);
    }

    pub fn commit(self: *FileConfig) !void {
        if (self.dirty) {
            try self.file.seekTo(0);
            try self.file.setEndPos(0);
            try self.file.writeAll(self.buf);
        }
        self.file.close();
    }

    pub fn clear(self: *FileConfig) void {
        self.buf = &.{};
        self.dirty = true;
    }

    pub fn overwrite(self: *FileConfig, new: []const u8) void {
        self.buf = new;
        self.dirty = true;
    }
};

const FileConfigSet = struct {
    const MAX_FETCH_SIZE = 2048;
    const SetError = error {
        DuplicateEntry,
    };
    file: std.fs.File,
    set: std.StringArrayHashMapUnmanaged(void),
    dirty: bool,

    pub fn init(zvm_dir: *std.fs.Dir, name: []const u8, arena: Allocator) !FileConfigSet {
        var file = try zvm_dir.createFile(name, .{ .truncate = false, .read = true });
        var buf: [256]u8 = undefined;
        var reader = file.reader(&buf);
        const buf2 = try reader.interface.allocRemaining(arena, .unlimited);
        var cfg = FileConfigSet {.file = file, .set = .empty, .dirty = false}; 
        try cfg.overwrite(buf2, arena);
        return cfg;
    }

    pub fn overwrite(self: *FileConfigSet, buf: []const u8, arena: Allocator) !void {
        self.set.clearRetainingCapacity();
        const count = blk: {
            var lines = std.mem.tokenizeScalar(u8, buf, '\n');
            var count: usize = 0;
            while (lines.next()) |_| {
                count += 1;
            }
            break :blk count;
        };
        self.set.ensureTotalCapacity(arena, count) catch unreachable;
        var lines = std.mem.tokenizeScalar(u8, buf, '\n');
        while (lines.next()) |line| {
            if (self.set.fetchPut(arena, line, {}) catch unreachable) |_|
                return SetError.DuplicateEntry;
        }
        assert(self.set.count() == count);
        self.dirty = true;
    }

    pub fn append_line(self: *FileConfigSet, buf: []const u8, arena: Allocator) !void {
        if (self.set.fetchPut(arena, buf, {}) catch unreachable) |_| return SetError.DuplicateEntry;
        self.dirty = true;
    }

    pub fn commit(self: *FileConfigSet) !void {
        if (self.dirty) {
            try self.file.seekTo(0);
            try self.file.setEndPos(0);
            var it = self.set.iterator();
            while (it.next()) |entry| {
                try self.file.writeAll(entry.key_ptr.*);
            }
        }
        self.file.close();
    }

    pub fn get(self: FileConfigSet, key: []const u8) bool {
        return self.set.get(key) != null;
    }

    pub fn fetch(self: *FileConfigSet, url: []const u8, client: *std.http.Client, arena: Allocator) !void {
        var buf: [MAX_FETCH_SIZE]u8 = undefined;
        var storage = std.ArrayListUnmanaged(u8).initBuffer(&buf);
        const resp = try client.fetch(.{
            .location = .{.url = url},
            .response_storage = .{.static = &storage },
        });
        if (resp.status != .ok) return Error.NetworkError;
        try self.overwrite(arena.dupe(u8, storage.items) catch unreachable, arena);
        self.dirty = true;
    }

    pub fn fetch_if_empty_or_force(self: *FileConfigSet, url: []const u8, client: *std.http.Client, force_fetch: bool, arena: Allocator) !void {
        if (force_fetch or self.set.count() == 0) return self.fetch(url, client, arena);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var arena_alloc = std.heap.ArenaAllocator.init(a);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var stdin = std.fs.File.stdin();

    //
    // cli
    //
    var opts: Options = undefined;
    var args = try std.process.argsWithAllocator(a);
    var arg_parser = Cli.ArgParser {};
    arg_parser.init(a, args.next().?, "zig package manager");
    defer arg_parser.deinit();

    // TODO: `nuke` command that remove entire installation
    // `add` command that adds a local folder to the list of installation
    const release_cmd = 
        arg_parser.sub_command("release", "(fetch and) list the currently avaiable releases")
        .add_opt(bool, &opts.release.fetch, .{.just = &false}, .{.prefix = "--fetch"}, "", "update the index of releases")
        .add_opt(?[]const u8, &opts.release.name, .{.just = &null}, .positional, "<release-name>", "print details for this specific release");

    const install_cmd = 
        arg_parser.sub_command("install", "install a release")
        .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the releaset to download, see `zvm list`")
        .add_opt(?[]const u8, &opts.install.mirror, .{.just = &null}, .{.prefix = "--mirror"}, "<mirror>", "the mirror to use")
        .add_opt(bool, &opts.install.fetch, .{.just = &false}, .{.prefix = "--fetch"}, "", "fetch the latest index and mirrors before install");

    const uninstall_cmd = 
        arg_parser.sub_command("uninstall", "uninstall a release")
        .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the releaset to uninstall, see `zvm list`");

    const mirror_cmd = 
        arg_parser.sub_command("mirror", "fetch and list all the known mirrors")
        .add_opt(bool, &opts.mirror.fetch, .{.just = &false}, .{.prefix = "--fetch"}, "", "update the list of mirror");

    const list_cmd = arg_parser.sub_command("list", "list all current installation");
    // list_cmd.add_opt(bool, &opts.list.valididate, &false, .{.prefix = "--valid"}, "validate and fix the current installation", a);

    const use_cmd = 
        arg_parser.sub_command("use", "use an installation")
        .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the release to use");

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

    // // this does not work, likely because of bug https://github.com/ziglang/zig/issues/19878
    // try client.initDefaultProxies(arena);
    // std.log.info("using proxy from env: {s}:{}", .{client.https_proxy.?.host, client.https_proxy.?.port});
    // assert((try client.fetch(.{.location = .{.url = "http://github.com"}})).status == .ok);

    //
    // fetch or read index from cached
    //
    var index_cfg = try FileConfig.init(&zvm_dir, "index.json", arena);
    defer index_cfg.commit() catch unreachable;
    try index_cfg.fetch_if_empty_or_force(official_download ++ "/index.json", &client, opts.release.fetch, arena);

    var json_obj = json.Scanner.initCompleteInput(a, index_cfg.buf); 
    defer json_obj.deinit();
    var index = Index.jsonParse(a, &json_obj, .{.ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = 1024}) catch |e| {
        std.log.debug("index buffer: {s}", .{index_cfg.buf});
        std.log.err("unxpected error occur while parsing index: {}", .{e});
        return e;
    };

    defer free_index(&index, a);


    //
    // read master locked
    // The file containing the commit of the current installation of the `master` release, if any.
    // When its empty, it means no master is instsalled, or something went terribly wrong.
    var master_cfg = try FileConfig.init(&zvm_dir, "master.txt", arena);
    defer master_cfg.commit() catch unreachable;


    //
    // read the list of installation
    //
    var list_cfg = try FileConfigSet.init(&zvm_dir, "list.txt", arena);
    defer list_cfg.commit() catch unreachable;

    //
    // read the current installation in use 
    //
    var use_cfg = try FileConfig.init(&zvm_dir, "use.txt", arena);
    defer use_cfg.commit() catch unreachable;

    //
    // detect the current platform
    //
    const double_str = try allocPrint(arena, "{s}-{s}", .{@tagName(builtin.cpu.arch), @tagName(builtin.target.os.tag)});
    std.log.info("Detected system: {s}", .{double_str});
    // for `install`, this is the release to 


    // 
    // get mirror and calculate the fastest
    //
    var mirror_cfg = try FileConfigSet.init(&zvm_dir, "mirror.txt", arena);
    try mirror_cfg.fetch_if_empty_or_force(official_download ++ "/community-mirrors.txt", &client, opts.mirror.fetch, arena);

    // handle different command
    if (mirror_cmd.occur) {
        var mirror_it = mirror_cfg.set.iterator();
        while (mirror_it.next()) |mirror| {
            print("{s}\n", .{mirror.key_ptr.*});
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
        var it = list_cfg.set.iterator();
        print("installed zig:\n", .{});
        while (it.next()) |entry| {
            print("{s}\n", .{entry.key_ptr.*});
        }
        return;
    } else if (release_cmd.occur) {
        if (opts.release.name) |release_name| {
            const release = index.map.get(release_name) orelse {
                std.log.err("Unknown release {s}, try with `--fetch`", .{release_name});
                return Error.UnknownRelease;
            };
            if (std.mem.eql(u8, release_name, "master")) {
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
        } else {
            var index_it = index.map.iterator();
            while (index_it.next()) |entry| {
                print("{s} {s}\n", .{entry.key_ptr.*, entry.value_ptr.version});
            }

        }

        return;
    } else if (use_cmd.occur) {
        // this is the name of the release the to used. 
        // A symlink would be created targeting the folder named `installed_name`.
        // For `master`, we need to retreive its commit
        const installed_name = try allocPrint(a, "zig-{s}-{s}", 
            .{double_str, if (is_master) master_cfg.buf else opts.install.release});
        defer a.free(installed_name);
        if (!list_cfg.get(installed_name)) {
            std.log.err("{s} is not installed", .{installed_name});
            return Error.UnknownRelease;
        }
        if (std.mem.eql(u8, use_cfg.buf, opts.install.release)) {
            std.log.info("{s} already in use", .{installed_name});
        }

        zvm_dir.deleteFile("zig") catch {};
        try zvm_dir.symLink(installed_name, "zig", .{.is_directory = true});
        use_cfg.overwrite(opts.install.release);
        return;
    } else if (uninstall_cmd.occur) {
        const installed_name = try allocPrint(a, "zig-{s}-{s}", 
            .{double_str, if (is_master) master_cfg.buf else opts.install.release});
        defer a.free(installed_name);

        if (!list_cfg.get(installed_name)) {
            std.log.err("{s} is not installed", .{installed_name});
            return Error.UnknownRelease;
        }
        if (!ask_for_yes(&stdin, "removing installation {s}", .{installed_name})) return;
        zvm_dir.deleteTree(installed_name) catch |e| {
            std.log.err("{}: failed to delete installation {s}", .{e, installed_name});
            return e;
        };
        assert(list_cfg.set.swapRemove(installed_name));

        if (std.mem.eql(u8, use_cfg.buf, installed_name)) {
            std.log.info("{s} is no longer in use", .{use_cfg.buf});
            zvm_dir.deleteFile("zig") catch {};
            use_cfg.clear();
        }

        if (is_master) {
            master_cfg.clear();
        }
        return; 
    } else if (install_cmd.occur) {
        const latest_master = index.map.get("master").?.version;
        const installed_name = try allocPrint(a, "zig-{s}-{s}", 
            .{double_str, if (is_master) latest_master else opts.install.release});
        defer a.free(installed_name);

        std.log.debug("installing {s}...", .{installed_name});
        if (list_cfg.get(installed_name)) {
            std.log.info("{s} is already installed, do `zvm use {s}` to use it", .{installed_name, opts.install.release});
            return;
        }
        // if we are install a master, and there is a master already installed, that this different from the latest master.
        if (is_master and master_cfg.buf.len != 0) {
            if (std.mem.eql(u8, master_cfg.buf, latest_master)) @panic("Something went wrong: the latest master should not have been installed.");
            if (!ask_for_yes(&stdin, 
                    "Trying to installed latest master {s}, but master {s} already installed, do you want to overwiter it?",
                    .{latest_master, master_cfg.buf})) return;
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


        const fastest = if (opts.install.mirror) |mirror| .{@as(i64, 0), mirror} else try cal_fastest_mirror(&client, mirror_cfg, a);
        std.log.debug("{s} has the lowest latency {}ms", .{fastest[1], fastest[0]});

        const final_url = try allocPrint(a, "{s}/{s}", .{fastest[1], tarball_name});
        defer a.free(final_url);
        std.log.debug("final url {s}", .{final_url});


        const output_path = try std.fs.path.resolve(a, &.{temp_folder, tarball_name});
        defer a.free(output_path);
        try download_tarball(final_url, output_path, a);
        const sig_url = if (!is_master) 
            try allocPrint(arena, "{s}/{s}/{s}.minisig", .{official_download, opts.install.release, tarball_name})
        else try allocPrint(arena, "{s}/{s}.minisig", .{official_builds, tarball_name});
        std.log.debug("signature url: {s}", .{sig_url});
        verify_tarball(output_path, tarball_name, sig_url, &client, a) catch |e| {
            std.log.err("{} failed to verify signature of {s}", .{e, output_path});
            return Error.SignatureError;
        };
        std.log.info("decompressing...", .{});
        try decompress_tarball(output_path, zvm_path, a);

        {
            const master_locked_installed_name = try allocPrint(arena, "zig-{s}-{s}", .{double_str, master_cfg.buf});
            try zvm_dir.deleteTree(master_locked_installed_name);
            master_cfg.overwrite(latest_master);
        }

        try list_cfg.append_line(installed_name, arena);
        std.log.info("{s} installed! do `zvm use` to use it", .{installed_name});
        // const symlink_path = try std.fs.path.resolve(a, &.{zvm_path, "zig"});
        // defer a.free(symlink_path);
        // std.fs.deleteFileAbsolute(symlink_path) catch {};
        // try std.fs.symLinkAbsolute(output_path[0..output_path.len-7], symlink_path, .{.is_directory = true});
    } else unreachable;
}
