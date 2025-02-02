const std = @import("std");
const imp = @import("../imp.zig");
const u = imp.util;

pub const repr = @import("./lang/repr.zig");
pub const pass = @import("./lang/pass.zig");

const syntax = repr.syntax;
const core = repr.core;
const type_ = repr.type_;
const value = repr.value;
const parse = pass.parse;
const desugar = pass.desugar;
const analyze = pass.analyze;
const interpret = pass.interpret;

comptime {
    @import("std").testing.refAllDecls(@This());
}

pub const ErrorInfo = union(enum) {
    Parse: parse.ErrorInfo,
    Desugar: desugar.ErrorInfo,
    Analyze: analyze.ErrorInfo,
    Interpret: interpret.ErrorInfo,

    pub fn getMessage(self: ErrorInfo) []const u8 {
        return switch (self) {
            .Parse => |parse_info| parse_info.message,
            .Desugar => |desugar_info| desugar_info.message,
            .Analyze => |analyze_info| analyze_info.message,
            .Interpret => |interpet_info| interpet_info.message,
        };
    }
};

pub const Error = parse.Error ||
    desugar.Error ||
    analyze.Error ||
    interpret.Error;

pub const SourceSelection = union(enum) {
    Point: usize,
    Range: [2]usize,
};

pub fn eval(
    arena: *u.ArenaAllocator,
    source: []const u8,
    constants: u.DeepHashMap(syntax.Name, value.Set),
    error_info: *?ErrorInfo,
) !value.Set {
    var desired_id: usize = 0;
    const interrupter = .{
        .current_id = 0,
        .desired_id = &desired_id,
    };
    var store = imp.lang.Store{
        .arena = arena,
        .interrupter = interrupter,
        .source = source,
        .constants = constants,
    };
    store.run();
    if (store.result.?) |set| {
        return set;
    } else |err| {
        error_info.* = store.error_info;
        return err;
    }
}

pub const Store = struct {
    arena: *u.ArenaAllocator,
    interrupter: Interrupter,

    // inputs
    source: []const u8,
    constants: u.DeepHashMap(syntax.Name, value.Set),
    watch_selection: ?SourceSelection = null,

    // intermediate results
    syntax_program: ?syntax.Program = null,
    watch_expr_id: ?syntax.ExprId = null,
    core_program: ?core.Program = null,
    program_type: ?type_.ProgramType = null,

    // outputs
    result: ?(Error!value.Set) = null,
    error_info: ?ErrorInfo = null,
    watch_results: ?u.DeepHashSet(interpret.WatchResult) = null,

    pub fn run(self: *Store) void {
        var parse_error_info: ?parse.ErrorInfo = null;
        self.syntax_program = parse.parse(self.arena, self.source, &parse_error_info) catch |err| {
            if (err == error.ParseError) {
                self.error_info = .{ .Parse = parse_error_info.? };
            }
            self.result = err;
            return;
        };

        if (self.watch_selection) |watch_selection|
            self.watch_expr_id = self.findSyntaxExprAt(watch_selection);

        var desugar_error_info: ?desugar.ErrorInfo = null;
        self.core_program = desugar.desugar(self.arena, self.syntax_program.?, self.constants, self.watch_expr_id, &desugar_error_info) catch |err| {
            if (err == error.DesugarError) {
                self.error_info = .{ .Desugar = desugar_error_info.? };
            }
            self.result = err;
            return;
        };

        var analyze_error_info: ?analyze.ErrorInfo = null;
        self.program_type = analyze.analyze(self.arena, self.core_program.?, self.interrupter, &analyze_error_info) catch |err| {
            if (err == error.AnalyzeError) {
                self.error_info = .{ .Analyze = analyze_error_info.? };
            }
            self.result = err;
            return;
        };

        self.watch_results = u.DeepHashSet(interpret.WatchResult).init(self.arena.allocator());
        var interpret_error_info: ?interpret.ErrorInfo = null;
        self.result = interpret.interpret(self.arena, self.core_program.?, self.program_type.?, &self.watch_results.?, self.interrupter, &interpret_error_info) catch |err| {
            if (err == error.InterpretError or err == error.NativeError) {
                self.error_info = .{ .Interpret = interpret_error_info.? };
            }
            self.result = err;
            return;
        };
    }

    pub fn findSyntaxExprAt(self: Store, selection: SourceSelection) ?syntax.ExprId {
        var expr_id: usize = self.syntax_program.?.exprs.len - 1;
        while (expr_id > 0) : (expr_id -= 1) {
            const source_range = self.syntax_program.?.from_source[expr_id];
            if (switch (selection) {
                .Point => |point| source_range[1] <= point,
                .Range => |range| source_range[0] >= range[0] and source_range[1] <= range[1],
            })
                return syntax.ExprId{ .id = expr_id };
        }
        return null;
    }

    pub fn getWatchRange(self: Store) ?[2]usize {
        return if (self.watch_expr_id) |watch_expr_id|
            self.syntax_program.?.from_source[watch_expr_id.id]
        else
            null;
    }

    pub fn getErrorRange(self: Store) ?[2]usize {
        if (self.error_info) |error_info| {
            switch (error_info) {
                .Parse => |parse_info| {
                    return [2]usize{ parse_info.start, parse_info.end };
                },
                .Desugar => |desugar_info| {
                    return self.syntax_program.?.from_source[desugar_info.expr_id.id];
                },
                .Analyze => |analyze_info| {
                    const syntax_expr_id = self.core_program.?.from_syntax[analyze_info.expr_id.id];
                    return self.syntax_program.?.from_source[syntax_expr_id.id];
                },
                .Interpret => |interpret_info| {
                    const syntax_expr_id = self.core_program.?.from_syntax[interpret_info.expr_id.id];
                    return self.syntax_program.?.from_source[syntax_expr_id.id];
                },
            }
        } else {
            return null;
        }
    }

    pub fn getWarningsRanges(self: Store, allocator: u.Allocator) ![]const [2]usize {
        var ranges = u.ArrayList([2]usize).init(allocator);
        if (self.program_type) |program_type| {
            for (program_type.warnings) |warning| {
                const syntax_expr_id = self.core_program.?.from_syntax[warning.expr_id.id];
                try ranges.append(self.syntax_program.?.from_source[syntax_expr_id.id]);
            }
        }
        return ranges.toOwnedSlice();
    }

    pub fn dumpInto(self: Store, writer: anytype, indent: u32) u.WriterError(@TypeOf(writer))!void {
        if (self.program_type) |program_type| {
            if (program_type.warnings.len > 0) {
                try writer.writeAll("warnings:\n");
                for (program_type.warnings) |warning| {
                    const syntax_expr_id = self.core_program.?.from_syntax[warning.expr_id.id];
                    const range = self.syntax_program.?.from_source[syntax_expr_id.id];
                    try std.fmt.format(writer, "[{}:{}] ", .{ range[0], range[1] });
                    try warning.dumpInto(writer, indent);
                    try writer.writeAll("\n");
                }
                // TODO inserting a gap here breaks tests :(
                //try writer.writeAll("\n");
            }
        }
        if (self.watch_results) |watch_results| {
            if (watch_results.count() > 0) {
                try writer.writeAll("watch:\n");
                var sorted_watch_results = u.ArrayList(interpret.WatchResult).init(u.dump_allocator);
                defer sorted_watch_results.deinit();
                var iter = watch_results.iterator();
                while (iter.next()) |entry| sorted_watch_results.append(entry.key_ptr.*) catch u.panic("OOM", .{});
                std.sort.sort(interpret.WatchResult, sorted_watch_results.items, {}, struct {
                    fn lessThan(_: void, a: interpret.WatchResult, b: interpret.WatchResult) bool {
                        return u.deepCompare(a, b) == .LessThan;
                    }
                }.lessThan);
                for (sorted_watch_results.items) |watch_result| {
                    try watch_result.dumpInto(writer, indent);
                    try writer.writeAll("\n---\n");
                }
                try writer.writeAll("\n");
            }
        }
        if (self.result) |result| {
            if (result) |set| {
                try writer.writeAll("type:\n");
                try self.program_type.?.program_type.dumpInto(writer, indent);
                try writer.writeAll("\nvalue:\n");
                try set.dumpInto(writer, indent);
                try writer.writeAll("\n");
            } else |err| {
                try std.fmt.format(writer, "{s}", .{@errorName(err)});
                switch (err) {
                    error.ParseError,
                    error.DesugarError,
                    error.AnalyzeError,
                    error.InterpretError,
                    error.NativeError,
                    => try std.fmt.format(writer, ": {s}", .{self.error_info.?.getMessage()}),
                    error.OutOfMemory,
                    error.WasInterrupted,
                    => {},
                }
            }
        }
    }
};

pub const Worker = struct {
    allocator: u.Allocator,
    config: Config,
    db: imp.db.DB,

    // mutex protects these fields
    mutex: std.Thread.Mutex,
    // background loop waits for this
    state_changed_event: std.Thread.AutoResetEvent,
    // when set to true, the background thread will deinit its state and then exit
    should_deinit: bool,
    // new_request and new_response behave like queues, except that they only care about the most recent item
    new_request: ?Request,
    new_response: ?Response,
    // desired_id is the most recent id set in new_request
    // if the interpreter is running and notices that desired_id has changed, it gives up and returns error.WasInterrupted so we can start again with the new program
    // desired_id is only changed inside mutex but is read atomically by the Interrupter outside the mutex
    // TODO I think this is safe because it only ever increases and we don't care exactly how long it takes for the interpreter to notice
    desired_id: usize,

    pub const Config = struct {
        db_path: [:0]const u8,
        memory_limit_bytes: ?usize = null,
    };

    pub const Request = struct {
        id: usize,
        text: []const u8,
        action: Action,
        selection: SourceSelection,

        pub const Action = enum {
            Eval,
            Commit,
        };
    };

    pub const Response = struct {
        id: usize,
        text: []const u8,
        kind: ResponseKind,
        warnings: []const [2]usize,

        pub fn deinit(self: Response, allocator: u.Allocator) void {
            allocator.free(self.warnings);
            allocator.free(self.text);
        }
    };

    pub const ResponseKind = union(enum) {
        Ok: ?[2]usize,
        Err: ?[2]usize,
    };

    // --- called by outside thread ---

    pub fn init(allocator: u.Allocator, config: Config) !*Worker {
        const self = try allocator.create(Worker);
        self.* = Worker{
            .allocator = allocator,
            .config = config,
            .db = try imp.db.DB.init(allocator, config.db_path),
            .mutex = .{},
            .state_changed_event = .{},
            .should_deinit = false,
            .new_request = null,
            .new_response = null,
            .desired_id = 0,
        };
        // spawn worker thread
        _ = try std.Thread.spawn(.{}, backgroundLoop, .{self});
        return self;
    }

    pub fn deinitSoon(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.should_deinit = true;
        @atomicStore(usize, &self.desired_id, std.math.maxInt(usize), .SeqCst);
        self.state_changed_event.set();
    }

    pub fn setRequest(self: *Worker, request: Request) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.new_request) |old_request| self.allocator.free(old_request.text);
        self.new_request = request;
        self.new_request.?.text = try self.allocator.dupe(u8, self.new_request.?.text);
        @atomicStore(usize, &self.desired_id, request.id, .SeqCst);
        self.state_changed_event.set();
    }

    pub fn getResponse(self: *Worker) ?Response {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.new_response) |response| {
            self.new_response = null;
            return response;
        } else {
            return null;
        }
    }

    // --- called by worker thread ---

    fn deinit(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.new_request) |request| self.allocator.free(request.text);
        if (self.new_response) |response| response.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn backgroundLoop(self: *Worker) !void {
        while (true) {
            // wait for a new request
            self.state_changed_event.wait();

            // get new request
            var new_request: Request = undefined;
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.should_deinit) {
                    self.deinit();
                    return;
                }
                if (self.new_request) |request| {
                    new_request = request;
                    self.new_request = null;
                } else {
                    // spurious wakeup, wait again
                    // (can happen like this:
                    //  outside: sets request a, wakes worker
                    //  outside: sets request b, wakes worker
                    //  worker: wakes up, reads request b, sets request null
                    //  worker: wakes up, reads request null)
                    continue;
                }
            }
            defer self.allocator.free(new_request.text);

            // eval
            var gpa = std.heap.GeneralPurposeAllocator(.{
                // TODO it's possible but awkward to set this to false when config.memory_limit_bytes is null
                .enable_memory_limit = true,
            }){
                .backing_allocator = self.allocator,
                .requested_memory_limit = self.config.memory_limit_bytes orelse std.math.maxInt(usize),
            };
            defer _ = gpa.deinit();
            var arena = u.ArenaAllocator.init(gpa.allocator());
            defer arena.deinit();
            const interrupter = Interrupter{
                .current_id = new_request.id,
                .desired_id = &self.desired_id,
            };
            var constants = u.DeepHashMap(syntax.Name, value.Set).init(arena.allocator());
            _ = try constants.put("db", self.db.rows);
            var store = Store{
                .arena = &arena,
                .interrupter = interrupter,
                .source = new_request.text,
                .constants = constants,
                .watch_selection = new_request.selection,
            };
            store.run();

            var response_buffer = u.ArrayList(u8).init(self.allocator);

            // maybe commit
            if (new_request.action == .Commit) {
                if (store.result) |result_e| {
                    if (result_e) |result| {
                        if (self.db.applyDiff(result)) {
                            try response_buffer.writer().writeAll("Committed:\n\n");
                        } else |err| {
                            try std.fmt.format(
                                response_buffer.writer(),
                                "Error in commit: {}\n{s}\n",
                                .{ err, if (self.db.error_info) |error_info| error_info.getMessage() else "" },
                            );
                        }
                    } else |_| {}
                }
            }

            // print result
            defer response_buffer.deinit();
            try store.dumpInto(response_buffer.writer(), 0);
            const response_kind = if (store.result.?) |_|
                ResponseKind{ .Ok = store.getWatchRange() }
            else |_|
                ResponseKind{ .Err = store.getErrorRange() };
            const warnings = try store.getWarningsRanges(self.allocator);

            // set response
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.new_response) |old_response| self.allocator.free(old_response.text);
                self.new_response = .{
                    .text = response_buffer.toOwnedSlice(),
                    .id = new_request.id,
                    .kind = response_kind,
                    .warnings = warnings,
                };
            }
        }
    }
};

pub const Interrupter = struct {
    current_id: usize,
    desired_id: *usize,

    // called by interpreter while running
    pub fn check(self: Interrupter) error{WasInterrupted}!void {
        // TODO probably don't need .SeqCst, but need to think hard about it
        if (@atomicLoad(usize, self.desired_id, .SeqCst) != self.current_id)
            return error.WasInterrupted;
    }
};
