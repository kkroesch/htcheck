const std = @import("std");

const Result = struct {
    http_status: ?u16 = null,
    dns_error: bool = false,
    connection_error: bool = false,
    tls_error: bool = false,
    response_time_seconds: f64 = 0.0,
    content_length_bytes: u64 = 0,
    error_message: []const u8 = "",
};

const OutputMode = enum { prometheus, short };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.next(); // skip program name

    var mode: OutputMode = .prometheus;
    var url: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--short")) {
            mode = .short;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll(
                \\Usage: htcheck [OPTIONS] <url>
                \\
                \\Options:
                \\  -s, --short   Compact CLI output for quick checks
                \\  -h, --help    Show this help
                \\
                \\Default output is Prometheus metrics format.
                \\
            ) catch {};
            std.process.exit(0);
        } else {
            url = arg;
        }
    }

    const target_url = url orelse {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Usage: htcheck [OPTIONS] <url>\n") catch {};
        std.process.exit(1);
    };

    const result = checkUrl(allocator, target_url);

    switch (mode) {
        .prometheus => outputPrometheus(allocator, target_url, result),
        .short => outputShort(allocator, target_url, result),
    }
}

fn checkUrl(allocator: std.mem.Allocator, url: []const u8) Result {
    var result = Result{};
    var timer = std.time.Timer.start() catch {
        result.error_message = "timer_init_failed";
        return result;
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Use Io.Writer.Allocating to capture the response body
    var response_buf = std.Io.Writer.Allocating.init(allocator);
    defer response_buf.deinit();

    const fetch_result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_buf.writer,
    }) catch |err| {
        result.response_time_seconds = readSeconds(&timer);
        classifyError(&result, err);
        return result;
    };

    result.response_time_seconds = readSeconds(&timer);
    result.http_status = @intFromEnum(fetch_result.status);
    result.content_length_bytes = response_buf.written().len;
    return result;
}

fn classifyError(result: *Result, err: anyerror) void {
    const err_name = @errorName(err);

    // DNS-related errors
    if (std.mem.indexOf(u8, err_name, "NameServer") != null or
        std.mem.indexOf(u8, err_name, "UnknownHost") != null or
        std.mem.indexOf(u8, err_name, "AddressNotAvail") != null or
        std.mem.indexOf(u8, err_name, "TemporaryNameServer") != null)
    {
        result.dns_error = true;
        result.error_message = err_name;
        return;
    }

    // TLS-related errors
    if (std.mem.indexOf(u8, err_name, "Tls") != null or
        std.mem.indexOf(u8, err_name, "Certificate") != null)
    {
        result.tls_error = true;
        result.error_message = err_name;
        return;
    }

    // Everything else → connection error
    result.connection_error = true;
    result.error_message = err_name;
}

fn readSeconds(timer: *std.time.Timer) f64 {
    const ns = timer.read();
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
}

fn outputPrometheus(allocator: std.mem.Allocator, url: []const u8, result: Result) void {
    const stdout = std.fs.File.stdout();

    const lines = [_][]const u8{
        "# HELP htcheck_http_status_code HTTP response status code (0 if no response)\n",
        "# TYPE htcheck_http_status_code gauge\n",
    };
    for (lines) |line| {
        stdout.writeAll(line) catch return;
    }

    // Use allocPrint for formatted lines
    const status_line = std.fmt.allocPrint(allocator, "htcheck_http_status_code{{url=\"{s}\"}} {d}\n\n", .{
        url, result.http_status orelse @as(u16, 0),
    }) catch return;
    defer allocator.free(status_line);
    stdout.writeAll(status_line) catch return;

    stdout.writeAll("# HELP htcheck_dns_error DNS resolution error (1=error, 0=ok)\n") catch return;
    stdout.writeAll("# TYPE htcheck_dns_error gauge\n") catch return;
    const dns_line = std.fmt.allocPrint(allocator, "htcheck_dns_error{{url=\"{s}\"}} {d}\n\n", .{
        url, @as(u8, if (result.dns_error) 1 else 0),
    }) catch return;
    defer allocator.free(dns_line);
    stdout.writeAll(dns_line) catch return;

    stdout.writeAll("# HELP htcheck_response_time_seconds Time until HTTP response in seconds\n") catch return;
    stdout.writeAll("# TYPE htcheck_response_time_seconds gauge\n") catch return;
    const time_line = std.fmt.allocPrint(allocator, "htcheck_response_time_seconds{{url=\"{s}\"}} {d:.6}\n\n", .{
        url, result.response_time_seconds,
    }) catch return;
    defer allocator.free(time_line);
    stdout.writeAll(time_line) catch return;

    stdout.writeAll("# HELP htcheck_connection_error TCP connection error (1=error, 0=ok)\n") catch return;
    stdout.writeAll("# TYPE htcheck_connection_error gauge\n") catch return;
    const conn_line = std.fmt.allocPrint(allocator, "htcheck_connection_error{{url=\"{s}\"}} {d}\n\n", .{
        url, @as(u8, if (result.connection_error) 1 else 0),
    }) catch return;
    defer allocator.free(conn_line);
    stdout.writeAll(conn_line) catch return;

    stdout.writeAll("# HELP htcheck_tls_error TLS handshake error (1=error, 0=ok)\n") catch return;
    stdout.writeAll("# TYPE htcheck_tls_error gauge\n") catch return;
    const tls_line = std.fmt.allocPrint(allocator, "htcheck_tls_error{{url=\"{s}\"}} {d}\n\n", .{
        url, @as(u8, if (result.tls_error) 1 else 0),
    }) catch return;
    defer allocator.free(tls_line);
    stdout.writeAll(tls_line) catch return;

    stdout.writeAll("# HELP htcheck_content_length_bytes Response body size in bytes\n") catch return;
    stdout.writeAll("# TYPE htcheck_content_length_bytes gauge\n") catch return;
    const cl_line = std.fmt.allocPrint(allocator, "htcheck_content_length_bytes{{url=\"{s}\"}} {d}\n\n", .{
        url, result.content_length_bytes,
    }) catch return;
    defer allocator.free(cl_line);
    stdout.writeAll(cl_line) catch return;

    stdout.writeAll("# HELP htcheck_up Target reachable with valid HTTP response (1=up, 0=down)\n") catch return;
    stdout.writeAll("# TYPE htcheck_up gauge\n") catch return;
    const up: u8 = if (result.http_status != null and !result.dns_error and !result.connection_error and !result.tls_error) 1 else 0;
    const up_line = std.fmt.allocPrint(allocator, "htcheck_up{{url=\"{s}\"}} {d}\n", .{ url, up }) catch return;
    defer allocator.free(up_line);
    stdout.writeAll(up_line) catch return;
}

fn outputShort(allocator: std.mem.Allocator, url: []const u8, result: Result) void {
    const stdout = std.fs.File.stdout();

    // ANSI color codes
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const dim = "\x1b[2m";

    // Timestamp: get epoch seconds and format as ISO-ish
    const epoch_secs = @divFloor(std.time.milliTimestamp(), @as(i64, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_secs) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    const timestamp = std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch return;
    defer allocator.free(timestamp);

    // Status indicator and color
    const is_up = result.http_status != null and !result.dns_error and !result.connection_error and !result.tls_error;
    const status_icon = if (is_up) "✓" else "✗";
    const status_color = if (is_up) green else red;

    // Status code string
    const status_str = if (result.http_status) |s|
        std.fmt.allocPrint(allocator, "{d}", .{s}) catch return
    else
        std.fmt.allocPrint(allocator, "---", .{}) catch return;
    defer allocator.free(status_str);

    // Status code color: 2xx green, 3xx yellow, 4xx/5xx red
    const code_color = if (result.http_status) |s| blk: {
        break :blk if (s >= 200 and s < 300) green else if (s >= 300 and s < 400) yellow else red;
    } else red;

    // Response time with color (green <1s, yellow <3s, red >=3s)
    const time_color = if (result.response_time_seconds < 1.0) green else if (result.response_time_seconds < 3.0) yellow else red;

    // Format size human-readable
    const size_str = if (result.content_length_bytes >= 1048576)
        std.fmt.allocPrint(allocator, "{d:.1}M", .{@as(f64, @floatFromInt(result.content_length_bytes)) / 1048576.0}) catch return
    else if (result.content_length_bytes >= 1024)
        std.fmt.allocPrint(allocator, "{d:.1}K", .{@as(f64, @floatFromInt(result.content_length_bytes)) / 1024.0}) catch return
    else
        std.fmt.allocPrint(allocator, "{d}B", .{result.content_length_bytes}) catch return;
    defer allocator.free(size_str);

    // Main line: ✓ 2025-02-09 14:23:01  200  0.342s  12.4K  https://example.com
    // Build with separate writes to avoid runtime string concat
    stdout.writeAll(status_color) catch return;
    stdout.writeAll(status_icon) catch return;
    stdout.writeAll(reset) catch return;
    stdout.writeAll(" ") catch return;
    stdout.writeAll(dim) catch return;
    stdout.writeAll(timestamp) catch return;
    stdout.writeAll(reset) catch return;
    stdout.writeAll("  ") catch return;
    stdout.writeAll(bold) catch return;
    stdout.writeAll(code_color) catch return;
    stdout.writeAll(status_str) catch return;
    stdout.writeAll(reset) catch return;
    stdout.writeAll("  ") catch return;
    stdout.writeAll(time_color) catch return;
    const time_str = std.fmt.allocPrint(allocator, "{d:.3}s", .{result.response_time_seconds}) catch return;
    defer allocator.free(time_str);
    stdout.writeAll(time_str) catch return;
    stdout.writeAll(reset) catch return;
    stdout.writeAll("  ") catch return;
    stdout.writeAll(dim) catch return;
    stdout.writeAll(size_str) catch return;
    stdout.writeAll(reset) catch return;
    stdout.writeAll("  ") catch return;
    stdout.writeAll(bold) catch return;
    stdout.writeAll(url) catch return;
    stdout.writeAll(reset) catch return;
    stdout.writeAll("\n") catch return;

    // Error detail line (only if errors present)
    if (result.error_message.len > 0) {
        const err_line = std.fmt.allocPrint(allocator, "  {s}└ {s}{s}\n", .{
            red, result.error_message, reset,
        }) catch return;
        defer allocator.free(err_line);
        stdout.writeAll(err_line) catch return;
    }
}

// --- Tests ---

test "successful HTTP request returns status 200 and up=1" {
    const allocator = std.testing.allocator;
    const result = checkUrl(allocator, "https://httpbin.org/bytes/64");

    try std.testing.expect(result.http_status != null);
    try std.testing.expectEqual(@as(u16, 200), result.http_status.?);
    try std.testing.expect(!result.dns_error);
    try std.testing.expect(!result.connection_error);
    try std.testing.expect(!result.tls_error);
    try std.testing.expect(result.response_time_seconds > 0.0);
    try std.testing.expectEqual(@as(u64, 64), result.content_length_bytes);
}

test "HTTP 404 returns status 404 and up=1" {
    const allocator = std.testing.allocator;
    const result = checkUrl(allocator, "https://httpbin.org/status/404");

    try std.testing.expect(result.http_status != null);
    try std.testing.expectEqual(@as(u16, 404), result.http_status.?);
    try std.testing.expect(!result.dns_error);
    try std.testing.expect(!result.connection_error);
    try std.testing.expect(!result.tls_error);
}

test "DNS error for non-existent domain" {
    const allocator = std.testing.allocator;
    const result = checkUrl(allocator, "https://this-domain-does-not-exist-xyz123.example.com/");

    try std.testing.expectEqual(@as(?u16, null), result.http_status);
    try std.testing.expect(result.dns_error or result.connection_error);
}

test "response time is positive for valid request" {
    const allocator = std.testing.allocator;
    const result = checkUrl(allocator, "https://httpbin.org/bytes/64");

    try std.testing.expect(result.response_time_seconds > 0.0);
    try std.testing.expect(result.response_time_seconds < 30.0);
}

