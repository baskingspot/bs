// Adapted from linuxwave's src/main.zig, src/gen.zig, src/wav.zig and src/file.zig
// (https://github.com/orhun/linuxwave), MIT License, Copyright (c) 2023-2024 Orhun Parmaksız.
const std = @import("std");

/// Generator configuration.
pub const GeneratorConfig = struct {
    /// Semitones from the base note in a major musical scale.
    scale: []const u8,
    /// Frequency of the note.
    ///
    /// <https://pages.mtu.edu/~suits/notefreqs.html>
    note: f32,
    /// Volume control.
    volume: u8,
};

/// Generator implementation.
pub const Generator = struct {
    /// Number of calculated samples per sine curve (affects perceived frequency).
    pub const sample_count: usize = 10000;

    /// Configuration.
    config: GeneratorConfig,

    /// Creates a new instance.
    pub fn init(config: GeneratorConfig) Generator {
        return Generator{ .config = config };
    }

    /// Generates a sound from the given sample.
    ///
    /// Returns an array that contains the amplitudes of the sound wave at a given point in time.
    pub fn generate(self: Generator, allocator: std.mem.Allocator, sample: u8) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < sample_count) : (i += 1) {
            // Calculate the frequency according to the equal temperament.
            // Hertz = 440 * 2^(semitone distance / 12)
            // (<http://en.wikipedia.org/wiki/Equal_temperament>)
            const tone_distance: f32 = @floatFromInt(self.config.scale[sample % self.config.scale.len]);
            const increment: f32 = @floatFromInt(i);
            var amp = @sin(self.config.note * std.math.pi * std.math.pow(f32, 2, tone_distance / 12) * (increment * 0.0001));
            // Scale the amplitude between 0 and 256.
            amp = (amp * std.math.maxInt(u8) / 2) + (std.math.maxInt(u8) / 2);
            // Apply the volume control.
            const volume: f32 = @floatFromInt(self.config.volume);
            amp = amp * volume / 100;
            try buffer.append(allocator, @trunc(amp));
        }
        return buffer.toOwnedSlice(allocator);
    }
};

/// File header.
const RIFF = [4]u8{ 'R', 'I', 'F', 'F' };
/// RIFF type.
const WAVE = [4]u8{ 'W', 'A', 'V', 'E' };
/// Chunk name for the information about how the waveform data is stored.
const FMT_ = [4]u8{ 'f', 'm', 't', ' ' };
/// Chunk name for the digital audio sample data.
const DATA = [4]u8{ 'd', 'a', 't', 'a' };
// Total length of the header.
const header_len: u32 = 44;
const data_chunk_pos: u32 = 36;

/// Format of the waveform data.
pub const Format = enum {
    /// Unsigned 8-bit.
    U8,
    /// Signed 16-bit little-endian.
    S16_LE,
    /// Signed 24-bit little-endian.
    S24_LE,
    /// Signed 32-bit little-endian.
    S32_LE,

    /// Returns the bytes per sample.
    pub fn getNumBytes(self: Format) u16 {
        return switch (self) {
            .U8 => 1,
            .S16_LE => 2,
            .S24_LE => 3,
            .S32_LE => 4,
        };
    }
};

/// Encoder configuration.
pub const EncoderConfig = struct {
    /// Number of channels.
    num_channels: usize,
    /// Sample rate.
    sample_rate: usize,
    /// Sample format.
    format: Format,

    /// Returns the data length needed for given duration.
    pub fn getDataLength(self: EncoderConfig, duration: usize) usize {
        return duration * (self.sample_rate * self.num_channels * self.format.getNumBytes()) - header_len;
    }
};

pub fn encode(writer: *std.Io.Writer, data: []const u8, config: EncoderConfig) !void {
    try writeChunks(writer, config, data);
}

/// Writes the headers with placeholder values for length.
///
/// This can be used while streaming the WAV file i.e. when the total length is unknown.
pub fn writeHeader(writer: *std.Io.Writer, config: EncoderConfig) !void {
    try writeChunks(writer, config, null);
}

/// Writes the WAV chunks with optional data.
///
/// <WAVE-form> → RIFF('WAVE'
///                    <fmt-ck>            // Format
///                    [<fact-ck>]         // Fact chunk
///                    [<cue-ck>]          // Cue points
///                    [<playlist-ck>]     // Playlist
///                    [<assoc-data-list>] // Associated data list
///                    <wave-data> )       // Wave data
fn writeChunks(writer: *std.Io.Writer, config: EncoderConfig, opt_data: ?[]const u8) !void {
    // Chunk configuration.
    const bytes_per_sample = config.format.getNumBytes();
    const num_channels: u16 = @intCast(config.num_channels);
    const sample_rate: u32 = @intCast(config.sample_rate);
    const byte_rate = sample_rate * @as(u32, num_channels) * bytes_per_sample;
    const block_align: u16 = num_channels * bytes_per_sample;
    const bits_per_sample: u16 = bytes_per_sample * 8;
    const data_len: u32 = if (opt_data) |data| @intCast(data.len) else 0;
    const endian = std.builtin.Endian.little;
    // Write the file header.
    try writer.writeAll(&RIFF);
    if (opt_data != null) {
        try writer.writeInt(u32, data_chunk_pos + 8 + data_len - 8, endian);
    } else {
        try writer.writeInt(u32, 0, endian);
    }
    try writer.writeAll(&WAVE);
    // Write the format chunk.
    try writer.writeAll(&FMT_);
    // Encode with pulse-code modulation (LPCM).
    try writer.writeInt(u32, 16, endian);
    // Uncompressed.
    try writer.writeInt(u16, 1, endian);
    try writer.writeInt(u16, num_channels, endian);
    try writer.writeInt(u32, sample_rate, endian);
    try writer.writeInt(u32, byte_rate, endian);
    try writer.writeInt(u16, block_align, endian);
    try writer.writeInt(u16, bits_per_sample, endian);
    // Write the data chunk.
    try writer.writeAll(&DATA);
    if (opt_data) |data| {
        try writer.writeInt(u32, data_len, endian);
        try writer.writeAll(data);
    } else {
        try writer.writeInt(u32, 0, endian);
    }
}

/// Default settings, as linuxwave's defaults.zig.
const defaults = struct {
    const input = "/dev/urandom";
    const output = "output.wav";
    const scale = "0,2,3,5,7,8,10,12";
    const sample_rate: usize = 24000;
    const note: f32 = 440;
    const channels: usize = 1;
    const format = Format.S16_LE;
    const volume: u8 = 50;
    const duration: usize = 20;
};

/// Reads the given file and returns a byte array with the length of `len`.
fn readBytes(io: std.Io, allocator: std.mem.Allocator, path: []const u8, len: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const reader = &file_reader.interface;
    return reader.readAlloc(allocator, len);
}

/// Runs `linuxwave`: reads entropy from `input_file`, turns it into music
/// and writes it to `out` as WAV.
fn run(io: std.Io, allocator: std.mem.Allocator, output: *std.Io.Writer, input_file: []const u8, out: []const u8) !void {
    const encoder_config: EncoderConfig = .{
        .num_channels = defaults.channels,
        .sample_rate = defaults.sample_rate,
        .format = defaults.format,
    };

    // Create generator configuration.
    const scale = s: {
        var scale: std.ArrayList(u8) = .empty;
        var splits = std.mem.splitAny(u8, defaults.scale, ",");
        while (splits.next()) |chunk| {
            try scale.append(allocator, try std.fmt.parseInt(u8, chunk, 0));
        }
        break :s try scale.toOwnedSlice(allocator);
    };
    defer allocator.free(scale);
    const generator_config = GeneratorConfig{
        .scale = scale,
        .note = defaults.note,
        .volume = defaults.volume,
    };
    const data_len = encoder_config.getDataLength(defaults.duration) / (Generator.sample_count - 2);

    // Read data from a file or stdin.
    const buffer = b: {
        if (std.mem.eql(u8, input_file, "-")) {
            try output.print("Reading {d} bytes from stdin\n", .{data_len});
            try output.flush();
            var read_buffer: [1024]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().reader(io, &read_buffer);
            const stdin = &stdin_reader.interface;
            break :b try stdin.readAlloc(allocator, data_len);
        }

        try output.print("Reading {d} bytes from {s}\n", .{ data_len, input_file });
        try output.flush();
        break :b try readBytes(io, allocator, input_file, data_len);
    };
    defer allocator.free(buffer);

    // Generate music.
    const generator: Generator = .init(generator_config);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    for (buffer) |v| {
        const gen_data = try generator.generate(allocator, v);
        defer allocator.free(gen_data);
        try data.appendSlice(allocator, gen_data);
    }

    // Encode WAV.
    var write_buffer: [1024]u8 = undefined;
    var fhandle: ?std.Io.File = null;
    defer if (fhandle) |f| {
        f.close(io);
    };
    var file_writer = w: {
        if (std.mem.eql(u8, out, "-")) {
            try output.print("Writing to stdout\n", .{});
            try output.flush();
            break :w std.Io.File.stdout().writer(io, &write_buffer);
        }

        try output.print("Saving to {s}\n", .{out});
        try output.flush();
        fhandle = try std.Io.Dir.cwd().createFile(io, out, .{});
        break :w fhandle.?.writer(io, &write_buffer);
    };
    try encode(&file_writer.interface, data.items, encoder_config);
    try file_writer.interface.flush();
}

/// Entry-point: `wave [input] [output]`.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var it = init.minimal.args.iterate();
    _ = it.skip();
    const input = it.next() orelse defaults.input;
    const out = it.next() orelse defaults.output;
    run(io, allocator, stderr, input, out) catch |err| {
        try stderr.print("Error occurred: {t}\n", .{err});
        try stderr.flush();
    };
}
