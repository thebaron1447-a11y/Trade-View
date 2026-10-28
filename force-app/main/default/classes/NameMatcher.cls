/**
 * Advisor name comparison and string similarity used by TradeMatcher.
 *
 * isCompatible() answers "could this row's advisor name refer to this person?":
 * the person's last name must appear in the row, and any other words in the row must
 * include their first name or its initial ("J. Morales" fits Julia Morales; "Jorge Morales" does not).
 * Accents, case, punctuation and hyphens are ignored ("Elise" fits "Élise").
 */
public inherited sharing class NameMatcher {
    // Lower-case accented letters common in English and French names, mapped to plain letters.
    @TestVisible
    private static final Map<String, String> FOLD = new Map<String, String>{
        'à' => 'a',
        'á' => 'a',
        'â' => 'a',
        'ä' => 'a',
        'ã' => 'a',
        'å' => 'a',
        'ç' => 'c',
        'è' => 'e',
        'é' => 'e',
        'ê' => 'e',
        'ë' => 'e',
        'ì' => 'i',
        'í' => 'i',
        'î' => 'i',
        'ï' => 'i',
        'ñ' => 'n',
        'ò' => 'o',
        'ó' => 'o',
        'ô' => 'o',
        'ö' => 'o',
        'õ' => 'o',
        'ù' => 'u',
        'ú' => 'u',
        'û' => 'u',
        'ü' => 'u',
        'ý' => 'y',
        'ÿ' => 'y',
        'œ' => 'oe',
        'æ' => 'ae'
    };

    /** Lower-cases, removes accents, and turns anything that is not a letter or digit into a space. */
    public static String fold(String value) {
        if (value == null) {
            return '';
        }
        String s = value.toLowerCase();
        for (String accented : FOLD.keySet()) {
            if (s.contains(accented)) {
                s = s.replace(accented, FOLD.get(accented));
            }
        }
        return s.replaceAll('[^a-z0-9]', ' ').normalizeSpace();
    }

    public static List<String> tokens(String value) {
        String folded = fold(value);
        return String.isBlank(folded) ? new List<String>() : folded.split(' ');
    }

    /** True when the row name could refer to the person. A blank row name is not evidence either way; callers check that first. */
    public static Boolean isCompatible(String rowName, String firstName, String lastName) {
        List<String> rowTokens = tokens(rowName);
        List<String> lastTokens = tokens(lastName);
        if (rowTokens.isEmpty() || lastTokens.isEmpty()) {
            return false;
        }
        List<String> others = new List<String>(rowTokens);
        for (String t : lastTokens) {
            Integer idx = others.indexOf(t);
            if (idx == -1) {
                return false;
            }
            others.remove(idx);
        }
        List<String> firstTokens = tokens(firstName);
        if (others.isEmpty() || firstTokens.isEmpty()) {
            return true;
        }
        String first = firstTokens[0];
        for (String t : others) {
            if (t == first || (t.length() == 1 && first.startsWith(t))) {
                return true;
            }
        }
        return false;
    }

    /** 1.0 for identical strings, 0.0 for completely different ones, using edit distance over the longer length. */
    public static Decimal similarity(String a, String b) {
        String x = a == null ? '' : a;
        String y = b == null ? '' : b;
        Integer longest = Math.max(x.length(), y.length());
        if (longest == 0) {
            return 1;
        }
        Integer distance = x.getLevenshteinDistance(y);
        // Explicit scale and rounding so the result is identical on every run (and to the Python cross-check).
        return Decimal.valueOf(longest - distance).divide(longest, 3, System.RoundingMode.HALF_UP);
    }
}
