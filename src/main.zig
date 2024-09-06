const std = @import("std");
const spoon = @import("spoon");
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const fmt = std.fmt;

const Grid = @import("Grid.zig");

var term: spoon.Term = undefined;

const legacy_input = false;
const spell_clear_entire_line = "\x1B[2K";

pub const Cursor = struct { x: usize, y: usize };

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
                try stderr.print("Unexpected error: {s}\n", .{@errorName(e)});
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
        while (bombs_placed < bombs) : (bombs_placed += 1) {
            const x = rand.random().intRangeLessThan(usize, 0, grid_w);
            const y = rand.random().intRangeLessThan(usize, 0, grid_h);
            grid.placeBomb(x, y) catch |e| switch (e) {
                error.AlreadyBomb => continue,
                else => return e,
            };
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
        // try render.clear();
        try render.moveCursorTo(0, 0);
        try render.setAttribute(spoon.Attribute{ .bg = .white });

        if (!lost) {
            try grid.render(&render);

            try render.moveCursorTo(grid_h, 0);
            if (try grid.hasWon()) {
                try render.setAttribute(spoon.Attribute{ .bold = true });
                try render.writeAllWrapping("\r\n" ++ spell_clear_entire_line ++ "You won!");
                try render.writeAllWrapping("\r\n" ++ spell_clear_entire_line);
                running = false;
            } else if (help) {
                help = false;
                try render.setAttribute(spoon.Attribute{ .fg = .bright_blue, .bold = true });
                try render.writeAllWrapping("\r" ++ spell_clear_entire_line ++ "Press q to quit, click or use arrow keys to move the cursor around. Press space or enter to reveal the space under the cursor.");
                try render.writeAllWrapping("\r\nPress f to set a flag, and t to set a question mark. If holding alt or ctrl, it instead removes it.");
            } else {
                try render.setAttribute(spoon.Attribute{ .fg = .bright_blue, .bold = true });
                try render.writeAllWrapping("\r" ++ spell_clear_entire_line ++ "Press ? or h for help");
                try render.writeAllWrapping("\r\n" ++ spell_clear_entire_line);
            }
        } else {
            try render.clear();
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

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    term.cook() catch {};
    std.builtin.default_panic(msg, trace, ret_addr);
}
