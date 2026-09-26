//! Recursive-descent TSX parser producing the ESTree-shaped `ast.Node` tree
//! (the shape oxc-parser hands the reference compiler, including
//! `ParenthesizedExpression` nodes and byte offsets on every node).
//!
//! TypeScript type positions are parsed for delimiting only and kept as
//! opaque `TS*` nodes with source ranges — enough for the analyzer to skip
//! them and for the type stripper to erase them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const Type = ast.Type;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;
const err = @import("err.zig");
const util = @import("util.zig");

pub const Error = err.Error;

const NodeList = std.ArrayList(*Node);
const OptNodeList = std.ArrayList(?*Node);

/// Parse a TSX module. `filename` is used in diagnostics.
pub fn parse(allocator: Allocator, source: []const u8, filename: []const u8) Error!*Node {
    return (try parseWithTypeRanges(allocator, source, filename)).program;
}

pub const Parsed = struct {
    program: *Node,
    /// TypeScript-only source ranges `[start, end)` the parser skipped
    /// (annotations, type parameters/arguments, `as` tails, modifiers, …).
    ts_ranges: []const [2]u32,
};

/// Parse and also report every TypeScript-only source range, for type stripping.
pub fn parseWithTypeRanges(allocator: Allocator, source: []const u8, filename: []const u8) Error!Parsed {
    var p = Parser{ .allocator = allocator, .src = source, .lexer = Lexer.init(allocator, source), .filename = filename };
    try p.advance();
    const program = try p.parseProgram();
    return .{ .program = program, .ts_ranges = try p.ts_ranges.toOwnedSlice(allocator) };
}

pub const Parser = struct {
    allocator: Allocator,
    src: []const u8,
    lexer: Lexer,
    filename: []const u8,
    tok: Token = .{},
    prev_end: u32 = 0,
    in_generator: bool = false,
    in_async: bool = false,
    ts_ranges: std.ArrayList([2]u32) = .empty,

    fn recordTs(self: *Parser, start: u32, end: u32) Error!void {
        if (end > start) try self.ts_ranges.append(self.allocator, .{ start, end });
    }

    /// Record the current token as TypeScript-only and consume it.
    fn eatTs(self: *Parser) Error!void {
        try self.recordTs(self.tok.start, self.tok.end);
        try self.advance();
    }

    // ── Token helpers ──────────────────────────────────────────────────────

    fn advance(self: *Parser) Error!void {
        self.prev_end = self.tok.end;
        self.tok = try self.lexer.next();
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        _ = self;
        return err.fail(fmt, args);
    }

    fn unexpected(self: *Parser) Error {
        if (self.tok.kind == .eof) return self.fail("Unexpected end of input", .{});
        return self.fail("Unexpected token `{s}` at offset {d}", .{ self.src[self.tok.start..self.tok.end], self.tok.start });
    }

    fn isPunct(self: *const Parser, text: []const u8) bool {
        return self.tok.isPunct(text);
    }

    fn isIdent(self: *const Parser, text: []const u8) bool {
        return self.tok.isIdent(text);
    }

    fn eatPunct(self: *Parser, text: []const u8) Error!bool {
        if (self.isPunct(text)) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn eatIdent(self: *Parser, text: []const u8) Error!bool {
        if (self.isIdent(text)) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn expectPunct(self: *Parser, text: []const u8) Error!void {
        if (!try self.eatPunct(text)) {
            return self.fail("Expected `{s}` but found `{s}` at offset {d}", .{ text, self.src[self.tok.start..self.tok.end], self.tok.start });
        }
    }

    fn expectIdent(self: *Parser, text: []const u8) Error!void {
        if (!try self.eatIdent(text)) {
            return self.fail("Expected `{s}` at offset {d}", .{ text, self.tok.start });
        }
    }

    fn consumeSemicolon(self: *Parser) Error!void {
        if (try self.eatPunct(";")) return;
        if (self.isPunct("}") or self.tok.kind == .eof or self.tok.newline_before) return;
        return self.unexpected();
    }

    fn node(self: *Parser, t: Type, start: u32) Allocator.Error!*Node {
        return ast.newNode(self.allocator, t, start, start);
    }

    fn finish(self: *Parser, n: *Node) *Node {
        n.end = self.prev_end;
        return n;
    }

    fn peekIsAfter(self: *Parser, comptime pred: fn (Token) bool) Error!bool {
        const state = self.lexer.save();
        const saved_tok = self.tok;
        const saved_prev = self.prev_end;
        try self.advance();
        const result = pred(self.tok);
        self.lexer.restore(state);
        self.tok = saved_tok;
        self.prev_end = saved_prev;
        return result;
    }

    /// Look at the token after the current one.
    fn peek(self: *Parser) Error!Token {
        const state = self.lexer.save();
        const saved_tok = self.tok;
        const saved_prev = self.prev_end;
        try self.advance();
        const result = self.tok;
        self.lexer.restore(state);
        self.tok = saved_tok;
        self.prev_end = saved_prev;
        return result;
    }

    const Snapshot = struct { state: lexer_mod.State, tok: Token, prev_end: u32, ts_len: usize };

    fn snapshot(self: *Parser) Snapshot {
        return .{ .state = self.lexer.save(), .tok = self.tok, .prev_end = self.prev_end, .ts_len = self.ts_ranges.items.len };
    }

    fn rewind(self: *Parser, snap: Snapshot) void {
        self.lexer.restore(snap.state);
        self.tok = snap.tok;
        self.prev_end = snap.prev_end;
        self.ts_ranges.shrinkRetainingCapacity(snap.ts_len);
    }

    const reserved = [_][]const u8{
        "break", "case",       "catch",  "class",   "const",  "continue", "debugger", "default",  "delete", "do",
        "else",  "enum",       "export", "extends", "false",  "finally",  "for",      "function", "if",     "import",
        "in",    "instanceof", "new",    "null",    "return", "super",    "switch",   "this",     "throw",  "true",
        "try",   "typeof",     "var",    "void",    "while",  "with",
    };

    fn isReserved(text: []const u8) bool {
        for (reserved) |word| if (util.eql(word, text)) return true;
        return false;
    }

    fn isBindingIdentToken(tok: Token) bool {
        return tok.kind == .identifier and !isReserved(tok.text);
    }

    // ── Program & statements ───────────────────────────────────────────────

    fn parseProgram(self: *Parser) Error!*Node {
        const program = try self.node(.Program, 0);
        var list: NodeList = .empty;
        while (self.tok.kind != .eof) {
            try list.append(self.allocator, try self.parseStatement());
        }
        program.statements = try list.toOwnedSlice(self.allocator);
        program.end = @intCast(self.src.len);
        return program;
    }

    fn parseStatement(self: *Parser) Error!*Node {
        const start = self.tok.start;
        if (self.tok.kind == .punct) {
            if (self.isPunct("{")) return self.parseBlock();
            if (self.isPunct(";")) {
                try self.advance();
                return self.finish(try self.node(.EmptyStatement, start));
            }
            if (self.isPunct("@")) {
                try self.skipDecorators();
                return self.parseStatement();
            }
        }
        if (self.tok.kind == .identifier) {
            const text = self.tok.text;
            if (util.eql(text, "var") or util.eql(text, "const") or (util.eql(text, "let") and try self.letIsDeclaration())) {
                if (util.eql(text, "const") and try self.peekIsAfter(isEnumToken)) return self.parseTsSkipStatement();
                const decl = try self.parseVariableDeclaration(false);
                try self.consumeSemicolon();
                return self.finish(decl);
            }
            if (util.eql(text, "function")) return self.parseFunction(.FunctionDeclaration, false, start);
            if (util.eql(text, "async") and try self.peekIsAfter(isFunctionNoNewline)) {
                try self.advance();
                return self.parseFunction(.FunctionDeclaration, true, start);
            }
            if (util.eql(text, "class")) return self.parseClass(.ClassDeclaration, start);
            if (util.eql(text, "abstract") and try self.peekIsAfter(isClassToken)) {
                try self.eatTs();
                return self.parseClass(.ClassDeclaration, start);
            }
            if (util.eql(text, "if")) return self.parseIf();
            if (util.eql(text, "for")) return self.parseFor();
            if (util.eql(text, "while")) return self.parseWhile();
            if (util.eql(text, "do")) return self.parseDoWhile();
            if (util.eql(text, "return")) return self.parseReturn();
            if (util.eql(text, "break") or util.eql(text, "continue")) return self.parseBreakContinue();
            if (util.eql(text, "throw")) return self.parseThrow();
            if (util.eql(text, "try")) return self.parseTry();
            if (util.eql(text, "switch")) return self.parseSwitch();
            if (util.eql(text, "debugger")) {
                try self.advance();
                try self.consumeSemicolon();
                return self.finish(try self.node(.DebuggerStatement, start));
            }
            if (util.eql(text, "import") and !try self.peekIsAfter(isParenOrDot)) return self.parseImport();
            if (util.eql(text, "export")) return self.parseExport();
            if (try self.isTsDeclarationStart()) return self.parseTsSkipStatement();
            // Labeled statement
            if (!isReserved(text) and try self.peekIsAfter(isColonToken)) {
                const label = try self.parseIdentifier();
                try self.expectPunct(":");
                const labeled = try self.node(.LabeledStatement, start);
                labeled.label = label;
                labeled.body = try self.parseStatement();
                return self.finish(labeled);
            }
        }
        const statement = try self.node(.ExpressionStatement, start);
        statement.expression = try self.parseExpression(false);
        try self.consumeSemicolon();
        return self.finish(statement);
    }

    fn isEnumToken(tok: Token) bool {
        return tok.isIdent("enum");
    }
    fn isClassToken(tok: Token) bool {
        return tok.isIdent("class");
    }
    fn isColonToken(tok: Token) bool {
        return tok.isPunct(":");
    }
    fn isParenOrDot(tok: Token) bool {
        return tok.isPunct("(") or tok.isPunct(".");
    }
    fn isFunctionNoNewline(tok: Token) bool {
        return tok.isIdent("function") and !tok.newline_before;
    }
    fn isArrowToken(tok: Token) bool {
        return tok.isPunct("=>") and !tok.newline_before;
    }
    fn isIdentOrBrace(tok: Token) bool {
        return tok.kind == .identifier or tok.isPunct("[") or tok.isPunct("{");
    }

    fn letIsDeclaration(self: *Parser) Error!bool {
        return self.peekIsAfter(isIdentOrBrace);
    }

    fn skipDecorators(self: *Parser) Error!void {
        while (self.isPunct("@")) {
            try self.advance();
            _ = try self.parseLeftHandSide();
        }
    }

    /// `type X =`, `interface X`, `enum X`, `declare …`, `namespace X`, `module X`
    fn isTsDeclarationStart(self: *Parser) Error!bool {
        const text = self.tok.text;
        if (util.eql(text, "type") or util.eql(text, "interface") or util.eql(text, "namespace")) {
            return try self.peekIsAfter(isIdentNoNewline);
        }
        if (util.eql(text, "module")) {
            return try self.peekIsAfter(isIdentOrStringNoNewline);
        }
        if (util.eql(text, "enum")) return true;
        if (util.eql(text, "declare")) return try self.peekIsAfter(isIdentNoNewline);
        if (util.eql(text, "global")) return try self.peekIsAfter(isBraceNoNewline);
        return false;
    }

    fn isIdentNoNewline(tok: Token) bool {
        return tok.kind == .identifier and !tok.newline_before;
    }
    fn isIdentOrStringNoNewline(tok: Token) bool {
        return (tok.kind == .identifier or tok.kind == .string) and !tok.newline_before;
    }
    fn isBraceNoNewline(tok: Token) bool {
        return tok.isPunct("{") and !tok.newline_before;
    }

    /// Consume a TypeScript-only declaration, returning an opaque TSDeclaration node.
    fn parseTsSkipStatement(self: *Parser) Error!*Node {
        const start = self.tok.start;
        const decl = try self.node(.TSDeclaration, start);
        if (try self.eatIdent("declare")) {
            // declare + (const|let|var|function|class|module|namespace|global|enum|type|interface|abstract)
            if (self.isIdent("var") or self.isIdent("let") or self.isIdent("const")) {
                if (self.isIdent("const") and try self.peekIsAfter(isEnumToken)) {
                    try self.advance();
                    try self.skipEnum();
                    return self.finish(decl);
                }
                _ = try self.parseVariableDeclaration(false);
                try self.consumeSemicolon();
                return self.finish(decl);
            }
            if (self.isIdent("function")) {
                _ = try self.parseFunction(.FunctionDeclaration, false, self.tok.start);
                return self.finish(decl);
            }
            if (self.isIdent("async")) {
                try self.advance();
                _ = try self.parseFunction(.FunctionDeclaration, true, self.tok.start);
                return self.finish(decl);
            }
            if (self.isIdent("class") or self.isIdent("abstract")) {
                _ = try self.eatIdent("abstract");
                _ = try self.parseClass(.ClassDeclaration, self.tok.start);
                return self.finish(decl);
            }
            if (self.isIdent("global")) {
                try self.advance();
                try self.skipBalanced("{", "}");
                return self.finish(decl);
            }
            // fallthrough to the plain TS declaration forms
        }
        if (try self.eatIdent("type")) {
            _ = try self.parseIdentifier();
            if (self.isPunct("<")) try self.skipTypeParameters();
            try self.expectPunct("=");
            _ = try self.parseType();
            try self.consumeSemicolon();
            return self.finish(decl);
        }
        if (try self.eatIdent("interface")) {
            _ = try self.parseIdentifier();
            if (self.isPunct("<")) try self.skipTypeParameters();
            if (try self.eatIdent("extends")) {
                while (true) {
                    _ = try self.parseType();
                    if (!try self.eatPunct(",")) break;
                }
            }
            try self.skipBalanced("{", "}");
            return self.finish(decl);
        }
        if (try self.eatIdent("enum")) {
            try self.skipEnum();
            return self.finish(decl);
        }
        if (self.isIdent("const")) {
            try self.advance();
            try self.expectIdent("enum");
            try self.skipEnum();
            return self.finish(decl);
        }
        if (try self.eatIdent("namespace") or try self.eatIdent("module")) {
            if (self.tok.kind == .string) try self.advance() else {
                _ = try self.parseIdentifier();
                while (try self.eatPunct(".")) _ = try self.parseIdentifier();
            }
            if (self.isPunct("{")) try self.skipBalanced("{", "}") else try self.consumeSemicolon();
            return self.finish(decl);
        }
        if (try self.eatIdent("global")) {
            try self.skipBalanced("{", "}");
            return self.finish(decl);
        }
        return self.unexpected();
    }

    fn skipEnum(self: *Parser) Error!void {
        _ = try self.parseIdentifier();
        try self.skipBalanced("{", "}");
    }

    /// Skip a balanced group; the current token must be `open`.
    fn skipBalanced(self: *Parser, open: []const u8, close: []const u8) Error!void {
        try self.expectPunct(open);
        var depth: usize = 1;
        var template_depths: std.ArrayList(usize) = .empty;
        defer template_depths.deinit(self.allocator);
        var brace_depth: usize = 0;
        while (depth > 0) {
            if (self.tok.kind == .eof) return self.fail("Unexpected end of input", .{});
            if (self.tok.kind == .template_head) {
                try template_depths.append(self.allocator, brace_depth);
                brace_depth += 1;
            } else if (self.tok.isPunct("{")) {
                brace_depth += 1;
                if (util.eql(open, "{")) depth += 1;
            } else if (self.tok.isPunct("}")) {
                if (template_depths.items.len > 0 and brace_depth == template_depths.items[template_depths.items.len - 1] + 1) {
                    brace_depth -= 1;
                    _ = template_depths.pop();
                    const cont = try self.lexer.rescanTemplateContinuation();
                    self.tok = cont;
                    if (cont.kind == .template_middle) {
                        try template_depths.append(self.allocator, brace_depth);
                        brace_depth += 1;
                    }
                } else {
                    if (brace_depth > 0) brace_depth -= 1;
                    if (util.eql(open, "{")) depth -= 1;
                }
            } else if (self.tok.isPunct(open)) {
                depth += 1;
            } else if (self.tok.isPunct(close)) {
                depth -= 1;
            }
            if (depth > 0) try self.advance();
        }
        try self.advance();
    }

    fn parseBlock(self: *Parser) Error!*Node {
        const block = try self.node(.BlockStatement, self.tok.start);
        try self.expectPunct("{");
        var list: NodeList = .empty;
        while (!self.isPunct("}")) {
            if (self.tok.kind == .eof) return self.fail("Unexpected end of input", .{});
            try list.append(self.allocator, try self.parseStatement());
        }
        try self.advance();
        block.statements = try list.toOwnedSlice(self.allocator);
        return self.finish(block);
    }

    fn parseVariableDeclaration(self: *Parser, no_in: bool) Error!*Node {
        const decl = try self.node(.VariableDeclaration, self.tok.start);
        decl.kind = if (util.eql(self.tok.text, "const")) .@"const" else if (util.eql(self.tok.text, "let")) .let else if (util.eql(self.tok.text, "using")) .using else .@"var";
        try self.advance();
        var list: NodeList = .empty;
        while (true) {
            const declarator = try self.node(.VariableDeclarator, self.tok.start);
            const id = try self.parseBindingTarget();
            if (self.isPunct("!") and !self.tok.newline_before) try self.eatTs();
            if (self.isPunct(":")) {
                id.type_annotation = try self.parseTypeAnnotation();
                id.end = self.prev_end;
            }
            declarator.id = id;
            if (try self.eatPunct("=")) declarator.init = try self.parseAssignment(no_in);
            try list.append(self.allocator, self.finish(declarator));
            if (!try self.eatPunct(",")) break;
        }
        decl.declarations = try list.toOwnedSlice(self.allocator);
        return self.finish(decl);
    }

    fn parseIf(self: *Parser) Error!*Node {
        const n = try self.node(.IfStatement, self.tok.start);
        try self.advance();
        try self.expectPunct("(");
        n.test_ = try self.parseExpression(false);
        try self.expectPunct(")");
        n.consequent = try self.parseStatement();
        if (try self.eatIdent("else")) n.alternate = try self.parseStatement();
        return self.finish(n);
    }

    fn parseWhile(self: *Parser) Error!*Node {
        const n = try self.node(.WhileStatement, self.tok.start);
        try self.advance();
        try self.expectPunct("(");
        n.test_ = try self.parseExpression(false);
        try self.expectPunct(")");
        n.body = try self.parseStatement();
        return self.finish(n);
    }

    fn parseDoWhile(self: *Parser) Error!*Node {
        const n = try self.node(.DoWhileStatement, self.tok.start);
        try self.advance();
        n.body = try self.parseStatement();
        try self.expectIdent("while");
        try self.expectPunct("(");
        n.test_ = try self.parseExpression(false);
        try self.expectPunct(")");
        _ = try self.eatPunct(";");
        return self.finish(n);
    }

    fn parseFor(self: *Parser) Error!*Node {
        const start = self.tok.start;
        try self.advance();
        var is_await = false;
        if (try self.eatIdent("await")) is_await = true;
        try self.expectPunct("(");
        var init: ?*Node = null;
        if (self.isPunct(";")) {
            // no init
        } else if (self.isIdent("var") or self.isIdent("const") or (self.isIdent("let") and try self.letIsDeclaration())) {
            init = try self.parseVariableDeclaration(true);
        } else {
            init = try self.parseExpression(true);
        }
        if (init != null and (self.isIdent("of") or self.isIdent("in"))) {
            const is_of = self.isIdent("of");
            try self.advance();
            const n = try self.node(if (is_of) .ForOfStatement else .ForInStatement, start);
            n.await_ = is_await;
            n.left = if (init.?.type == .VariableDeclaration) init.? else try self.toPattern(init.?);
            n.right = if (is_of) try self.parseAssignment(false) else try self.parseExpression(false);
            try self.expectPunct(")");
            n.body = try self.parseStatement();
            return self.finish(n);
        }
        const n = try self.node(.ForStatement, start);
        n.init = init;
        try self.expectPunct(";");
        if (!self.isPunct(";")) n.test_ = try self.parseExpression(false);
        try self.expectPunct(";");
        if (!self.isPunct(")")) n.update = try self.parseExpression(false);
        try self.expectPunct(")");
        n.body = try self.parseStatement();
        return self.finish(n);
    }

    fn parseReturn(self: *Parser) Error!*Node {
        const n = try self.node(.ReturnStatement, self.tok.start);
        try self.advance();
        if (!self.isPunct(";") and !self.isPunct("}") and self.tok.kind != .eof and !self.tok.newline_before) {
            n.argument = try self.parseExpression(false);
        }
        try self.consumeSemicolon();
        return self.finish(n);
    }

    fn parseBreakContinue(self: *Parser) Error!*Node {
        const n = try self.node(if (self.isIdent("break")) .BreakStatement else .ContinueStatement, self.tok.start);
        try self.advance();
        if (self.tok.kind == .identifier and !self.tok.newline_before and !isReserved(self.tok.text)) {
            n.label = try self.parseIdentifier();
        }
        try self.consumeSemicolon();
        return self.finish(n);
    }

    fn parseThrow(self: *Parser) Error!*Node {
        const n = try self.node(.ThrowStatement, self.tok.start);
        try self.advance();
        n.argument = try self.parseExpression(false);
        try self.consumeSemicolon();
        return self.finish(n);
    }

    fn parseTry(self: *Parser) Error!*Node {
        const n = try self.node(.TryStatement, self.tok.start);
        try self.advance();
        n.block = try self.parseBlock();
        if (self.isIdent("catch")) {
            const handler = try self.node(.CatchClause, self.tok.start);
            try self.advance();
            if (try self.eatPunct("(")) {
                const param = try self.parseBindingTarget();
                if (self.isPunct(":")) {
                    param.type_annotation = try self.parseTypeAnnotation();
                    param.end = self.prev_end;
                }
                handler.param = param;
                try self.expectPunct(")");
            }
            handler.body = try self.parseBlock();
            n.handler = self.finish(handler);
        }
        if (try self.eatIdent("finally")) n.finalizer = try self.parseBlock();
        return self.finish(n);
    }

    fn parseSwitch(self: *Parser) Error!*Node {
        const n = try self.node(.SwitchStatement, self.tok.start);
        try self.advance();
        try self.expectPunct("(");
        n.discriminant = try self.parseExpression(false);
        try self.expectPunct(")");
        try self.expectPunct("{");
        var cases: NodeList = .empty;
        while (!self.isPunct("}")) {
            const case = try self.node(.SwitchCase, self.tok.start);
            if (try self.eatIdent("case")) {
                case.test_ = try self.parseExpression(false);
            } else {
                try self.expectIdent("default");
            }
            try self.expectPunct(":");
            var body: NodeList = .empty;
            while (!self.isPunct("}") and !self.isIdent("case") and !self.isIdent("default")) {
                if (self.tok.kind == .eof) return self.fail("Unexpected end of input", .{});
                try body.append(self.allocator, try self.parseStatement());
            }
            case.consequents = try body.toOwnedSlice(self.allocator);
            try cases.append(self.allocator, self.finish(case));
        }
        try self.advance();
        n.cases = try cases.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    // ── Modules ────────────────────────────────────────────────────────────

    fn parseModuleExportName(self: *Parser) Error!*Node {
        if (self.tok.kind == .string) return self.parseLiteral();
        return self.parseIdentifierName();
    }

    fn parseImport(self: *Parser) Error!*Node {
        const n = try self.node(.ImportDeclaration, self.tok.start);
        try self.advance();
        var specifiers: NodeList = .empty;
        if (self.tok.kind == .string) {
            n.source = try self.parseLiteral();
            try self.skipImportAttributes();
            try self.consumeSemicolon();
            n.specifiers = &.{};
            return self.finish(n);
        }
        if (self.isIdent("type") and try self.peekIsAfter(isImportTypeFollow)) {
            try self.advance();
            n.import_kind = .type;
        }
        if (self.tok.kind == .identifier and !self.isPunct("{") and !self.isPunct("*")) {
            // `import x = require("y")` (TS) — skip as a TS declaration.
            if (try self.peekIsAfter(isEqualsToken)) {
                _ = try self.parseIdentifier();
                try self.expectPunct("=");
                _ = try self.parseExpression(false);
                try self.consumeSemicolon();
                const decl = try self.node(.TSDeclaration, n.start);
                return self.finish(decl);
            }
            const spec = try self.node(.ImportDefaultSpecifier, self.tok.start);
            spec.local = try self.parseIdentifier();
            try specifiers.append(self.allocator, self.finish(spec));
            if (!try self.eatPunct(",")) {
                try self.expectIdent("from");
                n.source = try self.parseStringLiteral();
                try self.skipImportAttributes();
                try self.consumeSemicolon();
                n.specifiers = try specifiers.toOwnedSlice(self.allocator);
                return self.finish(n);
            }
        }
        if (try self.eatPunct("*")) {
            const spec = try self.node(.ImportNamespaceSpecifier, self.prev_end - 1);
            try self.expectIdent("as");
            spec.local = try self.parseIdentifier();
            try specifiers.append(self.allocator, self.finish(spec));
        } else if (try self.eatPunct("{")) {
            while (!self.isPunct("}")) {
                const spec = try self.node(.ImportSpecifier, self.tok.start);
                if (self.isIdent("type") and try self.peekIsAfter(isSpecifierTypeFollow)) {
                    try self.advance();
                    spec.import_kind = .type;
                }
                const imported = try self.parseModuleExportName();
                spec.imported = imported;
                if (try self.eatIdent("as")) {
                    spec.local = try self.parseIdentifier();
                } else {
                    spec.local = try self.cloneAsIdentifier(imported);
                }
                try specifiers.append(self.allocator, self.finish(spec));
                if (!try self.eatPunct(",")) break;
            }
            try self.expectPunct("}");
        }
        try self.expectIdent("from");
        n.source = try self.parseStringLiteral();
        try self.skipImportAttributes();
        try self.consumeSemicolon();
        n.specifiers = try specifiers.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    fn isEqualsToken(tok: Token) bool {
        return tok.isPunct("=");
    }
    fn isImportTypeFollow(tok: Token) bool {
        return tok.isPunct("{") or tok.isPunct("*") or (tok.kind == .identifier and !tok.isIdent("from"));
    }
    fn isSpecifierTypeFollow(tok: Token) bool {
        // `type X`, `type X as Y`, but not `type as Y` / `type,` / `type }`
        return (tok.kind == .identifier or tok.kind == .string) and !tok.isIdent("as");
    }

    fn cloneAsIdentifier(self: *Parser, imported: *Node) Error!*Node {
        const local = try self.node(.Identifier, imported.start);
        local.end = imported.end;
        local.name = if (imported.type == .Literal) (imported.value.asString() orelse "") else imported.name;
        return local;
    }

    fn skipImportAttributes(self: *Parser) Error!void {
        if ((self.isIdent("with") or self.isIdent("assert")) and !self.tok.newline_before) {
            try self.advance();
            try self.skipBalanced("{", "}");
        }
    }

    fn parseExport(self: *Parser) Error!*Node {
        const start = self.tok.start;
        try self.advance();
        if (try self.eatIdent("default")) {
            const n = try self.node(.ExportDefaultDeclaration, start);
            if (self.isIdent("function")) {
                n.declaration = try self.parseFunction(.FunctionDeclaration, false, self.tok.start);
            } else if (self.isIdent("async") and try self.peekIsAfter(isFunctionNoNewline)) {
                const fstart = self.tok.start;
                try self.advance();
                n.declaration = try self.parseFunction(.FunctionDeclaration, true, fstart);
            } else if (self.isIdent("class")) {
                n.declaration = try self.parseClass(.ClassDeclaration, self.tok.start);
            } else if (self.isIdent("abstract") and try self.peekIsAfter(isClassToken)) {
                const cstart = self.tok.start;
                try self.eatTs();
                n.declaration = try self.parseClass(.ClassDeclaration, cstart);
            } else if (self.isIdent("interface") and try self.peekIsAfter(isIdentNoNewline)) {
                n.declaration = try self.parseTsSkipStatement();
            } else {
                n.declaration = try self.parseAssignment(false);
                try self.consumeSemicolon();
            }
            return self.finish(n);
        }
        if (self.isPunct("*")) {
            const n = try self.node(.ExportAllDeclaration, start);
            try self.advance();
            if (try self.eatIdent("as")) n.exported = try self.parseModuleExportName();
            try self.expectIdent("from");
            n.source = try self.parseStringLiteral();
            try self.skipImportAttributes();
            try self.consumeSemicolon();
            return self.finish(n);
        }
        if (self.isPunct("=")) {
            // `export = x;`
            try self.advance();
            _ = try self.parseExpression(false);
            try self.consumeSemicolon();
            return self.finish(try self.node(.TSDeclaration, start));
        }
        if (self.isIdent("as")) {
            // `export as namespace X;`
            try self.advance();
            try self.expectIdent("namespace");
            _ = try self.parseIdentifier();
            try self.consumeSemicolon();
            return self.finish(try self.node(.TSDeclaration, start));
        }
        const n = try self.node(.ExportNamedDeclaration, start);
        var type_only = false;
        if (self.isIdent("type") and try self.peekIsAfter(isBraceOrStar)) {
            try self.advance();
            type_only = true;
            n.export_kind = .type;
        }
        if (self.isPunct("{")) {
            try self.advance();
            var specifiers: NodeList = .empty;
            while (!self.isPunct("}")) {
                const spec = try self.node(.ExportSpecifier, self.tok.start);
                if (self.isIdent("type") and try self.peekIsAfter(isSpecifierTypeFollow)) {
                    try self.advance();
                    spec.export_kind = .type;
                }
                const local = try self.parseModuleExportName();
                spec.local = local;
                spec.exported = if (try self.eatIdent("as")) try self.parseModuleExportName() else try self.cloneAsIdentifier(local);
                try specifiers.append(self.allocator, self.finish(spec));
                if (!try self.eatPunct(",")) break;
            }
            try self.expectPunct("}");
            if (try self.eatIdent("from")) {
                n.source = try self.parseStringLiteral();
                try self.skipImportAttributes();
            }
            try self.consumeSemicolon();
            n.specifiers = try specifiers.toOwnedSlice(self.allocator);
            return self.finish(n);
        }
        // export declaration
        if (self.isIdent("var") or self.isIdent("let") or self.isIdent("const")) {
            if (self.isIdent("const") and try self.peekIsAfter(isEnumToken)) {
                n.declaration = try self.parseTsSkipStatement();
                n.export_kind = .type;
                return self.finish(n);
            }
            const decl = try self.parseVariableDeclaration(false);
            try self.consumeSemicolon();
            n.declaration = self.finish(decl);
            return self.finish(n);
        }
        if (self.isIdent("function")) {
            n.declaration = try self.parseFunction(.FunctionDeclaration, false, self.tok.start);
            return self.finish(n);
        }
        if (self.isIdent("async") and try self.peekIsAfter(isFunctionNoNewline)) {
            const fstart = self.tok.start;
            try self.advance();
            n.declaration = try self.parseFunction(.FunctionDeclaration, true, fstart);
            return self.finish(n);
        }
        if (self.isIdent("class")) {
            n.declaration = try self.parseClass(.ClassDeclaration, self.tok.start);
            return self.finish(n);
        }
        if (self.isIdent("abstract") and try self.peekIsAfter(isClassToken)) {
            const cstart = self.tok.start;
            try self.eatTs();
            n.declaration = try self.parseClass(.ClassDeclaration, cstart);
            return self.finish(n);
        }
        if (self.isPunct("@")) {
            try self.skipDecorators();
            n.declaration = try self.parseClass(.ClassDeclaration, self.tok.start);
            return self.finish(n);
        }
        if (try self.isTsDeclarationStart()) {
            n.declaration = try self.parseTsSkipStatement();
            n.export_kind = .type;
            return self.finish(n);
        }
        return self.unexpected();
    }

    fn isBraceOrStar(tok: Token) bool {
        return tok.isPunct("{") or tok.isPunct("*");
    }

    // ── Functions & classes ────────────────────────────────────────────────

    fn parseFunction(self: *Parser, t: Type, is_async: bool, start: u32) Error!*Node {
        const n = try self.node(t, start);
        n.async = is_async;
        try self.expectIdent("function");
        if (try self.eatPunct("*")) n.generator = true;
        if (self.tok.kind == .identifier and !self.isPunct("(")) {
            n.id = try self.parseIdentifier();
        }
        if (self.isPunct("<")) n.type_parameters = try self.parseTypeParametersNode();
        try self.parseFunctionRest(n);
        if (n.body == null) try self.recordTs(start, self.prev_end);
        return self.finish(n);
    }

    fn parseFunctionRest(self: *Parser, n: *Node) Error!void {
        n.params = try self.parseParams();
        if (self.isPunct(":")) n.return_type = try self.parseTypeAnnotation();
        if (self.isPunct("{")) {
            const saved_gen = self.in_generator;
            const saved_async = self.in_async;
            self.in_generator = n.generator;
            self.in_async = n.async;
            n.body = try self.parseBlock();
            self.in_generator = saved_gen;
            self.in_async = saved_async;
        } else {
            // Overload / declare signature without body.
            try self.consumeSemicolon();
        }
    }

    fn parseParams(self: *Parser) Error![]*Node {
        try self.expectPunct("(");
        var list: NodeList = .empty;
        while (!self.isPunct(")")) {
            if (self.isPunct("@")) try self.skipDecorators();
            // TS parameter property modifiers
            while (self.tok.kind == .identifier and isParamModifier(self.tok.text) and try self.peekIsAfter(isBindingStart)) {
                try self.eatTs();
            }
            // `this: T` pseudo-parameter
            if (self.isIdent("this") and try self.peekIsAfter(isColonToken)) {
                const this_start = self.tok.start;
                try self.advance();
                _ = try self.parseTypeAnnotation();
                const had_comma = self.isPunct(",");
                if (had_comma) try self.advance();
                try self.recordTs(this_start, self.prev_end);
                if (!had_comma) break;
                continue;
            }
            try list.append(self.allocator, try self.parseParam());
            if (!try self.eatPunct(",")) break;
        }
        try self.expectPunct(")");
        return list.toOwnedSlice(self.allocator);
    }

    fn isParamModifier(text: []const u8) bool {
        return util.eql(text, "public") or util.eql(text, "private") or util.eql(text, "protected") or util.eql(text, "readonly") or util.eql(text, "override");
    }

    fn isBindingStart(tok: Token) bool {
        return (tok.kind == .identifier and !tok.isPunct(",")) or tok.isPunct("{") or tok.isPunct("[");
    }

    fn parseParam(self: *Parser) Error!*Node {
        const start = self.tok.start;
        if (try self.eatPunct("...")) {
            const rest = try self.node(.RestElement, start);
            const target = try self.parseBindingTarget();
            if (self.isPunct(":")) {
                target.type_annotation = try self.parseTypeAnnotation();
                target.end = self.prev_end;
            }
            rest.argument = target;
            return self.finish(rest);
        }
        const target = try self.parseBindingTarget();
        if (self.isPunct("?")) {
            try self.eatTs();
            target.optional = true;
        }
        if (self.isPunct(":")) {
            target.type_annotation = try self.parseTypeAnnotation();
            target.end = self.prev_end;
        }
        if (try self.eatPunct("=")) {
            const assign = try self.node(.AssignmentPattern, start);
            assign.left = target;
            assign.right = try self.parseAssignment(false);
            return self.finish(assign);
        }
        return target;
    }

    /// Identifier | ObjectPattern | ArrayPattern (no default, no type).
    fn parseBindingTarget(self: *Parser) Error!*Node {
        if (self.isPunct("[")) return self.parseArrayPattern();
        if (self.isPunct("{")) return self.parseObjectPattern();
        return self.parseIdentifier();
    }

    /// Binding element: target with optional default.
    fn parseBindingElement(self: *Parser) Error!*Node {
        const start = self.tok.start;
        const target = try self.parseBindingTarget();
        if (try self.eatPunct("=")) {
            const assign = try self.node(.AssignmentPattern, start);
            assign.left = target;
            assign.right = try self.parseAssignment(false);
            return self.finish(assign);
        }
        return target;
    }

    fn parseArrayPattern(self: *Parser) Error!*Node {
        const n = try self.node(.ArrayPattern, self.tok.start);
        try self.expectPunct("[");
        var list: OptNodeList = .empty;
        while (!self.isPunct("]")) {
            if (self.isPunct(",")) {
                try self.advance();
                try list.append(self.allocator, null);
                continue;
            }
            if (self.isPunct("...")) {
                const rest = try self.node(.RestElement, self.tok.start);
                try self.advance();
                rest.argument = try self.parseBindingTarget();
                try list.append(self.allocator, self.finish(rest));
            } else {
                try list.append(self.allocator, try self.parseBindingElement());
            }
            if (!try self.eatPunct(",")) break;
        }
        try self.expectPunct("]");
        n.elements = try list.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    fn parseObjectPattern(self: *Parser) Error!*Node {
        const n = try self.node(.ObjectPattern, self.tok.start);
        try self.expectPunct("{");
        var list: NodeList = .empty;
        while (!self.isPunct("}")) {
            if (self.isPunct("...")) {
                const rest = try self.node(.RestElement, self.tok.start);
                try self.advance();
                rest.argument = try self.parseBindingTarget();
                try list.append(self.allocator, self.finish(rest));
            } else {
                const prop = try self.node(.Property, self.tok.start);
                prop.kind = .init;
                if (self.isPunct("[")) {
                    try self.advance();
                    prop.computed = true;
                    prop.key = try self.parseAssignment(false);
                    try self.expectPunct("]");
                } else {
                    prop.key = try self.parsePropertyKey();
                }
                if (try self.eatPunct(":")) {
                    prop.value_node = try self.parseBindingElement();
                } else {
                    prop.shorthand = true;
                    const key = prop.key.?;
                    if (key.type != .Identifier) return self.unexpected();
                    const value = try self.cloneAsIdentifier(key);
                    if (try self.eatPunct("=")) {
                        const assign = try self.node(.AssignmentPattern, key.start);
                        assign.left = value;
                        assign.right = try self.parseAssignment(false);
                        prop.value_node = self.finish(assign);
                    } else {
                        prop.value_node = value;
                    }
                }
                try list.append(self.allocator, self.finish(prop));
            }
            if (!try self.eatPunct(",")) break;
        }
        try self.expectPunct("}");
        n.properties = try list.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    fn parseClass(self: *Parser, t: Type, start: u32) Error!*Node {
        const n = try self.node(t, start);
        try self.expectIdent("class");
        if (self.tok.kind == .identifier and !self.isIdent("extends") and !self.isIdent("implements") and !self.isPunct("{")) {
            n.id = try self.parseIdentifier();
        }
        if (self.isPunct("<")) n.type_parameters = try self.parseTypeParametersNode();
        if (try self.eatIdent("extends")) {
            n.super_class = try self.parseLeftHandSideNoCall(false);
            if (self.isPunct("<")) try self.skipTypeArguments();
        }
        if (self.isIdent("implements")) {
            const impl_start = self.tok.start;
            try self.advance();
            while (true) {
                _ = try self.parseType();
                if (!try self.eatPunct(",")) break;
            }
            try self.recordTs(impl_start, self.prev_end);
        }
        const body = try self.node(.ClassBody, self.tok.start);
        try self.expectPunct("{");
        var members: NodeList = .empty;
        while (!self.isPunct("}")) {
            if (try self.eatPunct(";")) continue;
            if (try self.parseClassMember()) |member| try members.append(self.allocator, member);
        }
        try self.advance();
        body.statements = try members.toOwnedSlice(self.allocator);
        n.body = self.finish(body);
        return self.finish(n);
    }

    const member_modifiers = [_][]const u8{ "static", "public", "private", "protected", "readonly", "abstract", "override", "declare", "accessor" };

    fn isMemberModifier(text: []const u8) bool {
        for (member_modifiers) |m| if (util.eql(m, text)) return true;
        return false;
    }

    fn isMemberNameFollow(tok: Token) bool {
        // A modifier is a modifier only when followed by another member-name-ish token.
        return !(tok.isPunct("(") or tok.isPunct("=") or tok.isPunct(";") or tok.isPunct(":") or tok.isPunct("?") or tok.isPunct("!") or tok.isPunct("}") or tok.isPunct("<") or tok.newline_before);
    }

    fn parseClassMember(self: *Parser) Error!?*Node {
        const start = self.tok.start;
        if (self.isPunct("@")) try self.skipDecorators();
        var is_static = false;
        var is_declare = false;
        while (self.tok.kind == .identifier and isMemberModifier(self.tok.text) and try self.peekIsAfter(isMemberNameFollow)) {
            if (self.isIdent("static")) {
                if (try self.peekIsAfter(isBraceNoNewline)) {
                    try self.advance();
                    const block = try self.node(.StaticBlock, start);
                    const inner = try self.parseBlock();
                    block.statements = inner.statements;
                    return self.finish(block);
                }
                is_static = true;
            }
            if (self.isIdent("declare")) is_declare = true;
            if (self.isIdent("static") or self.isIdent("accessor")) try self.advance() else try self.eatTs();
        }
        // Index signature `[key: string]: T;`
        if (self.isPunct("[") and try self.isIndexSignature()) {
            try self.skipBalanced("[", "]");
            if (self.isPunct(":")) _ = try self.parseTypeAnnotation();
            try self.consumeSemicolon();
            try self.recordTs(start, self.prev_end);
            return null;
        }
        var kind: ast.Kind = .method;
        var is_async = false;
        var is_generator = false;
        if ((self.isIdent("get") or self.isIdent("set")) and try self.peekIsAfter(isMemberNameFollow)) {
            kind = if (self.isIdent("get")) .get else .set;
            try self.advance();
        } else if (self.isIdent("async") and try self.peekIsAfter(isMemberNameFollowNoNewline)) {
            is_async = true;
            try self.advance();
        }
        if (try self.eatPunct("*")) is_generator = true;
        var computed = false;
        var key: *Node = undefined;
        if (self.isPunct("[")) {
            try self.advance();
            computed = true;
            key = try self.parseAssignment(false);
            try self.expectPunct("]");
        } else if (self.tok.kind == .private_name) {
            key = try self.node(.PrivateIdentifier, self.tok.start);
            key.name = self.tok.text;
            try self.advance();
            key = self.finish(key);
        } else {
            key = try self.parsePropertyKey();
        }
        if (self.isPunct("?")) try self.eatTs();
        if (self.isPunct("!")) try self.eatTs();
        if (self.isPunct("(") or self.isPunct("<")) {
            const method = try self.node(.MethodDefinition, start);
            method.key = key;
            method.computed = computed;
            method.static = is_static;
            if (kind == .method and !computed and key.type == .Identifier and util.eql(key.name, "constructor")) kind = .constructor;
            method.kind = kind;
            const fn_node = try self.node(.FunctionExpression, self.tok.start);
            fn_node.async = is_async;
            fn_node.generator = is_generator;
            if (self.isPunct("<")) fn_node.type_parameters = try self.parseTypeParametersNode();
            try self.parseFunctionRest(fn_node);
            method.value_node = self.finish(fn_node);
            if (fn_node.body == null) {
                try self.recordTs(start, self.prev_end); // overload signature
                return null;
            }
            return self.finish(method);
        }
        const prop = try self.node(.PropertyDefinition, start);
        prop.key = key;
        prop.computed = computed;
        prop.static = is_static;
        if (self.isPunct(":")) prop.type_annotation = try self.parseTypeAnnotation();
        if (try self.eatPunct("=")) prop.value_node = try self.parseAssignment(false);
        try self.consumeSemicolon();
        if (is_declare) {
            try self.recordTs(start, self.prev_end);
            return null;
        }
        return self.finish(prop);
    }

    fn isMemberNameFollowNoNewline(tok: Token) bool {
        return isMemberNameFollow(tok) and !tok.newline_before;
    }

    fn isIndexSignature(self: *Parser) Error!bool {
        const snap = self.snapshot();
        defer self.rewind(snap);
        try self.advance();
        if (self.tok.kind != .identifier) return false;
        try self.advance();
        return self.isPunct(":");
    }

    // ── Expressions ────────────────────────────────────────────────────────

    fn parseExpression(self: *Parser, no_in: bool) Error!*Node {
        const start = self.tok.start;
        const first = try self.parseAssignment(no_in);
        if (!self.isPunct(",")) return first;
        const seq = try self.node(.SequenceExpression, start);
        var list: NodeList = .empty;
        try list.append(self.allocator, first);
        while (try self.eatPunct(",")) {
            try list.append(self.allocator, try self.parseAssignment(no_in));
        }
        seq.expressions = try list.toOwnedSlice(self.allocator);
        return self.finish(seq);
    }

    const assignment_operators = [_][]const u8{ "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??=" };

    fn isAssignmentOperator(tok: Token) bool {
        if (tok.kind != .punct) return false;
        for (assignment_operators) |op| if (util.eql(op, tok.text)) return true;
        return false;
    }

    fn parseAssignment(self: *Parser, no_in: bool) Error!*Node {
        const start = self.tok.start;
        // yield
        if (self.isIdent("yield") and self.in_generator) {
            const n = try self.node(.YieldExpression, start);
            try self.advance();
            if (try self.eatPunct("*")) n.generator = true;
            if (!self.tok.newline_before and !self.isPunct(")") and !self.isPunct("]") and !self.isPunct("}") and !self.isPunct(",") and !self.isPunct(";") and !self.isPunct(":") and self.tok.kind != .eof) {
                n.argument = try self.parseAssignment(no_in);
            }
            return self.finish(n);
        }
        if (try self.tryParseArrow(no_in)) |arrow| return arrow;

        const left = try self.parseConditional(no_in);
        if (isAssignmentOperator(self.tok)) {
            const op = self.tok.text;
            try self.advance();
            const n = try self.node(.AssignmentExpression, start);
            n.operator = op;
            n.left = if (util.eql(op, "=")) try self.toPattern(left) else left;
            n.right = try self.parseAssignment(no_in);
            return self.finish(n);
        }
        return left;
    }

    /// Arrow function detection & parse; null when the current position is not an arrow.
    fn tryParseArrow(self: *Parser, no_in: bool) Error!?*Node {
        const start = self.tok.start;
        var is_async = false;
        const snap = self.snapshot();
        if (self.isIdent("async") and !try self.peekIsAfter(isArrowToken)) {
            const after = try self.peek();
            if (!after.newline_before and (after.kind == .identifier or after.isPunct("(") or after.isPunct("<"))) {
                try self.advance();
                is_async = true;
            }
        }
        // Single identifier param: `x => …`
        if (isBindingIdentToken(self.tok) and try self.peekIsAfter(isArrowToken)) {
            const param = try self.parseIdentifier();
            try self.expectPunct("=>");
            const params = try self.allocator.alloc(*Node, 1);
            params[0] = param;
            return try self.parseArrowBody(start, params, is_async, no_in);
        }
        // Generic arrow `<T,>(…) =>` / `<T extends X>(…) =>`
        var type_params: ?*Node = null;
        if (self.isPunct("<") and try self.looksLikeGenericArrow()) {
            type_params = try self.parseTypeParametersNode();
        }
        if (self.isPunct("(") and try self.isArrowAfterParen()) {
            const params = try self.parseParams();
            var return_type: ?*Node = null;
            if (self.isPunct(":")) return_type = try self.parseTypeAnnotation();
            try self.expectPunct("=>");
            const arrow = try self.parseArrowBody(start, params, is_async, no_in);
            arrow.type_parameters = type_params;
            arrow.return_type = return_type;
            return arrow;
        }
        self.rewind(snap);
        return null;
    }

    fn looksLikeGenericArrow(self: *Parser) Error!bool {
        const snap = self.snapshot();
        defer self.rewind(snap);
        try self.advance();
        if (self.tok.kind != .identifier) return false;
        try self.advance();
        return self.isPunct(",") or self.isIdent("extends") or self.isPunct("=") or (self.isPunct(">") and try self.peekIsAfter(isParenToken));
    }

    fn isParenToken(tok: Token) bool {
        return tok.isPunct("(");
    }

    /// At `(`: does a balanced group followed by `=>` (or `: Type =>`) follow?
    fn isArrowAfterParen(self: *Parser) Error!bool {
        const snap = self.snapshot();
        defer self.rewind(snap);
        self.skipBalanced("(", ")") catch return false;
        if (self.isPunct("=>") and !self.tok.newline_before) return true;
        if (self.isPunct(":")) {
            _ = self.parseTypeAnnotation() catch return false;
            return self.isPunct("=>") and !self.tok.newline_before;
        }
        return false;
    }

    fn parseArrowBody(self: *Parser, start: u32, params: []*Node, is_async: bool, no_in: bool) Error!*Node {
        const arrow = try self.node(.ArrowFunctionExpression, start);
        arrow.params = params;
        arrow.async = is_async;
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.in_async = is_async;
        self.in_generator = false;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
        }
        if (self.isPunct("{")) {
            arrow.body = try self.parseBlock();
        } else {
            arrow.expression_body = true;
            arrow.body = try self.parseAssignment(no_in);
        }
        return self.finish(arrow);
    }

    fn parseConditional(self: *Parser, no_in: bool) Error!*Node {
        const start = self.tok.start;
        const test_ = try self.parseBinary(0, no_in);
        if (!self.isPunct("?")) return test_;
        try self.advance();
        const n = try self.node(.ConditionalExpression, start);
        n.test_ = test_;
        n.consequent = try self.parseAssignment(false);
        try self.expectPunct(":");
        n.alternate = try self.parseAssignment(no_in);
        return self.finish(n);
    }

    fn binaryPrecedence(tok: Token, no_in: bool) u8 {
        if (tok.kind == .identifier) {
            if (tok.isIdent("in")) return if (no_in) 0 else 10;
            if (tok.isIdent("instanceof")) return 10;
            if ((tok.isIdent("as") or tok.isIdent("satisfies")) and !tok.newline_before) return 10;
            return 0;
        }
        if (tok.kind != .punct) return 0;
        const t = tok.text;
        if (util.eql(t, "??")) return 4;
        if (util.eql(t, "||")) return 4;
        if (util.eql(t, "&&")) return 5;
        if (util.eql(t, "|")) return 6;
        if (util.eql(t, "^")) return 7;
        if (util.eql(t, "&")) return 8;
        if (util.eql(t, "==") or util.eql(t, "!=") or util.eql(t, "===") or util.eql(t, "!==")) return 9;
        if (util.eql(t, "<") or util.eql(t, ">") or util.eql(t, "<=") or util.eql(t, ">=")) return 10;
        if (util.eql(t, "<<") or util.eql(t, ">>") or util.eql(t, ">>>")) return 11;
        if (util.eql(t, "+") or util.eql(t, "-")) return 12;
        if (util.eql(t, "*") or util.eql(t, "/") or util.eql(t, "%")) return 13;
        if (util.eql(t, "**")) return 14;
        return 0;
    }

    fn parseBinary(self: *Parser, min_prec: u8, no_in: bool) Error!*Node {
        const start = self.tok.start;
        var left = try self.parseUnary();
        while (true) {
            const prec = binaryPrecedence(self.tok, no_in);
            if (prec == 0 or prec <= min_prec) {
                // `**` is right-associative
                if (!(prec == 14 and min_prec == 14)) break;
            }
            if (self.isIdent("as") or self.isIdent("satisfies")) {
                const n = try self.node(if (self.isIdent("as")) .TSAsExpression else .TSSatisfiesExpression, start);
                try self.advance();
                n.expression = left;
                n.type_annotation = try self.parseType();
                try self.recordTs(left.end, self.prev_end);
                left = self.finish(n);
                continue;
            }
            const op = self.tok.text;
            try self.advance();
            const is_logical = util.eql(op, "&&") or util.eql(op, "||") or util.eql(op, "??");
            const n = try self.node(if (is_logical) .LogicalExpression else .BinaryExpression, start);
            n.operator = op;
            n.left = left;
            n.right = try self.parseBinary(if (prec == 14) prec - 1 else prec, no_in);
            left = self.finish(n);
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!*Node {
        const start = self.tok.start;
        if (self.tok.kind == .punct) {
            const t = self.tok.text;
            if (util.eql(t, "!") or util.eql(t, "~") or util.eql(t, "+") or util.eql(t, "-")) {
                try self.advance();
                const n = try self.node(.UnaryExpression, start);
                n.operator = t;
                n.prefix = true;
                n.argument = try self.parseUnary();
                return self.finish(n);
            }
            if (util.eql(t, "++") or util.eql(t, "--")) {
                try self.advance();
                const n = try self.node(.UpdateExpression, start);
                n.operator = t;
                n.prefix = true;
                n.argument = try self.parseUnary();
                return self.finish(n);
            }
        } else if (self.tok.kind == .identifier) {
            const t = self.tok.text;
            if (util.eql(t, "typeof") or util.eql(t, "void") or util.eql(t, "delete")) {
                try self.advance();
                const n = try self.node(.UnaryExpression, start);
                n.operator = t;
                n.prefix = true;
                n.argument = try self.parseUnary();
                return self.finish(n);
            }
            if (util.eql(t, "await") and try self.awaitIsExpression()) {
                try self.advance();
                const n = try self.node(.AwaitExpression, start);
                n.argument = try self.parseUnary();
                return self.finish(n);
            }
        }
        const expr = try self.parseLeftHandSide();
        if ((self.isPunct("++") or self.isPunct("--")) and !self.tok.newline_before) {
            const n = try self.node(.UpdateExpression, start);
            n.operator = self.tok.text;
            n.prefix = false;
            n.argument = expr;
            try self.advance();
            return self.finish(n);
        }
        if (self.isPunct("**")) {
            // exponent binds tighter than unary handled in parseBinary via precedence
        }
        return expr;
    }

    fn awaitIsExpression(self: *Parser) Error!bool {
        if (self.in_async) return true;
        // Module top-level await: `await` followed by an expression start on the same line.
        const next = try self.peek();
        if (next.newline_before) return false;
        return next.kind == .identifier or next.kind == .number or next.kind == .string or next.isPunct("(") or next.isPunct("[") or next.isPunct("{") or next.kind == .template_head or next.kind == .template_no_subst;
    }

    fn parseLeftHandSide(self: *Parser) Error!*Node {
        return self.parseCallTail(try self.parseMemberOrNew(), true);
    }

    /// `new` expressions and member chains (no calls) — `extends` clauses / `new` callees.
    fn parseLeftHandSideNoCall(self: *Parser, allow_call: bool) Error!*Node {
        return self.parseCallTail(try self.parseMemberOrNew(), allow_call);
    }

    fn parseMemberOrNew(self: *Parser) Error!*Node {
        const start = self.tok.start;
        if (self.isIdent("new")) {
            try self.advance();
            if (self.isPunct(".")) {
                try self.advance();
                const meta = try self.node(.MetaProperty, start);
                const m = try self.node(.Identifier, start);
                m.name = "new";
                m.end = start + 3;
                meta.meta = m;
                meta.property = try self.parseIdentifierName();
                return self.finish(meta);
            }
            const n = try self.node(.NewExpression, start);
            n.callee = try self.parseLeftHandSideNoCall(false);
            if (self.isPunct("<") and try self.tryTypeArguments()) {}
            if (self.isPunct("(")) {
                n.arguments = try self.parseArguments();
            }
            return self.finish(n);
        }
        if (self.isIdent("import") and try self.peekIsAfter(isParenOrDot)) {
            try self.advance();
            if (try self.eatPunct(".")) {
                const meta = try self.node(.MetaProperty, start);
                const m = try self.node(.Identifier, start);
                m.name = "import";
                m.end = start + 6;
                meta.meta = m;
                meta.property = try self.parseIdentifierName();
                return self.finish(meta);
            }
            const n = try self.node(.ImportExpression, start);
            try self.expectPunct("(");
            n.source = try self.parseAssignment(false);
            if (try self.eatPunct(",")) {
                if (!self.isPunct(")")) {
                    _ = try self.parseAssignment(false);
                    _ = try self.eatPunct(",");
                }
            }
            try self.expectPunct(")");
            return self.finish(n);
        }
        return self.parsePrimary();
    }

    fn parseArguments(self: *Parser) Error![]*Node {
        try self.expectPunct("(");
        var list: NodeList = .empty;
        while (!self.isPunct(")")) {
            if (self.isPunct("...")) {
                const spread = try self.node(.SpreadElement, self.tok.start);
                try self.advance();
                spread.argument = try self.parseAssignment(false);
                try list.append(self.allocator, self.finish(spread));
            } else {
                try list.append(self.allocator, try self.parseAssignment(false));
            }
            if (!try self.eatPunct(",")) break;
        }
        try self.expectPunct(")");
        return list.toOwnedSlice(self.allocator);
    }

    /// Speculatively consume `<…>` type arguments when followed by `(` / template / `?.`.
    fn tryTypeArguments(self: *Parser) Error!bool {
        const snap = self.snapshot();
        self.skipTypeArguments() catch {
            self.rewind(snap);
            return false;
        };
        if (self.isPunct("(") or self.tok.kind == .template_head or self.tok.kind == .template_no_subst or self.isPunct("?.")) return true;
        self.rewind(snap);
        return false;
    }

    fn parseCallTail(self: *Parser, base: *Node, allow_call: bool) Error!*Node {
        const start = base.start;
        var expr = base;
        var in_chain = false;
        while (true) {
            if (self.isPunct(".")) {
                try self.advance();
                const n = try self.node(.MemberExpression, start);
                n.object = expr;
                n.property = try self.parsePropertyName();
                expr = self.finish(n);
            } else if (self.isPunct("?.")) {
                try self.advance();
                in_chain = true;
                if (self.isPunct("(")) {
                    if (!allow_call) break;
                    const n = try self.node(.CallExpression, start);
                    n.callee = expr;
                    n.optional = true;
                    n.arguments = try self.parseArguments();
                    expr = self.finish(n);
                } else if (self.isPunct("[")) {
                    try self.advance();
                    const n = try self.node(.MemberExpression, start);
                    n.object = expr;
                    n.computed = true;
                    n.optional = true;
                    n.property = try self.parseExpression(false);
                    try self.expectPunct("]");
                    expr = self.finish(n);
                } else {
                    const n = try self.node(.MemberExpression, start);
                    n.object = expr;
                    n.optional = true;
                    n.property = try self.parsePropertyName();
                    expr = self.finish(n);
                }
            } else if (self.isPunct("[")) {
                try self.advance();
                const n = try self.node(.MemberExpression, start);
                n.object = expr;
                n.computed = true;
                n.property = try self.parseExpression(false);
                try self.expectPunct("]");
                expr = self.finish(n);
            } else if (self.isPunct("(") and allow_call) {
                const n = try self.node(.CallExpression, start);
                n.callee = expr;
                n.arguments = try self.parseArguments();
                expr = self.finish(n);
            } else if (self.tok.kind == .template_head or self.tok.kind == .template_no_subst) {
                const n = try self.node(.TaggedTemplateExpression, start);
                n.tag = expr;
                n.quasi = try self.parseTemplate(true);
                expr = self.finish(n);
            } else if (self.isPunct("!") and !self.tok.newline_before and !try self.peekIsAfter(isAssignLike)) {
                try self.eatTs();
                const n = try self.node(.TSNonNullExpression, start);
                n.expression = expr;
                expr = self.finish(n);
            } else if (self.isPunct("<") and allow_call and !self.tok.newline_before and try self.tryTypeArguments()) {
                // type arguments consumed; loop continues to the call/template.
                if (self.isPunct("?.")) continue;
            } else break;
        }
        if (in_chain) {
            const chain = try self.node(.ChainExpression, start);
            chain.expression = expr;
            return self.finish(chain);
        }
        return expr;
    }

    fn isAssignLike(tok: Token) bool {
        // `x != y` lexes as `!=`, so a lone `!` followed by `=` can only be non-null + assignment;
        // treat `! =` (with space) as non-null anyway. Nothing to reject here.
        _ = tok;
        return false;
    }

    fn parsePropertyName(self: *Parser) Error!*Node {
        if (self.tok.kind == .private_name) {
            const n = try self.node(.PrivateIdentifier, self.tok.start);
            n.name = self.tok.text;
            try self.advance();
            return self.finish(n);
        }
        return self.parseIdentifierName();
    }

    fn parsePrimary(self: *Parser) Error!*Node {
        const start = self.tok.start;
        switch (self.tok.kind) {
            .identifier => {
                const t = self.tok.text;
                if (util.eql(t, "this")) {
                    try self.advance();
                    return self.finish(try self.node(.ThisExpression, start));
                }
                if (util.eql(t, "super")) {
                    try self.advance();
                    return self.finish(try self.node(.Super, start));
                }
                if (util.eql(t, "function")) return self.parseFunction(.FunctionExpression, false, start);
                if (util.eql(t, "async") and try self.peekIsAfter(isFunctionNoNewline)) {
                    try self.advance();
                    return self.parseFunction(.FunctionExpression, true, start);
                }
                if (util.eql(t, "class")) return self.parseClass(.ClassExpression, start);
                if (util.eql(t, "null") or util.eql(t, "true") or util.eql(t, "false")) return self.parseLiteral();
                if (isReserved(t)) return self.unexpected();
                return self.parseIdentifier();
            },
            .number, .string, .bigint => return self.parseLiteral(),
            .template_head, .template_no_subst => return self.parseTemplate(false),
            .private_name => {
                // `#x in obj`
                const n = try self.node(.PrivateIdentifier, start);
                n.name = self.tok.text;
                try self.advance();
                return self.finish(n);
            },
            .punct => {
                const t = self.tok.text;
                if (util.eql(t, "(")) {
                    try self.advance();
                    const inner = try self.parseExpression(false);
                    try self.expectPunct(")");
                    const n = try self.node(.ParenthesizedExpression, start);
                    n.expression = inner;
                    return self.finish(n);
                }
                if (util.eql(t, "[")) return self.parseArrayLiteral();
                if (util.eql(t, "{")) return self.parseObjectLiteral();
                if (util.eql(t, "/") or util.eql(t, "/=")) {
                    const tok = try self.lexer.rescanRegex();
                    self.tok = tok;
                    return self.parseLiteral();
                }
                if (util.eql(t, "<")) return self.parseJsx();
                return self.unexpected();
            },
            else => return self.unexpected(),
        }
    }

    fn parseIdentifier(self: *Parser) Error!*Node {
        if (self.tok.kind != .identifier or isReserved(self.tok.text)) return self.unexpected();
        const n = try self.node(.Identifier, self.tok.start);
        n.name = self.tok.text;
        try self.advance();
        return self.finish(n);
    }

    /// Any IdentifierName (keywords allowed) — property names, import/export names.
    fn parseIdentifierName(self: *Parser) Error!*Node {
        if (self.tok.kind != .identifier) return self.unexpected();
        const n = try self.node(.Identifier, self.tok.start);
        n.name = self.tok.text;
        try self.advance();
        return self.finish(n);
    }

    fn parseStringLiteral(self: *Parser) Error!*Node {
        if (self.tok.kind != .string) return self.unexpected();
        return self.parseLiteral();
    }

    fn parseLiteral(self: *Parser) Error!*Node {
        const n = try self.node(.Literal, self.tok.start);
        n.raw = self.src[self.tok.start..self.tok.end];
        switch (self.tok.kind) {
            .string => n.value = .{ .string = self.tok.text },
            .number => n.value = .{ .number = self.tok.number },
            .bigint => n.value = .{ .bigint = self.tok.text },
            .regex => n.value = .{ .regex = self.tok.text },
            .identifier => {
                if (self.isIdent("null")) n.value = .null else if (self.isIdent("true")) n.value = .{ .boolean = true } else if (self.isIdent("false")) n.value = .{ .boolean = false } else return self.unexpected();
            },
            else => return self.unexpected(),
        }
        try self.advance();
        return self.finish(n);
    }

    fn parseTemplate(self: *Parser, tagged: bool) Error!*Node {
        const n = try self.node(.TemplateLiteral, self.tok.start);
        var quasis: NodeList = .empty;
        var expressions: NodeList = .empty;
        while (true) {
            const tok = self.tok;
            const element = try self.node(.TemplateElement, tok.start + 1);
            const raw_end: u32 = if (tok.kind == .template_no_subst or tok.kind == .template_tail) tok.end - 1 else tok.end - 2;
            element.end = raw_end;
            element.raw = self.src[tok.start + 1 .. raw_end];
            element.cooked = if (tok.cooked_invalid) null else tok.text;
            if (tok.cooked_invalid and !tagged) return self.fail("Invalid escape sequence in template", .{});
            element.tail = tok.kind == .template_no_subst or tok.kind == .template_tail;
            try quasis.append(self.allocator, element);
            if (element.tail) {
                try self.advance();
                break;
            }
            try self.advance();
            try expressions.append(self.allocator, try self.parseExpression(false));
            if (!self.isPunct("}")) return self.unexpected();
            self.tok = try self.lexer.rescanTemplateContinuation();
        }
        n.quasis = try quasis.toOwnedSlice(self.allocator);
        n.expressions = try expressions.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    fn parseArrayLiteral(self: *Parser) Error!*Node {
        const n = try self.node(.ArrayExpression, self.tok.start);
        try self.expectPunct("[");
        var list: OptNodeList = .empty;
        while (!self.isPunct("]")) {
            if (self.isPunct(",")) {
                try self.advance();
                try list.append(self.allocator, null);
                continue;
            }
            if (self.isPunct("...")) {
                const spread = try self.node(.SpreadElement, self.tok.start);
                try self.advance();
                spread.argument = try self.parseAssignment(false);
                try list.append(self.allocator, self.finish(spread));
            } else {
                try list.append(self.allocator, try self.parseAssignment(false));
            }
            if (!try self.eatPunct(",")) break;
        }
        try self.expectPunct("]");
        n.elements = try list.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    fn parsePropertyKey(self: *Parser) Error!*Node {
        return switch (self.tok.kind) {
            .identifier => self.parseIdentifierName(),
            .string, .number, .bigint => self.parseLiteral(),
            else => self.unexpected(),
        };
    }

    fn isPropertyKeyFollow(tok: Token) bool {
        return !(tok.isPunct(",") or tok.isPunct(":") or tok.isPunct("(") or tok.isPunct("}") or tok.isPunct("=") or tok.isPunct("<") or tok.isPunct("?"));
    }

    fn parseObjectLiteral(self: *Parser) Error!*Node {
        const n = try self.node(.ObjectExpression, self.tok.start);
        try self.expectPunct("{");
        var list: NodeList = .empty;
        while (!self.isPunct("}")) {
            const start = self.tok.start;
            if (self.isPunct("...")) {
                const spread = try self.node(.SpreadElement, start);
                try self.advance();
                spread.argument = try self.parseAssignment(false);
                try list.append(self.allocator, self.finish(spread));
            } else {
                const prop = try self.node(.Property, start);
                prop.kind = .init;
                var is_async = false;
                var is_generator = false;
                if ((self.isIdent("get") or self.isIdent("set")) and try self.peekIsAfter(isPropertyKeyFollow)) {
                    prop.kind = if (self.isIdent("get")) .get else .set;
                    try self.advance();
                } else if (self.isIdent("async") and try self.peekIsAfter(isPropertyKeyFollowNoNewline)) {
                    is_async = true;
                    try self.advance();
                }
                if (try self.eatPunct("*")) is_generator = true;
                if (self.isPunct("[")) {
                    try self.advance();
                    prop.computed = true;
                    prop.key = try self.parseAssignment(false);
                    try self.expectPunct("]");
                } else {
                    prop.key = try self.parsePropertyKey();
                }
                if (self.isPunct("(") or self.isPunct("<")) {
                    prop.method = prop.kind == .init;
                    const fn_node = try self.node(.FunctionExpression, self.tok.start);
                    fn_node.async = is_async;
                    fn_node.generator = is_generator;
                    if (self.isPunct("<")) fn_node.type_parameters = try self.parseTypeParametersNode();
                    try self.parseFunctionRest(fn_node);
                    prop.value_node = self.finish(fn_node);
                } else if (try self.eatPunct(":")) {
                    prop.value_node = try self.parseAssignment(false);
                } else {
                    const key = prop.key.?;
                    if (key.type != .Identifier or prop.computed) return self.unexpected();
                    prop.shorthand = true;
                    const value = try self.cloneAsIdentifier(key);
                    if (self.isPunct("=")) {
                        // Cover grammar: `{ a = 1 }` only valid as a pattern.
                        try self.advance();
                        const assign = try self.node(.AssignmentPattern, key.start);
                        assign.left = value;
                        assign.right = try self.parseAssignment(false);
                        prop.value_node = self.finish(assign);
                    } else {
                        prop.value_node = value;
                    }
                }
                try list.append(self.allocator, self.finish(prop));
            }
            if (!try self.eatPunct(",")) break;
        }
        try self.expectPunct("}");
        n.properties = try list.toOwnedSlice(self.allocator);
        return self.finish(n);
    }

    fn isPropertyKeyFollowNoNewline(tok: Token) bool {
        return isPropertyKeyFollow(tok) and !tok.newline_before;
    }

    /// Reinterpret an expression as an assignment target pattern.
    fn toPattern(self: *Parser, expr: *Node) Error!*Node {
        switch (expr.type) {
            .ArrayExpression => {
                expr.type = .ArrayPattern;
                for (expr.elements) |maybe| {
                    if (maybe) |el| {
                        if (el.type == .SpreadElement) {
                            el.type = .RestElement;
                            el.argument = try self.toPattern(el.argument.?);
                        } else {
                            _ = try self.toPattern(el);
                        }
                    }
                }
            },
            .ObjectExpression => {
                expr.type = .ObjectPattern;
                for (expr.properties) |prop| {
                    if (prop.type == .SpreadElement) {
                        prop.type = .RestElement;
                        prop.argument = try self.toPattern(prop.argument.?);
                    } else if (prop.value_node) |value| {
                        prop.value_node = try self.toPattern(value);
                    }
                }
            },
            .AssignmentExpression => {
                if (!util.eql(expr.operator, "=")) return self.fail("Invalid assignment target", .{});
                expr.type = .AssignmentPattern;
                expr.operator = "";
                expr.left = try self.toPattern(expr.left.?);
            },
            .ParenthesizedExpression => {
                const inner = expr.expression.?;
                if (inner.type == .ObjectExpression or inner.type == .ArrayExpression) return self.fail("Invalid assignment target", .{});
                return expr;
            },
            else => {},
        }
        return expr;
    }

    // ── TypeScript types (delimiting only) ─────────────────────────────────

    fn parseTypeAnnotation(self: *Parser) Error!*Node {
        const n = try self.node(.TSTypeAnnotation, self.tok.start);
        try self.expectPunct(":");
        _ = try self.parseType();
        try self.recordTs(n.start, self.prev_end);
        return self.finish(n);
    }

    fn parseTypeParametersNode(self: *Parser) Error!*Node {
        const n = try self.node(.TSTypeParameterDeclaration, self.tok.start);
        try self.skipTypeParameters();
        return self.finish(n);
    }

    fn skipTypeParameters(self: *Parser) Error!void {
        const start = self.tok.start;
        try self.skipAngle();
        try self.recordTs(start, self.prev_end);
    }

    fn skipTypeArguments(self: *Parser) Error!void {
        const start = self.tok.start;
        try self.skipAngle();
        try self.recordTs(start, self.prev_end);
    }

    /// Skip a balanced `<…>` group, splitting `>>`-style tokens as needed.
    fn skipAngle(self: *Parser) Error!void {
        if (!self.isPunct("<")) return self.unexpected();
        try self.advance();
        var depth: usize = 1;
        while (depth > 0) {
            if (self.tok.kind == .eof) return self.fail("Unexpected end of input", .{});
            if (self.tok.kind == .punct and util.eql(self.tok.text, "=>")) {
                try self.advance();
                continue;
            }
            if (self.isPunct("<") or self.isPunct("<=") or self.isPunct("<<")) {
                depth += @intCast(std.mem.count(u8, self.tok.text, "<"));
                try self.advance();
                continue;
            }
            if (self.tok.kind == .punct and self.tok.text[0] == '>') {
                var closes: usize = 0;
                while (closes < self.tok.text.len and self.tok.text[closes] == '>') closes += 1;
                const take = @min(closes, depth);
                depth -= take;
                if (take < self.tok.text.len) {
                    // Give back the unconsumed part of the token.
                    self.lexer.resetTo(self.tok.start + @as(u32, @intCast(take)));
                    self.prev_end = self.tok.start + @as(u32, @intCast(take));
                    self.tok = try self.lexer.next();
                    self.tok.newline_before = false;
                } else {
                    try self.advance();
                }
                continue;
            }
            if (self.isPunct("(")) {
                try self.skipBalanced("(", ")");
                continue;
            }
            if (self.isPunct("{")) {
                try self.skipBalanced("{", "}");
                continue;
            }
            if (self.isPunct("[")) {
                try self.skipBalanced("[", "]");
                continue;
            }
            try self.advance();
        }
    }

    /// Parse a type, returning an opaque `TSType` node spanning it.
    pub fn parseType(self: *Parser) Error!*Node {
        const n = try self.node(.TSType, self.tok.start);
        try self.parseTypeInner();
        return self.finish(n);
    }

    fn parseTypeInner(self: *Parser) Error!void {
        // Function / constructor types
        if (self.isIdent("new")) {
            try self.advance();
            try self.parseFunctionType();
            return;
        }
        if (self.isIdent("abstract") and try self.peekIsAfter(isNewToken)) {
            try self.advance();
            try self.advance();
            try self.parseFunctionType();
            return;
        }
        if (self.isPunct("<")) {
            try self.skipTypeParameters();
            try self.parseFunctionType();
            return;
        }
        if (self.isPunct("(") and try self.isFunctionTypeAhead()) {
            try self.parseFunctionType();
            return;
        }
        // asserts x is T / x is T
        if (self.isIdent("asserts") and try self.peekIsAfter(isIdentNoNewline)) {
            try self.advance();
            try self.advance();
            if (try self.eatIdent("is")) try self.parseTypeInner();
            return;
        }
        try self.parseUnionType();
        // type predicate `x is T`
        if (self.isIdent("is") and !self.tok.newline_before) {
            try self.advance();
            try self.parseTypeInner();
        }
    }

    fn isNewToken(tok: Token) bool {
        return tok.isIdent("new");
    }

    fn isFunctionTypeAhead(self: *Parser) Error!bool {
        const snap = self.snapshot();
        defer self.rewind(snap);
        self.skipBalanced("(", ")") catch return false;
        return self.isPunct("=>");
    }

    fn parseFunctionType(self: *Parser) Error!void {
        try self.skipBalanced("(", ")");
        try self.expectPunct("=>");
        try self.parseTypeInner();
    }

    fn parseUnionType(self: *Parser) Error!void {
        _ = try self.eatPunct("|");
        try self.parseIntersectionType();
        while (self.isPunct("|")) {
            try self.advance();
            try self.parseIntersectionType();
        }
    }

    fn parseIntersectionType(self: *Parser) Error!void {
        _ = try self.eatPunct("&");
        try self.parseConditionalType();
        while (self.isPunct("&")) {
            try self.advance();
            try self.parseConditionalType();
        }
    }

    fn parseConditionalType(self: *Parser) Error!void {
        try self.parsePostfixType();
        if (self.isIdent("extends") and !self.tok.newline_before) {
            try self.advance();
            try self.parsePostfixType();
            try self.expectPunct("?");
            try self.parseTypeInner();
            try self.expectPunct(":");
            try self.parseTypeInner();
        }
    }

    fn parsePostfixType(self: *Parser) Error!void {
        try self.parsePrimaryType();
        while (self.isPunct("[") and !self.tok.newline_before) {
            try self.advance();
            if (!self.isPunct("]")) try self.parseTypeInner();
            try self.expectPunct("]");
        }
    }

    fn parsePrimaryType(self: *Parser) Error!void {
        switch (self.tok.kind) {
            .string, .number, .bigint => try self.advance(),
            .template_head, .template_no_subst => _ = try self.parseTemplate(true),
            .punct => {
                if (self.isPunct("(")) {
                    try self.advance();
                    try self.parseTypeInner();
                    try self.expectPunct(")");
                } else if (self.isPunct("{")) {
                    try self.skipBalanced("{", "}");
                } else if (self.isPunct("[")) {
                    try self.skipBalanced("[", "]");
                } else if (self.isPunct("-")) {
                    try self.advance();
                    try self.advance();
                } else if (self.isPunct("<")) {
                    try self.skipTypeParameters();
                    try self.parseFunctionType();
                } else return self.unexpected();
            },
            .identifier => {
                const t = self.tok.text;
                if (util.eql(t, "keyof") or util.eql(t, "readonly") or util.eql(t, "unique") or util.eql(t, "infer")) {
                    try self.advance();
                    try self.parsePostfixType();
                    if (util.eql(t, "infer") and self.isIdent("extends")) {
                        try self.advance();
                        try self.parsePostfixType();
                    }
                    return;
                }
                if (util.eql(t, "typeof")) {
                    try self.advance();
                    if (self.isIdent("import")) {
                        try self.advance();
                        try self.skipBalanced("(", ")");
                    } else {
                        _ = try self.parseIdentifierName();
                    }
                    while (self.isPunct(".") or self.isPunct("?.")) {
                        try self.advance();
                        _ = try self.parseIdentifierName();
                    }
                    if (self.isPunct("<") and !self.tok.newline_before) try self.skipTypeArguments();
                    return;
                }
                if (util.eql(t, "import")) {
                    try self.advance();
                    try self.skipBalanced("(", ")");
                    while (try self.eatPunct(".")) _ = try self.parseIdentifierName();
                    if (self.isPunct("<")) try self.skipTypeArguments();
                    return;
                }
                if (util.eql(t, "new")) {
                    try self.advance();
                    try self.parseFunctionType();
                    return;
                }
                // Entity name with optional type arguments (also keywords like string/void/this).
                try self.advance();
                while (self.isPunct(".")) {
                    try self.advance();
                    _ = try self.parseIdentifierName();
                }
                if (self.isPunct("<") and !self.tok.newline_before) try self.skipTypeArguments();
            },
            else => return self.unexpected(),
        }
    }

    // ── JSX ────────────────────────────────────────────────────────────────

    /// Current token is `<` (scanned in expression mode).
    fn parseJsx(self: *Parser) Error!*Node {
        const start = self.tok.start;
        const element = try self.parseJsxElementAt(start);
        // Resume expression-mode scanning after the element.
        self.prev_end = element.end;
        self.lexer.resetTo(element.end);
        self.tok = try self.lexer.next();
        return element;
    }

    fn jsxTag(self: *Parser) Error!void {
        self.prev_end = self.tok.end;
        self.tok = try self.lexer.nextJsxTag();
    }

    /// Parse an element or fragment whose `<` is at `start`; leaves the lexer just past the final `>`.
    fn parseJsxElementAt(self: *Parser, start: u32) Error!*Node {
        self.lexer.resetTo(start + 1);
        self.tok = .{ .kind = .punct, .text = "<", .start = start, .end = start + 1 };
        try self.jsxTag();
        if (self.isPunct(">")) {
            // Fragment
            const fragment = try self.node(.JSXFragment, start);
            const opening = try self.node(.JSXOpeningFragment, start);
            opening.end = self.tok.end;
            fragment.opening_fragment = opening;
            const children_end = self.tok.end;
            fragment.children = try self.parseJsxChildren(children_end);
            // current token: `<` of the closing tag (child mode)
            const close_start = self.tok.start;
            try self.jsxTag();
            try self.expectJsxPunct("/");
            if (!self.isPunct(">")) return self.fail("Expected closing fragment", .{});
            const closing = try self.node(.JSXClosingFragment, close_start);
            closing.end = self.tok.end;
            fragment.closing_fragment = closing;
            fragment.end = self.tok.end;
            return fragment;
        }
        const element = try self.node(.JSXElement, start);
        const opening = try self.node(.JSXOpeningElement, start);
        opening.name_node = try self.parseJsxElementName();
        if (self.isPunct("<")) {
            // type arguments on JSX element
            const snap_pos = self.tok.start;
            self.lexer.resetTo(snap_pos);
            self.tok = try self.lexer.next();
            try self.skipTypeArguments();
            self.lexer.resetTo(self.tok.start);
            try self.jsxTag();
        }
        var attributes: NodeList = .empty;
        while (!self.isPunct("/") and !self.isPunct(">")) {
            if (self.tok.kind == .eof) return self.fail("Unterminated JSX element", .{});
            try attributes.append(self.allocator, try self.parseJsxAttribute());
        }
        opening.attributes = try attributes.toOwnedSlice(self.allocator);
        if (self.isPunct("/")) {
            try self.jsxTag();
            if (!self.isPunct(">")) return self.fail("Expected `>` after `/` in JSX", .{});
            opening.self_closing = true;
            opening.end = self.tok.end;
            element.opening_element = opening;
            element.end = self.tok.end;
            return element;
        }
        opening.end = self.tok.end;
        element.opening_element = opening;
        element.children = try self.parseJsxChildren(self.tok.end);
        const close_start = self.tok.start;
        try self.jsxTag();
        try self.expectJsxPunct("/");
        const closing = try self.node(.JSXClosingElement, close_start);
        closing.name_node = try self.parseJsxElementName();
        if (!self.isPunct(">")) return self.fail("Expected `>` in closing JSX tag", .{});
        if (!try self.jsxNamesMatch(opening.name_node.?, closing.name_node.?)) {
            return self.fail("Expected corresponding JSX closing tag for `{s}`", .{self.src[opening.name_node.?.start..opening.name_node.?.end]});
        }
        closing.end = self.tok.end;
        element.closing_element = closing;
        element.end = self.tok.end;
        return element;
    }

    fn jsxNamesMatch(self: *Parser, a: *Node, b: *Node) Error!bool {
        return util.eql(self.src[a.start..a.end], self.src[b.start..b.end]);
    }

    fn expectJsxPunct(self: *Parser, text: []const u8) Error!void {
        if (!self.isPunct(text)) return self.fail("Expected `{s}` in JSX at offset {d}", .{ text, self.tok.start });
        try self.jsxTag();
    }

    fn parseJsxIdentifier(self: *Parser) Error!*Node {
        if (self.tok.kind != .identifier) return self.fail("Expected JSX identifier at offset {d}", .{self.tok.start});
        const n = try self.node(.JSXIdentifier, self.tok.start);
        n.name = self.tok.text;
        n.end = self.tok.end;
        try self.jsxTag();
        return n;
    }

    fn parseJsxElementName(self: *Parser) Error!*Node {
        const start = self.tok.start;
        var name = try self.parseJsxIdentifier();
        if (self.isPunct(":")) {
            try self.jsxTag();
            const ns = try self.node(.JSXNamespacedName, start);
            ns.namespace = name;
            ns.name_node = try self.parseJsxIdentifier();
            ns.end = ns.name_node.?.end;
            return ns;
        }
        while (self.isPunct(".")) {
            try self.jsxTag();
            const member = try self.node(.JSXMemberExpression, start);
            member.object = name;
            member.property = try self.parseJsxIdentifier();
            member.end = member.property.?.end;
            name = member;
        }
        return name;
    }

    fn parseJsxAttribute(self: *Parser) Error!*Node {
        const start = self.tok.start;
        if (self.isPunct("{")) {
            // {...spread}
            const spread = try self.node(.JSXSpreadAttribute, start);
            self.lexer.resetTo(self.tok.end);
            self.tok = try self.lexer.next();
            try self.expectPunct("...");
            spread.argument = try self.parseAssignment(false);
            if (!self.isPunct("}")) return self.unexpected();
            spread.end = self.tok.end;
            try self.jsxTag();
            return spread;
        }
        const attribute = try self.node(.JSXAttribute, start);
        var name = try self.parseJsxIdentifier();
        if (self.isPunct(":")) {
            try self.jsxTag();
            const ns = try self.node(.JSXNamespacedName, start);
            ns.namespace = name;
            ns.name_node = try self.parseJsxIdentifier();
            ns.end = ns.name_node.?.end;
            name = ns;
        }
        attribute.name_node = name;
        attribute.end = name.end;
        if (self.isPunct("=")) {
            try self.jsxTag();
            if (self.tok.kind == .string) {
                const literal = try self.node(.Literal, self.tok.start);
                literal.value = .{ .string = self.tok.text };
                literal.raw = self.src[self.tok.start..self.tok.end];
                literal.end = self.tok.end;
                attribute.value_node = literal;
                attribute.end = literal.end;
                try self.jsxTag();
            } else if (self.isPunct("{")) {
                attribute.value_node = try self.parseJsxExpressionContainer();
                attribute.end = attribute.value_node.?.end;
                try self.jsxTag();
            } else if (self.isPunct("<")) {
                const nested = try self.parseJsxElementAt(self.tok.start);
                attribute.value_node = nested;
                attribute.end = nested.end;
                try self.jsxTag();
            } else return self.fail("Expected JSX attribute value at offset {d}", .{self.tok.start});
        }
        return attribute;
    }

    /// Current token is `{` (either mode). Leaves the lexer just past the `}`.
    fn parseJsxExpressionContainer(self: *Parser) Error!*Node {
        const start = self.tok.start;
        const container = try self.node(.JSXExpressionContainer, start);
        self.lexer.resetTo(self.tok.end);
        self.tok = try self.lexer.next();
        if (self.isPunct("}")) {
            const empty = try self.node(.JSXEmptyExpression, start + 1);
            empty.end = self.tok.start;
            container.expression = empty;
        } else if (self.isPunct("...")) {
            try self.advance();
            container.type = .JSXSpreadChild;
            container.expression = try self.parseExpression(false);
            if (!self.isPunct("}")) return self.unexpected();
        } else {
            container.expression = try self.parseExpression(false);
            if (!self.isPunct("}")) return self.unexpected();
        }
        container.end = self.tok.end;
        return container;
    }

    /// Parse children starting at `pos`; returns with the current token being the `<` of the closing tag (child mode).
    fn parseJsxChildren(self: *Parser, pos: u32) Error![]*Node {
        var children: NodeList = .empty;
        self.lexer.resetTo(pos);
        while (true) {
            self.tok = try self.lexer.nextJsxChild();
            switch (self.tok.kind) {
                .eof => return self.fail("Unterminated JSX contents", .{}),
                .jsx_text => {
                    const text = try self.node(.JSXText, self.tok.start);
                    text.value = .{ .string = self.tok.text };
                    text.raw = self.src[self.tok.start..self.tok.end];
                    text.end = self.tok.end;
                    try children.append(self.allocator, text);
                },
                .punct => {
                    if (self.isPunct("{")) {
                        const container = try self.parseJsxExpressionContainer();
                        try children.append(self.allocator, container);
                        self.lexer.resetTo(container.end);
                    } else {
                        // `<`: closing tag or nested element
                        var i: usize = self.tok.end;
                        while (i < self.src.len and lexer_mod.Lexer.isIdentPart(self.src[i]) == false and (self.src[i] == ' ' or self.src[i] == '\n' or self.src[i] == '\t' or self.src[i] == '\r')) i += 1;
                        if (i < self.src.len and self.src[i] == '/') return children.toOwnedSlice(self.allocator);
                        const nested = try self.parseJsxElementAt(self.tok.start);
                        try children.append(self.allocator, nested);
                        self.lexer.resetTo(nested.end);
                    }
                },
                else => return self.unexpected(),
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

fn parseTest(a: Allocator, src: []const u8) !*Node {
    return parse(a, src, "test.tsx") catch |e| {
        std.debug.print("parse error: {s}\n", .{err.message()});
        return e;
    };
}

test "parses declarations, JSX, templates and TS annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const program = try parseTest(a,
        \\import { Publr, type X } from "publr/dom";
        \\export const state = Publr.reactive({ open: false, get label() { return state.open ? "a" : "b"; } });
        \\export const toggle = (event: Event) => { state.open = !state.open; };
        \\export function Disclosure({ startOpen = false, children }: Props) {
        \\  const x = items?.map((i) => i.v) ?? [];
        \\  return (
        \\    <div data-part="disclosure" class={`a ${b}`} $$show={cond}>
        \\      {children}
        \\      <Icon.Small hidden />
        \\    </div>
        \\  );
        \\}
    );
    try std.testing.expectEqual(@as(usize, 4), program.statements.len);
    const import_decl = program.statements[0];
    try std.testing.expectEqual(Type.ImportDeclaration, import_decl.type);
    try std.testing.expectEqual(ast.ImportKind.type, import_decl.specifiers[1].import_kind);
    const fn_decl = program.statements[3].declaration.?;
    try std.testing.expectEqual(Type.FunctionDeclaration, fn_decl.type);
    try std.testing.expectEqual(Type.ObjectPattern, fn_decl.params[0].type);
    const ret = fn_decl.body.?.statements[1];
    const jsx = ast.unparen(ret.argument.?);
    try std.testing.expectEqual(Type.JSXElement, jsx.type);
    try std.testing.expectEqualStrings("div", jsx.opening_element.?.name_node.?.name);
    try std.testing.expectEqual(@as(usize, 3), jsx.opening_element.?.attributes.len);
    try std.testing.expectEqualStrings("disclosure", jsx.opening_element.?.attributes[0].value_node.?.value.string);
    try std.testing.expectEqual(Type.JSXMemberExpression, jsx.children[3].opening_element.?.name_node.?.type);
    try std.testing.expectEqualStrings("<div data-part=\"disclosure\" class={`a ${b}`} $$show={cond}>", program.statements[3].declaration.?.body.?.statements[1].argument.?.expression.?.opening_element.?.slice(
        \\import { Publr, type X } from "publr/dom";
        \\export const state = Publr.reactive({ open: false, get label() { return state.open ? "a" : "b"; } });
        \\export const toggle = (event: Event) => { state.open = !state.open; };
        \\export function Disclosure({ startOpen = false, children }: Props) {
        \\  const x = items?.map((i) => i.v) ?? [];
        \\  return (
        \\    <div data-part="disclosure" class={`a ${b}`} $$show={cond}>
        \\      {children}
        \\      <Icon.Small hidden />
        \\    </div>
        \\  );
        \\}
    ));
}

test "distinguishes arrows, parenthesized expressions, ternaries and regex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const program = try parseTest(a,
        \\const f = async (a, { b = 1 }, ...rest): Promise<void> => a;
        \\const g = cond ? (x) : y;
        \\const h = (x) => x / 2 / 1;
        \\const r = /ab[/]c/gi.test(s);
        \\const j = <T,>(v: T) => v;
        \\const k = obj as unknown as string;
        \\label: for (const [k, v] of Object.entries(o)) { if (k) continue label; }
    );
    try std.testing.expectEqual(Type.ArrowFunctionExpression, program.statements[0].declarations[0].init.?.type);
    try std.testing.expect(program.statements[0].declarations[0].init.?.async);
    try std.testing.expectEqual(Type.ConditionalExpression, program.statements[1].declarations[0].init.?.type);
    try std.testing.expectEqual(Type.ParenthesizedExpression, program.statements[1].declarations[0].init.?.consequent.?.type);
    try std.testing.expectEqual(Type.ArrowFunctionExpression, program.statements[2].declarations[0].init.?.type);
    try std.testing.expectEqual(Type.Literal, program.statements[3].declarations[0].init.?.callee.?.object.?.type);
    try std.testing.expectEqualStrings("/ab[/]c/gi", program.statements[3].declarations[0].init.?.callee.?.object.?.raw);
    try std.testing.expectEqual(Type.ArrowFunctionExpression, program.statements[4].declarations[0].init.?.type);
    try std.testing.expectEqual(Type.TSAsExpression, program.statements[5].declarations[0].init.?.type);
    try std.testing.expectEqual(Type.LabeledStatement, program.statements[6].type);
}

test "reports a parse error with a message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Pjsx, parse(arena.allocator(), "const = ;", "bad.tsx"));
    try std.testing.expect(err.message().len > 0);
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    // Arbitrary bytes must never crash or hang the lexer/parser; a parse
    // error is the expected outcome (this is how the stray-backslash lexer
    // loop was caught).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var input: std.ArrayList(u8) = .empty;
    while (!smith.eos()) {
        const chunk = try input.addManyAsSlice(arena.allocator(), smith.value(u6));
        smith.bytes(chunk);
    }
    _ = parse(arena.allocator(), input.items, "fuzz.tsx") catch |e| switch (e) {
        error.Pjsx => {},
        else => return e,
    };
}

test "fuzz: the parser survives arbitrary input" {
    try std.testing.fuzz({}, fuzzParse, .{});
}
