/**
 * Identifies a file's layout by its header fingerprint, finds the Active mapping profile
 * for it, and resolves each column to a canonical field. A profile that would drop a
 * column, map two columns to one field, or miss a required field is rejected.
 */
public inherited sharing class MappingService {
    public class MappingException extends Exception {
    }

    public static final String IGNORE = 'IGNORE';
    public static final Set<String> CANONICAL_FIELDS = new Set<String>{
        'repCode', 'advisorName', 'firmName', 'branchName', 'fundName', 'tradeDate', 'amount', 'transactionType',
        'rowType', IGNORE
    };
    // tradeDate is the row date: trade date, AUM as-of date, or code effective date.
    public static final List<String> REQUIRED_FIELDS = new List<String>{ 'repCode', 'fundName', 'tradeDate', 'amount' };
    public static final List<String> ROSTER_REQUIRED_FIELDS = new List<String>{ 'repCode', 'advisorName', 'tradeDate' };
    public static final String CONVENTION_TYPE_COLUMN = 'Type Column';
    public static final String CONVENTION_SIGNED = 'Signed Amount';
    public static final String FEED_TRADE_ACTIVITY = 'Trade Activity';
    public static final String FEED_ROSTER = 'Advisor Code Roster';

    /** Blank Feed Type is treated as Trade Activity (profiles created before the field existed). */
    public static Boolean isRoster(Mapping_Profile__c profile) {
        return profile.Feed_Type__c == FEED_ROSTER;
    }

    private static final String NBSP = String.fromCharArray(new List<Integer>{ 160 });

    /** Trimmed, lower-cased, single-spaced header text. Used for fingerprints and column map lookups. */
    public static String headerKey(String header) {
        if (header == null) {
            return '';
        }
        return header.replace(NBSP, ' ').trim().toLowerCase().normalizeSpace();
    }

    /** SHA-256 (hex) of the normalized headers joined with "|". */
    public static String fingerprint(List<String> headers) {
        List<String> keys = new List<String>();
        for (String h : headers) {
            keys.add(headerKey(h));
        }
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(keys, '|')));
        return EncodingUtil.convertToHex(digest);
    }

    /**
     * Returns the Active profile for this fingerprint, or null if there is none.
     * If several Active profiles share the fingerprint, the one for this source firm wins;
     * if that is still ambiguous, a MappingException is thrown.
     */
    public static Mapping_Profile__c findActiveProfile(String headerFingerprint, String sourceFirm) {
        List<Mapping_Profile__c> profiles = [
            SELECT Id, Name, Source_Firm__c, Firm__c, Firm__r.Name, Column_Map__c, Date_Format__c,
                Decimal_Separator__c, Direction_Convention__c, Single_Firm_Feed__c, Feed_Type__c, AUM_Indicator_Values__c
            FROM Mapping_Profile__c
            WHERE Header_Fingerprint__c = :headerFingerprint AND Status__c = 'Active'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
        if (profiles.isEmpty()) {
            return null;
        }
        if (profiles.size() == 1) {
            return profiles[0];
        }
        List<Mapping_Profile__c> forFirm = new List<Mapping_Profile__c>();
        for (Mapping_Profile__c p : profiles) {
            if (p.Source_Firm__c != null && sourceFirm != null && p.Source_Firm__c.equalsIgnoreCase(sourceFirm)) {
                forFirm.add(p);
            }
        }
        if (forFirm.size() == 1) {
            return forFirm[0];
        }
        throw new MappingException(
            'More than one Active mapping profile matches this file layout' +
            (sourceFirm == null ? '' : ' for ' + sourceFirm) + '. Retire the extra profiles.'
        );
    }

    /**
     * Returns the canonical field for each column position. Throws a MappingException
     * listing every problem found, so a reviewer can fix the profile in one pass.
     */
    public static List<String> resolveColumns(List<String> headers, Mapping_Profile__c profile) {
        List<String> problems = new List<String>();
        Map<String, String> canonicalByHeader = parseColumnMap(profile.Column_Map__c, problems);

        List<String> resolved = new List<String>();
        Set<String> seenHeaders = new Set<String>();
        Map<String, Integer> fieldCounts = new Map<String, Integer>();
        for (String h : headers) {
            String key = headerKey(h);
            if (seenHeaders.contains(key)) {
                problems.add('The file has more than one column named "' + h + '".');
            }
            seenHeaders.add(key);
            String canonical = canonicalByHeader.get(key);
            if (canonical == null) {
                problems.add('Column "' + h + '" is not mapped. Map it to a field or to IGNORE.');
                resolved.add(IGNORE);
                continue;
            }
            resolved.add(canonical);
            if (canonical != IGNORE) {
                Integer count = fieldCounts.containsKey(canonical) ? fieldCounts.get(canonical) : 0;
                fieldCounts.put(canonical, count + 1);
            }
        }
        for (String f : fieldCounts.keySet()) {
            if (fieldCounts.get(f) > 1) {
                problems.add('More than one column is mapped to ' + f + '.');
            }
        }
        Boolean roster = isRoster(profile);
        for (String f : roster ? ROSTER_REQUIRED_FIELDS : REQUIRED_FIELDS) {
            if (!fieldCounts.containsKey(f)) {
                problems.add('No column is mapped to ' + f + ', which is required.');
            }
        }
        // Direction and AUM settings only apply to Trade Activity feeds; roster files have neither.
        if (!roster) {
            Boolean hasType = fieldCounts.containsKey('transactionType');
            if (profile.Direction_Convention__c == CONVENTION_TYPE_COLUMN && !hasType) {
                problems.add('Direction Convention is Type Column, but no column is mapped to transactionType.');
            }
            if (profile.Direction_Convention__c == CONVENTION_SIGNED && hasType) {
                problems.add('Direction Convention is Signed Amount, so the transactionType column must be mapped to IGNORE.');
            }
            Boolean hasRowType = fieldCounts.containsKey('rowType');
            if (hasRowType && String.isBlank(profile.AUM_Indicator_Values__c)) {
                problems.add('A column is mapped to rowType, so AUM Indicator Values must list the values that mark AUM rows.');
            }
            if (String.isNotBlank(profile.AUM_Indicator_Values__c) && !hasRowType && !hasType) {
                problems.add('AUM Indicator Values is set, but no rowType or transactionType column exists to read it from.');
            }
        }
        if (!problems.isEmpty()) {
            throw new MappingException(String.join(problems, '\n'));
        }
        return resolved;
    }

    private static Map<String, String> parseColumnMap(String json, List<String> problems) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(json)) {
            problems.add('The mapping profile has no Column Map.');
            return result;
        }
        Object parsed;
        try {
            parsed = System.JSON.deserializeUntyped(json);
        } catch (System.JSONException e) {
            problems.add('The Column Map is not valid JSON: ' + e.getMessage());
            return result;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            problems.add('The Column Map must be a JSON object of "column header": "field".');
            return result;
        }
        Map<String, Object> raw = (Map<String, Object>) parsed;
        for (String header : raw.keySet()) {
            String canonical = raw.get(header) == null ? null : String.valueOf(raw.get(header));
            if (canonical == null || !CANONICAL_FIELDS.contains(canonical)) {
                problems.add(
                    'Column "' + header + '" is mapped to "' + canonical + '", which is not a known field. Use one of: ' +
                    String.join(new List<String>(CANONICAL_FIELDS), ', ') + '.'
                );
                continue;
            }
            result.put(headerKey(header), canonical);
        }
        return result;
    }
}
