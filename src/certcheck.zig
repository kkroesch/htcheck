const std = @import("std");

const Result = struct {
    subject: []const u8 = "",
    issuer: []const u8 = "",
    not_after: []const u8 = "",
    days_remaining: ?i64 = null,
    serial: []const u8 = "",
    error_message: []const u8 = "",
    allocator: ?std.mem.Allocator = null,

    fn deinit(self: *Result) void {
        if (self.allocator) |alloc| {
            if (self.subject.len > 0) alloc.free(self.subject);
            if (self.issuer.len > 0) alloc.free(self.issuer);
            if (self.not_after.len > 0) alloc.free(self.not_after);
            if (self.serial.len > 0) alloc.free(self.serial);
        }
    }
};

const OutputMode = enum { prometheus, short };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.next(); // skip program name

    var mode: OutputMode = .prometheus;
    var host_arg: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--short")) {
            mode = .short;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll(
                \\Usage: certcheck [OPTIONS] <host[:port]>
                \\
                \\Options:
                \\  -s, --short   Compact CLI output for quick checks
                \\  -h, --help    Show this help
                \\
                \\Default output is Prometheus metrics format.
                \\Default port is 443 if not specified.
                \\
                \\Examples:
                \\  certcheck example.com
                \\  certcheck example.com:8443
                \\  certcheck -s example.com
                \\
            ) catch {};
            std.process.exit(0);
        } else {
            host_arg = arg;
        }
    }

    const target = host_arg orelse {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Usage: certcheck [OPTIONS] <host[:port]>\n") catch {};
        std.process.exit(1);
    };

    const host = extractHost(target);
    const port = extractPort(target);
    var result = checkCert(allocator, host, port);
    defer result.deinit();

    switch (mode) {
        .prometheus => outputPrometheus(allocator, host, port, result),
        .short => outputShort(allocator, host, port, result),
    }
}

/// Strip scheme and path, extract host
fn extractHost(target: []const u8) []const u8 {
    var s = target;
    // Strip scheme (https:// or http://)
    if (std.mem.indexOf(u8, s, "://")) |idx| {
        s = s[idx + 3 ..];
    }
    // Strip path
    if (std.mem.indexOfScalar(u8, s, '/')) |idx| {
        s = s[0..idx];
    }
    // Strip port
    if (std.mem.indexOfScalar(u8, s, ':')) |idx| {
        return s[0..idx];
    }
    return s;
}

/// Extract port part (default "443"), tolerates URL input
fn extractPort(target: []const u8) []const u8 {
    var s = target;
    // Strip scheme
    if (std.mem.indexOf(u8, s, "://")) |idx| {
        s = s[idx + 3 ..];
    }
    // Strip path
    if (std.mem.indexOfScalar(u8, s, '/')) |idx| {
        s = s[0..idx];
    }
    // Find port
    if (std.mem.indexOfScalar(u8, s, ':')) |idx| {
        return s[idx + 1 ..];
    }
    return "443";
}

/// Check TLS certificate via openssl s_client subprocess
fn checkCert(allocator: std.mem.Allocator, host: []const u8, port: []const u8) Result {
    var result = Result{ .allocator = allocator };

    const cmd = std.fmt.allocPrint(allocator,
        \\echo | openssl s_client -connect {s}:{s} -servername {s} 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -serial 2>/dev/null
    , .{ host, port, host }) catch return result;
    defer allocator.free(cmd);

    const argv = [_][]const u8{ "sh", "-c", cmd };

    const proc = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
    }) catch {
        result.error_message = "openssl_not_found";
        return result;
    };
    defer allocator.free(proc.stdout);
    defer allocator.free(proc.stderr);

    const exited_ok = switch (proc.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        result.error_message = "connection_failed";
        return result;
    }

    if (proc.stdout.len == 0) {
        result.error_message = "no_certificate";
        return result;
    }

    // Parse output lines:
    //   subject=CN=example.com
    //   issuer=C=US, O=Let's Encrypt, CN=R3
    //   notAfter=Mar 15 12:00:00 2025 GMT
    //   serial=0123456789ABCDEF
    var lines = std.mem.splitScalar(u8, proc.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "subject=")) {
            result.subject = allocator.dupe(u8, line["subject=".len..]) catch "";
        } else if (std.mem.startsWith(u8, line, "issuer=")) {
            result.issuer = allocator.dupe(u8, line["issuer=".len..]) catch "";
        } else if (std.mem.startsWith(u8, line, "notAfter=")) {
            const date_str = line["notAfter=".len..];
            result.not_after = allocator.dupe(u8, date_str) catch "";
            result.days_remaining = parseDaysRemaining(date_str);
        } else if (std.mem.startsWith(u8, line, "serial=")) {
            result.serial = allocator.dupe(u8, line["serial=".len..]) catch "";
        }
    }

    return result;
}

// --- Date parsing ---

/// Parse openssl date format "Mar 15 12:00:00 2025 GMT" into days remaining from now
fn parseDaysRemaining(date_str: []const u8) ?i64 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    if (date_str.len < 20) return null;

    const month_str = date_str[0..3];
    var month_num: u8 = 0;
    for (months, 1..) |m, i| {
        if (std.mem.eql(u8, month_str, m)) {
            month_num = @intCast(i);
            break;
        }
    }
    if (month_num == 0) return null;

    // Day: positions 4..6 (may have leading space)
    const day_str = std.mem.trim(u8, date_str[3..6], " ");
    const day = std.fmt.parseInt(u8, day_str, 10) catch return null;

    // Year: last token before "GMT"
    const year_start = std.mem.lastIndexOfScalar(u8, date_str, ' ') orelse return null;
    const before_gmt = std.mem.trimRight(u8, date_str[0..year_start], " ");
    const year_space = std.mem.lastIndexOfScalar(u8, before_gmt, ' ') orelse return null;
    const year_str = before_gmt[year_space + 1 ..];
    const year = std.fmt.parseInt(u16, year_str, 10) catch return null;

    const cert_epoch_day = epochDayFromDate(year, month_num, day) orelse return null;
    const now_secs = @divFloor(std.time.milliTimestamp(), @as(i64, 1000));
    const now_epoch_day: i64 = @divFloor(now_secs, 86400);

    return cert_epoch_day - now_epoch_day;
}

/// Convert year/month/day to epoch days (days since 1970-01-01)
fn epochDayFromDate(year: u16, month: u8, day: u8) ?i64 {
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) @as(i64, 1) else @as(i64, 0));
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const month_adj: i64 = @as(i64, month) - (if (month > 2) @as(i64, 3) else @as(i64, -9));
    const doy: i64 = @divFloor(153 * month_adj + 2, 5) + @as(i64, day) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// --- Output ---

fn outputPrometheus(allocator: std.mem.Allocator, host: []const u8, port: []const u8, result: Result) void {
    const stdout = std.fs.File.stdout();

    if (result.error_message.len > 0) {
        stdout.writeAll("# HELP certcheck_up Certificate check succeeded (1=ok, 0=failed)\n") catch return;
        stdout.writeAll("# TYPE certcheck_up gauge\n") catch return;
        const line = std.fmt.allocPrint(allocator, "certcheck_up{{host=\"{s}\",port=\"{s}\"}} 0\n", .{ host, port }) catch return;
        defer allocator.free(line);
        stdout.writeAll(line) catch return;
        return;
    }

    if (result.days_remaining) |days| {
        stdout.writeAll("# HELP certcheck_days_remaining Days until TLS certificate expires\n") catch return;
        stdout.writeAll("# TYPE certcheck_days_remaining gauge\n") catch return;
        const days_line = std.fmt.allocPrint(allocator, "certcheck_days_remaining{{host=\"{s}\",port=\"{s}\"}} {d}\n\n", .{ host, port, days }) catch return;
        defer allocator.free(days_line);
        stdout.writeAll(days_line) catch return;

        stdout.writeAll("# HELP certcheck_expired Certificate expired (1=expired, 0=valid)\n") catch return;
        stdout.writeAll("# TYPE certcheck_expired gauge\n") catch return;
        const expired: u8 = if (days <= 0) 1 else 0;
        const exp_line = std.fmt.allocPrint(allocator, "certcheck_expired{{host=\"{s}\",port=\"{s}\"}} {d}\n\n", .{ host, port, expired }) catch return;
        defer allocator.free(exp_line);
        stdout.writeAll(exp_line) catch return;
    }

    stdout.writeAll("# HELP certcheck_up Certificate check succeeded (1=ok, 0=failed)\n") catch return;
    stdout.writeAll("# TYPE certcheck_up gauge\n") catch return;
    const up_line = std.fmt.allocPrint(allocator, "certcheck_up{{host=\"{s}\",port=\"{s}\"}} 1\n", .{ host, port }) catch return;
    defer allocator.free(up_line);
    stdout.writeAll(up_line) catch return;
}

fn outputShort(allocator: std.mem.Allocator, host: []const u8, port: []const u8, result: Result) void {
    const stdout = std.fs.File.stdout();

    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const dim = "\x1b[2m";

    // Timestamp
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

    // Error case
    if (result.error_message.len > 0) {
        stdout.writeAll(red) catch return;
        stdout.writeAll("✗") catch return;
        stdout.writeAll(reset) catch return;
        stdout.writeAll(" ") catch return;
        stdout.writeAll(dim) catch return;
        stdout.writeAll(timestamp) catch return;
        stdout.writeAll(reset) catch return;
        stdout.writeAll("  🔓 ") catch return;
        stdout.writeAll(bold) catch return;
        stdout.writeAll(host) catch return;
        if (!std.mem.eql(u8, port, "443")) {
            stdout.writeAll(":") catch return;
            stdout.writeAll(port) catch return;
        }
        stdout.writeAll(reset) catch return;
        stdout.writeAll("  ") catch return;
        stdout.writeAll(red) catch return;
        stdout.writeAll(result.error_message) catch return;
        stdout.writeAll(reset) catch return;
        stdout.writeAll("\n") catch return;
        return;
    }

    // Success case
    if (result.days_remaining) |days| {
        const cert_color = if (days > 30) green else if (days > 7) yellow else red;
        const lock = if (days > 0) "🔒" else "🔓";
        const icon_color = if (days > 7) green else red;

        // Icon
        stdout.writeAll(icon_color) catch return;
        stdout.writeAll(if (days > 0) "✓" else "✗") catch return;
        stdout.writeAll(reset) catch return;
        stdout.writeAll(" ") catch return;

        // Timestamp
        stdout.writeAll(dim) catch return;
        stdout.writeAll(timestamp) catch return;
        stdout.writeAll(reset) catch return;
        stdout.writeAll("  ") catch return;

        // Lock + days
        stdout.writeAll(lock) catch return;
        stdout.writeAll(" ") catch return;
        stdout.writeAll(bold) catch return;
        stdout.writeAll(cert_color) catch return;
        const days_str = std.fmt.allocPrint(allocator, "{d}d", .{days}) catch return;
        defer allocator.free(days_str);
        stdout.writeAll(days_str) catch return;
        stdout.writeAll(reset) catch return;
        stdout.writeAll("  ") catch return;

        // Host
        stdout.writeAll(bold) catch return;
        stdout.writeAll(host) catch return;
        if (!std.mem.eql(u8, port, "443")) {
            stdout.writeAll(":") catch return;
            stdout.writeAll(port) catch return;
        }
        stdout.writeAll(reset) catch return;

        // Issuer
        if (result.issuer.len > 0) {
            stdout.writeAll("  ") catch return;
            stdout.writeAll(dim) catch return;
            stdout.writeAll(result.issuer) catch return;
            stdout.writeAll(reset) catch return;
        }

        stdout.writeAll("\n") catch return;
    }
}

// --- Tests ---

test "extractHost basic" {
    try std.testing.expectEqualStrings("example.com", extractHost("example.com"));
    try std.testing.expectEqualStrings("example.com", extractHost("example.com:8443"));
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com"));
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com:8443"));
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path"));
}

test "extractPort basic" {
    try std.testing.expectEqualStrings("443", extractPort("example.com"));
    try std.testing.expectEqualStrings("8443", extractPort("example.com:8443"));
    try std.testing.expectEqualStrings("443", extractPort("https://example.com"));
    try std.testing.expectEqualStrings("8443", extractPort("https://example.com:8443"));
}

test "parseDaysRemaining known date" {
    // A date far in the future should give positive days
    const days = parseDaysRemaining("Jan  1 00:00:00 2030 GMT");
    try std.testing.expect(days != null);
    try std.testing.expect(days.? > 0);
}

test "parseDaysRemaining past date" {
    const days = parseDaysRemaining("Jan  1 00:00:00 2020 GMT");
    try std.testing.expect(days != null);
    try std.testing.expect(days.? < 0);
}

test "epochDayFromDate known epoch" {
    // 1970-01-01 should be day 0
    const day0 = epochDayFromDate(1970, 1, 1);
    try std.testing.expect(day0 != null);
    try std.testing.expectEqual(@as(i64, 0), day0.?);
}
