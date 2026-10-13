/**
 * RFC 4180 CSV parser: quoted values, doubled quotes ("") inside quotes, delimiters and
 * line breaks inside quotes, CRLF or LF line endings, an optional UTF-8 byte order mark,
 * and comma, semicolon or tab delimiters. Fully blank lines are skipped.
 *
 * Uses indexOf with cached positions instead of a per-character loop, so parsing stays
 * linear in file size and well inside CPU limits for files of a few thousand rows.
 */
public inherited sharing class CsvParser {
    public class CsvException extends Exception {
    }

    private static final Integer QUOTE = 34;
    private static final Integer COMMA = 44;
    private static final Integer SEMICOLON = 59;
    private static final Integer TAB = 9;
    private static final Integer CR = 13;
    private static final Integer LF = 10;
    @TestVisible
    private static final String BOM = String.fromCharArray(new List<Integer>{ 65279 });

    private final String text;
    private final String delimiter;
    private final Integer n;
    // Cached position of the next delimiter / LF / CR at or after the current position; n = none left.
    private Integer nextDelim = -1;
    private Integer nextLf = -1;
    private Integer nextCr = -1;

    private CsvParser(String text, String delimiter) {
        this.text = text;
        this.delimiter = delimiter;
        this.n = text.length();
    }

    /** Picks the delimiter that occurs most often in the header line, outside quotes. Defaults to comma. */
    public static String detectDelimiter(String raw) {
        if (String.isBlank(raw)) {
            return ',';
        }
        Integer commas = 0;
        Integer semicolons = 0;
        Integer tabs = 0;
        Boolean inQuotes = false;
        Integer len = raw.length();
        for (Integer i = 0; i < len; i++) {
            Integer c = raw.charAt(i);
            if (c == QUOTE) {
                inQuotes = !inQuotes;
            } else if (!inQuotes) {
                if (c == LF || c == CR) {
                    break;
                } else if (c == COMMA) {
                    commas++;
                } else if (c == SEMICOLON) {
                    semicolons++;
                } else if (c == TAB) {
                    tabs++;
                }
            }
        }
        if (semicolons > commas && semicolons >= tabs) {
            return ';';
        }
        if (tabs > commas && tabs > semicolons) {
            return '\t';
        }
        return ',';
    }

    /** Parses the text into rows of values. Throws CsvException for an unclosed quote or text after a closing quote. */
    public static List<List<String>> parse(String raw, String delimiter) {
        if (String.isBlank(raw)) {
            return new List<List<String>>();
        }
        // Not String.isBlank: a tab is a valid delimiter but counts as blank.
        if (delimiter == null || delimiter.length() != 1) {
            throw new CsvException('Delimiter must be a single character.');
        }
        String body = raw.startsWith(BOM) ? raw.substring(1) : raw;
        return new CsvParser(body, delimiter).run();
    }

    private List<List<String>> run() {
        List<List<String>> rows = new List<List<String>>();
        Integer delimChar = delimiter.charAt(0);
        Integer i = 0;
        Integer line = 1;
        List<String> row = new List<String>();
        while (true) {
            String value;
            if (i < n && text.charAt(i) == QUOTE) {
                List<String> parts = new List<String>();
                Integer j = i + 1;
                while (true) {
                    Integer q = text.indexOf('"', j);
                    if (q == -1) {
                        throw new CsvException('Unclosed quoted value starting on line ' + line + '.');
                    }
                    parts.add(text.substring(j, q));
                    if (q + 1 < n && text.charAt(q + 1) == QUOTE) {
                        parts.add('"');
                        j = q + 2;
                    } else {
                        i = q + 1;
                        break;
                    }
                }
                value = String.join(parts, '');
            } else {
                Integer stop = boundary(i);
                value = text.substring(i, stop);
                i = stop;
            }
            row.add(value);

            if (i >= n) {
                addIfNotBlank(rows, row);
                break;
            }
            Integer c = text.charAt(i);
            if (c == delimChar) {
                i++;
                continue;
            }
            if (c == CR) {
                i++;
                if (i < n && text.charAt(i) == LF) {
                    i++;
                }
            } else if (c == LF) {
                i++;
            } else {
                throw new CsvException('Unexpected text after a quoted value on line ' + line + '.');
            }
            addIfNotBlank(rows, row);
            row = new List<String>();
            line++;
            if (i >= n) {
                break;
            }
        }
        return rows;
    }

    /** Position of the first delimiter, CR or LF at or after start; n if none. */
    private Integer boundary(Integer start) {
        nextDelim = seek(nextDelim, delimiter, start);
        nextLf = seek(nextLf, '\n', start);
        nextCr = seek(nextCr, '\r', start);
        return Math.min(nextDelim, Math.min(nextLf, nextCr));
    }

    private Integer seek(Integer cached, String token, Integer start) {
        if (cached >= start) {
            return cached;
        }
        Integer p = text.indexOf(token, start);
        return p == -1 ? n : p;
    }

    private static void addIfNotBlank(List<List<String>> rows, List<String> row) {
        for (String v : row) {
            if (String.isNotBlank(v)) {
                rows.add(row);
                return;
            }
        }
    }
}
