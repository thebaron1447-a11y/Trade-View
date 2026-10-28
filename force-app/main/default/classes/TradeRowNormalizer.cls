/**
 * Turns one parsed file row into an Import_Staging_Row__c using the column positions
 * resolved by MappingService and the profile's format settings. Problems never throw:
 * each is recorded in Validation_Errors__c so no row is silently dropped.
 */
public inherited sharing class TradeRowNormalizer {
    private static final Decimal MAX_AMOUNT = Decimal.valueOf('10000000000000000');
    public static final String PURCHASE = 'Purchase';
    public static final String REDEMPTION = 'Redemption';
    public static final String ROW_TRADE = 'Trade';
    public static final String ROW_AUM = 'AUM';
    public static final String ROW_ROSTER = 'Code Roster';
    public static final String MATCH_PENDING = 'Pending';
    public static final String MATCH_INVALID = 'Invalid';

    private static final String NBSP = String.fromCharArray(new List<Integer>{ 160 });
    private static final String NARROW_NBSP = String.fromCharArray(new List<Integer>{ 8239 });
    private static final Integer MIN_YEAR = 1990;
    private static final Integer MAX_YEAR = 2100;
    private static final Pattern YMD = Pattern.compile('^(\\d{4})[-/.](\\d{1,2})[-/.](\\d{1,2})(?:[ T]\\d{1,2}:\\d{2}(?::\\d{2})?)?$');
    private static final Pattern DMY_OR_MDY = Pattern.compile('^(\\d{1,2})[-/.](\\d{1,2})[-/.](\\d{4})(?:[ T]\\d{1,2}:\\d{2}(?::\\d{2})?)?$');
    private static final Pattern PLAIN_NUMBER = Pattern.compile('^\\d+(\\.\\d+)?$');

    @TestVisible
    private static final Map<String, String> TYPE_SYNONYMS = new Map<String, String>{
        'BUY' => PURCHASE,
        'B' => PURCHASE,
        'P' => PURCHASE,
        'PURCHASE' => PURCHASE,
        'PURCH' => PURCHASE,
        'PUR' => PURCHASE,
        'SUBSCRIPTION' => PURCHASE,
        'SUB' => PURCHASE,
        'ACHAT' => PURCHASE,
        'SELL' => REDEMPTION,
        'S' => REDEMPTION,
        'R' => REDEMPTION,
        'REDEMPTION' => REDEMPTION,
        'RED' => REDEMPTION,
        'REDEEM' => REDEMPTION,
        'REDEMP' => REDEMPTION,
        'VENTE' => REDEMPTION,
        'RACHAT' => REDEMPTION
    };

    /** Format settings taken from a Mapping_Profile__c. */
    public class Config {
        public String dateFormat;
        public String decimalSeparator;
        public String directionConvention;
        public String fallbackFirmName;
        public Boolean roster = false;
        // Normalized (upper-case letters and digits) values that mark a row as AUM.
        public Set<String> aumIndicators = new Set<String>();
    }

    public static Config configFrom(Mapping_Profile__c profile) {
        Config cfg = new Config();
        cfg.dateFormat = profile.Date_Format__c;
        cfg.decimalSeparator = profile.Decimal_Separator__c;
        cfg.directionConvention = profile.Direction_Convention__c;
        cfg.fallbackFirmName = (profile.Single_Firm_Feed__c == true && profile.Firm__c != null) ? profile.Firm__r.Name : null;
        cfg.roster = MappingService.isRoster(profile);
        if (String.isNotBlank(profile.AUM_Indicator_Values__c)) {
            for (String v : profile.AUM_Indicator_Values__c.split(',')) {
                String key = indicatorKey(v);
                if (String.isNotBlank(key)) {
                    cfg.aumIndicators.add(key);
                }
            }
        }
        return cfg;
    }

    @TestVisible
    private static String indicatorKey(String value) {
        return value == null ? '' : value.toUpperCase().replaceAll('[^A-Z0-9]', '');
    }

    /** Roster feed: every row is Code Roster. Otherwise AUM if the rowType (or transactionType) value is an AUM indicator. */
    @TestVisible
    private static String rowTypeFor(Map<String, String> byField, Config cfg) {
        if (cfg.roster == true) {
            return ROW_ROSTER;
        }
        if (cfg.aumIndicators.isEmpty()) {
            return ROW_TRADE;
        }
        String marker = byField.containsKey('rowType') ? byField.get('rowType') : byField.get('transactionType');
        return cfg.aumIndicators.contains(indicatorKey(marker)) ? ROW_AUM : ROW_TRADE;
    }

    public static Import_Staging_Row__c normalize(List<String> headers, List<String> values, List<String> canonicalByColumn, Config cfg, Integer rowNumber) {
        List<String> errors = new List<String>();
        Import_Staging_Row__c row = new Import_Staging_Row__c(Row_Number__c = rowNumber);
        row.Raw_Data__c = rawJson(headers, values).abbreviate(32768);

        if (values.size() != headers.size()) {
            errors.add('Row has ' + values.size() + ' values but the header has ' + headers.size() + ' columns.');
        }
        Map<String, String> byField = new Map<String, String>();
        for (Integer i = 0; i < canonicalByColumn.size() && i < values.size(); i++) {
            String field = canonicalByColumn[i];
            if (field != MappingService.IGNORE) {
                byField.put(field, clean(values[i]));
            }
        }

        String rowType = rowTypeFor(byField, cfg);
        row.Row_Type__c = rowType;
        row.Source_Rep_Code__c = textValue(normalizeRepCode(byField.get('repCode')), 'Rep code', 40, true, errors);
        row.Source_Advisor_Name__c = textValue(byField.get('advisorName'), 'Advisor name', 255, rowType == ROW_ROSTER, errors);
        String firm = byField.get('firmName');
        if (String.isBlank(firm)) {
            firm = cfg.fallbackFirmName;
        }
        row.Source_Firm_Name__c = textValue(firm, 'Firm name', 255, false, errors);
        row.Source_Branch_Name__c = textValue(byField.get('branchName'), 'Branch name', 255, false, errors);
        // Trades need a fund; AUM may be a total per code; roster rows have no fund.
        if (rowType != ROW_ROSTER) {
            row.Source_Fund_Name__c = textValue(byField.get('fundName'), 'Fund name', 255, rowType == ROW_TRADE, errors);
        }

        String dateLabel = rowType == ROW_TRADE ? 'Trade date' : (rowType == ROW_AUM ? 'As-of date' : 'Effective date');
        String rawDate = byField.get('tradeDate');
        if (String.isBlank(rawDate)) {
            errors.add(dateLabel + ' is missing.');
        } else {
            row.Trade_Date__c = parseDate(rawDate, cfg.dateFormat, errors);
        }

        if (rowType == ROW_TRADE) {
            applyAmountAndDirection(row, byField.get('amount'), byField.get('transactionType'), cfg, errors);
        } else if (rowType == ROW_AUM) {
            applyAumValue(row, byField.get('amount'), cfg, errors);
        }

        row.Validation_Errors__c = errors.isEmpty() ? null : String.join(errors, '\n').abbreviate(5000);
        row.Has_Errors__c = !errors.isEmpty();
        row.Match_Status__c = errors.isEmpty() ? MATCH_PENDING : MATCH_INVALID;
        return row;
    }

    // ------------------------------------------------------------------ field rules

    /** Removes whitespace, upper-cases, and drops leading zeros from all-digit codes ("0457" -> "457", "000" -> "0"). */
    @TestVisible
    private static String normalizeRepCode(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String code = value.deleteWhitespace().toUpperCase();
        if (code.isNumeric()) {
            code = code.replaceFirst('^0+(?=\\d)', '');
        }
        return code;
    }

    /** Parses a date strictly in the declared format, accepting / - . separators and an optional time. */
    @TestVisible
    private static Date parseDate(String value, String format, List<String> errors) {
        Matcher m;
        Integer year;
        Integer month;
        Integer day;
        if (format == 'YYYY-MM-DD') {
            m = YMD.matcher(value);
            if (m.matches()) {
                year = Integer.valueOf(m.group(1));
                month = Integer.valueOf(m.group(2));
                day = Integer.valueOf(m.group(3));
            }
        } else if (format == 'MM/DD/YYYY' || format == 'DD/MM/YYYY') {
            m = DMY_OR_MDY.matcher(value);
            if (m.matches()) {
                Boolean monthFirst = format == 'MM/DD/YYYY';
                month = Integer.valueOf(m.group(monthFirst ? 1 : 2));
                day = Integer.valueOf(m.group(monthFirst ? 2 : 1));
                year = Integer.valueOf(m.group(3));
            }
        } else {
            errors.add('The mapping profile has no valid Date Format.');
            return null;
        }
        if (year == null) {
            errors.add('Trade date "' + value + '" does not match the format ' + format + '.');
            return null;
        }
        if (year < MIN_YEAR || year > MAX_YEAR || month < 1 || month > 12 || day < 1 || day > Date.daysInMonth(year, month)) {
            errors.add('Trade date "' + value + '" is not a valid date in the format ' + format + '.');
            return null;
        }
        return Date.newInstance(year, month, day);
    }

    /**
     * Parses an amount: strips currency markers and spaces, handles (1,234.56), leading or trailing
     * minus signs, and period or comma decimal separators. Returns a signed value rounded to 2 decimals.
     */
    @TestVisible
    private static Decimal parseAmount(String value, String decimalSeparator, List<String> errors) {
        String s = value.replace(NBSP, ' ').replace(NARROW_NBSP, ' ').trim();
        s = s.replaceAll('(?i)\\b(CAD|USD)\\b', '').replace('$', '').trim();
        Boolean negative = false;
        if (s.startsWith('(') && s.endsWith(')')) {
            negative = true;
            s = s.substring(1, s.length() - 1).trim();
        }
        if (s.startsWith('-')) {
            negative = !negative;
            s = s.substring(1).trim();
        } else if (s.endsWith('-')) {
            negative = !negative;
            s = s.removeEnd('-').trim();
        }
        if (decimalSeparator == 'Comma') {
            s = s.replace('.', '').replace(' ', '').replace('\'', '').replace(',', '.');
        } else {
            s = s.replace(',', '').replace(' ', '').replace('\'', '');
        }
        if (!PLAIN_NUMBER.matcher(s).matches()) {
            errors.add('Amount "' + value + '" is not a number.');
            return null;
        }
        Decimal amount = Decimal.valueOf(s).setScale(2, System.RoundingMode.HALF_UP);
        // Amount__c is Number(18,2): 16 digits before the point. A bigger value would fail the whole file's insert.
        if (amount.abs() >= MAX_AMOUNT) {
            errors.add('Amount "' + value + '" is too large.');
            return null;
        }
        return negative ? -amount : amount;
    }

    @TestVisible
    private static void applyAmountAndDirection(Import_Staging_Row__c row, String rawAmount, String rawType, Config cfg, List<String> errors) {
        if (String.isBlank(rawAmount)) {
            errors.add('Amount is missing.');
            return;
        }
        Decimal amount = parseAmount(rawAmount, cfg.decimalSeparator, errors);
        if (amount == null) {
            return;
        }
        if (amount == 0) {
            errors.add('Amount is zero.');
            return;
        }
        if (cfg.directionConvention == MappingService.CONVENTION_SIGNED) {
            row.Transaction_Type__c = amount < 0 ? REDEMPTION : PURCHASE;
            row.Amount__c = amount.abs();
            return;
        }
        if (cfg.directionConvention == MappingService.CONVENTION_TYPE_COLUMN) {
            String key = rawType == null ? '' : rawType.toUpperCase().replaceAll('[^A-Z]', '');
            String type = TYPE_SYNONYMS.get(key);
            if (type == null) {
                errors.add('Transaction type "' + (rawType == null ? '' : rawType) + '" is not recognized as a purchase or redemption.');
            } else {
                row.Transaction_Type__c = type;
            }
            if (amount < 0) {
                errors.add('Amount is negative, but this source shows direction in its type column.');
            } else {
                row.Amount__c = amount;
            }
            return;
        }
        errors.add('The mapping profile has no valid Direction Convention.');
    }

    /** AUM is a balance: zero is valid, negative is not, and there is no direction. */
    @TestVisible
    private static void applyAumValue(Import_Staging_Row__c row, String rawAmount, Config cfg, List<String> errors) {
        if (String.isBlank(rawAmount)) {
            errors.add('AUM value is missing.');
            return;
        }
        Decimal amount = parseAmount(rawAmount, cfg.decimalSeparator, errors);
        if (amount == null) {
            return;
        }
        if (amount < 0) {
            errors.add('AUM value is negative.');
            return;
        }
        row.Amount__c = amount;
    }

    // ------------------------------------------------------------------ helpers

    private static String clean(String value) {
        return value == null ? null : value.replace(NBSP, ' ').replace(NARROW_NBSP, ' ').normalizeSpace();
    }

    private static String textValue(String value, String label, Integer maxLength, Boolean required, List<String> errors) {
        if (String.isBlank(value)) {
            if (required) {
                errors.add(label + ' is missing.');
            }
            return null;
        }
        if (value.length() > maxLength) {
            errors.add(label + ' is longer than ' + maxLength + ' characters.');
            return value.left(maxLength);
        }
        return value;
    }

    private static String rawJson(List<String> headers, List<String> values) {
        if (headers.size() != values.size()) {
            return System.JSON.serialize(values);
        }
        Map<String, String> raw = new Map<String, String>();
        for (Integer i = 0; i < headers.size(); i++) {
            raw.put(headers[i], values[i]);
        }
        return System.JSON.serialize(raw);
    }
}
