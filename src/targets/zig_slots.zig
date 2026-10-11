//! The compiled expressions of a program in `stores.js`: a module with a store of
//! its own returns its functions from the store's factory (`expressions`), beside
//! its actions, so `state` and its helpers are the instance's; any other module
//! registers them with `Publr.expressions`, in a block holding the top-level
//! helpers they read.

const std = @import("std");
const compiler = @import("../compiler.zig");
const err = @import("../err.zig");

pub const Error = err.Error || std.Io.Writer.Error;

pub const Slot = struct {
    name: []const u8,
    /// The function, as JavaScript: `({ row }) => row.on && state.open`.
    code: []const u8,
    expression: *const compiler.ExpressionIR,
    /// The props it reads, which the server hands it in its instance.
    props: []const []const u8 = &.{},
    /// State the module imports from a family: the name it reads it under and the
    /// family's store.
    foreign: ?struct {
        local: []const u8,
        store: []const u8,
    } = null,
};

/// Module name → its slots.
pub const Table = std.StringArrayHashMapUnmanaged([]const Slot);

/// The `expressions: { … }` member of a store factory's returned object.
pub fn factoryMember(arena: std.mem.Allocator, slots: []const Slot) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("    expressions: {\n");
    for (slots) |slot| try out.writer.print("      {s}: {s},\n", .{ slot.name, slot.code });
    try out.writer.writeAll("    },\n");
    return out.written();
}

/// A store registration with its slots added to the object its factory returns.
pub fn withFactoryMember(arena: std.mem.Allocator, registration: []const u8, slots: []const Slot) Error![]const u8 {
    if (slots.len == 0) return registration;
    const closing = "  };\n});";
    if (!std.mem.endsWith(u8, registration, closing)) return err.fail("a store registration does not end its factory as expected", .{});
    const head = registration[0 .. registration.len - closing.len];
    return std.mem.concat(arena, u8, &.{ head, try factoryMember(arena, slots), closing });
}

/// A module without a store of its own: its slots, registered with the stores
/// their imported state names, after the helpers they read.
pub fn block(arena: std.mem.Allocator, slots: []const Slot, declarations: []const compiler.DeclarationIR) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("Publr.expressions({");
    var stores: std.ArrayList([]const u8) = .empty;
    for (slots) |slot| {
        const foreign = slot.foreign orelse continue;
        var known = false;
        for (stores.items) |local| known = known or std.mem.eql(u8, local, foreign.local);
        if (known) continue;
        try stores.append(arena, foreign.local);
        try out.writer.print(" {s}: \"{s}\"", .{ foreign.local, foreign.store });
    }
    try out.writer.writeAll(if (stores.items.len > 0) " }, " else "}, ");

    const helpers = try read(arena, slots, declarations);
    if (helpers.len == 0) {
        try out.writer.writeAll("{\n");
        for (slots) |slot| try out.writer.print("  {s}: {s},\n", .{ slot.name, slot.code });
        try out.writer.writeAll("});");
        return out.written();
    }
    try out.writer.writeAll("(() => {\n");
    for (helpers) |helper| try out.writer.print("{s}\n", .{helper.code});
    try out.writer.writeAll("return {\n");
    for (slots) |slot| try out.writer.print("  {s}: {s},\n", .{ slot.name, slot.code });
    try out.writer.writeAll("};\n})());");
    return out.written();
}

/// The intrinsics a view's expression may call, ahead of the views in the server
/// program and, when a slot calls one, of the stores in `stores.js`: one meaning.
pub const intrinsics =
    \\// The compile-time helpers views import from publr-jsx, as the render's Zig has them
    \\// (`runtime/server.zig`: `initials`, `gravatar_url`).
    \\// A style object's CSS text: camelCase keys kebab-cased, a `--custom` property as it
    \\// is, an accessor called, empty values left out.
    \\const styleText = (style) => Object.entries(style ?? {})
    \\  .map(([name, value]) => [name, typeof value === "function" ? value() : value])
    \\  .filter(([, value]) => value != null && value !== false && value !== "")
    \\  .map(([name, value]) => (name.startsWith("--") ? name : name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())) + ":" + value)
    \\  .join(";");
    \\const initials = (name) => {
    \\  const words = String(name ?? "").split(/[ \t\n\r]+/).filter(Boolean).slice(0, 2);
    \\  return words.map((word) => {
    \\    const first = [...word][0];
    \\    return first >= "a" && first <= "z" ? first.toUpperCase() : first;
    \\  }).join("");
    \\};
    \\const gravatarUrl = (email, size) => {
    \\  let text = "";
    \\  for (const char of String(email ?? "")) if (!" \t\n\r".includes(char)) text += char.charCodeAt(0) < 128 ? char.toLowerCase() : char;
    \\  return `https://gravatar.com/avatar/${md5(unescape(encodeURIComponent(text)))}?d=blank&s=${size}`;
    \\};
    \\const md5 = (bytes) => {
    \\  const k = [], r = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
    \\  for (let i = 0; i < 64; i++) k[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) | 0;
    \\  const words = [];
    \\  const length = bytes.length;
    \\  for (let i = 0; i < length; i++) words[i >> 2] |= bytes.charCodeAt(i) << ((i % 4) * 8);
    \\  words[length >> 2] |= 0x80 << ((length % 4) * 8);
    \\  const total = (((length + 8) >> 6) + 1) * 16;
    \\  for (let i = 0; i < total; i++) words[i] |= 0;
    \\  words[total - 2] = length * 8;
    \\  let a = 0x67452301, b = 0xefcdab89 | 0, c = 0x98badcfe | 0, d = 0x10325476;
    \\  for (let block = 0; block < total; block += 16) {
    \\    let [aa, bb, cc, dd] = [a, b, c, d];
    \\    for (let i = 0; i < 64; i++) {
    \\      let f, g;
    \\      if (i < 16) { f = (bb & cc) | (~bb & dd); g = i; }
    \\      else if (i < 32) { f = (dd & bb) | (~dd & cc); g = (5 * i + 1) % 16; }
    \\      else if (i < 48) { f = bb ^ cc ^ dd; g = (3 * i + 5) % 16; }
    \\      else { f = cc ^ (bb | ~dd); g = (7 * i) % 16; }
    \\      const shift = r[(i >> 4) * 4 + (i % 4)];
    \\      const sum = (aa + f + k[i] + words[block + g]) | 0;
    \\      aa = dd; dd = cc; cc = bb;
    \\      bb = (bb + ((sum << shift) | (sum >>> (32 - shift)))) | 0;
    \\    }
    \\    a = (a + aa) | 0; b = (b + bb) | 0; c = (c + cc) | 0; d = (d + dd) | 0;
    \\  }
    \\  return [a, b, c, d].map((word) => {
    \\    let hex = "";
    \\    for (let i = 0; i < 4; i++) hex += ((word >>> (i * 8)) & 255).toString(16).padStart(2, "0");
    \\    return hex;
    \\  }).join("");
    \\};
    \\
;

/// The server program's `Publr`: `url` and `path` as publr-js has them, over the base
/// path the engine sets; what only a browser has is inert.
pub const server_publr =
    \\// What a view's helpers reach on `Publr` while the server renders: the base path the
    \\// page is served under (set by the engine as `__publr_base`, as the browser reads
    \\// `data-publr-base`), and inert stand-ins for what only a browser has.
    \\const publrBase = () => globalThis.__publr_base ?? "";
    \\const needsBase = (base, value) => {
    \\  if (base === "" || !value.startsWith("/") || value.startsWith("//")) return false;
    \\  if (!value.startsWith(base)) return true;
    \\  const rest = value.slice(base.length);
    \\  return !(rest === "" || rest[0] === "/" || rest[0] === "?" || rest[0] === "#");
    \\};
    \\// Messages in the reader's language, from the catalogue the engine was given
    \\// (`__publr_messages`), as publr-js reads it in the browser, form for form.
    \\const publrFew = (n) => n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14);
    \\const publrForm = (rule, n) => {
    \\  const last = n % 10, two = n % 100;
    \\  switch (rule) {
    \\    case "single": return 0;
    \\    case "zero_one_other": return n <= 1 ? 0 : 1;
    \\    case "polish": return n === 1 ? 0 : publrFew(n) ? 1 : 2;
    \\    case "east_slavic": return last === 1 && two !== 11 ? 0 : publrFew(n) ? 1 : 2;
    \\    case "czech": return n === 1 ? 0 : n >= 2 && n <= 4 ? 1 : 2;
    \\    case "slovenian": return two === 1 ? 0 : two === 2 ? 1 : two === 3 || two === 4 ? 2 : 3;
    \\    case "lithuanian": return last === 1 && (two < 11 || two > 19) ? 0 : last >= 2 && (two < 11 || two > 19) ? 1 : 2;
    \\    case "latvian": return last === 1 && two !== 11 ? 0 : n !== 0 ? 1 : 2;
    \\    case "romanian": return n === 1 ? 0 : n === 0 || (two >= 1 && two <= 19) ? 1 : 2;
    \\    case "arabic": return n === 0 ? 0 : n === 1 ? 1 : n === 2 ? 2 : two >= 3 && two <= 10 ? 3 : two >= 11 ? 4 : 5;
    \\    default: return n === 1 ? 0 : 1;
    \\  }
    \\};
    \\const publrMatching = (text, open) => {
    \\  let depth = 0;
    \\  for (let index = open; index < text.length; index++) {
    \\    if (text[index] === "{") depth++;
    \\    if (text[index] === "}" && --depth === 0) return index;
    \\  }
    \\  return -1;
    \\};
    \\const publrArm = (rest, value) => {
    \\  let fallback = "";
    \\  for (let open = rest.indexOf("{"); open >= 0; open = rest.indexOf("{")) {
    \\    const key = rest.slice(0, open).trim(), close = publrMatching(rest, open);
    \\    if (close < 0) break;
    \\    const arm = rest.slice(open + 1, close);
    \\    if (value !== undefined && key === value) return arm;
    \\    if (key === "other") fallback = arm;
    \\    rest = rest.slice(close + 1);
    \\  }
    \\  return fallback;
    \\};
    \\const publrFill = (text, values, count, depth = 0) => {
    \\  if (depth === 4 || text.indexOf("{") < 0) return text;
    \\  const valueOf = (name) => values && name in values ? String(values[name]) : name === "count" && count !== undefined ? String(count) : undefined;
    \\  let out = "", index = 0;
    \\  while (index < text.length) {
    \\    const open = text.indexOf("{", index), close = open < 0 ? -1 : publrMatching(text, open);
    \\    if (open < 0 || close < 0) return out + text.slice(index);
    \\    out += text.slice(index, open);
    \\    const inner = text.slice(open + 1, close), at = inner.indexOf(", select,");
    \\    const written = at >= 0 ? publrFill(publrArm(inner.slice(at + 9), valueOf(inner.slice(0, at))), values, count, depth + 1) : valueOf(inner);
    \\    out += written ?? text.slice(open, close + 1);
    \\    index = close + 1;
    \\  }
    \\  return out;
    \\};
    \\const publrLookup = (context, id, count) => {
    \\  const found = globalThis.__publr_messages;
    \\  const forms = found?.messages[context === "" ? id : context + "\u0004" + id];
    \\  if (!forms) return null;
    \\  const whole = count !== undefined && Number.isInteger(count) && count >= 0;
    \\  return forms[count === undefined ? 0 : whole ? publrForm(found.rule, count) : forms.length - 1] ?? null;
    \\};
    \\const Publr = {
    \\  t: (id, values) => publrFill(publrLookup("", id) ?? id, values),
    \\  tx: (context, id, values) => publrFill(publrLookup(context, id) ?? id, values),
    \\  tn: (one, other, count, values) => publrFill(publrLookup("", one, count) ?? (count === 1 ? one : other), values, count),
    \\  url: (path) => (needsBase(publrBase(), path) ? publrBase() + path : path),
    \\  path: (address) => {
    \\    const base = publrBase();
    \\    if (base === "" || !address.startsWith(base)) return address;
    \\    const rest = address.slice(base.length);
    \\    if (rest === "") return "/";
    \\    return rest[0] === "/" || rest[0] === "?" || rest[0] === "#" ? rest : address;
    \\  },
    \\  dataset: () => undefined,
    \\  stores: {},
    \\  reactive: (value) => value,
    \\  ref: () => ({ current: null }),
    \\  effect: () => {},
    \\  untrack: (read) => read(),
    \\};
    \\
;

/// Whether a slot calls an intrinsic, so `stores.js` carries them.
pub fn calls_intrinsic(slots: []const Slot) bool {
    for (slots) |slot| {
        if (mentions(slot.code, "initials") or mentions(slot.code, "gravatarUrl") or mentions(slot.code, "styleText")) return true;
    }
    return false;
}

/// One module in the server program: its state in, its slots out, after the
/// helpers they read.
pub fn serverModule(arena: std.mem.Allocator, name: []const u8, slots: []const Slot, declarations: []const compiler.DeclarationIR) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("  {s}: (state) => {{\n", .{name});
    for (try read(arena, slots, declarations)) |helper| try out.writer.print("{s}\n", .{helper.code});
    try out.writer.writeAll("return {\n");
    for (slots) |slot| try out.writer.print("  {s}: {s},\n", .{ slot.name, slot.code });
    try out.writer.writeAll("};\n},");
    return out.written();
}

/// The server program's entries: a module's slot table over a state, and a slot run
/// on it with a scope, the value answered as JSON, or `undefined` (also for a
/// function, which JSON leaves out).
pub const server_run =
    \\};
    \\// A module's slots over one render instance (its state and props), made once
    \\// per instance: the engine keeps the table and runs each slot on it with the
    \\// rest of the slot's scope (rows, loop values), the props behind it.
    \\globalThis.__publr_table = (module, instance) => {
    \\  const { state, props } = JSON.parse(instance);
    \\  const table = views[module](state);
    \\  table.__props = props ?? {};
    \\  return table;
    \\};
    \\globalThis.__publr_call = (table, slot, scope) => {
    \\  const value = table[slot](Object.assign(Object.create(table.__props), JSON.parse(scope)));
    \\  if (value === undefined || typeof value === "function") return "undefined";
    \\  return JSON.stringify(value);
    \\};
    \\
;

/// The declarations the slots read, and those they read in turn, in source order.
fn read(arena: std.mem.Allocator, slots: []const Slot, declarations: []const compiler.DeclarationIR) Error![]const compiler.DeclarationIR {
    const taken = try arena.alloc(bool, declarations.len);
    @memset(taken, false);
    var texts: std.ArrayList([]const u8) = .empty;
    for (slots) |slot| try texts.append(arena, slot.code);

    var changed = true;
    while (changed) {
        changed = false;
        for (declarations, 0..) |declaration, at| {
            if (taken[at]) continue;
            for (texts.items) |text| {
                if (!mentions(text, declaration.name)) continue;
                taken[at] = true;
                try texts.append(arena, declaration.code);
                changed = true;
                break;
            }
        }
    }

    var out: std.ArrayList(compiler.DeclarationIR) = .empty;
    for (declarations, 0..) |declaration, at| {
        if (taken[at]) try out.append(arena, declaration);
    }
    return out.items;
}

/// Whether `text` uses `name` as an identifier, not as a property (`.name`) and not as
/// words in a string or a template's text (`Move ${file.title} earlier` reads `file`,
/// never a helper called `earlier`).
fn mentions(text: []const u8, name: []const u8) bool {
    const Mode = enum { code, single, double, template };
    const Level = struct {
        mode: Mode,
        braces: u32 = 0,
    };
    var levels: [32]Level = undefined;
    var depth: usize = 1;
    levels[0] = .{
        .mode = .code,
    };
    var at: usize = 0;
    while (at < text.len) {
        const char = text[at];
        const level = &levels[depth - 1];
        switch (level.mode) {
            .single, .double => {
                if (char == '\\') {
                    at += 2;
                    continue;
                }
                if (char == (if (level.mode == .single) @as(u8, '\'') else '"')) depth -= 1;
                at += 1;
            },
            .template => {
                if (char == '\\') {
                    at += 2;
                    continue;
                }
                if (char == '`') {
                    depth -= 1;
                } else if (char == '$' and at + 1 < text.len and text[at + 1] == '{') {
                    if (depth == levels.len) return true;
                    levels[depth] = .{
                        .mode = .code,
                    };
                    depth += 1;
                    at += 1;
                }
                at += 1;
            },
            .code => {
                const opens: ?Mode = switch (char) {
                    '\'' => .single,
                    '"' => .double,
                    '`' => .template,
                    else => null,
                };
                if (opens) |mode| {
                    if (depth == levels.len) return true;
                    levels[depth] = .{
                        .mode = mode,
                    };
                    depth += 1;
                } else if (char == '{') {
                    level.braces += 1;
                } else if (char == '}') {
                    if (level.braces > 0) level.braces -= 1 else if (depth > 1) depth -= 1;
                } else if (identifier_char(char) and std.mem.startsWith(u8, text[at..], name)) {
                    const before: u8 = if (at == 0) ' ' else text[at - 1];
                    const after: u8 = if (at + name.len >= text.len) ' ' else text[at + name.len];
                    if (!identifier_char(before) and before != '.' and !identifier_char(after)) return true;
                }
                at += 1;
            },
        }
    }
    return false;
}

fn identifier_char(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '$';
}

test "a block carries the helpers its slots read, and theirs, in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const absent: compiler.ExpressionIR = .absent;
    const code = try block(a, &.{.{
        .name = "e_Badge_1",
        .code = "({ tone }) => TONES[tone] ?? FALLBACK",
        .expression = &absent,
    }}, &.{
        .{
            .name = "FALLBACK",
            .code = "const FALLBACK = pick(\"neutral\");",
        },
        .{
            .name = "unused",
            .code = "const unused = 1;",
        },
        .{
            .name = "TONES",
            .code = "const TONES = { success: \"text-success\" };",
        },
        .{
            .name = "pick",
            .code = "const pick = (tone) => `text-${tone}`;",
        },
    });
    try std.testing.expectEqualStrings(
        \\Publr.expressions({}, (() => {
        \\const FALLBACK = pick("neutral");
        \\const TONES = { success: "text-success" };
        \\const pick = (tone) => `text-${tone}`;
        \\return {
        \\  e_Badge_1: ({ tone }) => TONES[tone] ?? FALLBACK,
        \\};
        \\})());
    , code);
}

test "words in a string or a template's text are not reads" {
    try std.testing.expect(!mentions("({ file }) => `Move ${file.title} earlier`", "earlier"));
    try std.testing.expect(mentions("({ file }) => `Move ${earlier(file)} now`", "earlier"));
    try std.testing.expect(!mentions("() => \"later\" + 'later'", "later"));
    try std.testing.expect(mentions("() => `a ${`b ${later}`}` + later", "later"));
    try std.testing.expect(mentions("() => ({ a: 1 }) && later", "later"));
    try std.testing.expect(!mentions("() => item.later", "later"));
    try std.testing.expect(!mentions("() => \"it\\\"s later\"", "later"));
}

test "a plain module's helpers reach its block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try compiler.createPjsxModule(a,
        \\export const LOOKS = ["card", "tile"] as const;
        \\export type Look = (typeof LOOKS)[number];
        \\const LOOK: Record<Look, string> = { card: "rounded", tile: "flat" };
        \\export function Card({ look = "card" }: { look?: Look }) {
        \\  return <article class={["relative", LOOK[look]]} />;
        \\}
    , "Card.ptsx");
    try std.testing.expectEqual(@as(usize, 2), module.component.declarations.len);
    try std.testing.expectEqualStrings("LOOK", module.component.declarations[1].name);
}
