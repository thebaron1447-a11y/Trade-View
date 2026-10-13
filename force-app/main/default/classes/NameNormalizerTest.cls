// Generated from tools/verify/vectors.py; the same vectors are checked against a Python port before delivery.
@IsTest
private class NameNormalizerTest {
    @IsTest
    static void keysMatchVectors() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'Barder & Company', 'barder' },
            new List<String>{ 'Barder and Co', 'barder' },
            new List<String>{ 'Barder and C.', 'barder' },
            new List<String>{ 'Barder & Co., Inc.', 'barder' },
            new List<String>{ 'BARDER AND COMPANY', 'barder' },
            new List<String>{ 'Co', 'co' },
            new List<String>{ 'Lumière Valeurs Mobilières Ltée', 'lumière valeurs mobilières' },
            new List<String>{ 'Lumiere Valeurs Mobilieres', 'lumiere valeurs mobilieres' },
            new List<String>{ 'Kestrel Capital Inc.', 'kestrel capital' },
            new List<String>{ 'Kestrel Capital Ltd.', 'kestrel capital' },
            new List<String>{ 'Northgate WP', 'northgate wp' },
            new List<String>{ 'Smith Corp., Ltd.', 'smith' },
            new List<String>{ 'A.B.C. Securities Inc', 'a b c securities' },
            new List<String>{ 'Fontaine et Cie', 'fontaine' },
            new List<String>{ 'Wealth World Fund - Series A', 'wealth world fund series a' },
            new List<String>{ '   ', null },
            new List<String>{ '!!!', null }
        };
        for (List<String> c : cases) {
            Assert.areEqual(c[1], NameNormalizer.firmKey(c[0]), 'firmKey for ' + c[0]);
        }
    }

    @IsTest
    static void nullInputReturnsNull() {
        Assert.isNull(NameNormalizer.firmKey(null), 'null input');
    }
}
