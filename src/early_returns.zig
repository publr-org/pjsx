//! Early returns in a component — the last stage of canonicalization. A
//! component's markup is the expression its body ends by returning; an
//! `if (cond) return <A/>;` before that is the same component choosing
//! between two trees, which every target already lowers as a conditional.
//! So the source is rewritten before anything reads it:
//!
//!   if (back) { return <a/>; }      →   (removed)
//!   return <div/>;                  →   return <>{(back) ? (<a/>) : (<div/>)}</>;
//!
//! Only a function that ends by returning JSX is a component; helpers that
//! return text keep their early returns. An early return the rewrite cannot
//! express (statements beside it in the block, an `else`) is an error, never
//! dropped: the statements between run either way, so they must be setup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const err = @import("err.zig");
const parser = @import("parser.zig");
const Node = ast.Node;

const Early = struct {
    statement: *Node,
    condition: *Node,
    value: *Node,
};

const Rewrite = struct {
    early: []const Early,
    last: *Node,
};

pub fn rewrite(allocator: Allocator, code: []const u8) err.Error![]const u8 {
    // Most modules have no early return: skip the second parse for them.
    if (std.mem.count(u8, code, "return") < 2 or std.mem.indexOf(u8, code, "if") == null) {
        return code;
    }

    const program = parser.parse(allocator, code, "early-returns") catch |e| switch (e) {
        error.OutOfMemory => return e,
        // Not this stage's to report: the next parse says what is wrong.
        error.Pjsx => return code,
    };

    var rewrites: std.ArrayList(Rewrite) = .empty;
    for (program.statements) |statement| {
        const function = componentOf(statement) orelse continue;
        if (try rewriteOf(allocator, function)) |found| try rewrites.append(allocator, found);
    }
    if (rewrites.items.len == 0) return code;

    return apply(allocator, code, rewrites.items);
}

/// The function a top-level statement declares: `function X`, `export function
/// X`, `export default function`, `const X = () => {}`.
fn componentOf(statement: *Node) ?*Node {
    const declared = switch (statement.type) {
        .ExportNamedDeclaration, .ExportDefaultDeclaration => statement.declaration orelse return null,
        else => statement,
    };
    if (declared.type == .FunctionDeclaration) return declared;
    if (declared.type != .VariableDeclaration or declared.declarations.len != 1) return null;
    const init = declared.declarations[0].init orelse return null;
    const value = ast.unparen(init);
    return if (value.isFunction()) value else null;
}

fn rewriteOf(allocator: Allocator, function: *Node) err.Error!?Rewrite {
    const body = function.body orelse return null;
    if (body.type != .BlockStatement or body.statements.len < 2) return null;

    const last = body.statements[body.statements.len - 1];
    if (last.type != .ReturnStatement) return null;
    const returned = last.argument orelse return null;
    if (!ast.unparen(returned).isJsx()) return null;

    var early: std.ArrayList(Early) = .empty;
    for (body.statements[0 .. body.statements.len - 1]) |statement| {
        if (statement.type != .IfStatement) continue;
        if (earlyOf(statement)) |found| {
            try early.append(allocator, found);
            continue;
        }
        if (returnsInside(statement)) {
            return err.fail("a component returns its markup at the end; an early `return` " ++
                "lowers only as `if (cond) return <A/>;` with nothing beside it and no `else`. " ++
                "Branch inside the markup instead: `{{cond && (<A/>)}}`", .{});
        }
    }
    if (early.items.len == 0) return null;

    return .{
        .early = early.items,
        .last = last,
    };
}

/// `if (cond) return value;` or `if (cond) { return value; }`, nothing else.
fn earlyOf(statement: *Node) ?Early {
    if (statement.alternate != null) return null;
    const condition = statement.test_ orelse return null;
    var consequent = statement.consequent orelse return null;
    if (consequent.type == .BlockStatement) {
        if (consequent.statements.len != 1) return null;
        consequent = consequent.statements[0];
    }
    if (consequent.type != .ReturnStatement) return null;
    const value = consequent.argument orelse return null;
    return .{
        .statement = statement,
        .condition = condition,
        .value = value,
    };
}

/// Whether an `if` returns from the component in any of its branches.
fn returnsInside(statement: *Node) bool {
    for ([_]?*Node{ statement.consequent, statement.alternate }) |branch| {
        const node = branch orelse continue;
        if (node.type == .ReturnStatement) return true;
        if (node.type == .IfStatement and returnsInside(node)) return true;
        if (node.type != .BlockStatement) continue;
        for (node.statements) |inner| {
            if (inner.type == .ReturnStatement) return true;
            if (inner.type == .IfStatement and returnsInside(inner)) return true;
        }
    }
    return false;
}

fn apply(allocator: Allocator, code: []const u8, rewrites: []const Rewrite) err.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;

    for (rewrites) |one| {
        for (one.early) |early| {
            try out.appendSlice(allocator, code[at..early.statement.start]);
            at = early.statement.end;
        }

        const returned = one.last.argument.?;
        var chosen: std.ArrayList(u8) = .empty;
        try chosen.appendSlice(allocator, slice(code, returned));
        var index = one.early.len;
        while (index > 0) {
            index -= 1;
            const early = one.early[index];
            const nested = try std.fmt.allocPrint(allocator, "({s}) ? ({s}) : ({s})", .{
                slice(code, early.condition),
                slice(code, early.value),
                chosen.items,
            });
            chosen.clearRetainingCapacity();
            try chosen.appendSlice(allocator, nested);
        }

        try out.appendSlice(allocator, code[at..returned.start]);
        try out.appendSlice(allocator, "<>{");
        try out.appendSlice(allocator, chosen.items);
        try out.appendSlice(allocator, "}</>");
        at = returned.end;
    }

    try out.appendSlice(allocator, code[at..]);
    return out.toOwnedSlice(allocator);
}

fn slice(code: []const u8, node: *const Node) []const u8 {
    return code[node.start..node.end];
}

test "an early return in a component becomes the conditional it means" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try rewrite(a,
        \\export function Heading({ back }: { back: boolean }) {
        \\  if (back) {
        \\    return <a href="#">Back</a>;
        \\  }
        \\
        \\  return <div>Here</div>;
        \\}
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "if (back)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\return <>{(back) ? (<a href="#">Back</a>) : (<div>Here</div>)}</>;
    ) != null);
}

test "a helper returning text keeps its early returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\export const size = (bytes: number): string => {
        \\  if (bytes < 1024) return `${bytes} B`;
        \\  return `${bytes / 1024} KB`;
        \\};
    ;
    try std.testing.expectEqualStrings(src, try rewrite(a, src));
}

test "an early return beside other statements is an error, never dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.Pjsx, rewrite(a,
        \\export function Heading({ back }: { back: boolean }) {
        \\  if (back) {
        \\    const label = "Back";
        \\    return <a>{label}</a>;
        \\  }
        \\  return <div />;
        \\}
    ));
}
