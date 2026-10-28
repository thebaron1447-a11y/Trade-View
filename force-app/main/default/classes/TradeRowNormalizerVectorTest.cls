// Generated from tools/verify/vectors.py; the same vectors are checked against a Python port before delivery.
@IsTest
private class TradeRowNormalizerVectorTest {
    @IsTest
    static void parsesDates() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ '09/13/2026', 'MM/DD/YYYY', '2026-09-13' },
            new List<String>{ '13/09/2026', 'DD/MM/YYYY', '2026-09-13' },
            new List<String>{ '13/09/2026', 'MM/DD/YYYY', null },
            new List<String>{ '03/04/2026', 'MM/DD/YYYY', '2026-03-04' },
            new List<String>{ '03/04/2026', 'DD/MM/YYYY', '2026-04-03' },
            new List<String>{ '2026-09-13', 'YYYY-MM-DD', '2026-09-13' },
            new List<String>{ '2026-9-3', 'YYYY-MM-DD', '2026-09-03' },
            new List<String>{ '31/09/2026', 'DD/MM/YYYY', null },
            new List<String>{ '02/29/2024', 'MM/DD/YYYY', '2024-02-29' },
            new List<String>{ '02/29/2026', 'MM/DD/YYYY', null },
            new List<String>{ '09-13-2026', 'MM/DD/YYYY', '2026-09-13' },
            new List<String>{ '13.09.2026', 'DD/MM/YYYY', '2026-09-13' },
            new List<String>{ '2026-09-13T00:00:00', 'YYYY-MM-DD', '2026-09-13' },
            new List<String>{ '09/13/2026 14:30', 'MM/DD/YYYY', '2026-09-13' },
            new List<String>{ 'Sept 13 2026', 'MM/DD/YYYY', null },
            new List<String>{ '09/13/26', 'MM/DD/YYYY', null },
            new List<String>{ '01/01/1899', 'MM/DD/YYYY', null },
            new List<String>{ '2026-13-01', 'YYYY-MM-DD', null }
        };
        for (List<String> c : cases) {
            List<String> errors = new List<String>();
            Date got = TradeRowNormalizer.parseDate(c[0], c[1], errors);
            if (c[2] == null) {
                Assert.isNull(got, 'expected invalid: ' + c[0] + ' ' + c[1]);
                Assert.areEqual(1, errors.size(), 'one error for ' + c[0]);
            } else {
                Assert.areEqual(Date.valueOf(c[2]), got, c[0] + ' ' + c[1]);
                Assert.isTrue(errors.isEmpty(), 'no errors for ' + c[0]);
            }
        }
    }

    @IsTest
    static void parsesAmounts() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ '$1,250.00', 'Period', '1250.00' },
            new List<String>{ '-$1,250.00', 'Period', '-1250.00' },
            new List<String>{ '$-1,250.00', 'Period', '-1250.00' },
            new List<String>{ '(1,250.50)', 'Period', '-1250.50' },
            new List<String>{ '1250.5', 'Period', '1250.50' },
            new List<String>{ 'CAD 400,000', 'Period', '400000.00' },
            new List<String>{ '250-', 'Period', '-250.00' },
            new List<String>{ '1,234.567', 'Period', '1234.57' },
            new List<String>{ '12 500,00', 'Comma', '12500.00' },
            new List<String>{ '12' + String.fromCharArray(new List<Integer>{ 8239 }) + '500,00', 'Comma', '12500.00' },
            new List<String>{ '1.234,56', 'Comma', '1234.56' },
            new List<String>{ '-3 000,5', 'Comma', '-3000.50' },
            new List<String>{ 'abc', 'Period', null },
            new List<String>{ '1,2,3.4.5', 'Period', null },
            new List<String>{ '$', 'Period', null },
            new List<String>{ '12,345,678,901,234,567.00', 'Period', null },
            new List<String>{ '10,000,000,000,000,000.00', 'Period', null },
            new List<String>{ '9,999,999,999,999,999.99', 'Period', '9999999999999999.99' }
        };
        for (List<String> c : cases) {
            List<String> errors = new List<String>();
            Decimal got = TradeRowNormalizer.parseAmount(c[0], c[1], errors);
            if (c[2] == null) {
                Assert.isNull(got, 'expected invalid: ' + c[0]);
                Assert.areEqual(1, errors.size(), 'one error for ' + c[0]);
            } else {
                Assert.areEqual(Decimal.valueOf(c[2]), got, c[0] + ' ' + c[1]);
            }
        }
    }

    @IsTest
    static void normalizesRepCodes() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ '0457', '457' },
            new List<String>{ ' 457 ', '457' },
            new List<String>{ '000', '0' },
            new List<String>{ 'ab-12', 'AB-12' },
            new List<String>{ '0A12', '0A12' },
            new List<String>{ '00 12', '12' }
        };
        for (List<String> c : cases) {
            Assert.areEqual(c[1], TradeRowNormalizer.normalizeRepCode(c[0]), 'rep code ' + c[0]);
        }
        Assert.isNull(TradeRowNormalizer.normalizeRepCode('  '), 'blank code');
    }

    @IsTest
    static void mapsTransactionTypes() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'Buy', 'Purchase' },
            new List<String>{ 'SELL', 'Redemption' },
            new List<String>{ 'Achat', 'Purchase' },
            new List<String>{ 'RACHAT', 'Redemption' },
            new List<String>{ 'P', 'Purchase' },
            new List<String>{ 'R', 'Redemption' },
            new List<String>{ 'Sub.', 'Purchase' },
            new List<String>{ 'Exchange', null }
        };
        for (List<String> c : cases) {
            Assert.areEqual(c[1], TradeRowNormalizer.TYPE_SYNONYMS.get(c[0].toUpperCase().replaceAll('[^A-Z]', '')), 'type ' + c[0]);
        }
    }

    @IsTest
    static void fingerprintsMatchPython() {
        Assert.areEqual(
            '94c008e98d8013da010d83d5822a31969bfa7e3d315b0a9240394a2c9ccaf7df',
            MappingService.fingerprint(new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Gross Amt' }),
            'fingerprint matches Python sha256'
        );
        Assert.areEqual(
            'b6f990782ebb52d28b0f7abeaac1f5e92a2fd4bebab8e5e9d0724d4a7973bca6',
            MappingService.fingerprint(new List<String>{ '  Date de transaction ', 'Code représentant', 'MONTANT' }),
            'fingerprint matches Python sha256'
        );
    }
}
