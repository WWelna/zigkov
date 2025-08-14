// Copyright (C) 2025 William Welna (wwelna@occultusterra.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const clap = @import("clap");

// Global Arena Allocator because we don't care
var gpa = std.heap.DebugAllocator(.{}){};
const gpa_allocator = gpa.allocator();
var arena = std.heap.ArenaAllocator.init(gpa_allocator);
var allocator = arena.allocator();

const Word = struct {
    word:std.ArrayList(u8),
    next:std.ArrayList(WordStat),
    end_count:f64,
    end_normalized:f64,
    start_count:f64,
    start_normalized:f64,
};

const WordStat = struct {
    word:std.ArrayList(u8),
    count:f64,
    normalized:f64,
};

var MarkovChain:std.ArrayList(Word) = undefined;

pub inline fn clean(word:[] const u8, output:*std.ArrayList(u8)) !void {
    for (word) |x| {
        if(std.ascii.isAlphabetic(x) or x == '#' or x == '@' or x == '\'' or x == '€' or x == '-') { // Make this pretty somehow
            if(x != '#' or x != '@' or x != '\'' or x != '€' or x != '-') try output.append(std.ascii.toLower(x)) else try output.append(x);
        }
    }
}

pub inline fn add(chains:*std.ArrayList(Word), word:[] const u8, next:[] const u8, is_start:bool) !void {
    var updated:bool = false;
    var w = std.ArrayList(u8).init(allocator);
    var n = std.ArrayList(u8).init(allocator);
    try clean(word, &w); try clean(next, &n);
    if(w.items.len < 1 or n.items.len < 1) return;
    for (chains.items) |*x| {
        if(std.mem.eql(u8, w.items, x.word.items)) {
            if(is_start) x.start_count = 1;
            for(x.next.items) |*y| {
                if(std.mem.eql(u8, y.word.items, n.items)) {
                    updated = true;
                    y.count += 1;
                    break;
                }
            }
            if(updated == false) {
                // Add new next entry
                try x.next.append(.{.word = n, .count = 1, .normalized = 0});
                updated = true;
            }
            break;
        }
    }
    if(updated == false) { // No point setting this as not used again
        // Add new entry word/next pair
        var entry = std.ArrayList(WordStat).init(allocator);
        try entry.append(.{.word = n, .count = 1, .normalized = 0});
        try chains.append(.{.word = w, .next = entry, .end_count = 0, .end_normalized = 0, .start_count = if(is_start) 1 else 0, .start_normalized = 0});
    }
}

pub inline fn add_end(chains:*std.ArrayList(Word), word:[] const u8) !void {
    var updated:bool = false;
    var w = std.ArrayList(u8).init(allocator);
    try clean(word, &w);
    if(w.items.len < 1) return;
    for (chains.items) |*x| {
        if(std.mem.eql(u8, w.items, x.word.items)) {
            updated = true;
            x.end_count += 1;
        }
    }
    if(updated == false) { // No point setting this as not used again
        try chains.append(.{.word = w, .next = std.ArrayList(WordStat).init(allocator), .end_count = 1, .end_normalized = 0, .start_count = 0, .start_normalized = 0});
    }
}

pub inline fn do_stats(chains:*std.ArrayList(Word), data:[]const u8) !void {
    var file = try std.fs.cwd().openFile(data, .{ .mode = .read_only });
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    const buf = try allocator.alloc(u8, 4096);
    const buf2 = try allocator.alloc(u8, 4096);
    var post_count:f64 = 0;
    while (try in_stream.readUntilDelimiterOrEof(buf, '.')) |line| {
        post_count += 1;
        const tmp = buf2[0..std.mem.replacementSize(u8, line, "\n", "")];
        _ = std.mem.replace(u8, line, "\n", "", tmp);
        var splits = std.mem.splitAny(u8, tmp, " ");
        var is_start:bool = true;
        while (splits.next()) |x| {
            if(splits.peek()) |y| {
                try add(chains, x, y, is_start);
            } else try add_end(chains, x);
            is_start=false;
        }
    }

    for (chains.items) |*x| {
        x.end_normalized = x.end_count / post_count;
        x.start_normalized = x.start_count / post_count;
        var total:f64 = 0;
        for(x.next.items) |*y| total += y.count;
        const per2:f64 = (1.0 / total); // Calculate this only once
        for(x.next.items) |*y| y.normalized = y.count * per2;
    }
}

pub inline fn random(probability:f64, weight:f64) bool {
    const rand = std.crypto.random.float(f64);
    return rand <= (probability + weight);
}

pub inline fn do_spongebob(line:[]u8) void {
    for(line) |*x| {
        if(std.ascii.isAlphabetic(x.*) and std.ascii.isLower(x.*)) {
            if(random(0.5, 0)) {
                x.* = std.ascii.toUpper(x.*);
            }
        }
    }
}

pub inline fn find(chains:*std.ArrayList(Word), word:[] u8) ?*Word {
    for(chains.items) |*x| {
        if(std.mem.eql(u8, x.word.items, word)) {
            return x;
        }
    } // This function should, in theory, never fail
    return null;
}

pub fn do_next(chains:*std.ArrayList(Word)) !?[]u8 {
    var post = std.ArrayList(u8).init(allocator);
    var starter:*Word = undefined;
    while(true) {
        const i:usize = std.crypto.random.uintAtMost(usize, chains.items.len-1);
        if(chains.items[i].next.items.len > 5 and random(chains.items[i].start_normalized, 0)) {
            starter = &chains.items[i];
            try post.appendSlice(starter.word.items);
            try post.append(' ');
            break;
        }
    }
    
    var still_building:bool = true;
    while(still_building) {
        var selected:bool = false;
        var next:[] u8 = undefined;
        if(random(starter.end_normalized, 0.0)) break;
        while(!selected) {
            for (starter.next.items) |*x| {
                if(random(x.normalized, 0.01)) {
                    try post.appendSlice(x.word.items);
                    try post.append(' ');
                    selected = true;
                    next = x.word.items;
                    break;
                }
            }
        }
        if(still_building) {
            if(find(chains, next)) |z| { // This should never fail, in theory
                starter = z;
                if(starter.next.items.len < 1) still_building = false;
            } else still_building = false;
        }
    }

    return post.items;
}

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-p, --process <str>   Read text file & build markov chains.
        \\-o, --out <str>       Append output to text file.
        \\-m, --markov <str>    Read/use previously saved markov chain.
    ); // Need to add the JSON Loading/Saving Code

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa_allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        std.debug.print("--help\n", .{});
    if(res.args.process) |f| { // Only Argument it recognizes atm
        MarkovChain = std.ArrayList(Word).init(allocator);
        try do_stats(&MarkovChain, f);
        try std.io.getStdOut().writer().print("{s}\n", .{if(try do_next(&MarkovChain)) |s| s else ""});
        defer arena.deinit();
    }
    defer _ = gpa.deinit();
}
