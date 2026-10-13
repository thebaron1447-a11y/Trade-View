/**
 * Produces a matching key for firm, branch and fund names so that spelling variants
 * ("Barder & Company", "Barder and Co", "Barder and C.") resolve to the same key ("barder").
 * Keys are compared against Firm_Alias__c / Fund_Alias__c.Normalized_Key__c.
 */
public inherited sharing class NameNormalizer {
    // Multi-word suffixes must come before the single words they end with.
    @TestVisible
    private static final List<String> SUFFIXES = new List<String>{
        'and company', 'and co', 'and c', 'et compagnie', 'et cie',
        'incorporated', 'corporation', 'limited', 'company', 'compagnie',
        'corp', 'inc', 'ltd', 'ltée', 'ltee', 'llp', 'lp', 'cie', 'co', 'and', 'et'
    };

    /**
     * Lower-cases, converts "&" to "and", keeps letters (any language) and digits,
     * collapses spaces, then repeatedly strips legal suffixes from the end.
     * Each suffix must be preceded by a space, so a name that IS a suffix ("Co") is kept.
     * Returns null for blank input or a name made only of punctuation.
     */
    public static String firmKey(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.toLowerCase().replace('&', ' and ');
        s = s.replaceAll('[^\\p{L}\\p{N} ]', ' ').normalizeSpace();
        Boolean stripped = true;
        while (stripped) {
            stripped = false;
            for (String suffix : SUFFIXES) {
                if (s.endsWith(' ' + suffix)) {
                    s = s.removeEnd(' ' + suffix).normalizeSpace();
                    stripped = true;
                    break;
                }
            }
        }
        return String.isBlank(s) ? null : s;
    }
}
