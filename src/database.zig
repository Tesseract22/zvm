//! Package Database
//! These are the files used for persistent storage, typically placed in "~/.zvm"
const IS_WINDOW = @import("builtin").target.os.tag == .windows;
pub var temp_folder_path: []const u8 = undefined; // $init_on_main
pub const ENV_HOME = if (IS_WINDOW) "HOMEPATH" else "HOME";

pub const ZVM_STORAGE_PATH = ".zvm";
/// - INDEX: json of the releases of zig, and its url, etc.
const INDEX_PATH = "INDEX";
/// - INSTALLED: existing zig installations on each line,  e.g.
///    zig-x86_64-linux-0.16.0-dev.3153+d6f43caad
///    zig-x86_64-linux-0.15.2
///   The implies there should be folder named `zig-x86_64-linux-0.16.0-dev.3153+d6f43caad` and `zig-x86_64-linux-0.15.2` in ~/.zvm
const INSTALLED_PATH = "INSTALLED";
/// - master: the git commit of the current master
const MASTER_PATH = "MASTER";
/// - use: the current activated installation
const USE_PATH = "USE";
/// - zig: symbolic link to the zig executable in the activated installation. User would put set PATH to ~/.zvm, and then `zig` should refer to ~/.zvm/zig
pub const ZIG_PATH = "bin/" ++ if (IS_WINDOW) "zig.exe" else "zig";
/// mirror: the list of available mirrors
const MIRROR_PATH = "MIRROR";
/// - installation/: zig-* goes in here
pub const INSTALLATION_PATH = "installaiton/";

const std = @import("std");
const json = std.json;
const log = std.log;
const assert = std.debug.assert;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;
const Io = std.Io;

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
    UnknownRelease,
    UnknownPlatform,
    DownloadError,
    DecompressionError,
    SignatureError,
    NetworkError,
};

pub fn FileBuffer(comptime T: type) type {
    return struct {
        file: Io.File,
        data: T,

        const Self = @This();
        const MAX_FETCH_SIZE = 1024 * 100;
        pub fn init(name: []const u8) Self {
            const file = zvm_dir.createFile(io, name, .{ .truncate = false, .read = true, .lock = .exclusive })
                catch |e| fatal("{}: cannot create file: {s}/{s}", .{ e, ZVM_STORAGE_PATH, name });
            const data: T = switch (T) {
                []const u8 => &.{},
                std.StringArrayHashMapUnmanaged(void) => .empty,
                else => unreachable,
            };
            var res = Self{ .file = file, .data = data };
            res.refresh();
            return res;
        }

        pub fn init_to(name: []const u8, to: *Self) void {
            to.* = Self.init(name);
        }

        pub fn fetch(self: *Self, url: []const u8, client: *std.http.Client) !void {
            log.info("fetching: {s}", .{url});
            var buf: [MAX_FETCH_SIZE]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            const resp = try client.fetch(.{
                .location = .{ .url = url },
                .response_writer = &writer,
            });
            if (resp.status != .ok) return Error.NetworkError;
            self.overwrite(try arena.dupe(u8, writer.buffered()));
        }

        pub fn fetch_if_empty_or_force(self: *Self, url: []const u8, client: *std.http.Client, force_fetch: bool) !void {
            const stat = try self.file.stat(io);
            if (force_fetch or stat.size == 0) return self.fetch(url, client);
        }

        pub fn commit(self: *Self) !void {
            switch (T) {
                []const u8 => {
                    var buf: [64]u8 = undefined;
                    var writer = self.file.writer(io, &buf);
                    try writer.seekTo(0);
                    try self.file.setLength(io, 0);
                    try writer.interface.writeAll(self.data);
                    try writer.flush();

                },
                std.StringArrayHashMapUnmanaged(void) => {
                    var buf: [64]u8 = undefined;
                    var writer = self.file.writer(io, &buf);
                    try writer.seekTo(0);
                    try self.file.setLength(io, 0);

                    var it = self.data.iterator();
                    while (it.next()) |entry| {
                        try writer.interface.writeAll(entry.key_ptr.*);
                        try writer.interface.writeAll("\n");
                        try writer.flush();
                    }
                },
                else => @compileError("Unsupported type: " ++ @typeName(T)),
            }
            self.file.close(io);
        }

        pub fn clear(self: *Self) void {
            self.overwrite(&.{});
        }

        pub fn refresh(self: *Self) void {
            var buf: [256]u8 = undefined;
            var reader = self.file.reader(io, &buf);
            const content = reader.interface.allocRemaining(arena, .unlimited) catch @panic("OOM");
            self.overwrite(content);
        }

        pub fn overwrite_with(self: *Self, new: T) void {
            self.data = new;
        }

        pub fn overwrite(self: *Self, new: []const u8) void {
            switch (T) {
                []const u8 => {
                    self.data = new;
                },
                std.StringArrayHashMapUnmanaged(void) => {
                    self.data.clearRetainingCapacity();
                    const count = blk: {
                        var lines = std.mem.tokenizeScalar(u8, new, '\n');
                        var count: usize = 0;
                        while (lines.next()) |_| {
                            count += 1;
                        }
                        break :blk count;
                    };
                    self.data.ensureTotalCapacity(arena, count) catch unreachable;
                    var lines = std.mem.tokenizeScalar(u8, new, '\n');
                    while (lines.next()) |line| {
                        if (self.data.fetchPut(arena, arena.dupe(u8, line) catch @panic("OOM"), {}) catch unreachable) |kv|
                            fatal("set contains duplicate entry: {s}, something went terribly wrong", .{kv.key});
                    }
                    assert(self.data.count() == count);

                },
                else => @compileError("Unsupported type: " ++ @typeName(T)),
            }
        }
    };
}

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

const Index = json.ArrayHashMap(Release);

pub const OFFICIAL_DOWNLOAD = "https://ziglang.org/download"; // the url directory for "releases". i.e. 0.15.2
pub const OFFICIAL_BUILDS = "https://ziglang.org/builds"; // the url directory for nightly builds

pub const FileBufferPlain = FileBuffer([]const u8);
pub const FileBufferSet = FileBuffer(std.StringArrayHashMapUnmanaged(void));
pub var index_file: FileBufferPlain = undefined; // $init_on_main
pub var index: Index = undefined; // $init_on_main
pub var installed_file: FileBufferSet = undefined; // $init_on_main
pub var master_file: FileBufferPlain = undefined; // $init_on_main
pub var use_file: FileBufferPlain = undefined; // $init_on_main
pub var mirror_file: FileBufferSet = undefined; // $init_on_main
// pub var zig_file: std.Io.File = undefined; // $init_on_main
pub var zvm_path: []const u8 = undefined; // $init_on_main
pub var zvm_dir: Io.Dir = undefined; // $init_on_main
pub var installation_dir: Io.Dir = undefined; // $init_on_main
pub var arena: std.mem.Allocator = undefined; // $init_on_main
pub var io: Io = undefined; // $init_on_main

const main = @import("main.zig");

pub fn detect_zvm_installation(env: *const std.process.Environ.Map, arena_allocator: Allocator) void {
    arena = arena_allocator;
    const home = env.get(ENV_HOME).?;
    zvm_path = std.fs.path.resolvePosix(arena, &.{ home, ZVM_STORAGE_PATH }) catch @panic("OOM");
    temp_folder_path =
    if (IS_WINDOW)
        std.fs.path.resolvePosix(arena, &.{ home, "AppData", "Local", "Temp" }) catch @panic("OOM")
    else
        "/tmp";
}

pub fn nuke() void {
    Io.Dir.cwd().deleteTree(io, zvm_path) catch |e| fatal("cannot delete directory {s}: {}", .{ zvm_path, e });
}

pub fn init(io_: Io, self_path_abs: ?[]const u8) void {
    io = io_;
    zvm_dir = Io.Dir.openDirAbsolute(io, zvm_path, .{ .iterate = true }) catch |e|
        if (e == error.FileNotFound) blk: {
            if (!main.ask_for_yes("zvm is going to create {s}. You can delete it anytime.", .{zvm_path})) return;
            Io.Dir.createDirAbsolute(io, zvm_path, .default_dir) catch fatal("cannot create directory \"{s}\"", .{zvm_path});
            break :blk std.Io.Dir.openDirAbsolute(io, zvm_path, .{ .iterate = true }) catch fatal("cannot open directory \"{s}\"", .{zvm_path});
        } else fatal("cannot open directory: {}", .{e});

    var group = std.Io.Group.init;

    installation_dir = zvm_dir.createDirPathOpen(io, INSTALLATION_PATH,
        .{ .open_options = .{ .iterate = true }, .permissions = .default_dir }) catch |e|
        fatal("cannot create {s}/{s}: {}", .{ zvm_path, INSTALLATION_PATH, e } );
    group.async(io, FileBufferPlain.init_to, .{ INDEX_PATH, &index_file });
    group.async(io, FileBufferPlain.init_to, .{ MASTER_PATH, &master_file });
    group.async(io, FileBufferPlain.init_to, .{ USE_PATH, &use_file });
    group.async(io, FileBufferSet.init_to, .{ INSTALLED_PATH, &installed_file });
    group.async(io, FileBufferSet.init_to, .{ MIRROR_PATH, &mirror_file });

    group.await(io) catch unreachable;

    if (self_path_abs) |self|
        Io.Dir.cwd().copyFile(self, zvm_dir, ZIG_PATH, io, .{ .make_path = true }) catch |e|
            fatal("cannot copy `{s}` to `{s}/{s}`: {}", .{ self, zvm_path, ZIG_PATH, e });
}

pub fn fetch_if_force_or_empty(client: *std.http.Client, fetch: bool) void {
    const fresh_index = if (index_file.fetch_if_empty_or_force(OFFICIAL_DOWNLOAD ++ "/index.json", client, fetch)) true else |e| fallback: {
        std.log.warn("failed to fetch index: {}", .{e});
        break :fallback false;
    };
    {
        var json_obj = json.Scanner.initCompleteInput(arena, index_file.data); // FIXME: do this need to have same lifetime as `index`?
        index = Index.jsonParse(arena, &json_obj, .{ .ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = 1024 }) catch |e| fallback: {
            std.log.debug("index buffer: {s}", .{index_file.data});
            std.log.err("unxpected error occur while parsing index: {}", .{e});
            if (fresh_index and !main.ask_for_yes("do you want to proceed with the original index?", .{})) {
                fatal("cannot pasrse zig index", .{});
            }
            json_obj.deinit();
            index_file.refresh();
            json_obj = json.Scanner.initCompleteInput(arena, index_file.data);
            break :fallback Index.jsonParse(arena, &json_obj, .{ .ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = 1024 }) catch |e2| fatal("cannot parse zig index: {}", .{e2});
        };
    }

    mirror_file.fetch_if_empty_or_force(OFFICIAL_DOWNLOAD ++ "/community-mirrors.txt", client, fetch) catch |e| {
        std.log.err("failed to fetch mirrors: {}", .{e});
        if (fresh_index and !main.ask_for_yes("do you want to proceed with the original mirrors?", .{})) {
            std.process.abort();
        }
        mirror_file.refresh();
    };
}

pub fn deinit() !void {
    zvm_dir.close(io);
    installation_dir.close(io);
    try index_file.commit();
    try installed_file.commit();
    try master_file.commit();
    try use_file.commit();
    try mirror_file.commit();
    // free_index(&index, a);
}
