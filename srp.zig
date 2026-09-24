//SRP - The Sox Rofi Parser - Version 1.0
const std = @import("std");

const TEMP_PATH = "/tmp/srp/";
const CONFIG_NAME = "srp.cfg";
const RBT_MAP = TEMP_PATH ++ "rbtime.txt";
const RBP_MAP = TEMP_PATH ++ "rbpitch.txt";

const LABEL_MAX = 16;
const MAX_TOKENS = 512;
const MAX_DEPTH = 16;
const MAX_WIDTH = 16;
const BUFSIZE = 8192;
const BUFSIZE_HALF = BUFSIZE / 2;

const enumEffect = enum {unknown, zero, one, two, percent, macro, misc, rubber, raw, varmacro, target};
const enumRubber = enum(u8) {linear, exponential, sine, ushape, triangle, square, sawtooth};
const enumMode = enum {default, concat, mix, macro};
const enumMapType = enum {time_map, pitch_map};
const enumValueType = enum(u8) {none = 0, percent = 1, target = 2, relative = 4};
const enumParameterType = enum(u8) {factor_speed, factor_amplitude, cents_relative, cents_fractional, cents_integer,
                                    time_start, time_end, milliseconds, gain, frequency, mode, uint, rate, speed_start, speed_end};

var prng: std.Random.DefaultPrng = undefined;
var rng: std.Random = undefined;

const SRP = struct {
    var is_repeated: bool = false;
    var is_processing: bool = false;
    var use_dummy: bool = false;
    var use_XDT: bool = false;
    var scope: usize = 0;
    var width: usize = 0;
    var rendered: usize = 0;
    var combined: usize = 0;
    var bufpos: usize = 0;
}; 

const Token = struct {
    var path: [256]u8 = undefined;      //Path and name are effectively the same, just different storage types
    var name: []const u8 = undefined;   
    var label: []const u8 = undefined;
    var render: []const u8 = undefined;
    var effect: u8 = undefined;
    var channels: u8 = undefined;
    var rate: u24 = undefined;
    var precision: u8 = undefined;
    var duration: [11]u8 = undefined;   //Duration in xx:xx:xxx format
    var samples: u32 = undefined;
    var combo: usize = undefined;
};

const Rubber = struct {
    mode: enumRubber,
    amplitude: f32,
    plot_size: f32,
    mod: f32 = undefined,
    pitch: f32 = undefined,
    speed_start: f32,
    speed_end: f32,
    speed_current: f32 = undefined,
    steps: u32,
    step_current: u32 = undefined,
    factor: f32,
};

const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    buf: [BUFSIZE]u8,
    arg: std.ArrayList([]const u8),     //General-purpose array that mostly deals with cmd arguments
    tok: std.ArrayList([]const u8),     //General-purpose array that mostly contains tokens
    eff: std.ArrayList([2][]const u8),  //User-defined effects, SRP style
    raw: std.ArrayList([2][]const u8),  //Same, but here effects are defined in 'raw' terms as sox reads them
    pre: std.ArrayList([2][]const u8),  //Pre-defined user macros
    m2D: std.ArrayList(std.ArrayList([]const u8)),  //2D-array used for unrolling macros and de-nesting
    sound_path: []u8,                   //Stores the sound library path defined in the user config 
    sound_dummy: []u8,                  //Stores the playback method
    audio_device: []u8,                 //Stores the pulse audio device used by paplay or gstreamer
    audio_player: []u8,                 //Stores the playback method
    audio_volume: f32,                  //Stores the playback audio volume level, converts to u16 for pulse
}; 

const Effect = struct {
    name: []const u8,
    parameter_amount: i8, //-1 for arbitrary/unlimited amount
    parameter_flags: []const enumParameterType,
};

//Built-in custom effects
const effectMacroPreset = [_][2][] const u8 {
    .{"echo1","reverb 30 echos 1 0.6 200 0.8 400 0.6 600 0.4 800 0.2 1000 0.1 1200 0.05 1400 0.025"},
};

//Built-in test macros
const strMacroPreset = [_][2][] const u8 {
    .{"macro1","hello there+pitch;100"},
};

//
const effect_table = [_]Effect { 
    .{.name = "speed", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.factor_speed}},
    .{.name = "tempo", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.factor_speed}},
    .{.name = "pitch", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.cents_relative}},
    .{.name = "reverse", .parameter_amount = 0, .parameter_flags = &[_]enumParameterType{}},
    .{.name = "repeat", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.uint}},
    .{.name = "vol", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.gain}},
    .{.name = "rate", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.rate}},
    .{.name = "reverb", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.cents_integer}},
    .{.name = "overdrive", .parameter_amount = 1, .parameter_flags = &[_]enumParameterType{.cents_integer}},
    .{.name = "pad", .parameter_amount = 2, .parameter_flags = &[_]enumParameterType{.time_start, .time_end}},
    .{.name = "trim", .parameter_amount = 2, .parameter_flags = &[_]enumParameterType{.time_start, .time_end}}, 
    .{.name = "tremolo", .parameter_amount = 2, .parameter_flags = &[_]enumParameterType{.frequency, .cents_integer}},
    .{.name = "echo", .parameter_amount = 4, .parameter_flags = &[_]enumParameterType{.gain, .gain, .milliseconds, .cents_fractional}},
    .{.name = "echos", .parameter_amount = -1, .parameter_flags = &[_]enumParameterType{.gain, .gain, .milliseconds, .cents_fractional}},
    .{.name = "bend", .parameter_amount = -1, .parameter_flags = &[_]enumParameterType{.time_start, .cents_relative, .time_end}},
    .{.name = "rbt", .parameter_amount = 5, .parameter_flags = &[_]enumParameterType{.mode, .speed_start, .speed_end, .time_start, .time_end}},
    .{.name = "rbp", .parameter_amount = 5, .parameter_flags = &[_]enumParameterType{.mode, .factor_amplitude, .frequency, .time_start, .time_end}},
};

fn initRNG(seed: u64) void {
    prng = std.Random.DefaultPrng.init(@intCast(seed));
    rng = prng.random();
}

fn findEffect(s: []const u8, ctx: *Context) ?i8 {
    if (std.mem.eql(u8, s, "%INVALID%")) return null;
    for (ctx.raw.items) |str| {
        if (std.mem.eql(u8, s, str[0])) { 
            var args = std.mem.splitSequence(u8,str[1]," ");  
            while (args.next())|val| {
                ctx.arg.append(ctx.arena.allocator(), val) catch return null;
            }
            return null;
        }
    }
    for (ctx.eff.items) |str| {
        if (std.mem.eql(u8, s, str[0])) { 
            var buffer: []const u8 = undefined;
            const replacement_size = std.mem.replacementSize(u8, str[1], "$sound", Token.label);
            const replacements = std.mem.replace(u8, str[1], "$sound", Token.label, ctx.buf[0..]);
            if (replacements > 0) {
                buffer = ctx.buf[0..replacement_size];
                const newstr = std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{buffer}) catch return null;
                Token.label = newstr;
                std.debug.print("Found variable effect! Token: ({s})  Macro: ({s})\n",.{Token.label,newstr});
                return @intCast(-1);
            } else {
                const newstr = std.fmt.allocPrint(ctx.arena.allocator(), "{s}+{s}",.{Token.label,str[1]}) catch return null;
                Token.label = newstr;
                return @intCast(-2);
            }
            var args = std.mem.splitSequence(u8, str[1], "+");  
            while (args.next())|eff| {
                var parms = std.mem.splitSequence(u8, eff, ";");
                while (parms.next())|val|{
                    ctx.arg.append(ctx.arena.allocator(), val) catch return null;
                }
            }
            return null;
        }
    }
    for (effect_table, 0..)|effect,i|{
        if (std.mem.eql(u8, s, effect.name)){
            return @intCast(i);
        }
    }
    return null;
}

fn findMatchingClose(s: []const u8, startid: usize) ?usize {
    if (startid >= s.len or s[startid] != '{'){
        return null;
    }
    var depth: usize = 0;
    var i: usize = startid;
    while (i < s.len) : (i += 1){
        const c = s[i];
        if (c == '{'){
            depth += 1;
        } else if (c == '}'){
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn unrollMacro(s: []const u8, ctx: *Context, inc: bool) !void { 
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;
    var width: usize = 0;
    if (inc == true) { SRP.scope += 1; }
    while (std.mem.findAnyPos(u8, s, i, "_"))|val| {
        i = val;
        k = val+1;
        if ((s.len - 2) > i) { //String length sanity check
            if (s[i+1] == ';'){ 
                k = i + 2;
                while (k <= (s.len - 1)) : (k += 1){ //Check for macro arguments
                    if ((s[k] == ' ') or (s[k] == '+') or (s[k] == '{') or (s[k] == '}') or (s[k] == '/') or (s[k] == '\x00')){
                        break;
                    } else {
                        ctx.buf[BUFSIZE_HALF+j] = s[k];
                        j += 1;
                    }
                }   
                const args = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{ctx.buf[BUFSIZE_HALF..BUFSIZE_HALF+j]});
                var split = std.mem.splitSequence(u8, args, ";");
                while (split.next())|token|{
                    const sndstat = try findSnd(token, ctx);
                    if (sndstat == 0){
                        try ctx.arg.append(ctx.arena.allocator(), token); 
                    } else {
                        std.debug.print("SRP: UNROLL: Invalid token ({s})\n",.{args});
                    }
                }
            } 
        }
        while (i > 0) : (i -= 1){ //Find end of macro string, backwards from underscore
            if ((s[i] == ' ') or (s[i] == '{') or (s[i] == '}') or (s[i] == '+') or (s[i] == '/')){
                i += 1; //Overcorrection
                break;
            }
        }
        if ((i == 0) and ((s[0] == ' ') or (s[0] == '{') or (s[0] == '}') or (s[0] == '+'))){
            i += 1; //Special case for when the macro starts at index 1
        }
        const name = s[i..val]; //Macro name only
        const name2 = s[i..k]; //With underscore and macro argumeHere??\n",.{});
        if (parseMacros(name, ctx))|macro|{
            if (SRP.scope == ctx.m2D.items.len){
                _ = try ctx.m2D.append(ctx.arena.allocator(), std.ArrayList([]const u8).empty);
            } 
            const newmac = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{macro});
            _ = try ctx.m2D.items[SRP.scope].append(ctx.arena.allocator(), newmac);
            _ = try unrollMacro(ctx.m2D.items[SRP.scope].items[width], ctx, true);

            const strlen = std.mem.replacementSize(u8, ctx.m2D.items[SRP.scope-1].items[0], name2, ctx.m2D.items[SRP.scope].items[width]);
            _ = std.mem.replace(u8, ctx.m2D.items[SRP.scope-1].items[0], name2, ctx.m2D.items[SRP.scope].items[width], ctx.buf[0..]);
            const str = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{ctx.buf[0..strlen]});
            ctx.m2D.items[SRP.scope-1].items[0] = str[0..];
            width += 1;
        } else {
            std.debug.print("SRP: Macro not found ({s}), skipping..\n",.{name});
        }
        i = val + 1;
        j = 0;
        k = 0;
    }
    if (SRP.scope == 0){
    
    } else if (SRP.scope > MAX_DEPTH) {
        std.debug.print("SRP ERROR: Too many recursions, exiting...\n",.{});
        std.process.exit(1);
    } else {
        SRP.scope -= 1;
    }
}

fn checkMacroDuplicate(s: []const u8, ctx: *Context) void {
    _ = s;
    _ = ctx;
}

fn parseMacros(s: []const u8, ctx: *Context) ?[]const u8 {
    var name: []const u8 = "%INVALID%";
    var macro: []const u8 = "%INVALID%";
    for (ctx.pre.items) |str| {
        if (std.mem.eql(u8, s, str[0])) {
            name = str[0];
            macro = str[1];
            break;
        }
    } 
    if (std.mem.eql(u8, name, "%INVALID%") or std.mem.eql(u8, macro, "%INVALID%")) { return null; }
    if (std.mem.find(u8, macro, "$"))|tmp|{
        _ = tmp;
        var marks: usize = 0;
        var markpos: usize = 0;
        while (std.mem.findAnyPos(u8, macro, markpos,"$"))|x|{
            marks += 1;
            markpos = x + 1;
        }
        if (macro.len > 0){
            var args: usize = 0;
            var rsize: usize = 0;
            var amt: usize = 0;
            while (marks > 0) {
                if (ctx.arg.items.len > args){
                    const varstr = std.fmt.allocPrint(ctx.arena.allocator(), "{s}{}", .{"$",args}) catch { return null; };
                    rsize = std.mem.replacementSize(u8, macro, varstr, ctx.arg.items[args]);
                    amt = std.mem.replace(u8, macro, varstr, ctx.arg.items[args], &ctx.buf);
                    macro = std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{ctx.buf[0..rsize]}) catch { return null; };
                } else {
                    if (SRP.use_dummy == true) {
                        const varstr = std.fmt.allocPrint(ctx.arena.allocator(), "{s}{}", .{"$",args}) catch { return null; };
                        rsize = std.mem.replacementSize(u8, macro, varstr, ctx.sound_dummy);
                        amt = std.mem.replace(u8, macro, varstr, ctx.sound_dummy, &ctx.buf);
                        macro = std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{ctx.buf[0..rsize]}) catch { return null; };
                    } else {
                        std.debug.print("SRP PARSE MACRO: Variable macro failed with no dummy replacement. ({s}).\n",.{macro});
                        return null;
                    }
                }
                args += 1;
                marks -= amt;
            }
            if (args == 0){
                std.debug.print("PARSE MACRO: No argument found, macro nullified. ({s}).\n",.{macro});
                return null;
            } else {
                ctx.arg.clearAndFree(ctx.arena.allocator());
            }
        }
    }
    if (std.mem.eql(u8, name, "gabe")){ //Experiemental unique macro case
        return macro;
    } else {
        return macro;
    }
        return null;
}

fn parseCurly(token: []const u8, width_index: usize, ctx: *Context) !void {
    var width: usize = 0;
    var id2: usize = 0;
    var end: usize = undefined;
    while (std.mem.findAnyPos(u8, token, id2, "{")) |id| {
        SRP.scope += 1;
        if (SRP.scope == ctx.m2D.items.len){
            _ = try ctx.m2D.append(ctx.arena.allocator(), std.ArrayList([]const u8).empty);
        } 
        if (findMatchingClose(token,id)) |close|{
           end = close;
        } else {
           std.debug.print("Failed to find ending curly brace!\n",.{});
           std.process.exit(1);
        }
        const resolved = token[id..end+1];
        const resolv_clearbrace = token[id+1..end];

        const newmac = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{resolv_clearbrace});
        _ = try ctx.m2D.items[SRP.scope].append(ctx.arena.allocator(), newmac);
        width = ctx.m2D.items[SRP.scope].items.len - 1;
        _ = try parseCurly(ctx.m2D.items[SRP.scope].items[width], width, ctx);
        
        const renderstr2 = try std.fmt.allocPrint(ctx.arena.allocator(), " ${}-{} ",.{SRP.scope,width});
        const strlen2 = std.mem.replacementSize(u8, ctx.m2D.items[SRP.scope-1].items[width_index], resolved, renderstr2);
        _ = std.mem.replace(u8, ctx.m2D.items[SRP.scope-1].items[width_index], resolved, renderstr2, ctx.buf[0..]);

        const str = ctx.buf[0..strlen2];
        const newstr = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{str});
        ctx.m2D.items[SRP.scope-1].items[width_index] = newstr[0..];
        SRP.width = width;
        _ = try concatRender(ctx.m2D.items[SRP.scope].items[width], ctx);
        SRP.scope -= 1;
        width += 1;
        id2 = end + 1;
    }
}

fn checkEffect(parms: *std.mem.SplitIterator(u8, .sequence)) i8 {
    _ = parms.first(); 
    var i: usize = 0;
    while (parms.next())|value|{
        if (std.fmt.parseFloat(f32, value))|f|{
            std.debug.print("CHECK EFFECT: Value success: ({d:.2})\n",.{f});
        } else |err| {
            std.debug.print("CHECK EFFECT: Value fail: ({}) Value: ({s})\n",.{err, value});
            return -1;
        }
        i += 1;
    }
    parms.reset();
    return 0;
}

fn getValidParameters(effect_id: usize, parameter_id: usize) u8 {
    switch (effect_table[effect_id].parameter_flags[parameter_id]){
      .mode => {
          return @intFromEnum(enumValueType.none);
      },
      .gain => {
          return @intFromEnum(enumValueType.none);
      },
      .time_start => {
          return @intFromEnum(enumValueType.percent);
      },
      .time_end => {
          return @intFromEnum(enumValueType.percent) + @intFromEnum(enumValueType.relative);
      },
      .frequency => {
          return @intFromEnum(enumValueType.none);
      },
      .factor_speed => {
          return @intFromEnum(enumValueType.target);
      },
      .factor_amplitude => {
          return @intFromEnum(enumValueType.none);
      },
      .milliseconds => {
          return @intFromEnum(enumValueType.none);
      },
      .cents_integer => {
          return @intFromEnum(enumValueType.none);
      },
      .cents_fractional => {
          return @intFromEnum(enumValueType.none);
      },
      else => {
          return @intFromEnum(enumValueType.none);
      },
    }
    return @intFromEnum(enumValueType.none);
}

fn parseEffects(effect: []const u8, ctx: *Context) ![]const u8 {
    var args = std.mem.splitSequence(u8,effect,";");
    const effect_name = args.peek() orelse return "%INVALID%";
    const eff: i8 = findEffect(effect_name, ctx) orelse return "%INVALID%";
    if ((eff == 15) or (eff == 16)) { return "}"; }
    if (@as(i8,eff) == -1) { return "{1"; }
    else if (@as(i8,eff) == -2) { return "{0"; }
    Token.effect = @intCast(eff);

    var list = std.ArrayList([]const u8).empty; 
    defer list.deinit(ctx.arena.allocator());

    try ctx.arg.append(ctx.arena.allocator(), effect_name);
    _ = args.next();
    var i: usize = 0;
    if (std.mem.eql(u8, effect_name, "bend")){ //Special formatting for bend and arbitrary parameter amount
        var strs: [3][]const u8 = undefined;
        var joinedstr: []const u8 = ""; 
        var x: usize = 0;
        while (args.next())|val|{
            if (val.len != 0 and std.ascii.isAlphabetic(val[val.len - 1])) { 
                const parameter_type = getValidParameters(@intCast(Token.effect), x);
                const str = checkNumberSuffix(val[val.len - 1], val, parameter_type, Token.effect, @intCast(i), ctx) catch { 
                    ctx.arg.clearAndFree(ctx.arena.allocator());
                    return "%INVALID%"; 
                }; 
                strs[x] = str;
            } else {
                strs[x] = val;
            }
            x += 1;
            if (x == 3) {
                joinedstr = try std.mem.join(ctx.arena.allocator(), ",", &.{strs[0], strs[1], strs[2]});
                try ctx.arg.append(ctx.arena.allocator(), joinedstr);
                x = 0;
            }
        }
        return "k";
    } else {
        while (i < effect_table[Token.effect].parameter_amount){
            const arg = args.next() orelse break;
            if (arg.len != 0 and (std.ascii.isAlphabetic(arg[arg.len - 1]) or std.ascii.isPunctuation(arg[arg.len - 1]))) { 
                const parameter_type = getValidParameters(@intCast(Token.effect), i);
                const str = checkNumberSuffix(arg[arg.len - 1], arg, parameter_type, Token.effect, @intCast(i), ctx) catch { 
                    ctx.arg.clearAndFree(ctx.arena.allocator());
                    return "%INVALID%"; 
                }; 
                try ctx.arg.append(ctx.arena.allocator(), str);
            } else {
                try ctx.arg.append(ctx.arena.allocator(), arg);
            } 
            i += 1;
        }
    }
    return "k";
}

//User may specify a target duration using percentages (0p-100p) as calculated by this function
fn getTargetPercent(f: *f32) void { //
    const samples: f32 = @floatFromInt(Token.samples);
    const rate: f32 = @floatFromInt(Token.rate);
    const sec_duration: f32 = (samples / rate);
    const cent: f32 = sec_duration / 100;
    f.* = (cent * f.*);
    std.debug.print("Length: ({d:.2})  Cent: ({})  New: ({})\n",.{sec_duration,cent,f.*});
    return;
}

//For example: "speed" only takes 1 parameter: changing the speed of the audio by (x) times
//If the user wants a specific duration instead, the factor (x) can be calculated using this function
fn getTargetFactor(f: *f32) void {
    const samples: f32 = @floatFromInt(Token.samples);
    const rate: f32 = @floatFromInt(Token.rate);
    const sec_duration: f32 = (samples / rate);
    const factor: f32 = sec_duration / f.*;
    f.* = factor;
    std.debug.print("Length: ({d:.2})  Samples: ({})  Rate: ({})\n",.{sec_duration,Token.samples,Token.rate});
    return;
}

//Many sox effects have a start and end (or duration) 
//But if the duration is unknown to the user, it can be calculated and shortened by (f) amount of seconds
fn getTargetRelative(f: *f32) void { //'r' for relative or reverse, e.g. relative to audio duration
    const samples: f32 = @floatFromInt(Token.samples);
    const rate: f32 = @floatFromInt(Token.rate);
    const sec_duration: f32 = (samples / rate);
    const factor: f32 = sec_duration - f.*;
    f.* = factor;
    std.debug.print("Length: ({d:.2})  Samples: ({})  Rate: ({})\n",.{sec_duration,Token.samples,Token.rate});
    return;
}

fn checkNumberSuffix(char: u8, str: []const u8, valid_flags: u8, effect_id: u8, parameter_id: u8,ctx: *Context) ![]const u8 {
    var parsed_value: f32 = undefined;
    if (char != '?') { parsed_value = std.fmt.parseFloat(f32, str[0..str.len-1]) catch |err| return err; }
    const err = error.InvalidValueConversion;
    switch (char){
        'p' => { 
            if ((valid_flags & @intFromEnum(enumValueType.percent)) != 0) {
                getTargetPercent(&parsed_value); 
            } else {
                std.debug.print("SRP CHECK EFFECT: Invalid usage of percent for this value ({any})({})({}).\n",.{valid_flags,effect_id,parameter_id});
                return err; 
            }
        },
        't' => { 
            if ((valid_flags & @intFromEnum(enumValueType.target)) != 0) {
                getTargetFactor(&parsed_value); 
            } else {
                std.debug.print("SRP CHECK EFFECT: Invalid usage of target for this value.\n",.{});
                return err; 
            }
        },
        'r' => { 
            if ((valid_flags & @intFromEnum(enumValueType.relative)) != 0) {
                getTargetRelative(&parsed_value); 
            } else {
                std.debug.print("SRP CHECK EFFECT: Invalid usage of relative duration for this value.\n",.{});
                return err; 
            }
        },
        'k' => {
            if (std.mem.eql(u8, "rate", effect_table[effect_id].name)){
                return str;
            }
        },
        '?' => {
            generateRandomValue(&parsed_value, str, effect_id, parameter_id) catch |err2| return err2;
        },
        else => { 
            return error.UnknownConversionChar;
        },
    } 
    const formatstr = try std.fmt.allocPrint(ctx.arena.allocator(), "{}", .{parsed_value});
    return formatstr;
}

fn floatRange(min: f32, max: f32) f32 {
    const r: u32 = rng.int(u32) & ((1 << 24) - 1); //Mantissa shift
    const t: f32 = @as(f32, @floatFromInt(r)) / @as(f32, (1 << 24) - 1);
    return min + t * (max - min);
}

fn generateRandomValue(f: *f32, str: []const u8, effect_id: u8, parameter_id: u8) !void {
    var range: [2]?f32 = .{null, null};
    var min: isize = 0;
    var max: isize = 0;
    const clearq = str[0..str.len-1];
    const err1 = error.RandomUnavailable;
    const err2 = error.RandomRangeParseFailed;
    if (std.mem.containsAtLeast(u8, clearq, 1, ":")){
        var val = std.mem.splitSequence(u8, clearq, ":");
        var i: usize = 0;
        while (val.next())|value|{
            if ((value[0] == ' ') or (i == 2)) { break; }
            range[i] = std.fmt.parseFloat(f32, value) catch return err2;
            i += 1;
        }
    }
    switch (effect_table[Token.effect].parameter_flags[parameter_id]){
      .mode => { 
          if (effect_id == 15){ }
          return err1;
      },
      .gain => {
          const x = floatRange(range[0] orelse 0.1, range[1] orelse 1.0);
          f.* = x;
      },
      .time_start => {
          const dur: f32 = @as(f32, @floatFromInt(Token.samples)) / @as(f32, @floatFromInt(Token.rate));
          const x = floatRange(range[0] orelse 0.01, range[1] orelse dur);
          f.* = x;
      },
      .time_end => {
          const dur: f32 = @as(f32, @floatFromInt(Token.samples)) / @as(f32, @floatFromInt(Token.rate));
          const x = floatRange(range[0] orelse 0.01, range[1] orelse dur);
          f.* = x;
      },
      .frequency => {
          min = @as(isize, @intFromFloat(range[0] orelse 1)); //1
          max = @as(isize, @intFromFloat(range[1] orelse 15)); //15
          const hz: f32 = @as(f32, @floatFromInt(rng.intRangeAtMost(u8, @intCast(min), @intCast(max))));
          f.* = hz;
      },
      .factor_speed => {
          const x = floatRange(range[0] orelse 0.2, range[1] orelse 5);
          f.* = x;
      },
      .factor_amplitude => {
          const x = floatRange(range[0] orelse 0.2, range[1] orelse 10);
          f.* = x;
      },
      .milliseconds => {
          min = @as(isize, @intFromFloat(range[0] orelse 1));
          max = @as(isize, @intFromFloat(range[1] orelse 1500));
          const millisecond_delay: f32 = @as(f32, @floatFromInt(rng.intRangeAtMost(u16, @intCast(min), @intCast(max))));
          f.* = millisecond_delay;
      },
      .cents_integer => {
          min = @as(isize, @intFromFloat(range[0] orelse 0));
          max = @as(isize, @intFromFloat(range[1] orelse 100));
          const cent: f32 = @as(f32, @floatFromInt(rng.intRangeAtMost(u8, @intCast(min), @intCast(max))));
          f.* = cent;
      },
      .cents_fractional => {
          const x = floatRange(range[0] orelse 0.1, range[1] orelse 1.0);
          f.* = x;
      },
      .cents_relative => {
          min = @as(isize, @intFromFloat(range[0] orelse -2000));
          max = @as(isize, @intFromFloat(range[1] orelse 2000));
          const cent: f32 = @as(f32, @floatFromInt(rng.intRangeAtMost(i16, @intCast(min), @intCast(max))));
          f.* = cent;
      },
      .uint => {
          min = @as(isize, @intFromFloat(range[0] orelse 1));
          max = @as(isize, @intFromFloat(range[1] orelse 10));
          const repeat: f32 = @as(f32, @floatFromInt(rng.intRangeAtMost(u8, @intCast(min), @intCast(max))));
          f.* = repeat;
      },
      .rate => {
          min = @as(isize, @intFromFloat(range[0] orelse 400));
          max = @as(isize, @intFromFloat(range[1] orelse 44100));
          const rate: f32 = @as(f32, @floatFromInt(rng.intRangeAtMost(u16, @intCast(min), @intCast(max))));
          f.* = rate;
      },
      .speed_start => {
          const x = floatRange(range[0] orelse 0.1, range[1] orelse 10);
          f.* = x;
      },
      .speed_end => {   
          const x = floatRange(range[0] orelse 0.1, range[1] orelse 10);
          f.* = x;
      },
    }
}

fn preRubber(token: []const u8, ctx: *Context) !void {
    const plot_rate: f32 = 20; //Time map changes per second
    var map_type: enumMapType = .time_map;
    Token.effect = 15;
    var args = std.mem.splitSequence(u8,token,";");
    const effect_name = args.first();
    if (std.mem.eql(u8, effect_name, "rbp")){
        map_type = .pitch_map;
        Token.effect = 16; 
    } 
    var time_map: std.Io.File = undefined;
    var pitch_map: std.Io.File = undefined;
    const second_half = BUFSIZE/2; //Second half of buffer

    if (std.Io.Dir.openFileAbsolute(ctx.io, RBP_MAP, std.Io.Dir.OpenFileOptions{.mode = .write_only}))|cap| {
        pitch_map = cap;
    } else |err| {
        std.debug.print("{any} Could not find rb pitchmap, creating...\n", .{err});  
        pitch_map = try std.Io.Dir.createFileAbsolute(ctx.io, RBP_MAP, std.Io.Dir.CreateFileOptions{.truncate = true, .permissions = .default_file}); 
    }
    if (std.Io.Dir.openFileAbsolute(ctx.io, RBT_MAP, std.Io.Dir.OpenFileOptions{.mode = .write_only}))|cap| {
        time_map = cap;
    } else |err| {
        std.debug.print("{any} Could not find rb timemap, creating...\n", .{err});
        time_map = try std.Io.Dir.createFileAbsolute(ctx.io, RBT_MAP, std.Io.Dir.CreateFileOptions{.truncate = true, .permissions = .default_file}); 
    }
    _ = try time_map.setLength(ctx.io, 0);
    _ = try pitch_map.setLength(ctx.io, 0);
    var parms: [5]f32 = .{0, 1, 1, 0, 0};
    var i: usize = 0;
    while (args.next())|parm|{
        const p = parm;
        if (p.len != 0 and (std.ascii.isAlphabetic(p[p.len - 1]) or std.ascii.isPunctuation(p[p.len - 1]))) { 
            const parameter_type = getValidParameters(Token.effect, i);
            const parsed = checkNumberSuffix(p[p.len - 1], p, (parameter_type), Token.effect, @intCast(i), ctx) catch |err| { 
                time_map.close(ctx.io);
                pitch_map.close(ctx.io);
                std.debug.print("{any} Parsing error.\n", .{err});
                return;
            };
            parms[i] = try std.fmt.parseFloat(f32, parsed);
        } else {
            parms[i] = try std.fmt.parseFloat(f32, parm); 
        }
        i += 1;
    }
    const sample_rate: f32 = @floatFromInt(Token.rate);
    const sample_length: f32 = @floatFromInt(Token.samples);
    const sample_stepsize = sample_rate / plot_rate;
    var steps = sample_length / sample_stepsize;
    const rate_stepsize: u32 = @trunc(sample_stepsize);
    _ = rate_stepsize;
    const steps_int: u32 = @trunc(steps);
    const stepsize_reference: f32 = sample_length / steps;
    const old_duration: f32 = sample_length / sample_rate;

    var step_reference: f32 = 0;
    var step_new: f32 = 0;
    var step_count: u32 = 0;

    const start_speed: f32 = parms[1];
    const end_speed: f32 = parms[2];
    const start_pos_old: f32 = parms[3];
    const end_pos_old: f32 = if ((parms[4] != 0) and (parms[4] <= old_duration)) parms[4] else old_duration;

    const start_pos_new: f32 = @trunc(start_pos_old * sample_rate);
    const end_pos_new: f32 = @trunc(end_pos_old * sample_rate);
    steps = @trunc((end_pos_new - start_pos_new) / sample_stepsize); //Safe to reuse steps here as the counter uses the int version

    const mode_f: u32 = @intFromFloat(parms[0]);
    var rubber: Rubber = .{
        .mode = @enumFromInt(mode_f),
        .amplitude = std.math.log(f32, std.math.e, 10),
        .plot_size = 0,
        .mod = start_speed,
        .pitch = start_speed,
        .speed_start = start_speed,
        .speed_end = end_speed,
        .speed_current = start_speed,
        .steps = steps_int,
        .step_current = 0,
        .factor = std.math.pow(f32, end_speed / start_speed, 1.0 / @as(f32, steps))
    };

    if (Token.rate != 44100){
        std.debug.print("\n\nDEBUG: FOUND A CASE WHERE SAMPLE RATE IS NOT 44KHZ!\n\n",.{});
        unreachable;
    }

    var rwrite = time_map.writer(ctx.io, &ctx.buf);
    _ = try rwrite.seekTo(0);
    _ = try rwrite.interface.print("0 0\n", .{});
    _ = try rwrite.flush();
    var rwrite2 = pitch_map.writer(ctx.io, ctx.buf[second_half..]); //Writes to the second half of buffer not to collide with timemap
    _ = try rwrite2.seekTo(0);
    _ = try rwrite2.interface.print("0 {d:.2}\n", .{rubber.pitch});
    _ = try rwrite2.flush();
    std.debug.print("AMP: ({})\n",.{rubber.amplitude});
    if ((rubber.mode == .linear) or (rubber.mode == .exponential)) { rubber.plot_size = (end_speed - start_speed) / steps; } 
    else if (rubber.mode == .sine) { 
        rubber.plot_size = ((std.math.pi * 2) / steps) * end_speed; rubber.mod = 0; 
        rubber.speed_current = 1;
        rubber.pitch = 1;
        rubber.amplitude = std.math.log(f32, 10, start_speed);
    } else if (rubber.mode == .triangle){
        rubber.plot_size = ((std.math.pi * 2) / steps) * end_speed; rubber.mod = 0; 
    } else { 
        rubber.plot_size = ((std.math.pi * 2) / steps) * end_speed; rubber.mod = 0; 
        rubber.speed_current = 1;
        rubber.pitch = 1;
        rubber.amplitude = rubber.speed_start;
    }

    while (step_count < steps_int){
        step_reference += stepsize_reference;
        if ((step_reference >= start_pos_new) and (step_reference <= end_pos_new)){
            speedFactor(&rubber);
            rubber.step_current += 1;
        }
        step_new += stepsize_reference / rubber.speed_current;
        rubber.pitch = rubber.speed_current;
        _ = try rwrite.interface.print("{d:.0} {d:.0}\n", .{step_reference, step_new});
        _ = try rwrite2.interface.print("{d:.0} {d:.2}\n", .{step_reference, rubber.pitch});
        _ = try rwrite.flush();
        _ = try rwrite2.flush();
        step_count += 1;
    }
    const new_length: f32 = step_new;
    const new_duration: f32 = new_length / sample_rate;

    const duration = try std.fmt.allocPrint(ctx.arena.allocator(), "{}",.{new_duration});
    const pitchform = try std.fmt.allocPrint(ctx.arena.allocator(), "{}",.{rubber.pitch});
    const rubname = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}rubber.wav",.{TEMP_PATH});
    const sndname = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{Token.name});

    var rublist = std.ArrayList([]const u8).empty; 
    defer rublist.deinit(ctx.arena.allocator());
    try rublist.append(ctx.arena.allocator(), "rubberband");
    if (map_type == .pitch_map){
        try rublist.append(ctx.arena.allocator(), "-p");
        try rublist.append(ctx.arena.allocator(), pitchform);
        try rublist.append(ctx.arena.allocator(), "--freqmap");
        try rublist.append(ctx.arena.allocator(), RBP_MAP);
    } else {
        try rublist.append(ctx.arena.allocator(), "-D");
        try rublist.append(ctx.arena.allocator(), duration);
        try rublist.append(ctx.arena.allocator(), "--timemap");
        try rublist.append(ctx.arena.allocator(), RBT_MAP);
    }
    try rublist.append(ctx.arena.allocator(), sndname);
    try rublist.append(ctx.arena.allocator(), rubname);

    _ = try rwrite.flush();
    _ = try rwrite2.flush();
    _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = try rublist.toOwnedSlice(ctx.arena.allocator())});
    Token.name = rubname;
    try updateSoxInfo(Token.name, ctx);
    ctx.arg.clearAndFree(ctx.arena.allocator());
    time_map.close(ctx.io);
    pitch_map.close(ctx.io);
}

fn speedFactor(rubber: *Rubber) void {
    var wave: f32 = undefined;
    const min_speed: f32 = 1.0 / @abs(rubber.speed_start);
    const max_speed: f32 = @abs(rubber.speed_start); 
    const polarity: f32 = if (rubber.speed_start < 0) -1 else 1;
    const center = (min_speed + max_speed) * 0.5;
    const range = (max_speed - min_speed) * 0.5;
    switch (rubber.mode){
        .linear => { 
            const speed = rubber.mod;
            rubber.mod += rubber.plot_size;
            rubber.speed_current = speed; 
        }, 
        .exponential => {
            const t = @as(f32, @floatFromInt(rubber.step_current)) / @as(f32, @floatFromInt(rubber.steps));
            const u = t * t * (3.0 - 2.0 * t);
            const speed = rubber.speed_start * std.math.pow(f32, (rubber.speed_end / rubber.speed_start), u);
            rubber.mod *= rubber.factor;
            rubber.speed_current = speed; 
        },
        .sine => { 
            wave = std.math.sin(rubber.mod);
            const speed = 1 + rubber.amplitude * wave;
            rubber.mod += rubber.plot_size;
            rubber.speed_current = speed; 
        },
        .ushape => {
            wave = std.math.sin(rubber.mod);
            wave *= polarity;
            const speed = center + range * wave;
            rubber.mod += rubber.plot_size;
            rubber.speed_current = speed; 
        },
        .triangle => {
            wave = (2.0 / std.math.pi) * std.math.asin(std.math.sin(rubber.mod));
            wave *= polarity;
            const speed = center + range * wave;
            rubber.mod += rubber.plot_size;
            rubber.speed_current = speed; 
        },
        .square => {
            if (std.math.sin(rubber.mod) >= 0) { wave = 1.0; } else { wave = -1.0; }
            wave *= polarity;
            const speed = std.math.pow(f32, range, wave);
            rubber.mod += rubber.plot_size;
            //rubber.mod += rubber.plot_size / rubber.speed_current; //More equal real-time wave
            rubber.speed_current = speed; 
        },
        .sawtooth => { 
            const phase = rubber.mod / (2.0 * std.math.pi);
            wave = 2.0 * (phase - std.math.floor(phase)) - 1.0;
            wave *= polarity;
            const speed = center + range * wave;
            rubber.mod += rubber.plot_size;
            rubber.speed_current = speed; 
        },
    }
}

fn updateSoxInfo(token: []const u8, ctx: *Context) !void {
    const soxi = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = &.{"soxi", token} });
    var toks = std.mem.splitSequence(u8, soxi.stdout, "\n");
    var start: usize = 0;
    var end: usize = 0;
    while (toks.next())|line|{
        if (std.mem.find(u8, line, "Channels") != null){
            for (line) |c| {
                if ((c >= '0') and (c <= '9')){
                    Token.channels = c - '0';
                }
            }
        } else if (std.mem.find(u8, line, "Sample Rate") != null){
            for (line, 0..) |c,i| {
                if ((c >= '0') and (c <= '9')){
                    if (start == 0){
                        start = i;
                    } else {
                        end = i;
                    }
                }
            }
            Token.rate = try std.fmt.parseInt(u24, line[start..end+1], 10);
            start = 0;
            end = 0;
        } else if (std.mem.find(u8, line, "Precision") != null){
            for (line, 0..) |c,i| {
                if ((c >= '0') and (c <= '9')){
                    if (start == 0){
                        start = i;
                    } else {
                        end = i;
                    }
                }
            }
            Token.precision = try std.fmt.parseInt(u8, line[start..end+1], 10);
            start = 0;
            end = 0;
        } else if (std.mem.find(u8, line, "Duration") != null){
            start = 31;
            end = 31;
            for (line[start..]) |c| {
                if ((c >= '0') and (c <= '9')){
                    end += 1;
                } else {
                    break;
                }
            }
            @memcpy(&Token.duration, line[17..28]);
            Token.samples = try std.fmt.parseInt(u32, line[start..end], 10);
            start = 0;
            end = 0;
        }
    }
}

fn reformatSpaces(token: []const u8, ctx: *Context) []const u8 {
    var newlen: usize = 0;
    var c_old: u8 = 0;
    for (token[0..])|c|{
        if (c == ' '){
            if ((c_old == 0) or (c_old == ' ') or (c_old == '/')){
                continue;
            }
        } else if ((c == '+') or (c == '/')){
            if (c_old == ' '){
                newlen -= 1;
            }
        }
        ctx.buf[newlen] = c;     
        newlen += 1;
        c_old = c;
    }
    if (c_old == ' ') newlen -= 1;
    return ctx.buf[0..newlen];
}

fn parseQueue(ctx: *Context, queue: *std.mem.SplitIterator(u8, .sequence), mode: enumMode) !void {
    loop_token: while (queue.next())|token|{
        if (token.len == 0){
            continue;
        }
        var merge_list = std.mem.splitSequence(u8, token, "/");
        _ = merge_list.first();
        if (merge_list.next())|hello|{
            merge_list.reset();
            _ = hello;
            var split_id: usize = Token.combo;
            _ = try parseQueue(ctx, &merge_list, .mix);
            var merge_queue = std.ArrayList([]const u8).empty; 
            var amt: usize = Token.combo - split_id;
            _ = try merge_queue.append(ctx.arena.allocator(), "sox");
            while (amt > 0){ 
                const formatstr = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render{}.wav", .{TEMP_PATH,split_id});
                _ = try merge_queue.append(ctx.arena.allocator(), formatstr);
                split_id += 1;
                amt -= 1;
            }
            const formatstr = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render{}.wav",.{TEMP_PATH,split_id});
            _ = try merge_queue.append(ctx.arena.allocator(), formatstr);
            _ = try merge_queue.append(ctx.arena.allocator(), "-m");
            _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = try merge_queue.toOwnedSlice(ctx.arena.allocator())});
            const concatstr = try std.fmt.allocPrint(ctx.arena.allocator(), "&{}",.{Token.combo});
            try ctx.tok.append(ctx.arena.allocator(), concatstr);
            Token.combo += 1;
            SRP.rendered += 1;
            continue :loop_token;
        }
        var effect_list = std.mem.splitSequence(u8, token, "+");
        var sound_name = effect_list.first();
        if ((Token.combo == 0) and (mode == .default)){  //Rofi may send file extension on first token    
            if (std.mem.endsWith(u8, sound_name, ".ogg")){
                sound_name = std.mem.cutSuffix(u8, sound_name, ".ogg") orelse sound_name;
            } else if (std.mem.endsWith(u8, sound_name, ".mp3")){
                sound_name = std.mem.cutSuffix(u8, sound_name, ".mp3") orelse sound_name;
            }
        }
        const findstatus = try findSnd(sound_name, ctx);
        if (findstatus == 1) {
            continue;
        }
        try updateSoxInfo(Token.name, ctx);
        const concatstr = try std.fmt.allocPrint(ctx.arena.allocator(), "&{}",.{Token.combo});
        if (effect_list.peek() != null){
            loop_effect: while (effect_list.next())|fx|{
                const effect_name = try parseEffects(fx, ctx);
                if (std.mem.eql(u8, effect_name, "%INVALID%")) { continue :loop_effect; }
                switch (effect_name[0]){
                    '{' => {  //Variable effect macro
                        if (effect_name[1] == '0'){ //Effect macro
                            var effmacro = std.mem.splitSequence(u8, Token.label, "€");
                            try parseQueue(ctx, &effmacro, .macro);
                            continue :loop_effect;
                        } else if (effect_name[1] == '1'){ //Variable effect macro
                            var varmacro = std.mem.splitSequence(u8, Token.label, " ");
                            try parseQueue(ctx, &varmacro, .default);
                            continue :loop_token;
                        }
                    },
                    '}' => {  //Rubbberband effects
                        if ((std.mem.startsWith(u8, fx, "rbp")) or  
                            (std.mem.startsWith(u8, fx, "rbt")) or
                            (std.mem.startsWith(u8, fx, "rbx"))){ 
                            Token.render = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render.wav",.{TEMP_PATH});
                            preRender(ctx) catch continue :loop_token;
                            preRubber(fx, ctx) catch continue :loop_token;
                            continue :loop_effect;
                        }
                    },
                    else => { //Any regular effect
                    },
                }
            }
            Token.render = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render{}.wav",.{TEMP_PATH,Token.combo});
            preRender(ctx) catch continue :loop_token;
            if ((mode != .mix) and (mode != .macro)) { try ctx.tok.append(ctx.arena.allocator(), concatstr); }
        } else {
            try updateSoxInfo(Token.name, ctx);
            if ((Token.rate == 44100) and (Token.channels == 2) and (mode != .mix) and (mode != .macro)){
                _ = try ctx.tok.append(ctx.arena.allocator(), Token.label);
            } else {
                Token.render = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render{}.wav",.{TEMP_PATH,Token.combo});
                const status = std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = &.{"sox", Token.name,"-r","44100","-c","2",Token.render}}) catch continue :loop_token;
                _ = status;
                if ((mode != .mix) and (mode != .macro)) { try ctx.tok.append(ctx.arena.allocator(), concatstr); }
            }
        }
       SRP.rendered += 1;
       Token.combo += 1;
   }
}

fn concatRender(token: []const u8, ctx: *Context) !void {
    if ((std.mem.findAny(u8, token, "{") != null) or (std.mem.findAny(u8, token, "}") != null)){
        std.debug.print("FATAL ERROR! Curly braces found in concat renderer. Exiting...\n",.{});
        std.process.exit(1);
    } 
    var list = std.ArrayList([]const u8).empty; 
    defer list.deinit(ctx.arena.allocator());
    const reformstr = reformatSpaces(token, ctx);
    const temp = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{reformstr});
    var tokens = std.mem.splitSequence(u8, temp, " ");
    Token.combo = 0;
    _ = try parseQueue(ctx, &tokens, .concat); 
    try ctx.arg.append(ctx.arena.allocator(), "sox");
    for (ctx.tok.items)|z|{
        if (z[0] == '$'){   //Pre-rendered concat sounds from inner scopes
            const str = try reformatCombo(z, ctx);
            try ctx.arg.append(ctx.arena.allocator(), str);
        } else if (z[0] == '&'){    //Pre-rendered individual sounds from this concat instance
            const renderID = try std.fmt.parseInt(u8, z[1..], 10);
            const sform = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render{}.wav",.{TEMP_PATH,renderID});
            try ctx.arg.append(ctx.arena.allocator(), sform);
        } else { 
            const sform = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}.*",.{z});
            const findstd = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = &.{"find", ctx.sound_path, "-name", sform, "-print0"} });
            const sname = std.mem.cutSuffix(u8, findstd.stdout, "\n") orelse findstd.stdout;
            try ctx.arg.append(ctx.arena.allocator(), sname);
        }
    }
    ctx.tok.clearAndFree(ctx.arena.allocator());
    const out = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}combo{}-{}.wav",.{TEMP_PATH,SRP.scope,SRP.width});
    try ctx.arg.append(ctx.arena.allocator(), out);
    _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = try ctx.arg.toOwnedSlice(ctx.arena.allocator())});
    SRP.combined += 1;
}

fn reformatCombo(token: []const u8, ctx: *Context) ![]const u8 {
    var cnum = std.mem.splitAny(u8, token[1..], "-");
    const i_scope = try std.fmt.parseInt(u8, (cnum.next() orelse "0"), 10);
    const i_width = try std.fmt.parseInt(u8, (cnum.next() orelse "0"), 10);
    const combostr = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}combo{}-{}.wav",.{TEMP_PATH,i_scope,i_width});
    return combostr;
}

fn debugPrintByteStr(token: []const u8) void {
    for (token) |b| {     
        std.debug.print("{x:0>2} ",.{b});
    }
}

fn findSnd(token: []const u8, ctx: *Context) !u8 {
    if (token.len == 0) { return 1; }
    if (token[0] == '?'){
        const formatstr = try std.fmt.allocPrint(ctx.arena.allocator(), "find {s} -type f -name \"*.*\" | shuf -n 1",.{ctx.sound_path});
        const findstd2 = try std.process.run(ctx.arena.allocator(),ctx.io, .{.argv = &.{"sh","-c",formatstr}});
        std.debug.print("RANDOM FIND: {s}\n",.{findstd2.stdout});
        if (findstd2.stdout.len == 0){
            if ((SRP.use_dummy == true) and (std.mem.eql(u8, token, ctx.sound_dummy) == false)){
                _ = try findSnd(ctx.sound_dummy, ctx); 
                return 0;
            } else if ((SRP.use_dummy == true) and (std.mem.eql(u8, token, ctx.sound_dummy) == true)){
                std.debug.print("SRP FINDSND: DUMMY NOT FOUND! ({s})\n",.{ctx.sound_dummy});
                std.process.exit(1);
            } else {
                return 1;
            }
        } else {
            @memcpy(Token.path[0..findstd2.stdout.len], findstd2.stdout);
            Token.name = Token.path[0..findstd2.stdout.len-1];
        }
    } else if (token[0] == '$'){
        const formatstr = try reformatCombo(token, ctx);
        @memcpy(Token.path[0..formatstr.len], formatstr);
        Token.name = Token.path[0..formatstr.len];
    } else {
        const findstr = try std.fmt.allocPrint(ctx.arena.allocator(), "find {s} -type f -name \"{s}.*\" | shuf -n 1",.{ctx.sound_path,token});
        const findstd = try std.process.run(ctx.arena.allocator(),ctx.io, .{.argv = &.{"sh","-c",findstr}});
        if (findstd.stdout.len == 0){    
            if ((SRP.use_dummy == true) and (std.mem.eql(u8, token, ctx.sound_dummy) == false)){
                _ = try findSnd(ctx.sound_dummy, ctx);
                return 0;
            } else if ((SRP.use_dummy == true) and (std.mem.eql(u8, token, ctx.sound_dummy) == true)){
                std.debug.print("SRP FINDSND: DUMMY NOT FOUND! ({s})\n",.{ctx.sound_dummy});
                std.process.exit(1);
            } else {
                return 1;
            }
        } else {
            @memcpy(Token.path[0..findstd.stdout.len], findstd.stdout);
            Token.name = Token.path[0..findstd.stdout.len-1];
        }
    }
    const tokenalloc = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{token});
    Token.label = tokenalloc;
    return 0;
}

fn playQueue(ctx: *Context) !void {
    for (ctx.tok.items)|token|{
        if (token[0] == '$'){   //Pre-rendered concat sounds from inner scopes
            Token.name = try reformatCombo(token, ctx);
        } else if (token[0] == '&'){    //Pre-rendered individual sounds from this concat instance
            const renderID = try std.fmt.parseInt(u8, token[1..], 10);
            Token.name = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}render{}.wav",.{TEMP_PATH,renderID});
        } else { 
            const sform = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}.*",.{token});
            const findstd = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = &.{"find", ctx.sound_path, "-name", sform, "-print0"} });
            Token.name = std.mem.cutSuffix(u8, findstd.stdout, "\n") orelse findstd.stdout;
        }
        if (std.mem.eql(u8, ctx.audio_player, "gstreamer")){
            const gs_input = try std.fmt.allocPrint(ctx.arena.allocator(), "location={s}", .{Token.name});
            const gs_device = try std.fmt.allocPrint(ctx.arena.allocator(), "device={s}", .{ctx.audio_device});
            const gs_volume = try std.fmt.allocPrint(ctx.arena.allocator(), "volume={}", .{ctx.audio_volume});
            _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{ //GStreamer
                .argv = &.{"gst-launch-1.0", "filesrc", gs_input, "!", "decodebin", "!", "audioconvert", "!", "audioresample", "!",
                "volume", gs_volume, "!", "pulsesink", gs_device},
            });
        }  else {
            ctx.audio_volume = @trunc(ctx.audio_volume * 65535);
            const pulse_volume = try std.fmt.allocPrint(ctx.arena.allocator(), "--volume={}", .{ctx.audio_volume});
            _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{ //paplay
                .argv = &.{"paplay", "--d=V1", pulse_volume, Token.name},
            });
        }
    }
    ctx.tok.clearAndFree(ctx.arena.allocator());
}

fn debugPrint2DArray(ctx: *Context) void {
    var xx: usize = 0;
    var xy: usize = 0;
    for (ctx.m2D.items)|a|{
        for (a.items)|b| {
            std.debug.print("DEBUG 2D ARRAY: ({}:{}) ({s})\n",.{xx,xy,b});
            xy += 1;
        }
        xx += 1;
        xy = 0;
    }
}

fn preRender(ctx: *Context) !void {
    var args = std.ArrayList([]const u8).empty; 
    defer args.deinit(ctx.arena.allocator());

    if (std.mem.eql(u8, Token.name, Token.render)){
        std.debug.print("\nPRERENDER WARNING! Equal names for input and output render!\n\n",.{});
        unreachable;
    }

    try args.append(ctx.arena.allocator(), "sox");
    try args.append(ctx.arena.allocator(), Token.name);
    try args.append(ctx.arena.allocator(), "-c");
    try args.append(ctx.arena.allocator(), "2");
    try args.append(ctx.arena.allocator(), "-r");
    try args.append(ctx.arena.allocator(), "44100");
    try args.append(ctx.arena.allocator(), Token.render); 
    for (ctx.arg.items)|arg|{
        try args.append(ctx.arena.allocator(),arg);
    }
    const status = std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = try args.toOwnedSlice(ctx.arena.allocator())}) catch |err| {
        std.debug.print("RENDER ERROR: {any}\n",.{err});
        ctx.arg.clearAndFree(ctx.arena.allocator());
        return err;
    };
    _ = status;
    Token.name = Token.render;
    try updateSoxInfo(Token.name, ctx);

    ctx.arg.clearAndFree(ctx.arena.allocator());  
    SRP.rendered += 1;
}

pub fn main(init: std.process.Init) !void {
    const time = std.time; 
    const Io = std.Io;
    const stdin = std.Io.File.stdin();

    var ctx: Context = undefined;

    ctx = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = std.heap.ArenaAllocator.init(init.gpa),
        .buf = undefined,
        .arg = std.ArrayList([]const u8).empty,
        .tok = std.ArrayList([]const u8).empty,
        .eff = std.ArrayList([2][]const u8).empty,
        .raw = std.ArrayList([2][]const u8).empty,
        .pre = std.ArrayList([2][]const u8).empty,
        .m2D = std.ArrayList(std.ArrayList([]const u8)).empty,
        .sound_path = undefined,
        .sound_dummy = undefined,
        .audio_device = undefined,
        .audio_player = undefined,
        .audio_volume = 1,
    };
    defer ctx.arena.deinit();
    defer ctx.arg.deinit(ctx.arena.allocator());
    defer ctx.tok.deinit(ctx.arena.allocator());
    defer ctx.eff.deinit(ctx.arena.allocator());
    defer ctx.raw.deinit(ctx.arena.allocator());
    defer ctx.pre.deinit(ctx.arena.allocator());
    defer ctx.m2D.deinit(ctx.arena.allocator());

    var cmdarg_list = std.ArrayList([]const u8).empty;
    defer cmdarg_list.deinit(ctx.arena.allocator());
    var cmdargs = try init.minimal.args.iterateAllocator(ctx.arena.allocator());
    defer cmdargs.deinit();
    cmdargs = cmdargs;
    var cmdarg_amt: usize = 0;
    while (cmdargs.next())|cmdvar|{
        cmdarg_amt += 1;
        _ = try cmdarg_list.append(ctx.arena.allocator(), cmdvar);
    }
    
    //Prepare built-in macros into a combined array
    for (strMacroPreset)|macro|{ 
        _ = try ctx.pre.append(ctx.arena.allocator(), .{macro[0], macro[1]}); 
    }
    for (effectMacroPreset)|macro|{
        _ = try ctx.raw.append(ctx.arena.allocator(), .{macro[0], macro[1]}); 
    }

    //Check if tmp folder exists
    if (Io.Dir.accessAbsolute(ctx.io, TEMP_PATH, .{.read = true}))|dir|{
        _ = dir;
    } else |err| {
        std.debug.print("{}: Temp folder not found. Creating...\n",.{err});
        if (Io.Dir.createDirAbsolute(ctx.io, TEMP_PATH, Io.File.Permissions.default_dir))|dir2|{
            std.debug.print("Creating tmp folder... {}\n",.{dir2});
        } else |err2| {
            std.debug.print("{}: Could not create tmp folder at ({s})! Exiting...\n",.{err2,TEMP_PATH});
            std.process.exit(1);
        }
    }
    const exedir = try std.process.executableDirPathAlloc(ctx.io, ctx.arena.allocator());
    const confpath = try std.fs.path.join(ctx.arena.allocator(), &.{exedir,CONFIG_NAME});
    defer ctx.arena.allocator().free(exedir);
    defer ctx.arena.allocator().free(confpath);
    
    //Check for config file
    var conffile: std.Io.File = undefined;
    var filesize: u64 = undefined;
    filesize = 0;
    const tryconf = std.Io.Dir.openFileAbsolute(ctx.io, confpath, std.Io.Dir.OpenFileOptions{});
    if (tryconf) |f| {
        conffile = f;
    } else |err| {
        std.debug.print("{any}\nCould not read config file! Make sure it is setup properly.\n",.{err}); 
        std.debug.print("Expected config path: {s}\n",.{confpath}); 
        std.process.exit(1);
    }
    const filestat = conffile.stat(ctx.io) catch |err| {
        std.debug.print("{any}\nFailed to read config file stats.\n",.{err}); 
        std.process.exit(1);
    };
    filesize = filestat.size;
    if (filesize < 16) {
        std.debug.print("ERROR: Config file size smaller than smallest possible valid config.\n",.{}); 
        std.process.exit(1);
    } else if (filesize > BUFSIZE) {
        std.debug.print("ERROR: Config file size larger than SRP buffer size (max buffer size: {}).\n",.{BUFSIZE}); 
        std.process.exit(1);
    }
    var fileconfig_reader = conffile.reader(ctx.io, ctx.buf[0..]);
    const file_io = &fileconfig_reader.interface; 
    var sound_path: []u8 = undefined;
    var line_column: usize = 0;
    var confline: usize = 0;
    var matchpoint: [4]usize = .{0,0,0,0};
    var matches: usize = 0;
    lineread: while (try file_io.takeDelimiter('\n'))|line| {
        if (line.len == 0) { continue; }
        if (line[0] == '#') { continue; }
        line_column = 0;
        matches = 0;
        matchpoint = .{0,0,0,0};
        if (std.mem.startsWith(u8, line, "SOUND_")){
            const start = std.mem.find(u8, line, "\"") orelse 12;
            const end = std.mem.findLastAny(u8, line, "\"") orelse 0;
            if (start < end){
                if (line.len < 7) { 
                    std.debug.print("SRP ERROR: Config incorrectly setup. Line ({s})\n",.{line});
                    std.process.exit(1);  
                }
                sound_path = line[start+1..end];
                if (line[6] == 'F'){
                    if (Io.Dir.accessAbsolute(ctx.io, sound_path, .{.read = true}))|dir|{
                        _ = dir;
                        ctx.sound_path = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{sound_path}); 
                    } else |err3| {
                        std.debug.print("SRP ERROR: ({}) Could not find sound library folder! ({s})\n",.{err3,sound_path});
                        std.process.exit(1);
                    }
                } else if (line[6] == 'D'){    
                    ctx.audio_device = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{sound_path}); 
                } else if (line[6] == 'P'){ 
                    ctx.audio_player = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{sound_path}); 
                } else if (line[6] == 'V'){ 
                    var volume: f32 = std.fmt.parseFloat(f32, sound_path) catch 1;
                    if ((volume < 0) or (volume > 1.0)) {
                        volume = 1;
                    }
                    ctx.audio_volume = volume; 
                } else if (line[6] == 'R'){
                    ctx.sound_dummy = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{sound_path}); 
                    SRP.use_dummy = true;
                }
            } else {
                std.debug.print("SRP ERROR: Can't read config string... Line: ({s})\n",.{line});
                std.process.exit(1);
            }
            line_column = 0;
        } else if ((std.mem.startsWith(u8, line, "USERMACRO")) or (std.mem.startsWith(u8, line, "USEREFFECT")) or (std.mem.startsWith(u8, line, "RAWSFX"))){
            while (std.mem.findAnyPos(u8, line, line_column+1, "\""))|linecap|{
                if (matches > 3) { //Fail-safe for lines containing too many quotes
                    continue :lineread;
                }
                line_column = linecap;
                matchpoint[matches] = linecap;
                matches += 1;
            }
            var name = line[matchpoint[0]+1..matchpoint[1]];
            var macro = line[matchpoint[2]+1..matchpoint[3]];
            if (line[4] == 'M') { //For now, lazy single-character comparisons to differentiate between macro types
                for (ctx.pre.items)|item|{
                    if (std.mem.eql(u8, item[0], name)){
                        std.debug.print("Warning: Found duplicate macro ({s}), ignoring...\n",.{item[0]});
                        continue :lineread;
                    } 
                }
                name = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{name}); 
                macro = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{macro}); 
                _ = try ctx.pre.append(ctx.arena.allocator(), .{name, macro}); 
            } else if (line[4] == 'F') {
                for (ctx.raw.items)|item|{
                    if (std.mem.eql(u8, item[0], name)){
                        std.debug.print("Warning: Found duplicate raw effect ({s}), ignoring...\n",.{item[0]});
                        continue :lineread;
                    } 
                }
                name = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{name}); 
                macro = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{macro}); 
                _ = try ctx.raw.append(ctx.arena.allocator(), .{name, macro}); 
            } else if (line[4] == 'E') {
                for (ctx.eff.items)|item|{
                    if (std.mem.eql(u8, item[0], name)){
                        std.debug.print("Warning: Found duplicate user effect ({s}), ignoring...\n",.{item[0]});
                        continue :lineread;
                    } 
                }
                name = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{name}); 
                macro = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}", .{macro}); 
                _ = try ctx.eff.append(ctx.arena.allocator(), .{name, macro}); 
            }

        } 
        confline += 1;
    }
    conffile.close(ctx.io); 
    
    var prompt: []u8 = &.{};
    var file_reader: Io.File.Reader = undefined;

    //Do as much processing as possible before this statement! stdin.reader will have to wait for user input to be done anyway.
    if (cmdarg_amt == 2) {
        prompt = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{cmdarg_list.items[1]});
    } else {
        file_reader = stdin.reader(ctx.io, ctx.buf[0..]);
        SRP.is_processing = true;
        const reader = &file_reader.interface;
        while (try reader.takeDelimiter('\n')) |line| {
            if (std.mem.endsWith(u8, line, "!")){
                SRP.use_XDT = true;
                const excl = std.mem.findLast(u8, line, "!") orelse 0;
                prompt = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{line[0..excl]});
                std.debug.print("USING XDOTOOL!\n",.{});
            } else {
                prompt = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{line[0..]});
            }
        }
    }
    
    const start = Io.Clock.awake.now(ctx.io);
    _ = try ctx.m2D.append(ctx.arena.allocator(), std.ArrayList([]const u8).empty);
    _ = try ctx.m2D.items[0].append(ctx.arena.allocator(), prompt);
    SRP.scope += 1;
    std.debug.print("\nSRP: Unrolling input: ({s})\n",.{ctx.m2D.items[0].items[0]});

    _ = try unrollMacro(ctx.m2D.items[0].items[0], &ctx, false);
    SRP.scope = 0;

    //Using elapsed time as prng for now
    const end_rng = Io.Clock.awake.now(ctx.io); 
    const seed_rng: u64 = @intCast(start.durationTo(end_rng).nanoseconds);
    initRNG(seed_rng); 
    
    const dest = try ctx.arena.allocator().alloc(u8, ctx.m2D.items[0].items[0].len);
    defer ctx.arena.allocator().free(dest);
    std.mem.copyForwards(u8, dest, ctx.m2D.items[0].items[0]);

    ctx.m2D.clearAndFree(ctx.arena.allocator());

    _ = try ctx.m2D.append(ctx.arena.allocator(), std.ArrayList([]const u8).empty);
    _ = try ctx.m2D.items[0].append(ctx.arena.allocator(), dest);
    _ = try parseCurly(ctx.m2D.items[0].items[0], 0, &ctx);

    const reformstr = reformatSpaces(ctx.m2D.items[0].items[0], &ctx);
    const temp = try std.fmt.allocPrint(ctx.arena.allocator(), "{s}",.{reformstr});
    var token_list = std.mem.splitSequence(u8,temp," ");
    token_list = token_list;
    if (SRP.use_XDT){
        _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = &.{"xdotool","keydown","Home"},});
    }
    Token.combo = 0;
    std.debug.print("SRP: Parsing processed token... ({s})\n",.{temp});
    _ = try parseQueue(&ctx, &token_list, .default);
    _ = try playQueue(&ctx); 

    if (SRP.use_XDT){
        _ = try std.process.run(ctx.arena.allocator(), ctx.io, .{.argv = &.{"xdotool","keyup","Home"},});
    }

    const end = Io.Clock.awake.now(ctx.io);
    const elapsed1: f64 = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("Rendered: ({})  Combined: ({})  Time: {d:.3}ms\n\n", .{SRP.rendered, SRP.combined, (elapsed1 / time.ns_per_ms)});

    SRP.is_processing = false;
}
