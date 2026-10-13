// Generated from tools/verify/vectors.py; the same vectors are checked against a Python port before delivery.
@IsTest
private class CsvParserTest {
    @IsTest
    static void parsesVectors() {
        assertRows('simple', CsvParser.parse('a,b\n1,2\n', ','), new List<List<String>>{ new List<String>{ 'a', 'b' }, new List<String>{ '1', '2' } });
        assertRows('crlf', CsvParser.parse('a,b\r\n1,2', ','), new List<List<String>>{ new List<String>{ 'a', 'b' }, new List<String>{ '1', '2' } });
        assertRows('quoted comma', CsvParser.parse('"x, y",z\n', ','), new List<List<String>>{ new List<String>{ 'x, y', 'z' } });
        assertRows('escaped quote', CsvParser.parse('"he said ""hi""",2', ','), new List<List<String>>{ new List<String>{ 'he said "hi"', '2' } });
        assertRows('newline in quotes', CsvParser.parse('"line1\nline2",3', ','), new List<List<String>>{ new List<String>{ 'line1\nline2', '3' } });
        assertRows('bom', CsvParser.parse(String.fromCharArray(new List<Integer>{ 65279 }) + 'a,b', ','), new List<List<String>>{ new List<String>{ 'a', 'b' } });
        assertRows('blank lines skipped', CsvParser.parse('a,b\n\n1,2\n,\n', ','), new List<List<String>>{ new List<String>{ 'a', 'b' }, new List<String>{ '1', '2' } });
        assertRows('trailing delimiter', CsvParser.parse('a,b,\n', ','), new List<List<String>>{ new List<String>{ 'a', 'b', '' } });
        assertRows('semicolon', CsvParser.parse('a;b\n1,5;2', ';'), new List<List<String>>{ new List<String>{ 'a', 'b' }, new List<String>{ '1,5', '2' } });
        assertRows('tab', CsvParser.parse('a\tb\n1\t2', '\t'), new List<List<String>>{ new List<String>{ 'a', 'b' }, new List<String>{ '1', '2' } });
        assertRows('space delimiter', CsvParser.parse('a b\n1 2', ' '), new List<List<String>>{ new List<String>{ 'a', 'b' }, new List<String>{ '1', '2' } });
        assertRows('empty', CsvParser.parse('', ','), new List<List<String>>{  });
    }

    @IsTest
    static void rejectsMalformedQuotes() {
        assertThrows('"abc,1', ',', 'unclosed quote');
        assertThrows('"a"b,1', ',', 'text after quote');
        assertThrows('a,b', ',,', 'two-character delimiter');
        assertThrows('a,b', '', 'empty delimiter');
    }

    @IsTest
    static void detectsDelimiter() {
        Assert.areEqual(';', CsvParser.detectDelimiter('a;b;c\n1,2;3'), 'delimiter for \'a;b;c\\n1,2;3\'');
        Assert.areEqual(',', CsvParser.detectDelimiter('a,b\n'), 'delimiter for \'a,b\\n\'');
        Assert.areEqual(',', CsvParser.detectDelimiter('"x;y",b'), 'delimiter for \'"x;y",b\'');
        Assert.areEqual('\t', CsvParser.detectDelimiter('a\tb\tc'), 'delimiter for \'a\\tb\\tc\'');
        Assert.areEqual(',', CsvParser.detectDelimiter('abc'), 'delimiter for \'abc\'');
        Assert.areEqual(',', CsvParser.detectDelimiter(null), 'null defaults to comma');
    }

    @IsTest
    static void rejectsBadDelimiter() {
        try {
            CsvParser.parse('a,b', ',,');
            Assert.fail('Expected CsvException');
        } catch (CsvParser.CsvException e) {
            Assert.isTrue(e.getMessage().contains('single character'), 'message: ' + e.getMessage());
        }
    }

    @IsTest
    static void parsesLargeFileWithinLimits() {
        // 5,000 rows with quoted values: guards against quadratic scanning on the platform.
        List<String> lines = new List<String>{ 'Trade Dt,Dealer Rep #,Fund,Amount' };
        for (Integer i = 0; i < 5000; i++) {
            lines.add('09/13/2026,0457,"Wealth World Fund, Series A","$1,250.00"');
        }
        Integer cpuBefore = Limits.getCpuTime();
        List<List<String>> rows = CsvParser.parse(String.join(lines, '\n'), ',');
        Assert.areEqual(5001, rows.size(), 'row count');
        Assert.areEqual('Wealth World Fund, Series A', rows[5000][2], 'quoted value');
        Assert.isTrue(Limits.getCpuTime() - cpuBefore < 8000, 'parse CPU ms: ' + (Limits.getCpuTime() - cpuBefore));
    }

    private static void assertRows(String name, List<List<String>> got, List<List<String>> want) {
        Assert.areEqual(want.size(), got.size(), name + ': row count ' + got);
        for (Integer r = 0; r < want.size(); r++) {
            Assert.areEqual(want[r], got[r], name + ': row ' + r);
        }
    }

    private static void assertThrows(String text, String delimiter, String name) {
        try {
            CsvParser.parse(text, delimiter);
            Assert.fail(name + ': expected CsvException');
        } catch (CsvParser.CsvException e) {
            Assert.isNotNull(e.getMessage(), 'case: ' + name);
        }
    }
}
