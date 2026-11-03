// Removes the stranded work sweeper's four schedules. Salesforce refuses to deploy Apex that a scheduled job depends
// on, so run this before every deploy and schedule-sweeper.apex after it.
// Run: sf apex run --file scripts/apex/unschedule-sweeper.apex --target-org tradeDemo
StrandedWorkSweeper.unschedule();
System.debug('Sweeper schedules left: ' + [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Trade View stranded work sweeper%']);
