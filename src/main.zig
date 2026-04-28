//! Author:      Tesseract22
//! Version:     v0.1.2
//! Date:        2026-04-26
//!
//! Description: Zig Version Manager
//!
//! Changelog:
//!   v0.1.0 - 2026-04-26 - Initial release
//!   v0.1.1 - 2026-04-26
//!     Refactor with database abstraction
//!     Added `nuke` command
//!   v0.1.2 - 2026-04-28
//!     Upgrade to zig 0.16.0, use io.async to speed to mirror speed test
//!
//! License: MIT

// TODO
// 1. upgrade to zig 0.16
// 2. fetch with thread pool?
// 3. being able to install specific commit
const VERSION = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 2, .build = @import("build").commit };

const public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"; // public key used to verify zig tarball
const official_download = "https://ziglang.org/download"; // the url directory for "releases". i.e. 0.15.2
const official_builds = "https://ziglang.org/builds"; // the url directory for nightly builds

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const fatal = std.process.fatal;
const json = std.json;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const print = std.debug.print;
const Io = std.Io;

const builtin = @import("builtin");

const Cli = @import("cli.zig");

const Latency = struct { i64, []const u8 };

const Index = json.ArrayHashMap(Release);

const temp_folder = if (builtin.target.os.tag == .windows) "~/AppData/Local/Temp" else "/tmp";

const c = @cImport({
    @cInclude("curl/curl.h");
});

const db = @import("database.zig");

var http_proxy: ?[]const u8 = null;
var https_proxy: ?[]const u8 = null;

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
        var r = Release{};
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

const Error = error{
    DecompressionError,
    SignatureError,
    GeneralNetworkError,
    NotFoundError,
};

const Options = struct {
    install: struct {
        release: []const u8,
        mirror: ?[]const u8,
        fetch: bool,
    },

    release: struct { fetch: bool, name: ?[]const u8 },

    list: struct {
        valididate: bool,
    },

    mirror: struct {
        fetch: bool,
    },

    add: struct {
        path: []const u8,
    },
};

fn free_db(a: Allocator) void {
    var it = db.index.map.iterator();
    while (it.next()) |entry| {
        a.free(entry.key_ptr.*);
        entry.value_ptr.deinit(a);
    }
    db.index.deinit(a);
}

fn test_fetch_mirror(client: *std.http.Client, url: []const u8, item: *Latency) Io.Cancelable!void {
    const start_t = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    _ = client.fetch(.{
        .location = .{ .url = url },
        .keep_alive = false,
    }) catch |e| {
        log.err("{} cannot connect to mirror {s}. skipping.", .{ e, url });
        return Io.Cancelable.Canceled;
    };
    const end_t = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const latency = end_t - start_t;

    item.*[0] = latency;
    log.debug("mirror: {s} {}ms", .{ url, latency });
}

// this only test latency for now, not throughput
fn test_fastest_mirror(client: *std.http.Client, a: Allocator) []Latency {
    var mirror_it = db.mirror_file.set.iterator();
    const latencies = a.alloc(Latency, mirror_it.len + 1) catch @panic("OOM");

    var group = Io.Group.init;
    defer group.cancel(io);

    var idx: u32 = 0;
    while (mirror_it.next()) |mirror|: (idx += 1) {
        const url = mirror.key_ptr.*;
        const item = &latencies[idx];
        item[0] = std.math.maxInt(i64);
        item[1] = url;
        group.async(io, test_fetch_mirror, .{ client, url, item });
    }
    {
        const item = &latencies[idx];
        item.*[0] = std.math.maxInt(i64);
        item.*[1] = official_builds;
        const start_t = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (client.fetch(.{
            .location = .{ .url = official_builds },
            .keep_alive = false,
        })) |_| {
            const end_t = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            const latency = end_t - start_t;
            item.*[0] = latency;
            log.debug("mirror: {s} {}ms", .{ official_builds, latency });
        } else |e| {
            log.err("{} cannot connect to mirror {s}. skipping.", .{ e, official_builds });
    }
    }
    std.mem.sort(Latency, latencies, void{}, latency_less_than);
    return latencies;
}

const off_t = c.curl_off_t;
const ProgressState = struct {
    last_run: off_t = 0,
    curl: *c.CURL,
};
fn download_progress(p: *anyopaque, dltotal: off_t, dlnow: off_t, ultotal: off_t, ulnow: off_t) callconv(.c) c_int {
    _ = ultotal;
    _ = ulnow;
    const MINIMAL_PROGRESS_FUNCTIONALITY_INTERVAL = 3000000;
    const prog: *ProgressState = @ptrCast(@alignCast(p));
    const curl = prog.curl;
    var curtime: off_t = 0;
    assert(c.curl_easy_getinfo(curl, c.CURLINFO_TOTAL_TIME, &curtime) == c.CURLE_OK);
    if ((curtime - prog.last_run) >= MINIMAL_PROGRESS_FUNCTIONALITY_INTERVAL) {
        prog.last_run = curtime;
        std.debug.print("downloading [", .{});
        const total_len = 20;
        const done: usize = if (dltotal != 0) @intCast(@divFloor(total_len * dlnow, dltotal)) else 0;
        for (0..done) |_| std.debug.print("#", .{});
        for (0..total_len - done) |_| std.debug.print(".", .{});
        std.debug.print("] {}/{} bytes\r", .{ dlnow, dltotal });
    }

    return 0;
}

fn download_curl(url: [:0]const u8, output_path: []const u8, a: Allocator) !void {
    log.debug("curl to {s}", .{output_path});
    _ = a;
    const curl = c.curl_easy_init() orelse {
        log.err("failed to initialize curl handle", .{});
        return Error.GeneralNetworkError;
    };
    defer c.curl_easy_cleanup(curl);
    var prog = ProgressState{ .curl = curl };
    _ = c.curl_easy_setopt(curl, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_XFERINFOFUNCTION, download_progress);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_XFERINFODATA, &prog);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(i32, 1));

    _ = c.curl_easy_setopt(curl, c.CURLOPT_NOPROGRESS, @as(c_int, 0));
    if (https_proxy orelse http_proxy) |proxy| {
        log.debug("using proxy: {s}", .{proxy});
        _ = c.curl_easy_setopt(curl, c.CURLOPT_PROXY, proxy.ptr);
    }
    const f = try Io.Dir.createFileAbsolute(io, output_path, .{});
    defer f.close(io);
    var write_buf: [1024*8]u8 = undefined;
    var writer = f.writer(io, &write_buf);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &writer);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, write_data);

    log.info("downloading {s}", .{url});
    const res = c.curl_easy_perform(curl);
    try writer.flush();
    if (res != c.CURLE_OK) {
        log.err("failed to perform curl to {s}: {}", .{ url, res });
        return Error.GeneralNetworkError;
    }
    std.debug.print("\n", .{});
    var response_status: c_int = undefined;
    _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &response_status);
    if (response_status != 200) {
        log.err("fetch content from {s} response with {}", .{ url, response_status });
        if (response_status == 404) {
            return Error.NotFoundError;
        }
        return Error.GeneralNetworkError;
    }
    return;
}

fn write_data(buf: *anyopaque, size: usize, nmemb: usize, userp: *anyopaque) callconv(.c) usize {
    std.debug.assert(size == 1);
    const writer: *Io.File.Writer = @ptrCast(@alignCast(userp));
    const data: [*]u8 = @ptrCast(@alignCast(buf));
    writer.interface.writeAll(data[0..nmemb]) catch |e| {
        log.err("cannot save download to file: {}", .{e});
        return 0;
    };
    return nmemb;
}

fn verify_tarball(tarball_path: []const u8, tarball_name: []const u8, sig_url: [:0]const u8, a: Allocator) !void {
    const sig_path = try allocPrint(a, "{s}/{s}.minisig", .{ temp_folder, tarball_name });
    defer a.free(sig_path);
    download_curl(sig_url, sig_path, a) catch |e| {
        switch (e) {
            Error.NotFoundError =>
                log.err("the signature file does not exist at `{s}`, probably because you are downloading a non-release build that is not the latest, try rerun with `--fetch`", .{ sig_url }),
            else => {},
        }
        return e;
    };

    var minisign = std.process.spawn(io, .{
        .argv = &.{ "minisign", "-Vm", tarball_path, "-P", public_key, "-x", sig_path },
    }) catch |e| {
        if (e == error.FileNotFound) log.err("program `minisign` is not installed or available in $PATH", .{});
        return e;
    };
    switch (try minisign.wait(io)) {
        .exited => |exit_code| {
            log.info("minisign exited with {}", .{exit_code});
            if (exit_code != 0) return Error.SignatureError;
        },
        else => |other| {
            log.err("minisign terminated unxpectedly {}", .{other});
            return Error.SignatureError;
        },
    }
}

fn decompress_tarball(tarball_path: []const u8, output_dir: []const u8, a: Allocator) !void {
    _ = a;
    var tar = try std.process.spawn(io, .{
        .argv = &.{ "tar", "xf", tarball_path, "-C", output_dir }
    });
    const tar_term = try tar.wait(io);
    switch (tar_term) {
        .exited => |exit_code| {
            log.info("tar exited with {}", .{exit_code});
            if (exit_code != 0) return Error.DecompressionError;
        },
        else => |other| {
            log.err("tar terminated unxpectedly {}", .{other});
            return Error.DecompressionError;
        },
    }
}

fn read_list(str: []const u8, a: Allocator) !std.StringArrayHashMapUnmanaged(void) {
    var map = std.StringArrayHashMapUnmanaged(void){};
    var it = std.mem.tokenizeScalar(u8, str, '\n');
    while (it.next()) |line| {
        try map.putNoClobber(a, line, void{});
    }
    return map;
}

fn print_list_of_releases() void {
    print("Available releases: {}\n", .{db.index.map.count()});
    var it = db.index.map.iterator();
    while (it.next()) |entry| {
        print("{s} {s}\n", .{ entry.key_ptr.*, entry.value_ptr.version });
    }
}

pub var stdin: std.Io.File = undefined;
pub var io: Io = undefined;

pub fn ask_for_yes(comptime fmt: []const u8, args: anytype) bool {
    print(fmt ++ "\n", args);
    print("y[es], n[o]?\n", .{});
    var buf: [32]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    var buf2: [32]u8 = undefined;
    const yes_or_no = reader.interface.takeSentinel('\n') catch |e| {
        if (e == error.StreamTooLong) return ask_for_yes(fmt, args);
        log.err("{}: you mean no? fine.", .{e});
        return false;
    };
    const lower = std.ascii.lowerString(&buf2, yes_or_no);
    if (std.mem.eql(u8, lower, "y") or std.mem.eql(u8, lower, "yes")) return true;
    if (std.mem.eql(u8, lower, "n") or std.mem.eql(u8, lower, "no")) return false;
    return ask_for_yes(fmt, args);
}

pub fn main(init: std.process.Init) !void {
    var gpa = init.gpa;

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    stdin = std.Io.File.stdin();
    io = init.io;

    //
    // cli
    //
    var opts: Options = undefined;
    var args = init.minimal.args.iterate();
    var arg_parser = Cli.ArgParser{};
    arg_parser.init(gpa, args.next().?, std.fmt.comptimePrint("zig package manager {f}", .{VERSION}));
    defer arg_parser.deinit();

    // `add` command that adds a local folder to the list of installation
    const release_cmd =
        arg_parser.sub_command("release", "(fetch and) list the currently avaiable releases")
            .add_opt(bool, &opts.release.fetch, .{ .just = &false }, .{ .prefix = "--fetch" }, "", "update the db.index of releases")
            .add_opt(?[]const u8, &opts.release.name, .{ .just = &null }, .positional, "<release-name>", "print details for this specific release");

    const install_cmd =
        arg_parser.sub_command("install", "install a release")
            .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the releaset to download, see `zvm list`")
            .add_opt(?[]const u8, &opts.install.mirror, .{ .just = &null }, .{ .prefix = "--mirror" }, "<mirror>", "the mirror to use")
            .add_opt(bool, &opts.install.fetch, .{ .just = &false }, .{ .prefix = "--fetch" }, "", "fetch the latest db.index and mirrors before install");

    const uninstall_cmd =
        arg_parser.sub_command("uninstall", "uninstall a release")
            .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the releaset to uninstall, see `zvm list`");

    const mirror_cmd =
        arg_parser.sub_command("mirror", "fetch and list all the known mirrors")
            .add_opt(bool, &opts.mirror.fetch, .{ .just = &false }, .{ .prefix = "--fetch" }, "", "update the list of mirror");

    const list_cmd = arg_parser.sub_command("list", "list all current installation");
    // list_cmd.add_opt(bool, &opts.list.valididate, &false, .{.prefix = "--valid"}, "validate and fix the current installation", a);

    const use_cmd =
        arg_parser.sub_command("use", "use an installation")
            .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the release to use");

    const add_cmd =
        arg_parser.sub_command("add", "add a manually donwloaded tarball to the list of installations")
            .add_opt([]const u8, &opts.add.path, .none, .positional, "<path>", "the path to add");

    const nuke_cmd =
        arg_parser.sub_command("nuke", "nuke the whole zvm installation");

    try arg_parser.parse(&args);
    opts.mirror.fetch = opts.mirror.fetch or opts.install.fetch;
    opts.release.fetch = opts.release.fetch or opts.install.fetch;

    if (arg_parser.root_command.occur) {
        arg_parser.print_help();
        return;
    }
    const is_master = std.mem.eql(u8, opts.install.release, "master");

    var env = init.environ_map;

    db.detect_zvm_installation(env, arena);

    if (nuke_cmd.occur) {
        if (ask_for_yes("do you want to delete everything in {s}", .{db.zvm_path})) {
            db.nuke();
        } else {
            log.info("nothing to do. exit.", .{});
        }
        return;
    }

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    db.init(io, opts.release.fetch, &client);
    // TOOD: rollback changes if any error occur
    defer db.deinit() catch |e| fatal("failed to commit changes: {}", .{e});

    // // this does not work, likely because of bug https://github.com/ziglang/zig/issues/19878
    // try client.initDefaultProxies(arena);
    // log.info("using proxy from env: {s}:{}", .{client.https_proxy.?.host, client.https_proxy.?.port});
    // assert((try client.fetch(.{.location = .{.url = "http://github.com"}})).status == .ok);
    http_proxy = env.get("HTTP_PROXY") orelse env.get("http_proxy");
    https_proxy = env.get("HTTPS_PROXY") orelse env.get("https_proxy");

    //
    // detect the current platform
    //
    const double_str = try allocPrint(arena, "{s}-{s}", .{ @tagName(builtin.cpu.arch), @tagName(builtin.target.os.tag) });
    log.info("Detected system: {s}", .{double_str});
    // for `install`, this is the release to

    print("\n====================\n\n", .{});
    // handle different command
    if (mirror_cmd.occur) {
        var mirror_it = db.mirror_file.set.iterator();
        while (mirror_it.next()) |mirror| {
            print("{s}\n", .{mirror.key_ptr.*});
        }
        return;
    } else if (list_cmd.occur) {
        // if (opts.list.valididate) {
        //     var installed_it = zvm.iterate();
        //     while (try installed_it.next()) |entry| {
        //         if (entry.kind != .directory) continue;
        //     }
        // }
        var it = db.installed_file.set.iterator();
        print("installed zig: {}\n", .{db.installed_file.set.count()});
        while (it.next()) |entry| {
            print("{s}\n", .{entry.key_ptr.*});
        }
        return;
    } else if (release_cmd.occur) {
        if (opts.release.name) |release_name| {
            const release = db.index.map.get(release_name) orelse {
                fatal("Unknown release {s}, try with `--fetch` to update to list of releases", .{release_name});
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
                print("{s}: {s}\n", .{ platform.key_ptr.*, download.tarball });
            }
        } else {
            print_list_of_releases();
        }

        return;
    } else if (use_cmd.occur) {
        // this is the name of the release the to used.
        // A symlink would be created targeting the folder named `installed_name`.
        // For `master`, we need to retreive its commit
        const installed_name = try allocPrint(gpa, "zig-{s}-{s}", .{ double_str, if (is_master) db.master_file.buf else opts.install.release });
        defer gpa.free(installed_name);
        if (!db.installed_file.get(installed_name))
            fatal("{s} is not installed", .{installed_name});
        if (std.mem.eql(u8, db.use_file.buf, opts.install.release)) {
            print("{s} already in use\n", .{installed_name});
        }

        db.zvm_dir.deleteFile(io, "zig") catch {};
        try db.zvm_dir.symLink(io, installed_name, "zig", .{ .is_directory = true });
        db.use_file.overwrite(opts.install.release);
        print("{s} up and running!\n", .{ installed_name });
        return;
    } else if (uninstall_cmd.occur) {
        const installed_name = try allocPrint(gpa, "zig-{s}-{s}", .{ double_str, if (is_master) db.master_file.buf else opts.install.release });
        defer gpa.free(installed_name);

        if (!db.installed_file.get(installed_name))
            fatal("{s} is not installed", .{installed_name});
        if (!ask_for_yes("removing installation {s}", .{installed_name})) return;
        db.zvm_dir.deleteTree(io, installed_name) catch |e| {
            log.err("{}: failed to delete installation {s}", .{ e, installed_name });
            return e;
        };
        db.installed_file.remove(installed_name);

        if (std.mem.eql(u8, db.use_file.buf, installed_name)) {
            log.info("{s} is no longer in use", .{db.use_file.buf});
            db.zvm_dir.deleteFile(io, "zig") catch {};
            db.use_file.clear();
        }

        if (is_master) {
            db.master_file.clear();
        }
        return;
    } else if (add_cmd.occur) {
        var f = try Io.Dir.openFileAbsolute(io, opts.add.path, .{});
        defer f.close(io);
        const basename = std.fs.path.basename(opts.add.path);
        const kind = (try f.stat(io)).kind;

        const installed_name = switch (kind) {
            .file => blk: {
                const idx = std.mem.lastIndexOf(u8, basename, ".tar") orelse
                    fatal("file does not start ends with `.tar`", .{});
                const folder_name = basename[0..idx];
                if (db.installed_file.get(folder_name))
                    fatal("{s} already existed as an installation", .{folder_name});
                try decompress_tarball(opts.add.path, db.ZVM_STORAGE_PATH, gpa);
                break :blk folder_name;
            },
            .directory => blk: {
                if (db.installed_file.get(basename))
                    fatal("{s} already existed as an installation", .{opts.add.path});
                try std.Io.Dir.renameAbsolute(opts.add.path, try std.fs.path.resolve(arena, &.{ db.zvm_path, basename }), io);
                break :blk basename;
            },
            else => {
                fatal("<path> ({s}) must be either a tar file or a directory", .{opts.add.path});
            },
        };
        db.installed_file.append_line(installed_name) catch unreachable;
        return;
    } else if (install_cmd.occur) {
        const latest_master = db.index.map.get("master").?.version;
        const installed_name = try allocPrint(gpa, "zig-{s}-{s}", .{ double_str, if (is_master) latest_master else opts.install.release });
        defer gpa.free(installed_name);

        log.debug("installing {s}...", .{installed_name});
        if (db.installed_file.get(installed_name)) {
            log.info("{s} is already installed, do `zvm use {s}` to use it", .{ installed_name, opts.install.release });
            return;
        }
        // if we are install a master, and there is a master already installed, that this different from the latest master.
        if (is_master and db.master_file.buf.len != 0) {
            if (std.mem.eql(u8, db.master_file.buf, latest_master)) @panic("Something went wrong: the latest master should not have been installed.");
            if (!ask_for_yes("Trying to installed latest master {s}, but master {s} already installed, do you want to overwiter it?", .{ latest_master, db.master_file.buf })) return;
        }

        const release = db.index.map.get(opts.install.release) orelse {
            log.err("Unknown release {s}", .{opts.install.release});
            print_list_of_releases();
            std.process.abort();
        };
        const download = release.platforms.get(double_str) orelse
            fatal("No {s} found for {s}, run `zvm release {s}` to see the available platform.", .{ double_str, double_str, opts.install.release });

        print("tarball: {s}, size: {s}\n", .{download.tarball, download.size});

        // get the last component of tarball, i.e. the name of the tarball
        const tarball_uri = try std.Uri.parse(download.tarball);
        var alloc_writer = Io.Writer.Allocating.init(gpa);
        defer alloc_writer.deinit();
        try tarball_uri.path.formatPath(&alloc_writer.writer);
        const path = try alloc_writer.toOwnedSlice();
        defer gpa.free(path);

        const tarball_name = std.fs.path.basename(path);

        const latencies_sorted: []const Latency = if (opts.install.mirror) |mirror| &.{.{ @as(i64, 0), mirror }} else test_fastest_mirror(&client, gpa);
        defer if (latencies_sorted.len > 1) gpa.free(latencies_sorted);
        var first_time = true;

        for (latencies_sorted) |latency_item| {
            log.debug("{s} has latency {}ms", .{ latency_item[1], latency_item[0] });
            if (!first_time and !ask_for_yes("do you want to proceed with next mirror", .{})) { // skip?
                return;
            }
            first_time = false;
            const final_url = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ latency_item[1], tarball_name }, 0) catch @panic("OOM");
            defer gpa.free(final_url);

            const output_path = std.fs.path.resolve(gpa, &.{ temp_folder, tarball_name }) catch @panic("OOM");
            defer gpa.free(output_path);
            download_curl(final_url, output_path, gpa) catch |e| {
                switch (e) {
                    Error.GeneralNetworkError => log.err("this specific mirror does not have this release", .{}),
                    else => log.err("cannot fetch `{s}`: {}", .{ final_url, e }),
                }
                continue;
            };
            const sig_url = if (!is_master)
                std.fmt.allocPrintSentinel(arena, "{s}/{s}/{s}.minisig", .{ official_download, opts.install.release, tarball_name }, 0) catch @panic("OOM")
            else
                std.fmt.allocPrintSentinel(arena, "{s}/{s}.minisig", .{ official_builds, tarball_name }, 0) catch @panic("OOM");

            log.debug("signature url: {s}", .{sig_url});
            verify_tarball(output_path, tarball_name, sig_url, gpa) catch |e|
                fatal("{} failed to verify signature of {s}, potentially dangerous source", .{ e, output_path });
            log.info("decompressing...", .{});
            try decompress_tarball(output_path, db.zvm_path, gpa);
            try Io.Dir.deleteFileAbsolute(io, output_path);

            if (is_master) {
                const master_locked_installed_name = try allocPrint(arena, "zig-{s}-{s}", .{ double_str, db.master_file.buf });
                try db.zvm_dir.deleteTree(io, master_locked_installed_name);
                db.master_file.overwrite(latest_master);
            }

            try db.installed_file.append_line(installed_name);
            break;
        } else {
            fatal("no mirror left to proceed, something went terribly wrong", .{});
        }
        print("{s} installed! run `zvm use` to use it", .{installed_name});
    } else unreachable;
}
