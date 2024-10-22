Utility library for working with flat file databases.

flatdb Library
==============

Example
-------
```zig
const RecordIterator = flatdb.DelimitedBufferIterator(u8, .{
    .delims = &.{'\n'}, // split records on newlines
    .delimit_mode = .terminator, // skip final empty record
});

const FieldIterator = flatdb.DelimitedBufferIterator(u8, .{
    .delims = &.{','}, // split fields on commas
    .delimit_mode = .separator, // allow final empty field
});

var record_it = RecordIterator.init(buffer);
while (record_it.next(), 1..) |line, record_num| {
    std.debug.print("record {d}: ", .{record_num});

    var field_it = FieldIterator.init(line);
    while (field_it.next(), 0..) |field, field_num| {
        if (field_num == 0) {
            std.debug.print("{s}", .{field});
        } else {
            std.debug.print(",{s}", .{field});
        }
    }

    std.debug.print("\n", .{});
}
```
