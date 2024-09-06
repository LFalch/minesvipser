const std = @import("std");
const spoon = @import("spoon");
const mem = std.mem;

const main = @import("main.zig");

pub const BOMB: u8 = 255;

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
    try ctx.hideCursor();
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
                        BOMB => 'o',
                        else => unreachable,
                    };
                    try ctx.writeAllWrapping(&[_]u8{char});
                },
            }
        }
        try ctx.writeAllWrapping("\r\n");
    }
    try ctx.showCursor();
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
                    if (field == BOMB) {
                        try ctx.writeAllWrapping("!");
                    } else {
                        try ctx.writeAllWrapping("X");
                    }
                    try ctx.setAttribute(spoon.Attribute{ .bg = .white });
                },
                .flagged => {
                    try ctx.setAttribute(spoon.Attribute{ .bg = .red, .fg = .bright_white });
                    if (field == BOMB) {
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
                        BOMB => 'O',
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

    if (self.fields[index] == BOMB) return error.AlreadyBomb;

    self.fields[index] = BOMB;
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
    if (field == BOMB) return error.Explode;

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
        const isBomb = b == BOMB;
        if (!isBomb and !isShown) return false;
    }
    return true;
}
pub fn keepCursorInBounds(self: *const Self, cursor: *main.Cursor) void {
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

const IS2 = struct { isize, isize };
const Coord = struct { x: usize, y: usize };
const neighbours: [8]Coord = @bitCast([_]IS2{
    .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
});
