const std = @import("std");
const spoon = @import("spoon");
const mem = std.mem;
const os = std.os;

var term: spoon.Term = undefined;

const legacy_input = false;

const Cursor = struct { x: usize, y: usize };

pub fn main() !void {
    term = spoon.Term{};
    try term.init(.{});
    defer term.deinit();
    try term.uncook(.{
        .request_mouse_tracking = true,
        .request_kitty_keyboard_protocol = !legacy_input,
    });

    try term.fetchSize();
    try term.setWindowTitle("minesvipser", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var grid = try Grid.init(10, 10, alloc);
    defer grid.deinit();

    try grid.placeBomb(0, 0);
    try grid.placeBomb(5, 5);
    try grid.placeBomb(2, 2);
    try grid.placeBomb(5, 3);
    try grid.placeBomb(2, 4);
    try grid.placeBomb(2, 3);
    try grid.placeBomb(3, 2);

    var fds: [1]os.pollfd = undefined;
    fds[0] = .{
        .fd = term.tty.?,
        .events = os.POLL.IN,
        .revents = undefined,
    };

    var running = true;
    var lost = false;

    var cursor: ?Cursor = null;

    while (running) {
        var render = try term.getRenderContext();
        try render.clear();
        try render.moveCursorTo(0, 0);
        try render.setAttribute(spoon.Attribute{ .bg = .white });

        if (!lost) {
            try grid.render(&render);

            if (try grid.hasWon()) {
                try render.setAttribute(spoon.Attribute{ .bold = true });
                try render.writeAllWrapping("\r\nYou won!");
                running = false;
            }
        } else {
            try grid.renderLost(&render);

            try render.setAttribute(spoon.Attribute{ .bold = true });
            try render.writeAllWrapping("\r\nYou lost!");
            running = false;
        }

        if (cursor) |m| {
            try render.moveCursorTo(m.y, m.x);
            try render.showCursor();
        } else {
            try render.hideCursor();
        }

        try render.done();

        var buf: [128]u8 = undefined;
        _ = try os.poll(&fds, -1);
        const read = try term.readInput(&buf);
        var it = spoon.inputParser(buf[0..read]);

        while (it.next()) |in| {
            switch (in.content) {
                .mouse => |m| {
                    if (m.button != .release) {
                        cursor = .{
                            .x = m.x,
                            .y = m.y,
                        };
                    }
                },
                else => {
                    if (in.eqlDescription("escape")) {
                        cursor = null;
                    } else if (in.eqlDescription("q") or in.eqlDescription("C-c")) {
                        running = false;
                    } else if (in.eqlDescription("space") or in.eqlDescription("enter")) {
                        if (cursor) |m| {
                            grid.click(m.x, m.y) catch |e| switch (e) {
                                error.Explode => {
                                    lost = true;
                                },
                                else => return e,
                            };
                        }
                    } else if (in.eqlDescription("f")) {
                        if (cursor) |m| {
                            try grid.flag(m.x, m.y);
                        }
                    } else if (in.eqlDescription("A-f")) {
                        if (cursor) |m| {
                            try grid.unflag(m.x, m.y);
                        }
                    } else if (in.eqlDescription("arrow-left")) {
                        if (cursor) |*m| {
                            m.x -|= 1;
                        } else cursor = .{ .x = 0, .y = 0 };
                    } else if (in.eqlDescription("arrow-right")) {
                        if (cursor) |*m| {
                            m.x += 1;
                        } else cursor = .{ .x = 0, .y = 0 };
                    } else if (in.eqlDescription("arrow-up")) {
                        if (cursor) |*m| {
                            m.y -|= 1;
                        } else cursor = .{ .x = 0, .y = 0 };
                    } else if (in.eqlDescription("arrow-down")) {
                        if (cursor) |*m| {
                            m.y += 1;
                        } else cursor = .{ .x = 0, .y = 0 };
                    }
                },
            }

            if (cursor) |*c| {
                grid.keepCursorInBounds(c);
            }
        }
    }
}

pub const bomb: u8 = 255;

const Grid = struct {
    width: usize,
    bytes: []u8,
    mask: []MaskEntry,
    alloc: mem.Allocator,

    pub const MaskEntry = enum(u2) {
        hidden,
        flagged,
        shown,
    };

    const Self = @This();
    pub fn init(width: usize, height: usize, alloc: mem.Allocator) !Self {
        var bytes = try alloc.alloc(u8, width * height);
        var mask = try alloc.alloc(MaskEntry, width * height);

        mem.set(u8, bytes, 0);
        mem.set(MaskEntry, mask, .hidden);

        return .{
            .bytes = bytes,
            .mask = mask,
            .width = width,
            .alloc = alloc,
        };
    }
    pub fn deinit(self: Self) void {
        self.alloc.free(self.mask);
        self.alloc.free(self.bytes);
    }
    pub fn render(self: *Self, ctx: *spoon.Term.RenderContext) !void {
        var heightIndex: usize = 0;
        while (heightIndex < self.bytes.len) : (heightIndex += self.width) {
            var offset: usize = 0;
            while (offset < self.width) : (offset += 1) {
                switch (self.mask[heightIndex + offset]) {
                    .hidden => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .bright_white });
                        try ctx.writeAllWrapping(" ");
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .flagged => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                        try ctx.writeAllWrapping("F");
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .shown => {
                        const byte = self.bytes[heightIndex + offset];
                        const char = switch (byte) {
                            0 => ' ',
                            1...8 => |b| '0' + b,
                            bomb => 'o',
                            else => unreachable,
                        };
                        try ctx.writeAllWrapping(&[_]u8{char});
                    },
                }
            }
            try ctx.writeAllWrapping("\r\n");
        }
    }
    pub fn renderLost(self: *Self, ctx: *spoon.Term.RenderContext) !void {
        var heightIndex: usize = 0;
        while (heightIndex < self.bytes.len) : (heightIndex += self.width) {
            var offset: usize = 0;
            while (offset < self.width) : (offset += 1) {
                const byte = self.bytes[heightIndex + offset];

                switch (self.mask[heightIndex + offset]) {
                    .flagged => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                        if (byte == bomb) {
                            try ctx.writeAllWrapping("F");
                        } else {
                            try ctx.writeAllWrapping("x");
                        }
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .hidden, .shown => {
                        const char = switch (byte) {
                            0 => ' ',
                            1...8 => |b| '0' + b,
                            bomb => 'O',
                            else => unreachable,
                        };
                        try ctx.writeAllWrapping(&[_]u8{char});
                    },
                }
            }
            try ctx.writeAllWrapping("\r\n");
        }
    }
    pub fn placeBomb(self: *Self, x: usize, y: usize) !void {
        const index = try self.getIndex(x, y);

        if (self.bytes[index] == bomb) return error.AlreadyBomb;

        self.bytes[index] = bomb;
        self.increment(x +% 1, y -% 1) catch {};
        self.increment(x, y -% 1) catch {};
        self.increment(x -% 1, y -% 1) catch {};
        self.increment(x +% 1, y) catch {};
        self.increment(x -% 1, y) catch {};
        self.increment(x +% 1, y +% 1) catch {};
        self.increment(x, y +% 1) catch {};
        self.increment(x -% 1, y +% 1) catch {};
    }
    pub fn flag(self: *Self, x: usize, y: usize) !void {
        const index = try self.getIndex(x, y);

        if (self.mask[index] != .hidden) return;
        self.mask[index] = .flagged;
    }
    pub fn unflag(self: *Self, x: usize, y: usize) !void {
        const index = try self.getIndex(x, y);

        if (self.mask[index] != .flagged) return;
        self.mask[index] = .hidden;
    }
    pub fn click(self: *Self, x: usize, y: usize) !void {
        const index = try self.getIndex(x, y);

        if (self.mask[index] != .hidden) return;
        if (self.bytes[index] == bomb) return error.Explode;

        self.mask[index] = .shown;
        if (self.bytes[index] == 0) {
            self.click(x +% 1, y -% 1) catch {};
            self.click(x, y -% 1) catch {};
            self.click(x -% 1, y -% 1) catch {};
            self.click(x +% 1, y) catch {};
            self.click(x -% 1, y) catch {};
            self.click(x +% 1, y +% 1) catch {};
            self.click(x, y +% 1) catch {};
            self.click(x -% 1, y +% 1) catch {};
        }
    }
    pub fn hasWon(self: *Self) !bool {
        for (self.bytes) |b, i| {
            const isShown = self.mask[i] == .shown;
            const isBomb = b == bomb;
            if (!isBomb and !isShown) return false;
        }
        return true;
    }
    pub fn keepCursorInBounds(self: *const Self, cursor: *Cursor) void {
        if (cursor.x >= self.width) cursor.x = self.width - 1;
        if (cursor.y >= self.bytes.len/self.width) cursor.y = self.bytes.len/self.width-1;
    }
    inline fn increment(self: *Self, x: usize, y: usize) !void {
        const index = try self.getIndex(x, y);

        if (self.bytes[index] < 9) {
            self.bytes[index] += 1;
        }
    }
    inline fn getIndex(self: *Self, x: usize, y: usize) !usize {
        if (x >= self.width) return error.XBiggerThanWidth;
        const index = x + y *% self.width;
        if (index >= self.bytes.len) return error.YBiggerThanHeight;
        return index;
    }
};

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    term.cook() catch {};
    std.builtin.default_panic(msg, trace, ret_addr);
}
