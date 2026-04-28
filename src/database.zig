//! Package Database
//! These are the files used for persistent storage, typically placed in "~/.zvm"

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
const ZIG_PATH = "zig";
/// mirror: the list of available mirrors
const MIRROR_PATH = "MIRROR";
// - other directories: zig-*: zig installation

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

const FileBuffer = struct {
    file: Io.File,
    buf: []const u8,
    dirty: bool, // if dirty, commit will overwrite the file.

    const MAX_FETCH_SIZE = 1024 * 100;
    pub fn init(name: []const u8) FileBuffer {
        const file = zvm_dir.createFile(io, name, .{ .truncate = false, .read = true, .lock = .exclusive }) catch |e| fatal("{}: cannot create file: {s}/{s}", .{ e, ZVM_STORAGE_PATH, name });
        var res = FileBuffer{ .file = file, .buf = &.{}, .dirty = true };
        res.refresh();
        return res;
    }

    pub fn fetch(self: *FileBuffer, url: []const u8, client: *std.http.Client) !void {
        log.info("fetching: {s}", .{url});
        var buf: [MAX_FETCH_SIZE]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const resp = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
        });
        if (resp.status != .ok) return Error.NetworkError;
        self.overwrite(try arena.dupe(u8, writer.buffered()));
        self.dirty = true;
    }

    pub fn fetch_if_empty_or_force(self: *FileBuffer, url: []const u8, client: *std.http.Client, force_fetch: bool) !void {
        if (force_fetch or self.buf.len == 0) return self.fetch(url, client);
    }

    pub fn commit(self: *FileBuffer) !void {
        if (self.dirty) {
            var buf: [256]u8 = undefined;
            var writer = self.file.writer(io, &buf);
            try writer.seekTo(0);
            try self.file.setLength(io, 0);
            try writer.interface.writeAll(self.buf);
            try writer.flush();
        }
        self.file.close(io);
    }

    pub fn clear(self: *FileBuffer) void {
        self.buf = &.{};
        self.dirty = true;
    }

    pub fn refresh(self: *FileBuffer) void {
        if (self.dirty) {
            var buf: [256]u8 = undefined;
            var reader = self.file.reader(io, &buf);
            const content = reader.interface.allocRemaining(arena, .unlimited) catch @panic("OOM");
            self.buf = content;
            self.dirty = false;
        }
    }

    pub fn overwrite(self: *FileBuffer, new: []const u8) void {
        self.buf = new;
        self.dirty = true;
    }
};

pub const FileBufferSet = struct {
    const MAX_FETCH_SIZE = 2048;
    const SetError = error{
        DuplicateEntry,
    };
    file: Io.File,
    set: std.StringArrayHashMapUnmanaged(void),
    dirty: bool,

    pub fn init(name: []const u8) FileBufferSet {
        const file = zvm_dir.createFile(io, name, .{ .truncate = false, .read = true }) catch |e| fatal("{}: cannot create file: {s}/{s}", .{ e, ZVM_STORAGE_PATH, name });
        var res = FileBufferSet{
            .file = file,
            .set = .empty,
            .dirty = true,
        };
        res.refresh();
        return res;
    }

    pub fn refresh(self: *FileBufferSet) void {
        if (self.dirty) {
            var buf: [256]u8 = undefined;
            var reader = self.file.reader(io, &buf);
            const content = reader.interface.allocRemaining(arena, .unlimited) catch @panic("OOM");
            self.overwrite(content);
            self.dirty = false;
        }
    }

    pub fn overwrite(self: *FileBufferSet, buf: []const u8) void {
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
            if (self.set.fetchPut(arena, arena.dupe(u8, line) catch @panic("OOM"), {}) catch unreachable) |kv|
                fatal("set contains duplicate entry: {s}, something went terribly wrong", .{kv.key});
        }
        assert(self.set.count() == count);
        self.dirty = true;
    }

    pub fn overwrite_set(self: *FileBufferSet, new: std.StringArrayHashMapUnmanaged(void)) void {
        self.set.deinit(arena);
        self.set = new.clone(arena) catch @panic("OOM");
        self.dirty = true;
    }

    pub fn append_line(self: *FileBufferSet, buf: []const u8) !void {
        if (self.set.fetchPut(arena, try arena.dupe(u8, buf), {}) catch unreachable) |_| return SetError.DuplicateEntry;
        self.dirty = true;
    }

    pub fn remove(self: *FileBufferSet, key: []const u8) void {
        assert(self.set.swapRemove(key));
        self.dirty = true;
    }

    pub fn commit(self: *FileBufferSet) !void {
        if (self.dirty) {
            var buf: [256]u8 = undefined;
            var writer = self.file.writer(io, &buf);
            try writer.seekTo(0);
            try self.file.setLength(io, 0);

            var it = self.set.iterator();
            while (it.next()) |entry| {
                try writer.interface.writeAll(entry.key_ptr.*);
                try writer.interface.writeAll("\n");
            try writer.flush();
            }
        }
        self.file.close(io);
    }

    pub fn get(self: FileBufferSet, key: []const u8) bool {
        return self.set.get(key) != null;
    }

    pub fn fetch(self: *FileBufferSet, url: []const u8, client: *std.http.Client) !void {
        log.info("fetching: {s}", .{url});
        var buf: [MAX_FETCH_SIZE]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const resp = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
        });
        if (resp.status != .ok) return Error.NetworkError;
        self.overwrite(try arena.dupe(u8, writer.buffered()));
        self.dirty = true;
    }

    pub fn fetch_if_empty_or_force(self: *FileBufferSet, url: []const u8, client: *std.http.Client, force_fetch: bool) !void {
        if (force_fetch or self.set.count() == 0) return self.fetch(url, client);
    }
};

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

const OFFICIAL_DOWNLOAD = "https://ziglang.org/download"; // the url directory for "releases". i.e. 0.15.2
const OFFICIAL_BUILDS = "https://ziglang.org/builds"; // the url directory for nightly builds

pub var index_file: FileBuffer = undefined; // $init_on_main
pub var index: Index = undefined; // $init_on_main
pub var installed_file: FileBufferSet = undefined; // $init_on_main
pub var master_file: FileBuffer = undefined; // $init_on_main
pub var use_file: FileBuffer = undefined; // $init_on_main
pub var mirror_file: FileBufferSet = undefined; // $init_on_main
// pub var zig_file: std.Io.File = undefined; // $init_on_main
pub var zvm_path: []const u8 = undefined; // $init_on_main
pub var zvm_dir: Io.Dir = undefined; // $init_on_main
pub var arena: std.mem.Allocator = undefined; // $init_on_main
pub var io: Io = undefined; // $init_on_main

const main = @import("main.zig");

pub fn detect_zvm_installation(env: *const std.process.Environ.Map, arena_allocator: Allocator) void {
    arena = arena_allocator;
    const home = env.get("HOME").?;
    zvm_path = std.fs.path.resolvePosix(arena, &.{ home, ZVM_STORAGE_PATH }) catch @panic("OOM");
}

pub fn nuke() void {
    Io.Dir.cwd().deleteTree(io, zvm_path) catch |e| fatal("cannot delete directory {s}: {}", .{ zvm_path, e });
}

pub fn init(io_: Io, fetch: bool, client: *std.http.Client) void {
    io = io_;
    zvm_dir = Io.Dir.openDirAbsolute(io, zvm_path, .{ .iterate = true }) catch |e|
        if (e == error.FileNotFound) blk: {
            if (!main.ask_for_yes("zvm is going to create {s}. You can delete it anytime.", .{zvm_path})) return;
            Io.Dir.createDirAbsolute(io, zvm_path, .default_dir) catch fatal("cannot create directory \"{s}\"", .{zvm_path});
            break :blk std.Io.Dir.openDirAbsolute(io, zvm_path, .{ .iterate = true }) catch fatal("cannot open directory \"{s}\"", .{zvm_path});
        } else fatal("cannot open directory: {}", .{e});

    index_file = .init(INDEX_PATH);
    installed_file = .init(INSTALLED_PATH);
    master_file = .init(MASTER_PATH);
    use_file = .init(USE_PATH);
    mirror_file = .init(MIRROR_PATH);

    const fresh_index = if (index_file.fetch_if_empty_or_force(OFFICIAL_DOWNLOAD ++ "/index.json", client, fetch)) true else |e| fallback: {
        std.log.warn("failed to fetch index: {}", .{e});
        break :fallback false;
    };
    {
        var json_obj = json.Scanner.initCompleteInput(arena, index_file.buf); // FIXME: do this need to have same lifetime as `index`?
        index = Index.jsonParse(arena, &json_obj, .{ .ignore_unknown_fields = true, .allocate = .alloc_always, .max_value_len = 1024 }) catch |e| fallback: {
            std.log.debug("index buffer: {s}", .{index_file.buf});
            std.log.err("unxpected error occur while parsing index: {}", .{e});
            if (fresh_index and !main.ask_for_yes("do you want to proceed with the original index?", .{})) {
                fatal("cannot pasrse zig index", .{});
            }
            json_obj.deinit();
            index_file.refresh();
            json_obj = json.Scanner.initCompleteInput(arena, index_file.buf);
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
    try index_file.commit();
    try installed_file.commit();
    try master_file.commit();
    try use_file.commit();
    try mirror_file.commit();
    // free_index(&index, a);
}
