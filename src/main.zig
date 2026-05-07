//! Author:      Tesseract22
//! Version:     v0.2.2
//! Date:        2026-05-06
//!
//! Description: Zig Version Manager
//!
//! Changelog:
//!   v0.1.0 - 2026-04-26 - Initial release
//!   v0.2.0 - 2026-05-03
//!     Added `nuke` command
//!     Upgrade to zig 0.16.0, use io.async to speed to mirror speed test
//!     Add '--validate' option to `list` command
//!     Rework mirror speed test, add `--timeout` options to `install` command
//!     Adpat to windows, use a shim exe instead of symlink to "activate" a installation
//!     Use zig library minizign instead of requiring user to have cli tool minisign installed
//!   v0.2.1 - 2026-05-04
//!     Fetches signature file first, then the tarball. Keep signature file in memory.
//!     Fix list --validate
//!   v0.2.2 - 2026-05-06
//!     Use stdout for print
//!     Use zig implementatio of decompression and extracting tar
//!     Add --platform flag to specify platform double
//!
//! License: MIT

// TODO
// - being able to install specific commit
// - Add command to set env var
// - per-folder config with .env
const VERSION = std.SemanticVersion{ .major = 0, .minor = 2, .patch = 2, .build = @import("build").commit };

const PUBLIC_KEY = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"; // public key used to verify zig tarball
const pk = minizign.PublicKey.decodeFromBase64(PUBLIC_KEY) catch unreachable;

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const fatal = std.process.fatal;
const json = std.json;
const Allocator = std.mem.Allocator;
fn allocPrint(allocator: Allocator, comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch @panic("OOM");
} 
const Io = std.Io;

const builtin = @import("builtin");

const Cli = @import("cli.zig");
const minizign = @import("thirdparty/minizign.zig");

const EndpointThroughput = struct {
    spd: f32,
    url: []const u8,

    fn throughput_gt(_: void, lhs: EndpointThroughput, rhs: EndpointThroughput) bool {
        return lhs.spd > rhs.spd;
    }
};

const Index = json.ArrayHashMap(Release);

const db = @import("database.zig");
// const utils = @import("utils.zig");

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

const Error = error{
    DecompressionError,
    SignatureError,
    GeneralNetworkError,
    NotFoundError,
};

const Options = struct {
    fetch: bool,
    platform: ?[]const u8,
    install: struct {
        release: []const u8,
        mirror: ?[]const u8,
        timeout: i64,
    },

    release: struct { name: ?[]const u8 },

    list: struct {
        validate: bool,
    },

    mirror: struct {},

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

// this only test latency for now, not throughput
fn test_fastest_mirror(client: *std.http.Client, tarball_name: []const u8, timeout: i64, arena: Allocator, root: std.Progress.Node) []EndpointThroughput {
    const mirrors_node = root.startFmt(db.mirror_file.data.count(), "Testing mirror download speed", .{});
    const throughput_lists = arena.alloc(EndpointThroughput, db.mirror_file.data.count()) catch @panic("OOM");
    var mirror_idx: u32 = 0;
    var it = db.mirror_file.data.iterator();
    var group = Io.Group.init;
    while (it.next()) |mirror|: (mirror_idx += 1) {
        const final_url = allocPrint(arena, "{s}/{s}", .{ mirror.key_ptr.*, tarball_name });
        group.async(io, download_test_spd, .{ client, final_url, 1<<20, &throughput_lists[mirror_idx], mirrors_node });
    }
    io.sleep(.fromSeconds(timeout), .awake) catch unreachable;
    group.cancel(io);

    std.mem.sort(EndpointThroughput, throughput_lists, void{}, EndpointThroughput.throughput_gt);
    mirrors_node.end();

    return throughput_lists;
}

fn download_test_spd(
    client: *std.http.Client, url: []const u8,
    cancel_size: ?usize, latency_slot: *EndpointThroughput,
    root: std.Progress.Node) Io.Cancelable!void {

    latency_slot.spd = 0;
    latency_slot.url = url;

    var buf: [64]u8 = undefined;
    var discard = Io.Writer.Discarding.init(&buf);
    latency_slot.spd = download_to_writer(client, url, &discard.writer, cancel_size, root) catch |e| fallback: {
        log.warn("cannot test speed from `{s}`: {}", .{ url, e });
        break :fallback 0;
    };
    // log.debug("{s}: {} bytes/s", .{ latency_slot.url, latency_slot.spd });
}

fn download_to_path(client: *std.http.Client, url: []const u8, dest: []const u8, cancel_size: ?usize, root: std.Progress.Node) !f32 {
    log.debug("fetching {s} into {s}", .{ url, dest });
    const f = try Io.Dir.createFileAbsolute(io, dest, .{});
    defer f.close(io);

    return download_to_file(client, url, f, cancel_size, root);
}

fn download_to_file(client: *std.http.Client, url: []const u8, f: Io.File, cancel_size: ?usize, root: std.Progress.Node) !f32 {
    var write_buf: [1024*8]u8 = undefined;
    var writer = f.writer(io, &write_buf);

    return download_to_writer(client, url, &writer.interface, cancel_size, root);

}

fn download_to_writer(client: *std.http.Client, url: []const u8, writer: *Io.Writer, cancel_size: ?usize, root: std.Progress.Node) !f32 {
    const max_size = cancel_size orelse std.math.maxInt(usize);
    const node = root.startFmt(max_size/1024, "downloading `{s}`", .{ url });
    defer node.end();


    // TODO: zig's TCP timeout is not yet implemented
    var req = try client.request(.GET, try std.Uri.parse(url), .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8*1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status == .not_found) return Error.NotFoundError;
    if (response.head.status != .ok) return Error.GeneralNetworkError;

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => client.allocator.alloc(u8, std.compress.zstd.default_window_len) catch @panic("OOM"),
        .deflate, .gzip => client.allocator.alloc(u8, std.compress.flate.max_window_len) catch @panic("OOM"),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    const length = (response.head.content_length orelse max_size);
    node.setEstimatedTotalItems(@min(length, max_size)/1024);

    const start_t = std.Io.Timestamp.now(io, .awake).toMicroseconds();
    var offset: usize = 0;
    while (offset < max_size) {
        io.checkCancel() catch break;
        const content = reader.take(64) catch |err| switch (err) {
            error.EndOfStream => {
                offset += try reader.streamRemaining(writer);
                break;
        },
            else => |e| return e,
        };
        try writer.writeAll(content[0..@min(content.len, max_size - offset)]);
        node.setCompletedItems(offset/1024);

        offset += content.len;
    }
    try writer.flush();
    const end_t = std.Io.Timestamp.now(io, .awake).toMicroseconds();

    const spd = @as(f32, @floatFromInt(offset))/@as(f32, @floatFromInt(end_t - start_t)) * std.time.us_per_s;
    return spd;
}

fn verify_tarball(
    tarball_f: Io.File,
    sig: minizign.Signature, gpa: Allocator, root: std.Progress.Node) !void {

    const verify_node = root.startFmt(1, "Verifying", .{});
    defer verify_node.end();
    try pk.verifyFile(gpa, io, tarball_f, sig, null);
}

fn decompress_tarball(tarball_path: []const u8, tarball_f: Io.File, gpa: Allocator, root: std.Progress.Node) !void {
    const node = root.startFmt(1, "Decompressing {s}", .{ tarball_path });
    defer node.end();

    var buf: [1024]u8 = undefined;
    var reader = tarball_f.reader(io, &buf);


    const ext = std.fs.path.extension(tarball_path);
    const base = std.fs.path.basename(tarball_path);
    if (std.mem.eql(u8, ext, ".xz")) {
        assert(std.mem.eql(u8, std.fs.path.extension(base), ".tar"));

        var xz = try std.compress.xz.Decompress.init(&reader.interface , gpa, gpa.alloc(u8, 1024) catch @panic("OOM"));
        defer xz.deinit();

        try std.tar.extract(io, db.installation_dir, &xz.reader, .{});
    } else if (std.mem.eql(u8, ext, ".zip"))  {
        try std.zip.extract(db.installation_dir, &reader, .{});
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

pub fn print(comptime fmt: []const u8, args: anytype) void {
    stdout.print(fmt, args) catch unreachable;
}

pub var stdin: *Io.Reader = undefined;
pub var stdout: *Io.Writer = undefined;
pub var io: Io = undefined;

pub fn ask_for_yes(comptime fmt: []const u8, args: anytype) bool {
    print(fmt ++ "\n", args);
    print("y[es], n[o]? ", .{});
    stdout.flush() catch unreachable;
    var buf: [32]u8 = undefined;
    var yes_or_no = stdin.takeDelimiterExclusive('\n') catch |e| {
        if (e == error.StreamTooLong) return ask_for_yes(fmt, args);
        std.log.err("{}: you mean no? fine.", .{e});
        return false;
    };
    // on windows, newlien is \r\n
    if (yes_or_no.len > 0 and yes_or_no[yes_or_no.len - 1] == '\r')  yes_or_no = yes_or_no[0..yes_or_no.len-1];
    const lower = std.ascii.lowerString(&buf, yes_or_no);
    if (std.mem.eql(u8, lower, "y") or std.mem.eql(u8, lower, "yes")) return true;
    if (std.mem.eql(u8, lower, "n") or std.mem.eql(u8, lower, "no")) return false;
    return ask_for_yes(fmt, args);
}

pub fn path_resolve(arena: Allocator, paths: []const []const u8) []const u8 {
    return std.fs.path.resolve(arena, paths) catch @panic("OOM");
}

pub fn main(init: std.process.Init) !void {
    var gpa = init.gpa;
    io = init.io;
    var stdin_buf: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    stdin = &stdin_reader.interface;

    var stdout_buf: [64]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout = &stdout_writer.interface;
    defer stdout.flush() catch unreachable;


    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const env = init.environ_map;
    db.detect_zvm_installation(env, arena);

    var args = init.minimal.args.iterateAllocator(gpa) catch @panic("OOM");
    defer args.deinit();
    const prog_path = args.next().?;

    const self_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_path);
    const self_path_base = std.fs.path.basename(self_path);
    log.debug("prog: {s} ({s})", .{ prog_path, self_path });

    const is_shim = std.mem.eql(u8, self_path_base, std.fs.path.basename(db.ZIG_PATH));
    db.init(io, if (!is_shim) self_path else null);
    defer db.deinit() catch |e| fatal("failed to commit changes: {}", .{e});
    if (is_shim) {
        const installed_name = db.use_file.data;
        const zig_path = std.fs.path.resolve(arena, &.{ db.zvm_path, db.INSTALLATION_PATH, installed_name, "zig" }) catch @panic("OOM");

        var zig_args = std.ArrayList([]const u8).initCapacity(arena, init.minimal.args.vector.len) catch @panic("OOM");
        zig_args.appendAssumeCapacity(zig_path);
        while (args.next()) |arg| {
            zig_args.appendAssumeCapacity(arg);
        }
        // init.minimal.args.vector
        var zig = std.process.spawn(io, .{
            .argv = zig_args.items,
        }) catch |e| fatal("cannot spawn `{s}` as shim: {}", .{ zig_path, e });
        _ = zig.wait(io) catch {};
        return ;
    }

    //
    // cli
    //
    var opts: Options = undefined;
    var arg_parser = Cli.ArgParser{};
    arg_parser.init(gpa, prog_path, std.fmt.comptimePrint("zig package manager {f}", .{VERSION}));
    defer arg_parser.deinit();

    // `add` command that adds a local folder to the list of installation
    const release_cmd =
        arg_parser.sub_command("release", "(fetch and) list the currently avaiable releases")
            .add_opt(bool, &opts.fetch, .{ .just = &false }, .{ .prefix = "--fetch" }, "", "update the db.index of releases")
            .add_opt(?[]const u8, &opts.release.name, .{ .just = &null }, .positional, "<release-name>", "print details for this specific release");

    const install_cmd =
        arg_parser.sub_command("install", "install a release")
            .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the releaset to download, see `zvm list`")
            .add_opt(?[]const u8, &opts.install.mirror, .{ .just = &null }, .{ .prefix = "--mirror" }, "<mirror>", "the mirror to use")
            .add_opt(bool, &opts.fetch, .{ .just = &false }, .{ .prefix = "--fetch" }, "<seconds>", "fetch the latest db.index and mirrors before install")
            .add_opt(i64, &opts.install.timeout, .{ .just = &5 }, .{ .prefix = "--timeout" }, "", "the timeout to use for testing speed in mirrors (experimental)");

    const uninstall_cmd =
        arg_parser.sub_command("uninstall", "uninstall a release")
            .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the releaset to uninstall, see `zvm list`");

    const mirror_cmd =
        arg_parser.sub_command("mirror", "fetch and list all the known mirrors")
            .add_opt(bool, &opts.fetch, .{ .just = &false }, .{ .prefix = "--fetch" }, "", "update the list of mirror");

    const list_cmd = arg_parser.sub_command("list", "list all current installation")
        .add_opt(bool, &opts.list.validate, .{ .just = &false }, .{ .prefix = "--validate" }, "", "tries to verify the list of installation");
    // list_cmd.add_opt(bool, &opts.list.valididate, &false, .{.prefix = "--valid"}, "validate and fix the current installation", a);

    const use_cmd =
        arg_parser.sub_command("use", "use an installation")
            .add_opt([]const u8, &opts.install.release, .none, .positional, "<release>", "the release to use");

    const add_cmd =
        arg_parser.sub_command("add", "add a manually donwloaded tarball to the list of installations")
            .add_opt([]const u8, &opts.add.path, .none, .positional, "<path>", "the path to add");

    const nuke_cmd =
        arg_parser.sub_command("nuke", "nuke the whole zvm installation");

    arg_parser.add_opt_global(?[]const u8, &opts.platform, .{ .just = &null }, .{ .prefix = "--platform" }, "<platform-double>", "specify the platform to download from, such as `x86_64-linux. defaults to the platform zvm is running on`");

    try arg_parser.parse(&args);

    if (arg_parser.root_command.occur) {
        arg_parser.print_help();
        return;
    }
    const is_master = std.mem.eql(u8, opts.install.release, "master");

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

    const prog_root = std.Progress.start(io, .{});
    defer prog_root.end();


    db.fetch_if_force_or_empty(&client, opts.fetch);
    // TOOD: rollback changes if any error occur

    // // this does not work, likely because of bug https://github.com/ziglang/zig/issues/19878
    // try client.initDefaultProxies(arena);
    // log.info("using proxy from env: {s}:{}", .{client.https_proxy.?.host, client.https_proxy.?.port});
    // assert((try client.fetch(.{.location = .{.url = "http://github.com"}})).status == .ok);
    http_proxy = env.get("HTTP_PROXY") orelse env.get("http_proxy");
    https_proxy = env.get("HTTPS_PROXY") orelse env.get("https_proxy");

    //
    // detect the current platform
    //
    const double_str = opts.platform 
        orelse allocPrint(arena, "{s}-{s}", .{ @tagName(builtin.cpu.arch), @tagName(builtin.target.os.tag) });
    log.info("Platform: {s}", .{double_str});
    // for `install`, this is the release to

    print("\n====================\n\n", .{});
    // handle different command
    if (mirror_cmd.occur) {
        var mirror_it = db.mirror_file.data.iterator();
        while (mirror_it.next()) |mirror| {
            print("{s}\n", .{mirror.key_ptr.*});
        }
        return;
    } else if (list_cmd.occur) {
        if (opts.list.validate) {
            print("Valiating zig instsallation...\n", .{});
            var real_installed = std.StringArrayHashMapUnmanaged(void).empty;
            errdefer real_installed.deinit(gpa);
            var should_overwrite = false;

            var installed_it = db.installation_dir.iterate();
            while (try installed_it.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                if (db.installed_file.data.get(entry.name) == null) {
                    log.err("direcotry `{s}` does not exist in the list of installation", .{ entry.name });
                    if (ask_for_yes("Do you want to add `{s}` to the list of installation", .{ entry.name })) {
                        should_overwrite = true;
                        real_installed.putNoClobber(arena, entry.name, {}) catch @panic("OOM");
                    }
                } else {
                    real_installed.putNoClobber(arena, entry.name, {}) catch @panic("OOM");
                }
            }

            var it = db.installed_file.data.iterator();
            while (it.next()) |item| {
                if (real_installed.get(item.key_ptr.*) == null) {
                    log.err("entry `{s}` does not actually exist, deleting it from the list of installations", .{ item.key_ptr.* });
                    should_overwrite = true;
                }
            }

            if (should_overwrite) {
                db.installed_file.overwrite_with(real_installed);
                print("Overwriting existing list, new list:\n", .{});
            } else {
                print("Everything seems fine.\n", .{});
            }
            print("\n", .{});
        }
        var it = db.installed_file.data.iterator();
        print("installed zig: {}\n", .{db.installed_file.data.count()});
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
        const installed_name = allocPrint(arena, "zig-{s}-{s}", .{ double_str, if (is_master) db.master_file.data else opts.install.release });
        if (db.installed_file.data.get(installed_name) == null)
            fatal("{s} is not installed", .{installed_name});
        if (std.mem.eql(u8, db.use_file.data, installed_name)) {
            print("{s} already in use\n", .{installed_name});
        }

        db.use_file.overwrite(installed_name);
        print("{s} up and running!\n", .{ installed_name });
        return;
    } else if (uninstall_cmd.occur) {
        const installed_name = allocPrint(gpa, "zig-{s}-{s}", .{ double_str, if (is_master) db.master_file.data else opts.install.release });
        defer gpa.free(installed_name);

        if (db.installed_file.data.get(installed_name) == null)
            fatal("{s} is not installed", .{installed_name});
        if (!ask_for_yes("removing installation {s}", .{installed_name})) return;
        db.installation_dir.deleteTree(io, installed_name) catch |e| {
            log.err("{}: failed to delete installation {s}", .{ e, installed_name });
            return e;
        };
        _ = db.installed_file.data.swapRemove(installed_name);

        if (std.mem.eql(u8, db.use_file.data, installed_name)) {
            log.info("{s} is no longer in use", .{db.use_file.data});
            // db.zvm_dir.deleteFile(io, "zig") catch {};
            // db.use_file.clear();
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
                if (db.installed_file.data.get(folder_name)) |_|
                    fatal("{s} already existed as an installation", .{folder_name});
                try decompress_tarball(opts.add.path, f, gpa, prog_root);
                break :blk folder_name;
            },
            .directory => blk: {
                if (db.installed_file.data.get(basename)) |_|
                    fatal("{s} already existed as an installation", .{opts.add.path});
                try std.Io.Dir.renameAbsolute(opts.add.path, try std.fs.path.resolve(arena, &.{ db.zvm_path, basename }), io);
                break :blk basename;
            },
            else => {
                fatal("<path> ({s}) must be either a tar file or a directory", .{opts.add.path});
            },
        };
        db.installed_file.data.putNoClobber(db.arena, installed_name, {}) catch unreachable;
        return;
    } else if (install_cmd.occur) {
        const latest_master = db.index.map.get("master").?.version;
        const installed_name = allocPrint(arena, "zig-{s}-{s}", .{ double_str, if (is_master) latest_master else opts.install.release });

        const install_node = prog_root.startFmt(4, "Installing {s}", .{ installed_name });
        defer install_node.end();
        if (db.installed_file.data.get(installed_name)) |_| {
            print("{s} is already installed, do `zvm use {s}` to use it\n", .{ installed_name, opts.install.release });
            return;
        }
        // if we are install a master, and there is a master already installed, that this different from the latest master.
        if (is_master and db.master_file.data.len != 0) {
            if (std.mem.eql(u8, db.master_file.data, latest_master)) @panic("Something went wrong: the latest master should not have been installed.");
            if (!ask_for_yes("Trying to installed latest master {s}, but master {s} already installed, do you want to overwiter it?", .{ latest_master, db.master_file.data })) return;
        }

        const release = db.index.map.get(opts.install.release) orelse {
            log.err("Unknown release {s}", .{opts.install.release});
            print_list_of_releases();
            std.process.abort();
        };

        const download = release.platforms.get(double_str) orelse
            fatal("No {s} found for {s}, run `zvm release {s}` to see the available platform.", .{ double_str, double_str, opts.install.release });
        const tarball_size = std.fmt.parseInt(usize, download.size, 10) catch unreachable;

        print("tarball: {s}, size: {}\n", .{download.tarball, tarball_size});

        // get the last component of tarball, i.e. the name of the tarball
        const path = blk: {
            const tarball_uri = try std.Uri.parse(download.tarball);
            var alloc_writer = Io.Writer.Allocating.init(gpa);
            defer alloc_writer.deinit();
            try tarball_uri.path.formatPath(&alloc_writer.writer);
            break :blk try alloc_writer.toOwnedSlice();
        };
        defer gpa.free(path);

        const tarball_name = std.fs.path.basename(path);

        var sig = blk: {
            const sig_url = if (!is_master)
                    allocPrint(arena, "{s}/{s}/{s}.minisig", .{ db.OFFICIAL_DOWNLOAD, opts.install.release, tarball_name })
                else
                    allocPrint(arena, "{s}/{s}.minisig", .{ db.OFFICIAL_BUILDS, tarball_name });

            log.debug("signature url: {s}", .{sig_url});

            const sig_node = install_node.startFmt(2, "Verifying {s}", .{ tarball_name });
            defer sig_node.end();
            var sig_writer = Io.Writer.Allocating.init(gpa);
            defer sig_writer.deinit();
            _ = download_to_writer(&client, sig_url, &sig_writer.writer, null, sig_node) catch |e| {
                switch (e) {
                    Error.NotFoundError =>
                        log.err("the signature file does not exist at `{s}`, probably because you are downloading a non-release build that is not the latest, try rerun with `--fetch`", .{ sig_url }),
                    else => {},
                }
                return e;
            };
            break :blk try minizign.Signature.decode(gpa, sig_writer.written());
        };
        defer sig.deinit();

        const tarball_path = std.fs.path.resolve(gpa, &.{ db.temp_folder_path, tarball_name }) catch @panic("OOM");
        defer gpa.free(tarball_path);

        const throughput_list: []const EndpointThroughput = if (opts.install.mirror) |mirror|
            &.{ EndpointThroughput { .spd = 100 , .url = allocPrint(arena, "{s}/{s}", .{ mirror, tarball_name }) } }
        else
            test_fastest_mirror(&client, tarball_name, opts.install.timeout, arena, install_node);
        // const latencies_sorted: []const Latency = if (opts.install.mirror) |mirror| &.{.{ @as(i64, 0), mirror }} else test_fastest_mirror(&client, gpa);
        // defer if (latencies_sorted.len > 1) gpa.free(latencies_sorted);

        log.debug("tarbal path: {s}", .{ tarball_path });
        var tarball_f = try Io.Dir.createFileAbsolute(io, tarball_path, .{ .truncate = true, .read = true });
        defer tarball_f.close(io);

        var first_time = true;
        for (throughput_list) |item| {
            log.info("{s}, speed: {} MB/s", .{ item.url, item.spd/(1<<20) });
            if (item.spd == 0) {
                log.err("cannot download from `{s}`, skipping.", .{ item.url });
                continue;
            }
            if (!first_time and !ask_for_yes("do you want to proceed with next mirror", .{})) { // skip?
                return;
            }
            first_time = false;
            //
            // Download zig
            //
            _ = download_to_file(&client, item.url, tarball_f, null, install_node) catch |e| {
                switch (e) {
                    Error.NotFoundError => log.err("this specific mirror does not have this release", .{}),
                    else => log.err("cannot fetch `{s}`: {}", .{ item.url, e }),
                }
                continue;
            };
            break;
        } else {
            fatal("no mirror left to proceed, something went terribly wrong", .{});
        }


        // Verify tarball
        //
        verify_tarball(tarball_f, sig, gpa, install_node) catch |e|
            fatal("{} failed to verify signature of {s}, potentially dangerous source", .{ e, tarball_path });

        //
        // Decompress tarball
        //
        try decompress_tarball(tarball_path, tarball_f, gpa, install_node);
        install_node.completeOne();
        try Io.Dir.deleteFileAbsolute(io, tarball_path);

        if (is_master) {
            const master_locked_installed_name = allocPrint(arena, "zig-{s}-{s}", .{ double_str, db.master_file.data });
            try db.zvm_dir.deleteTree(io, master_locked_installed_name);
            db.master_file.overwrite(latest_master);
        }

        try db.installed_file.data.putNoClobber(db.arena, installed_name, {});

        print("{s} installed! run `zvm use` to use it", .{installed_name});
    } else unreachable;
}
