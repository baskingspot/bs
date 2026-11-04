// Adapted from linuxwave's src/gen.zig and src/wav.zig
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

test "generate music" {
    const config = GeneratorConfig{
        .scale = &[_]u8{ 0, 1 },
        .note = 440,
        .volume = 100,
    };
    const generator = Generator.init(config);
    const allocator = std.testing.allocator;

    var data1 = try generator.generate(allocator, 'a');
    defer allocator.free(data1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 127, 145, 163, 181, 197, 212, 225, 235 }, data1[0..8]);
    try std.testing.expect(data1.len == 10000);

    var data2 = try generator.generate(allocator, 'b');
    defer allocator.free(data2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 127, 144, 161, 178, 193, 208, 221, 232 }, data2[0..8]);
    try std.testing.expect(data2.len == 10000);
}

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

test "encode WAV" {
    var buffer: [1000]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try encode(&writer, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{
        .num_channels = 1,
        .sample_rate = 44100,
        .format = .S16_LE,
    });
    try std.testing.expectEqualSlices(u8, "RIFF", buffer[0..4]);
}
