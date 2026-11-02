@IsTest
private class SecurityModelTest {
    /** A held row behind a code review: Barder trade on code 7001, which is not set up. */
    private static Import_Staging_Row__c heldRow() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '7001', 'Julia Morales', 'Wealth World ETF', Date.newInstance(2026, 9, 29), 1000)
            }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Held', row.Match_Status__c, 'fixture: held behind a code review');
        return row;
    }

    private static String failureOf(SObject change, Boolean asUser) {
        try {
            if (asUser) {
                update as user change;
            } else {
                update change;
            }
        } catch (Exception e) {
            return e.getMessage();
        }
        return 'no error';
    }

    @IsTest
    static void aReviewerCannotChangeWhatTheSystemSets() {
        Import_Staging_Row__c row = heldRow();
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });

        System.runAs(reviewer) {
            // Through the API or a record page: the field is read-only for reviewers.
            String byHand = failureOf(new Import_Staging_Row__c(Id = row.Id, Match_Status__c = 'Matched'), true);
            Assert.areNotEqual('no error', byHand, 'field-level security refuses it');
            // Through code or automation running in system mode: the guard refuses it.
            String bySystemMode = failureOf(new Import_Staging_Row__c(Id = row.Id, Match_Status__c = 'Matched'), false);
            Assert.isTrue(bySystemMode.contains('is set by the system and cannot be changed by hand'), 'the guard refuses it: ' + bySystemMode);
            String counts = failureOf(new Code_Follow_Up__c(Id = row.Code_Follow_Up__c, Held_Row_Count__c = 0), false);
            Assert.isTrue(counts.contains('is set by the system'), 'code review counts too: ' + counts);
            String stamp = failureOf(new Import_Staging_Row__c(Id = row.Id, Decided_By__c = UserInfo.getUserId()), false);
            Assert.isTrue(stamp.contains('is set by the system'), 'and who decided: ' + stamp);

            // What a person decides still saves.
            Assert.areEqual('no error', failureOf(new Import_Staging_Row__c(Id = row.Id, Assigned_To__c = reviewer.Id), true), 'assignment');
            Assert.areEqual(
                'no error',
                failureOf(new Code_Follow_Up__c(Id = row.Code_Follow_Up__c, Resolution_Notes__c = 'Asked the firm.'), true),
                'code review notes'
            );
        }
        Import_Staging_Row__c saved = [SELECT Match_Status__c, Assigned_To__c FROM Import_Staging_Row__c WHERE Id = :row.Id];
        Assert.areEqual('Held', saved.Match_Status__c, 'unchanged');
        Assert.areEqual(reviewer.Id, saved.Assigned_To__c, 'assigned');
    }

    @IsTest
    static void theDataFixPermissionAllowsAHandFix() {
        Import_Staging_Row__c row = heldRow();
        // Trade Import Admin carries the Trade Import Data Fix permission; this user does not have Modify All Data.
        User admin = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Admin' });

        System.runAs(admin) {
            Assert.isTrue(SystemFieldGuard.mayFixData(), 'the admin holds the Data Fix permission through Trade Import Admin');
            Assert.areEqual('no error', failureOf(new Import_Staging_Row__c(Id = row.Id, Match_Notes__c = 'Corrected by hand.'), true), 'allowed');
        }
        Assert.areEqual('Corrected by hand.', [SELECT Match_Notes__c FROM Import_Staging_Row__c WHERE Id = :row.Id].Match_Notes__c, 'saved');
    }

    @IsTest
    static void aReviewerMayNotFixData() {
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });
        System.runAs(reviewer) {
            Assert.isFalse(SystemFieldGuard.mayFixData(), 'no Data Fix permission and no Modify All Data');
        }
    }

    @IsTest
    static void theReviewerPermissionSetMatchesTheGuard() {
        Map<String, SObjectType> types = new Map<String, SObjectType>{
            'Import_Staging_Row__c' => Import_Staging_Row__c.SObjectType,
            'Code_Follow_Up__c' => Code_Follow_Up__c.SObjectType
        };
        Map<String, Set<String>> editable = new Map<String, Set<String>>();
        for (FieldPermissions fp : [
            SELECT SobjectType, Field
            FROM FieldPermissions
            WHERE Parent.Name = 'Trade_Import_Reviewer' AND PermissionsEdit = TRUE AND SobjectType IN :types.keySet()
        ]) {
            if (!editable.containsKey(fp.SobjectType)) {
                editable.put(fp.SobjectType, new Set<String>());
            }
            editable.get(fp.SobjectType).add(fp.Field.substringAfter('.').toLowerCase());
        }
        for (String objectName : types.keySet()) {
            Set<String> people = SystemFieldGuard.PEOPLE_FIELDS.get(types.get(objectName));
            Set<String> granted = editable.containsKey(objectName) ? editable.get(objectName) : new Set<String>();
            for (String f : granted) {
                Assert.isTrue(people.contains(f), objectName + '.' + f + ' is editable by reviewers but guarded as a system field');
            }
            for (String f : people) {
                // A required field (a code review's Status) has no field permission: it is always editable.
                Boolean required = !types.get(objectName).getDescribe().fields.getMap().get(f).getDescribe().isNillable();
                Assert.isTrue(required || granted.contains(f), objectName + '.' + f + ' is a reviewer field but read-only in the permission set');
            }
        }
        Set<String> guarded = SystemFieldGuard.guardedFields(Import_Staging_Row__c.SObjectType).keySet();
        Assert.isTrue(guarded.contains('Match_Status__c'), 'match results are guarded');
        Assert.isFalse(guarded.contains('Reviewer_Decision__c'), 'decisions are not');
    }

    @IsTest
    static void theIntegrationUserEditsNothingDirectly() {
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM FieldPermissions WHERE Parent.Name = 'Trade_Import_Integration' AND PermissionsEdit = TRUE],
            'no editable fields: every save is made by the system writer'
        );
        Assert.areEqual(
            0,
            [
                SELECT COUNT()
                FROM ObjectPermissions
                WHERE Parent.Name = 'Trade_Import_Integration' AND (PermissionsCreate = TRUE OR PermissionsEdit = TRUE OR PermissionsDelete = TRUE)
            ],
            'read-only on every object'
        );
    }
}
