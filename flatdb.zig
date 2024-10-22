const std = @import("std");
const mem = std.mem;

// TODO: quoted fields

/// Error returned by iterator when unterminated mode is .error.
const DatabaseError = error{
    /// Error generated when delimit mode is .terminator and error mode is
    /// .error and final value is not properly terminated.
    UnexpectedExtraField,
};

/// The delimit mode controls how the parser treats the final value when it is
/// empty.  When the mode is .separator, a final empty value will be produced
/// by the iterator.  When the mode is .terminator, a final empty value is
/// ignored.
pub const DelimitMode = enum {
    /// Delimit between fields.
    separator,
    /// Delimit at end of fields.
    terminator,
};

/// The error mode controls how final unterminated value is handled.  If the
/// delimit mode is .separator, this has no effect.
pub const UnterminatedMode = enum {
    /// Ignore missing terminator and return unterminated value.
    ok,
    /// Skip value with missing terminator.
    skip,
    /// Return error if there is a missing terminator.
    @"error",
};

pub fn DelimitedBufferOptions(comptime T: type) type {
    return struct {
        /// Set of values that delimit fields within the buffer.
        delims: []const T,
        /// True to treate repeated delimiters as one.
        collapse: bool = false,
        /// Whether delimiter should be treated as terminator or separator.
        delimit_mode: DelimitMode,
        /// How to handle final unterminated value.
        unterminated_mode: UnterminatedMode = .ok,
    };
}

/// Iterate over fields in a flat text buffer.
pub fn DelimitedBufferIterator(
    comptime T: type,
    comptime options: DelimitedBufferOptions(T),
) type {
    const delimit_mode = options.delimit_mode;
    const unterminated_mode = options.unterminated_mode;
    const can_error = delimit_mode == .terminator and unterminated_mode == .@"error";
    const Result = if (can_error) DatabaseError!?[]const T else ?[]const T;

    return struct {
        buffer: []const T,
        offset: usize = 0,
        finalized: bool = false,

        /// Set the buffer to scan.
        pub fn init(buffer: []const T) @This() {
            return .{ .buffer = buffer };
        }

        /// Return the next field value.  Return null when no more fields are
        /// available.
        pub fn next(this: *@This()) Result {
            const buffer = this.buffer;
            const offset = this.offset;
            const delims = options.delims;

            if (this.finalized) {
                return null;
            } else if (offset >= buffer.len) {
                this.finalized = true;

                switch (options.delimit_mode) {
                    .terminator => return null,
                    .separator => return if (this.lookbackIsDelim()) "" else null,
                }
            } else if (mem.indexOfAnyPos(T, buffer, offset, delims)) |pos| {
                this.offset = pos + 1;

                if (options.collapse) {
                    while (this.isDelim()) this.offset += 1;
                }

                return buffer[offset..pos];
            } else {
                this.offset = buffer.len;

                // check if remaining data is unterminated
                if (options.delimit_mode == .terminator) {
                    // handle unterminated data
                    switch (options.unterminated_mode) {
                        .skip => return null,
                        .@"error" => return DatabaseError.UnexpectedExtraField,
                        else => {},
                    }
                }

                return buffer[offset..];
            }
        }

        /// Return true if the current offset is a delimited.
        fn isDelim(this: @This()) bool {
            if (this.offset < this.buffer.len) {
                const val = this.buffer[this.offset];

                for (options.delims) |delim| {
                    if (val == delim) return true;
                }
            }

            return false;
        }

        /// Return the last value scanned.  Return null when at beginning of
        /// buffer.
        fn lookback(this: @This()) ?T {
            return if (this.offset == 0) null else this.buffer[this.offset - 1];
        }

        /// Return true if the last value scanned was a delimiter.
        fn lookbackIsDelim(this: @This()) bool {
            if (this.lookback()) |val| {
                for (options.delims) |delim| {
                    if (delim == val) return true;
                }
            }

            return false;
        }
    };
}

test "lines of text" {
    // basic text file, delimited by newline
    const LineIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{'\n'},
        .delimit_mode = .separator,
    });

    const buffer = try std.testing.allocator.alloc(u8, test_db.len);
    defer std.testing.allocator.free(buffer);
    @memcpy(buffer, test_db);

    var it = LineIterator.init(buffer);

    try std.testing.expectStringStartsWith(it.next().?, "name");
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectStringStartsWith(it.next().?, "apple");
    try std.testing.expectStringStartsWith(it.next().?, "banana");
    try std.testing.expectStringStartsWith(it.next().?, "carrot");
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "POSIX text" {
    // POSIX standard specifies that final line of text file must end with
    // newline character.
    const PosixTextIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{'\n'},
        .delimit_mode = .terminator,
    });

    const buffer = try std.testing.allocator.alloc(u8, test_db.len);
    defer std.testing.allocator.free(buffer);
    @memcpy(buffer, test_db);

    var it = PosixTextIterator.init(buffer);

    try std.testing.expectStringStartsWith(it.next().?, "name");
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectStringStartsWith(it.next().?, "apple");
    try std.testing.expectStringStartsWith(it.next().?, "banana");
    try std.testing.expectStringStartsWith(it.next().?, "carrot");
    try std.testing.expectEqual(null, it.next());
}

test "collapsed delimiters" {
    // read POSIX text, but skip empty lines
    const NonEmptyLineIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{'\n'},
        .delimit_mode = .terminator,
        .collapse = true,
    });

    const buffer = try std.testing.allocator.alloc(u8, test_db.len);
    defer std.testing.allocator.free(buffer);
    @memcpy(buffer, test_db);

    var it = NonEmptyLineIterator.init(buffer);

    try std.testing.expectStringStartsWith(it.next().?, "name");
    try std.testing.expectStringStartsWith(it.next().?, "apple");
    try std.testing.expectStringStartsWith(it.next().?, "banana");
    try std.testing.expectStringStartsWith(it.next().?, "carrot");
    try std.testing.expectEqual(null, it.next());
}

test "error mode" {
    // using this iterator only for grabbing first line
    const LineIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{'\n'},
        .delimit_mode = .separator,
    });

    // iterate with final unterminated value
    const LooseIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{','},
        .delimit_mode = .terminator,
        .unterminated_mode = .ok,
    });

    // iterate without final unterminated value
    const LossyIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{','},
        .delimit_mode = .terminator,
        .unterminated_mode = .skip,
    });

    // error on final unterminated value
    const FailIterator = DelimitedBufferIterator(u8, .{
        .delims = &.{','},
        .delimit_mode = .terminator,
        .unterminated_mode = .@"error",
    });

    const buffer = try std.testing.allocator.alloc(u8, test_db.len);
    defer std.testing.allocator.free(buffer);
    @memcpy(buffer, test_db);

    var line_it = LineIterator.init(buffer);
    const line = line_it.next().?;

    var loose = LooseIterator.init(line);
    var lossy = LossyIterator.init(line);
    var fail = FailIterator.init(line);

    try std.testing.expectStringStartsWith(loose.next().?, "name");
    try std.testing.expectEqual(null, loose.next());
    try std.testing.expectEqual(null, lossy.next());
    try std.testing.expectError(DatabaseError.UnexpectedExtraField, fail.next());
}

/// Used in test cases to load test data.
fn read_file(allocator: mem.Allocator, path: []const u8) ![]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const abs_path = try std.fs.path.resolve(allocator, &.{ cwd, path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

/// Simple database example for unit tests.
const test_db = @embedFile("test.db");
