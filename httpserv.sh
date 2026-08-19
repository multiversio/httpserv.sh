#!/usr/bin/env -S java --source 25

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.channels.WritableByteChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.stream.Stream;

public class Httpserv {

    static boolean silent = false;
    static boolean etag = false;
    static long latencyNanos = 0;
    static long bandwidthBytesPerSec = 0;
    static Path root;
    static final List<Cred> authCreds = new ArrayList<>();

    sealed interface Cred permits BasicCred, BearerCred, HeaderCred {
        boolean matches(Headers h);
    }
    record BasicCred(String encoded) implements Cred {
        public boolean matches(Headers h) {
            String v = h.getFirst("Authorization");
            return v != null && v.equals("Basic " + encoded);
        }
    }
    record BearerCred(String token) implements Cred {
        public boolean matches(Headers h) {
            String v = h.getFirst("Authorization");
            return v != null && v.equals("Bearer " + token);
        }
    }
    record HeaderCred(Map<String, String> required) implements Cred {
        public boolean matches(Headers h) {
            for (var e : required.entrySet()) {
                String got = h.getFirst(e.getKey());
                if (got == null || !got.equals(e.getValue())) return false;
            }
            return true;
        }
    }

    public static void main(String[] args) throws Exception {
        int port = 8080;
        Path dir = Path.of(".");
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "-p", "--port" -> port = Integer.parseInt(args[++i]);
                case "-d", "--dir" -> dir = Path.of(args[++i]);
                case "-s", "--silent" -> silent = true;
                case "-e", "--etag" -> etag = true;
                case "--latency" -> latencyNanos = parseDuration(args[++i]);
                case "--bandwidth" -> bandwidthBytesPerSec = parseRate(args[++i]);
                case "-a", "--auth" -> authCreds.add(parseAuth(args[++i]));
                case "-h", "--help" -> { printHelp(); return; }
                default -> {
                    if (args[i].startsWith("-")) {
                        System.err.println("unknown option: " + args[i]);
                        printHelp();
                        System.exit(1);
                    }
                    dir = Path.of(args[i]);
                }
            }
        }
        root = dir.toAbsolutePath().normalize();
        if (!Files.isDirectory(root)) {
            System.err.println("Not a directory: " + root);
            System.exit(1);
        }

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/", Httpserv::handle);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.start();
        String flags = (etag ? " [etag]" : "")
                + (latencyNanos > 0 ? " [latency=%dms]".formatted(latencyNanos / 1_000_000) : "")
                + (bandwidthBytesPerSec > 0 ? " [bw=%dKB/s]".formatted(bandwidthBytesPerSec / 1024) : "")
                + (authCreds.isEmpty() ? "" : " [auth:%d]".formatted(authCreds.size()))
                + (silent ? " [silent]" : "");
        IO.println("Serving %s at http://localhost:%d%s".formatted(root, port, flags));
    }

    static void printHelp() {
        IO.println("""
                Usage: httpserv.sh [options] [directory]

                  -d, --dir DIR     directory to serve (default: .)
                  -p, --port PORT   listen port (default: 8080)
                  -s, --silent      suppress access logging
                  -e, --etag        send ETag header (value = lastModified millis)
                      --latency DUR fixed delay before each file response
                                    (e.g. 150ms, 2s, 1500us; bare number = ms)
                      --bandwidth RATE  throttle response body throughput
                                    (e.g. 10MB/s, 500KB/s; /s optional, 1024-based)
                  -a, --auth SPEC   require authentication (repeatable; any match passes)
                                    basic:USER:PASS
                                    bearer:TOKEN
                                    api-key:HEADER:VALUE
                                    header:H1=V1,H2=V2,...   (all headers required)
                  -h, --help        show this help
                """);
    }

    static Cred parseAuth(String spec) {
        int colon = spec.indexOf(':');
        if (colon < 0) throw new IllegalArgumentException("bad --auth spec: " + spec);
        String scheme = spec.substring(0, colon);
        String rest = spec.substring(colon + 1);
        return switch (scheme) {
            case "basic" -> {
                int c = rest.indexOf(':');
                if (c < 0) throw new IllegalArgumentException("bad basic auth: " + spec);
                String creds = rest.substring(0, c) + ":" + rest.substring(c + 1);
                yield new BasicCred(Base64.getEncoder().encodeToString(creds.getBytes(StandardCharsets.UTF_8)));
            }
            case "bearer" -> new BearerCred(rest);
            case "api-key" -> {
                int c = rest.indexOf(':');
                if (c < 0) throw new IllegalArgumentException("bad api-key auth: " + spec);
                Map<String, String> m = new LinkedHashMap<>();
                m.put(rest.substring(0, c), rest.substring(c + 1));
                yield new HeaderCred(m);
            }
            case "header" -> {
                Map<String, String> m = new LinkedHashMap<>();
                for (String pair : rest.split(",")) {
                    int eq = pair.indexOf('=');
                    if (eq < 0) throw new IllegalArgumentException("bad header pair: " + pair);
                    m.put(pair.substring(0, eq).trim(), pair.substring(eq + 1).trim());
                }
                if (m.isEmpty()) throw new IllegalArgumentException("header auth needs at least one pair");
                yield new HeaderCred(m);
            }
            default -> throw new IllegalArgumentException("unknown auth scheme: " + scheme);
        };
    }

    static long parseDuration(String spec) {
        String s = spec.trim();
        long unitNanos;
        String number;
        if (s.endsWith("us")) {
            unitNanos = 1_000L;
            number = s.substring(0, s.length() - 2);
        } else if (s.endsWith("ms")) {
            unitNanos = 1_000_000L;
            number = s.substring(0, s.length() - 2);
        } else if (s.endsWith("s")) {
            unitNanos = 1_000_000_000L;
            number = s.substring(0, s.length() - 1);
        } else {
            unitNanos = 1_000_000L;
            number = s;
        }
        try {
            double value = Double.parseDouble(number.trim());
            if (value < 0) throw new IllegalArgumentException("negative duration: " + spec);
            return (long) (value * unitNanos);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("bad duration: " + spec);
        }
    }

    static long parseRate(String spec) {
        String s = spec.trim();
        if (s.toLowerCase().endsWith("/s")) {
            s = s.substring(0, s.length() - 2).trim();
        }
        long unitBytes;
        String number;
        String upper = s.toUpperCase();
        if (upper.endsWith("KB")) {
            unitBytes = 1024L;
            number = s.substring(0, s.length() - 2);
        } else if (upper.endsWith("MB")) {
            unitBytes = 1024L * 1024L;
            number = s.substring(0, s.length() - 2);
        } else if (upper.endsWith("GB")) {
            unitBytes = 1024L * 1024L * 1024L;
            number = s.substring(0, s.length() - 2);
        } else if (upper.endsWith("B")) {
            unitBytes = 1L;
            number = s.substring(0, s.length() - 1);
        } else {
            unitBytes = 1L;
            number = s;
        }
        try {
            double value = Double.parseDouble(number.trim());
            if (value <= 0) throw new IllegalArgumentException("rate must be positive: " + spec);
            return (long) (value * unitBytes);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("bad rate: " + spec);
        }
    }

    static boolean checkAuth(HttpExchange ex) throws IOException {
        if (authCreds.isEmpty()) return true;
        Headers h = ex.getRequestHeaders();
        for (Cred c : authCreds) if (c.matches(h)) return true;
        Headers resp = ex.getResponseHeaders();
        boolean hasBasic = authCreds.stream().anyMatch(c -> c instanceof BasicCred);
        boolean hasBearer = authCreds.stream().anyMatch(c -> c instanceof BearerCred);
        if (hasBasic) resp.add("WWW-Authenticate", "Basic realm=\"httpserv\"");
        if (hasBearer) resp.add("WWW-Authenticate", "Bearer realm=\"httpserv\"");
        ex.sendResponseHeaders(401, -1);
        return false;
    }

    static void handle(HttpExchange ex) {
        try (ex) {
            log(ex);
            if (!checkAuth(ex)) return;
            switch (ex.getRequestMethod()) {
                case "GET"     -> serve(ex, false);
                case "HEAD"    -> serve(ex, true);
                case "OPTIONS" -> options(ex);
                case "TRACE"   -> trace(ex);
                default -> {
                    ex.getResponseHeaders().set("Allow", "GET, HEAD, OPTIONS, TRACE");
                    ex.sendResponseHeaders(405, -1);
                }
            }
        } catch (Throwable t) {
            if (!silent) t.printStackTrace();
        }
    }

    static void options(HttpExchange ex) throws IOException {
        ex.getResponseHeaders().set("Allow", "GET, HEAD, OPTIONS, TRACE");
        ex.sendResponseHeaders(204, -1);
    }

    static void trace(HttpExchange ex) throws IOException {
        StringBuilder sb = new StringBuilder();
        sb.append("TRACE %s %s\r\n".formatted(ex.getRequestURI(), ex.getProtocol()));
        for (var e : ex.getRequestHeaders().entrySet()) {
            for (var v : e.getValue()) {
                sb.append("%s: %s\r\n".formatted(e.getKey(), v));
            }
        }
        sb.append("\r\n");
        byte[] body = sb.toString().getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "message/http");
        ex.sendResponseHeaders(200, body.length);
        try (OutputStream os = body(ex)) { os.write(body); }
    }

    static void serve(HttpExchange ex, boolean head) throws IOException {
        String rawPath = ex.getRequestURI().getPath();
        String decoded = URLDecoder.decode(rawPath, StandardCharsets.UTF_8);
        String rel = decoded.startsWith("/") ? decoded.substring(1) : decoded;
        Path target = root.resolve(rel).normalize();
        if (!target.startsWith(root)) { ex.sendResponseHeaders(403, -1); return; }
        if (!Files.exists(target))    { ex.sendResponseHeaders(404, -1); return; }

        if (Files.isDirectory(target)) {
            if (!rawPath.endsWith("/")) {
                ex.getResponseHeaders().set("Location", rawPath + "/");
                ex.sendResponseHeaders(301, -1);
                return;
            }
            Path index = target.resolve("index.html");
            if (Files.isRegularFile(index)) serveFile(ex, index, head);
            else listDirectory(ex, target, rawPath, head);
            return;
        }
        serveFile(ex, target, head);
    }

    static void sleepLatency() {
        if (latencyNanos <= 0) return;
        long millis = latencyNanos / 1_000_000L;
        int nanos = (int) (latencyNanos % 1_000_000L);
        try {
            Thread.sleep(millis, nanos);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    static void serveFile(HttpExchange ex, Path file, boolean head) throws IOException {
        sleepLatency();
        long size = Files.size(file);
        long lastModified = Files.getLastModifiedTime(file).toMillis();
        String contentType = probeContentType(file);
        String lastModifiedHeader = httpDate(lastModified);
        String entityTag = etag ? "\"%d\"".formatted(lastModified) : null;

        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", contentType);
        h.set("Accept-Ranges", "bytes");
        h.set("Last-Modified", lastModifiedHeader);
        if (entityTag != null) {
            h.set("ETag", entityTag);
        }

        RangeOutcome outcome = evaluateRange(ex, size, entityTag, lastModifiedHeader);
        switch (outcome.decision()) {
            case WHOLE -> sendWholeRepresentation(ex, file, size, head);
            case PARTIAL -> sendPartialContent(ex, file, size, contentType, outcome.ranges(), head);
            case NOT_SATISFIABLE -> sendRangeNotSatisfiable(ex, size);
        }
    }

    static String probeContentType(Path file) throws IOException {
        String probed = Files.probeContentType(file);
        return probed == null ? "application/octet-stream" : probed;
    }

    /**
     * RFC 7231 section 7.1.1.1 requires the fixed-length IMF-fixdate form, which
     * pads the day-of-month to two digits. RFC_1123_DATE_TIME does not pad it,
     * and an If-Range date validator is compared by exact match.
     */
    static final DateTimeFormatter IMF_FIXDATE =
            DateTimeFormatter.ofPattern("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US);

    static String httpDate(long epochMillis) {
        Instant instant = Instant.ofEpochMilli(epochMillis);
        return IMF_FIXDATE.format(ZonedDateTime.ofInstant(instant, ZoneOffset.UTC));
    }

    /** A closed byte interval of a representation, both ends inclusive. */
    record ByteRange(long start, long end) {
        long length() {
            return end - start + 1;
        }
    }

    enum RangeDecision { WHOLE, PARTIAL, NOT_SATISFIABLE }

    /** What to answer a request with; `ranges` is populated only for PARTIAL. */
    record RangeOutcome(RangeDecision decision, List<ByteRange> ranges) {
        static final RangeOutcome WHOLE = new RangeOutcome(RangeDecision.WHOLE, List.of());
        static final RangeOutcome NOT_SATISFIABLE = new RangeOutcome(RangeDecision.NOT_SATISFIABLE, List.of());

        static RangeOutcome partial(List<ByteRange> ranges) {
            return new RangeOutcome(RangeDecision.PARTIAL, List.copyOf(ranges));
        }
    }

    /**
     * RFC 7233 section 3.1: Range applies only to units the server understands
     * and yields to a failed If-Range precondition. Anything that leaves the
     * header field inapplicable falls back to a 200 response.
     *
     * <p>Section 3.1 also says to ignore Range on methods other than GET, which
     * would make HEAD answer 200. HEAD is evaluated here exactly like GET
     * instead: RFC 7231 section 4.3.2 asks a HEAD response to mirror the header
     * fields of the matching GET, and Apache, nginx, and S3 all answer 206. This
     * server exists to stand in for those, and a client probing range support
     * with HEAD should see what they would send.
     */
    static RangeOutcome evaluateRange(HttpExchange ex, long size,
                                      String entityTag, String lastModifiedHeader) {
        Headers request = ex.getRequestHeaders();
        String rangeHeader = request.getFirst("Range");
        if (rangeHeader == null) {
            return RangeOutcome.WHOLE;
        }
        String ifRange = request.getFirst("If-Range");
        if (ifRange != null && !validatorMatches(ifRange, entityTag, lastModifiedHeader)) {
            return RangeOutcome.WHOLE;
        }
        String byteRangeSet = byteRangeSetOf(rangeHeader);
        if (byteRangeSet == null) {
            return RangeOutcome.WHOLE;
        }
        return parseByteRangeSet(byteRangeSet, size);
    }

    /**
     * RFC 7233 section 3.2: the client is saying "send the range only if you
     * still hold the representation I already have part of". A leading DQUOTE
     * marks an entity-tag and anything else is an HTTP-date. The condition uses
     * strong comparison, which no weak entity-tag can satisfy.
     */
    static boolean validatorMatches(String ifRange, String entityTag, String lastModifiedHeader) {
        String validator = ifRange.trim();
        if (validator.startsWith("\"")) {
            return validator.equals(entityTag);
        }
        if (validator.regionMatches(true, 0, "W/\"", 0, 3)) {
            return false;
        }
        return validator.equals(lastModifiedHeader);
    }

    /** Returns the byte-range-set, or null when the unit is not "bytes". */
    static String byteRangeSetOf(String rangeHeader) {
        String value = rangeHeader.trim();
        String unit = "bytes=";
        if (!value.regionMatches(true, 0, unit, 0, unit.length())) {
            return null;
        }
        return value.substring(unit.length());
    }

    enum SpecKind { SATISFIABLE, UNSATISFIABLE, INVALID, MALFORMED }

    /** One parsed byte-range-spec; `range` is populated only for SATISFIABLE. */
    record SpecOutcome(SpecKind kind, ByteRange range) {
        static final SpecOutcome UNSATISFIABLE = new SpecOutcome(SpecKind.UNSATISFIABLE, null);
        static final SpecOutcome INVALID = new SpecOutcome(SpecKind.INVALID, null);
        static final SpecOutcome MALFORMED = new SpecOutcome(SpecKind.MALFORMED, null);

        static SpecOutcome satisfiable(long start, long end) {
            return new SpecOutcome(SpecKind.SATISFIABLE, new ByteRange(start, end));
        }
    }

    /**
     * RFC 7233 sections 2.1 and 4.1: one invalid spec poisons the whole set,
     * specs that start past the end are simply left out, and a set with nothing
     * left to serve is unsatisfiable. Text the byte-range grammar does not cover
     * is not a range request at all, which leaves the header field ignored.
     */
    static RangeOutcome parseByteRangeSet(String byteRangeSet, long size) {
        List<ByteRange> satisfiable = new ArrayList<>();
        boolean sawSpec = false;
        for (String element : byteRangeSet.split(",", -1)) {
            String spec = element.trim();
            if (spec.isEmpty()) {
                continue;
            }
            sawSpec = true;
            SpecOutcome outcome = parseByteRangeSpec(spec, size);
            switch (outcome.kind()) {
                case MALFORMED -> {
                    return RangeOutcome.WHOLE;
                }
                case INVALID -> {
                    return RangeOutcome.NOT_SATISFIABLE;
                }
                case UNSATISFIABLE -> {
                    continue;
                }
                case SATISFIABLE -> satisfiable.add(outcome.range());
            }
        }
        if (!sawSpec) {
            return RangeOutcome.WHOLE;
        }
        if (satisfiable.isEmpty()) {
            return RangeOutcome.NOT_SATISFIABLE;
        }
        return RangeOutcome.partial(satisfiable);
    }

    static SpecOutcome parseByteRangeSpec(String spec, long size) {
        int dash = spec.indexOf('-');
        if (dash < 0) {
            return SpecOutcome.MALFORMED;
        }
        String firstBytePos = spec.substring(0, dash).trim();
        String lastBytePos = spec.substring(dash + 1).trim();
        if (firstBytePos.isEmpty()) {
            return parseSuffixByteRangeSpec(lastBytePos, size);
        }
        return parseFirstLastByteRangeSpec(firstBytePos, lastBytePos, size);
    }

    /** RFC 7233 section 2.1: "-N" asks for the last N bytes of the representation. */
    static SpecOutcome parseSuffixByteRangeSpec(String suffixLength, long size) {
        long wanted = parseByteCount(suffixLength);
        if (wanted < 0) {
            return SpecOutcome.MALFORMED;
        }
        if (wanted == 0 || size == 0) {
            return SpecOutcome.UNSATISFIABLE;
        }
        long start = wanted >= size ? 0 : size - wanted;
        return SpecOutcome.satisfiable(start, size - 1);
    }

    /** RFC 7233 section 2.1: "N-" and "N-M", where an absent M means "to the end". */
    static SpecOutcome parseFirstLastByteRangeSpec(String firstBytePos, String lastBytePos, long size) {
        long start = parseByteCount(firstBytePos);
        if (start < 0) {
            return SpecOutcome.MALFORMED;
        }
        long end = size - 1;
        if (!lastBytePos.isEmpty()) {
            end = parseByteCount(lastBytePos);
            if (end < 0) {
                return SpecOutcome.MALFORMED;
            }
            if (end < start) {
                return SpecOutcome.INVALID;
            }
        }
        if (start >= size) {
            return SpecOutcome.UNSATISFIABLE;
        }
        return SpecOutcome.satisfiable(start, Math.min(end, size - 1));
    }

    /**
     * Parses a 1*DIGIT field, returning -1 when it is not one. The grammar puts
     * no ceiling on the digit count, and a value past long range needs no exact
     * arithmetic: as a first-byte-pos it is unsatisfiable and as a last-byte-pos
     * or suffix-length it covers the whole representation, so it saturates.
     */
    static long parseByteCount(String digits) {
        if (digits.isEmpty()) {
            return -1;
        }
        long value = 0;
        boolean saturated = false;
        for (int i = 0; i < digits.length(); i++) {
            char c = digits.charAt(i);
            if (c < '0' || c > '9') {
                return -1;
            }
            if (saturated) {
                continue;
            }
            int digit = c - '0';
            if (value > (Long.MAX_VALUE - digit) / 10) {
                value = Long.MAX_VALUE;
                saturated = true;
                continue;
            }
            value = value * 10 + digit;
        }
        return value;
    }

    /**
     * States the length of the body a HEAD response must not include. The
     * exchange would otherwise treat that length as bytes still to come.
     */
    static void sendHeadersOnly(HttpExchange ex, int status, long contentLength) throws IOException {
        ex.getResponseHeaders().set("Content-Length", Long.toString(contentLength));
        ex.sendResponseHeaders(status, -1);
    }

    static void sendWholeRepresentation(HttpExchange ex, Path file, long size, boolean head) throws IOException {
        if (head) {
            sendHeadersOnly(ex, 200, size);
            return;
        }
        ex.sendResponseHeaders(200, size == 0 ? -1 : size);
        if (size == 0) {
            return;
        }
        try (OutputStream os = body(ex);
             InputStream is = Files.newInputStream(file)) {
            is.transferTo(os);
        }
    }

    static void sendRangeNotSatisfiable(HttpExchange ex, long size) throws IOException {
        ex.getResponseHeaders().set("Content-Range", "bytes */%d".formatted(size));
        ex.sendResponseHeaders(416, -1);
    }

    /**
     * RFC 7233 section 4.1: a request for one range must not be answered with a
     * multipart payload, since a client asking for one part need not understand
     * multipart at all.
     */
    static void sendPartialContent(HttpExchange ex, Path file, long size, String contentType,
                                   List<ByteRange> ranges, boolean head) throws IOException {
        if (ranges.size() == 1) {
            sendSinglePart(ex, file, size, ranges.get(0), head);
            return;
        }
        sendMultipart(ex, file, size, contentType, ranges, head);
    }

    static void sendSinglePart(HttpExchange ex, Path file, long size, ByteRange range, boolean head)
            throws IOException {
        ex.getResponseHeaders().set("Content-Range",
                "bytes %d-%d/%d".formatted(range.start(), range.end(), size));
        if (head) {
            sendHeadersOnly(ex, 206, range.length());
            return;
        }
        ex.sendResponseHeaders(206, range.length());
        try (OutputStream os = body(ex);
             InputStream is = Files.newInputStream(file)) {
            is.skipNBytes(range.start());
            copy(is, os, range.length());
        }
    }

    /**
     * RFC 7233 section 4.1 and appendix A: each part restates the representation
     * Content-Type and its own Content-Range, the parts keep the order in which
     * the client listed them, and the overall Content-Range header field stays
     * off the response so a client cannot mistake this for a single-part reply.
     */
    static void sendMultipart(HttpExchange ex, Path file, long size, String contentType,
                              List<ByteRange> ranges, boolean head) throws IOException {
        String boundary = "httpserv_%016x".formatted(System.nanoTime());
        List<byte[]> partHeaders = new ArrayList<>();
        for (int i = 0; i < ranges.size(); i++) {
            partHeaders.add(partHeader(boundary, contentType, size, ranges.get(i), i == 0));
        }
        byte[] closeDelimiter = "\r\n--%s--\r\n".formatted(boundary).getBytes(StandardCharsets.US_ASCII);

        long payloadLength = multipartLength(partHeaders, ranges, closeDelimiter.length);

        ex.getResponseHeaders().set("Content-Type", "multipart/byteranges; boundary=" + boundary);
        if (head) {
            sendHeadersOnly(ex, 206, payloadLength);
            return;
        }
        ex.sendResponseHeaders(206, payloadLength);
        try (OutputStream os = body(ex);
             FileChannel channel = FileChannel.open(file)) {
            WritableByteChannel out = Channels.newChannel(os);
            for (int i = 0; i < ranges.size(); i++) {
                os.write(partHeaders.get(i));
                transferRange(channel, out, ranges.get(i));
            }
            os.write(closeDelimiter);
        }
    }

    static byte[] partHeader(String boundary, String contentType, long size, ByteRange range, boolean first) {
        String precedingCrlf = first ? "" : "\r\n";
        String header = "%s--%s\r\nContent-Type: %s\r\nContent-Range: bytes %d-%d/%d\r\n\r\n".formatted(
                precedingCrlf, boundary, contentType, range.start(), range.end(), size);
        return header.getBytes(StandardCharsets.US_ASCII);
    }

    static long multipartLength(List<byte[]> partHeaders, List<ByteRange> ranges, int closeDelimiterLength) {
        long total = closeDelimiterLength;
        for (int i = 0; i < ranges.size(); i++) {
            total += partHeaders.get(i).length + ranges.get(i).length();
        }
        return total;
    }

    /**
     * The Content-Length was computed from the file size, so a file truncated
     * mid-response would leave the client waiting on bytes that never come.
     * Fail the exchange instead of silently sending a short body.
     */
    static void transferRange(FileChannel channel, WritableByteChannel out, ByteRange range) throws IOException {
        long position = range.start();
        long remaining = range.length();
        while (remaining > 0) {
            long transferred = channel.transferTo(position, remaining, out);
            if (transferred <= 0) {
                throw new IOException("file truncated at byte %d while sending a range".formatted(position));
            }
            position += transferred;
            remaining -= transferred;
        }
    }

    static void copy(InputStream is, OutputStream os, long len) throws IOException {
        byte[] buf = new byte[64 * 1024];
        while (len > 0) {
            int n = is.read(buf, 0, (int) Math.min(buf.length, len));
            if (n < 0) break;
            os.write(buf, 0, n);
            len -= n;
        }
    }

    static OutputStream body(HttpExchange ex) {
        OutputStream raw = ex.getResponseBody();
        if (bandwidthBytesPerSec <= 0) return raw;
        return new ThrottledOutputStream(raw, bandwidthBytesPerSec);
    }

    static final class ThrottledOutputStream extends OutputStream {
        private static final int CHUNK = 16 * 1024;
        private final OutputStream out;
        private final long bytesPerSecond;
        private final long startNanos = System.nanoTime();
        private long written = 0;

        ThrottledOutputStream(OutputStream out, long bytesPerSecond) {
            this.out = out;
            this.bytesPerSecond = bytesPerSecond;
        }

        public void write(int b) throws IOException {
            out.write(b);
            written++;
            throttle();
        }

        public void write(byte[] b, int off, int len) throws IOException {
            int pos = off;
            int remaining = len;
            while (remaining > 0) {
                int n = Math.min(CHUNK, remaining);
                out.write(b, pos, n);
                written += n;
                pos += n;
                remaining -= n;
                throttle();
            }
        }

        public void flush() throws IOException {
            out.flush();
        }

        public void close() throws IOException {
            out.close();
        }

        private void throttle() throws IOException {
            long elapsedNanos = System.nanoTime() - startNanos;
            long sleepNanos = targetNanos() - elapsedNanos;
            if (sleepNanos <= 0) return;
            try {
                Thread.sleep(sleepNanos / 1_000_000L, (int) (sleepNanos % 1_000_000L));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted while throttling", e);
            }
        }

        private long targetNanos() {
            long wholeSeconds = written / bytesPerSecond;
            long remainderBytes = written % bytesPerSecond;
            return wholeSeconds * 1_000_000_000L
                    + remainderBytes * 1_000_000_000L / bytesPerSecond;
        }
    }

    static void listDirectory(HttpExchange ex, Path dir, String urlPath, boolean head) throws IOException {
        StringBuilder sb = new StringBuilder();
        sb.append("""
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>Index of %1$s</title>
                <style>
                  body{font-family:monospace;margin:2em}
                  a{text-decoration:none;color:#06c}a:hover{text-decoration:underline}
                  td{padding:2px 20px 2px 0}
                  th{text-align:left;padding-right:20px;border-bottom:1px solid #ccc}
                  .s{text-align:right}
                </style>
                </head><body>
                <h1>Index of %1$s</h1>
                <table>
                <tr><th>Name</th><th class="s">Size</th><th>Modified</th></tr>
                """.formatted(esc(urlPath)));
        if (!urlPath.equals("/")) {
            sb.append("<tr><td><a href=\"../\">../</a></td><td></td><td></td></tr>");
        }
        try (Stream<Path> s = Files.list(dir)) {
            s.sorted((a, b) -> {
                boolean da = Files.isDirectory(a), db = Files.isDirectory(b);
                if (da != db) return da ? -1 : 1;
                return a.getFileName().toString().compareToIgnoreCase(b.getFileName().toString());
            }).forEach(p -> appendEntry(sb, p));
        }
        sb.append("</table></body></html>");
        byte[] body = sb.toString().getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "text/html; charset=utf-8");
        if (head) {
            ex.getResponseHeaders().set("Content-Length", Integer.toString(body.length));
            ex.sendResponseHeaders(200, -1);
            return;
        }
        ex.sendResponseHeaders(200, body.length);
        try (OutputStream os = body(ex)) { os.write(body); }
    }

    static void appendEntry(StringBuilder sb, Path p) {
        try {
            String name = p.getFileName().toString();
            boolean d = Files.isDirectory(p);
            String slash = d ? "/" : "";
            String href = URLEncoder.encode(name, StandardCharsets.UTF_8).replace("+", "%20") + slash;
            String size = d ? "-" : humanSize(Files.size(p));
            String mod = DateTimeFormatter.ISO_INSTANT.format(
                    Files.getLastModifiedTime(p).toInstant().truncatedTo(ChronoUnit.SECONDS));
            sb.append("<tr><td><a href=\"%s\">%s%s</a></td><td class=\"s\">%s</td><td>%s</td></tr>"
                    .formatted(href, esc(name), slash, size, mod));
        } catch (IOException ignore) {
        }
    }

    static String humanSize(long n) {
        if (n < 1024) return "%d B".formatted(n);
        String[] u = {"KB", "MB", "GB", "TB", "PB"};
        double v = n;
        int i = -1;
        do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
        return "%.1f %s".formatted(v, u[i]);
    }

    static String esc(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace("\"", "&quot;");
    }

    static void log(HttpExchange ex) {
        if (silent) return;
        String ua = ex.getRequestHeaders().getFirst("User-Agent");
        String range = ex.getRequestHeaders().getFirst("Range");
        String line = "[%s]  \"%s %s\" \"%s\"".formatted(
                DateTimeFormatter.ISO_INSTANT.format(Instant.now()),
                ex.getRequestMethod(),
                ex.getRequestURI(),
                ua == null ? "-" : ua);
        if (range != null) line += " Range: " + range;
        IO.println(line);
    }
}
