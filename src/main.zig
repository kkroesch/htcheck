const std = @import("std");

const Result = struct {
    http_status: ?u16 = null,
    dns_error: bool = false,
    connection_error: bool = false,
    tls_error: bool = false,
    response_time_seconds: f64 = 0.0,
    error_message: []const u8 = "",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const url = readUrl(allocator) catch {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("ERROR: Failed to read URL from stdin\n") catch {};
        std.process.exit(1);
    };
    defer allocator.free(url);

    if (url.len == 0) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("ERROR: Empty URL provided\n") catch {};
        std.process.exit(1);
    }

    const result = checkUrl(allocator, url);
    outputPrometheus(allocator, url, result);
}

fn readUrl(allocator: std.mem.Allocator) ![]const u8 {
    const stdin = std.fs.File.stdin();
    var buf: [8192]u8 = undefined;
    var total: usize = 0;

    while (total < buf.len) {
        const n = stdin.read(buf[total..]) catch break;
        if (n == 0) break;
        // Check for newline in just-read bytes
        if (std.mem.indexOfScalar(u8, buf[total .. total + n], '\n')) |nl| {
            total += nl;
            break;
        }
        total += n;
    }

    const trimmed = std.mem.trim(u8, buf[0..total], &std.ascii.whitespace);
    return allocator.dupe(u8, trimmed);
}

fn checkUrl(allocator: std.mem.Allocator, url: []const u8) Result {
    var result = Result{};
    var timer = std.time.Timer.start() catch {
        result.error_message = "timer_init_failed";
        return result;
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const fetch_result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
    }) catch |err| {
        result.response_time_seconds = readSeconds(&timer);
        classifyError(&result, err);
        return result;
    };

    result.response_time_seconds = readSeconds(&timer);
    result.http_status = @intFromEnum(fetch_result.status);
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

    stdout.writeAll("# HELP htcheck_up Target reachable with valid HTTP response (1=up, 0=down)\n") catch return;
    stdout.writeAll("# TYPE htcheck_up gauge\n") catch return;
    const up: u8 = if (result.http_status != null and !result.dns_error and !result.connection_error and !result.tls_error) 1 else 0;
    const up_line = std.fmt.allocPrint(allocator, "htcheck_up{{url=\"{s}\"}} {d}\n", .{ url, up }) catch return;
    defer allocator.free(up_line);
    stdout.writeAll(up_line) catch return;
}
