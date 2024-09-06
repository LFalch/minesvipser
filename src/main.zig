const std = @import("std");
const spoon = @import("spoon");
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const fmt = std.fmt;

var term: spoon.Term = undefined;

const legacy_input = false;

const Cursor = struct { x: usize, y: usize };

pub fn main() !u8 {
    term_main() catch |e| {
        const stderr = std.io.getStdErr().writer();
        switch (e) {
            error.TooManyBombs => try stderr.print("Too many bombs for given grid size\n", .{}),
            error.TermTooSmall => try stderr.print("Terminal screen is too small for given grid size\n", .{}),
            error.InvalidCharacter => try stderr.print("Usage: {s} [width=8] [height=8] [bomb count=10]\n", .{os.argv[0]}),
            error.Overflow => try stderr.print("Argument was too big\n", .{}),
            error.OutOfMemory => try stderr.print("Ran out of memory allocating the grid\n", .{}),

            else => {
                try stderr.print("Unexpected error: {s}", .{@errorName(e)});
                return e;
            },
        }
        return 1;
    };

    return 0;
}

fn handleSigWinch(_: c_int) callconv(.C) void {
    term.fetchSize() catch {};
}

pub fn term_main() !void {
    const grid_w = if (os.argv.len > 1) try fmt.parseInt(usize, mem.span(os.argv[1]), 10) else 8;
    const grid_h = if (os.argv.len > 2) try fmt.parseInt(usize, mem.span(os.argv[2]), 10) else 8;
    const bombs = if (os.argv.len > 3) try fmt.parseInt(usize, mem.span(os.argv[3]), 10) else 10;

    if (bombs > grid_w * grid_h) return error.TooManyBombs;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var grid = try Grid.init(grid_w, grid_h, alloc);
    defer grid.deinit();

    {
        var rand = std.rand.DefaultPrng.init(@bitCast(std.time.timestamp()));
        var bombs_placed: usize = 0;
        while (bombs_placed < bombs) {
            const x = rand.random().intRangeAtMost(usize, 0, grid_w - 1);
            const y = rand.random().intRangeAtMost(usize, 0, grid_h - 1);
            grid.placeBomb(x, y) catch |e| switch (e) {
                error.AlreadyBomb => continue,
                else => return e,
            };

            bombs_placed += 1;
        }
    }

    term = spoon.Term{};
    try term.init(.{});
    defer term.deinit() catch {};
    try term.uncook(.{
        .request_mouse_tracking = true,
        .request_kitty_keyboard_protocol = !legacy_input,
    });

    try posix.sigaction(posix.SIG.WINCH, &posix.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.empty_sigset,
        .flags = 0,
    }, null);

    try term.fetchSize();
    if (term.width < grid_w or term.height < grid_h) return error.TermTooSmall;

    try term.setWindowTitle("minesvipser", .{});

    var fds: [1]posix.pollfd = undefined;
    fds[0] = .{
        .fd = term.tty.?,
        .events = posix.POLL.IN,
        .revents = undefined,
    };

    var running = true;
    var lost = false;
    var help = false;

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
            } else if (help) {
                help = false;
                try render.setAttribute(spoon.Attribute{ .fg = .bright_blue, .bold = true });
                try render.writeAllWrapping("\rPress q to quit, click or use arrow keys to move the cursor around. Press space or enter to reveal the space under the cursor.");
                try render.writeAllWrapping("\r\nPress f to set a flag, and t to set a question mark. If holding alt or ctrl, it instead removes it.");
            } else {
                try render.setAttribute(spoon.Attribute{ .fg = .bright_blue, .bold = true });
                try render.writeAllWrapping("\rPress ? or h for help");
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
        _ = try posix.poll(&fds, -1);
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
                            grid.click(m.x, m.y, true) catch |e| switch (e) {
                                error.Explode => {
                                    lost = true;
                                },
                                else => return e,
                            };
                        }
                    } else if (in.eqlDescription("f")) {
                        if (cursor) |m| {
                            try grid.flag(m.x, m.y, .set, .flagged);
                        }
                    } else if (in.eqlDescription("A-f") or in.eqlDescription("C-f") or in.eqlDescription("A-C-f")) {
                        if (cursor) |m| {
                            try grid.flag(m.x, m.y, .remove, .flagged);
                        }
                    } else if (in.eqlDescription("t")) {
                        if (cursor) |m| {
                            try grid.flag(m.x, m.y, .set, .maybe_flagged);
                        }
                    } else if (in.eqlDescription("A-t") or in.eqlDescription("C-t") or in.eqlDescription("A-C-t")) {
                        if (cursor) |m| {
                            try grid.flag(m.x, m.y, .remove, .maybe_flagged);
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
                    } else if (in.eqlDescription("?") or in.eqlDescription("h")) {
                        help = true;
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
    fields: []u8,
    mask: [*]u8,
    alloc: mem.Allocator,

    pub const MaskEntry = enum(u2) {
        hidden = 0,
        flagged = 1,
        shown = 2,
        maybe_flagged = 3,
    };

    fn mask_entry(self: *const Self, index: usize) MaskEntry {
        const array_index = index >> 2;
        // shift twice because we're moving two bits
        const sub_index: u3 = @as(u3, @truncate(index & 0b11)) << 1;
        return @enumFromInt((self.mask[array_index] >> sub_index) & 0b11);
    }
    fn set_mask_entry(self: *Self, index: usize, me: MaskEntry) void {
        const array_index = index >> 2;
        // shift twice because we're moving two bits
        const sub_index: u3 = @as(u3, @truncate(index & 0b11)) << 1;
        const mask: u8 = ~(@as(u8, 0b11) << sub_index);

        self.mask[array_index] &= mask;
        self.mask[array_index] |= @as(u8, @intFromEnum(me)) << sub_index;
    }
    inline fn mask_length(fields_len: usize) usize {
        return (fields_len >> 2) + ((fields_len & 1) | (fields_len & 2));
    }

    const Self = @This();
    pub fn init(width: usize, height: usize, alloc: mem.Allocator) !Self {
        const fields = try alloc.alloc(u8, width * height);
        @memset(fields, 0);

        const mask = try alloc.alloc(u8, mask_length(fields.len));
        @memset(mask, 0);

        return .{
            .fields = fields,
            .mask = mask.ptr,
            .width = width,
            .alloc = alloc,
        };
    }
    pub fn deinit(self: Self) void {
        self.alloc.free(self.mask[0..mask_length(self.fields.len)]);
        self.alloc.free(self.fields);
    }
    pub fn render(self: *Self, ctx: *spoon.Term.RenderContext) !void {
        var heightIndex: usize = 0;
        while (heightIndex < self.fields.len) : (heightIndex += self.width) {
            var offset: usize = 0;
            while (offset < self.width) : (offset += 1) {
                switch (self.mask_entry(heightIndex + offset)) {
                    .hidden => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .cyan });
                        try ctx.writeAllWrapping(" ");
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .maybe_flagged => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                        try ctx.writeAllWrapping("?");
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .flagged => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                        try ctx.writeAllWrapping("F");
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .shown => {
                        const field = self.fields[heightIndex + offset];
                        const char = switch (field) {
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
        while (heightIndex < self.fields.len) : (heightIndex += self.width) {
            var offset: usize = 0;
            while (offset < self.width) : (offset += 1) {
                const field = self.fields[heightIndex + offset];

                switch (self.mask_entry(heightIndex + offset)) {
                    .maybe_flagged => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                        if (field == bomb) {
                            try ctx.writeAllWrapping("!");
                        } else {
                            try ctx.writeAllWrapping("X");
                        }
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .flagged => {
                        try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                        if (field == bomb) {
                            try ctx.writeAllWrapping("F");
                        } else {
                            try ctx.writeAllWrapping("x");
                        }
                        try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                    },
                    .hidden, .shown => {
                        const char = switch (field) {
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

        if (self.fields[index] == bomb) return error.AlreadyBomb;

        self.fields[index] = bomb;
        for (neighbours) |n| {
            self.increment(x +% n.x, y +% n.y) catch {};
        }
    }
    pub fn flag(self: *Self, x: usize, y: usize, setOrRemove: enum { set, remove }, flagEntry: MaskEntry) !void {
        const index = try self.getIndex(x, y);

        const s: std.meta.Tuple(&.{ MaskEntry, MaskEntry }) = switch (setOrRemove) {
            .set => .{ MaskEntry.hidden, flagEntry },
            .remove => .{ flagEntry, MaskEntry.hidden },
        };
        const toReplace = s[0];
        const with = s[1];

        if (self.mask_entry(index) != toReplace) return;
        self.set_mask_entry(index, with);
    }
    fn get(self: *const Self, x: usize, y: usize, neighbour_flags: *usize) void {
        const index = self.getIndex(x, y) catch return;
        if (self.mask_entry(index) == .flagged) {
            neighbour_flags.* += 1;
        }
    }
    pub fn click(self: *Self, x: usize, y: usize, comptime player_click: bool) !void {
        const index = try self.getIndex(x, y);
        const field = self.fields[index];

        if (player_click and self.mask_entry(index) == .shown) {
            var neighbour_flags: usize = 0;
            for (neighbours) |n| {
                self.get(x +% n.x, y +% n.y, &neighbour_flags);
            }
            if (neighbour_flags >= field) {
                for (neighbours) |n| {
                    self.click(x +% n.x, y +% n.y, false) catch |e|
                        if (e == error.Explode) return error.Explode;
                }
            }
            return;
        }

        if (self.mask_entry(index) != .hidden) return;
        if (field == bomb) return error.Explode;

        self.set_mask_entry(index, .shown);
        if (field == 0) {
            for (neighbours) |n| {
                self.click(x +% n.x, y +% n.y, false) catch {};
            }
        }
    }
    pub fn hasWon(self: *Self) !bool {
        for (self.fields, 0..) |b, i| {
            const isShown = self.mask_entry(i) == .shown;
            const isBomb = b == bomb;
            if (!isBomb and !isShown) return false;
        }
        return true;
    }
    pub fn keepCursorInBounds(self: *const Self, cursor: *Cursor) void {
        if (cursor.x >= self.width) cursor.x = self.width - 1;
        if (cursor.y >= self.fields.len / self.width) cursor.y = self.fields.len / self.width - 1;
    }
    inline fn increment(self: *Self, x: usize, y: usize) !void {
        const index = try self.getIndex(x, y);

        if (self.fields[index] < 9) {
            self.fields[index] += 1;
        }
    }
    inline fn getIndex(self: *const Self, x: usize, y: usize) !usize {
        if (x >= self.width) return error.XBiggerThanWidth;
        const index = x + y *% self.width;
        if (index >= self.fields.len) return error.YBiggerThanHeight;
        return index;
    }
};

const IS2 = struct { isize, isize };
const Coord = struct { x: usize, y: usize };
const neighbours: [8]Coord = @bitCast([_]IS2{
    .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
});

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    term.cook() catch {};
    std.builtin.default_panic(msg, trace, ret_addr);
}
