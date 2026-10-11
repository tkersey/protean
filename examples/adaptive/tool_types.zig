//! Small relational values; all analysis is performed by composed BPI3 code.
const c = @import("protean_contracts");
pub const Row = struct {
    id: u64,
    key: u64,
    value: u64,
    group: u64,
    matches: u64,
    match_id: u64,
    mismatches: u64,
    status: u64,
};
pub const Rows = c.Vector(Row, 32);
pub const Keys = c.Vector(u64, 32);
pub const Table = struct { rows: Rows, relation: Rows, selected: Keys };
pub const Status = enum(u64) { unclassified = 0, agreement = 1, mismatch = 2, missing = 3, ambiguous = 4, group_count = 5 };
