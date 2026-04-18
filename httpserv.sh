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
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.stream.Stream;

public class Httpserv {

    static boolean silent = false;
    static boolean etag = false;
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
        try (OutputStream os = ex.getResponseBody()) { os.write(body); }
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

    static void serveFile(HttpExchange ex, Path file, boolean head) throws IOException {
        long size = Files.size(file);
        long lastModified = Files.getLastModifiedTime(file).toMillis();
        String ct = Files.probeContentType(file);
        if (ct == null) ct = "application/octet-stream";

        Headers h = ex.getResponseHeaders();
        h.set("Content-Type", ct);
        h.set("Accept-Ranges", "bytes");
        h.set("Last-Modified", DateTimeFormatter.RFC_1123_DATE_TIME.format(
                ZonedDateTime.ofInstant(Instant.ofEpochMilli(lastModified), ZoneOffset.UTC)));
        if (etag) h.set("ETag", "\"%d\"".formatted(lastModified));

        String range = ex.getRequestHeaders().getFirst("Range");
        if (range != null && range.startsWith("bytes=")) {
            long[] r = parseRange(range.substring(6), size);
            if (r == null) {
                h.set("Content-Range", "bytes */%d".formatted(size));
                ex.sendResponseHeaders(416, -1);
                return;
            }
            long start = r[0], end = r[1], len = end - start + 1;
            h.set("Content-Range", "bytes %d-%d/%d".formatted(start, end, size));
            if (head) {
                h.set("Content-Length", Long.toString(len));
                ex.sendResponseHeaders(206, -1);
                return;
            }
            ex.sendResponseHeaders(206, len);
            try (OutputStream os = ex.getResponseBody();
                 InputStream is = Files.newInputStream(file)) {
                is.skipNBytes(start);
                copy(is, os, len);
            }
            return;
        }

        if (head) {
            h.set("Content-Length", Long.toString(size));
            ex.sendResponseHeaders(200, -1);
            return;
        }
        ex.sendResponseHeaders(200, size == 0 ? -1 : size);
        if (size > 0) {
            try (OutputStream os = ex.getResponseBody();
                 InputStream is = Files.newInputStream(file)) {
                is.transferTo(os);
            }
        }
    }

    static long[] parseRange(String spec, long size) {
        if (spec.indexOf(',') >= 0) spec = spec.substring(0, spec.indexOf(','));
        int dash = spec.indexOf('-');
        if (dash < 0) return null;
        String s = spec.substring(0, dash).trim();
        String e = spec.substring(dash + 1).trim();
        try {
            long start, end;
            if (s.isEmpty()) {
                if (e.isEmpty()) return null;
                long suffix = Long.parseLong(e);
                if (suffix <= 0) return null;
                start = Math.max(0, size - suffix);
                end = size - 1;
            } else {
                start = Long.parseLong(s);
                end = e.isEmpty() ? size - 1 : Long.parseLong(e);
            }
            if (start < 0 || start > end || start >= size) return null;
            if (end >= size) end = size - 1;
            return new long[]{start, end};
        } catch (NumberFormatException ex) {
            return null;
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
        try (OutputStream os = ex.getResponseBody()) { os.write(body); }
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
