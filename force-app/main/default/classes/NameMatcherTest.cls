// Generated from tools/verify/vectors.py; the same vectors are checked against a Python port before delivery.
@IsTest
private class NameMatcherTest {
    @IsTest
    static void compatibilityMatchesVectors() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'Julia Morales', 'Julia', 'Morales', 'true' },
            new List<String>{ 'J. Morales', 'Julia', 'Morales', 'true' },
            new List<String>{ 'Morales', 'Julia', 'Morales', 'true' },
            new List<String>{ 'Morales, Julia', 'Julia', 'Morales', 'true' },
            new List<String>{ 'JULIA  MORALES', 'Julia', 'Morales', 'true' },
            new List<String>{ 'Jorge Morales', 'Julia', 'Morales', 'false' },
            new List<String>{ 'Julia Moralez', 'Julia', 'Morales', 'false' },
            new List<String>{ 'Elise Gagnon', 'Élise', 'Gagnon', 'true' },
            new List<String>{ 'Élise Gagnon et Marc-André Roy', 'Élise', 'Gagnon', 'true' },
            new List<String>{ 'Élise Gagnon et Marc-André Roy', 'Marc-André', 'Roy', 'true' },
            new List<String>{ 'Marc Andre Roy', 'Marc-André', 'Roy', 'true' },
            new List<String>{ 'M. Roy', 'Marc-André', 'Roy', 'true' },
            new List<String>{ 'Priya Nair', 'Marcus', 'Bell', 'false' },
            new List<String>{ 'P. Nair', 'Priya', 'Nair', 'true' },
            new List<String>{ 'Northgate Team', 'Aisha', 'Khan', 'false' },
            new List<String>{ 'Ryan Chen', 'Megan', 'Chen', 'false' },
            new List<String>{ '', 'Julia', 'Morales', 'false' },
            new List<String>{ 'Julia Morales', null, 'Morales', 'true' }
        };
        for (List<String> c : cases) {
            Assert.areEqual(Boolean.valueOf(c[3]), NameMatcher.isCompatible(c[0], c[1], c[2]), 'compatible: ' + c[0] + ' vs ' + c[1] + ' ' + c[2]);
        }
        Assert.isFalse(NameMatcher.isCompatible(null, 'Julia', 'Morales'), 'null row name');
        Assert.isFalse(NameMatcher.isCompatible('Julia Morales', 'Julia', null), 'null last name');
    }

    @IsTest
    static void foldsAccentsAndPunctuation() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'Élise', 'elise' },
            new List<String>{ 'Marc-André Roy', 'marc andre roy' },
            new List<String>{ '  BÉRUBÉ, Zoë ', 'berube zoe' },
            new List<String>{ 'Cœur', 'coeur' },
            new List<String>{ null, '' },
            new List<String>{ 'R&D 2', 'r d 2' }
        };
        for (List<String> c : cases) {
            Assert.areEqual(c[1], NameMatcher.fold(c[0]), 'fold: ' + c[0]);
        }
        Assert.areEqual(new List<String>{ 'marc', 'andre', 'roy' }, NameMatcher.tokens('Marc-André Roy'), 'tokens');
        Assert.isTrue(NameMatcher.tokens('  ').isEmpty(), 'blank has no tokens');
    }

    @IsTest
    static void similarityMatchesVectors() {
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'etf wealth world fund a', 'wealth world fund a', '0.826' },
            new List<String>{ 'northgate wealth partner', 'northgate wealth partners', '0.960' },
            new List<String>{ 'abc', 'abc', '1.000' },
            new List<String>{ 'abc', 'xyz', '0.000' },
            new List<String>{ '', '', '1' },
            new List<String>{ 'abc', 'abd', '0.667' }
        };
        for (List<String> c : cases) {
            Assert.areEqual(Decimal.valueOf(c[2]), NameMatcher.similarity(c[0], c[1]), 'similarity: ' + c[0] + ' vs ' + c[1]);
        }
        Assert.isTrue(NameMatcher.similarity(null, null) == 1, 'nulls compare as identical');
    }
}
