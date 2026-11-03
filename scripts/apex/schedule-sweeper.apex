// Schedules the stranded work sweeper every 15 minutes (audit F-08), replacing any earlier schedule.
// Run once after deploying: sf apex run --file scripts/apex/schedule-sweeper.apex --target-org tradeDemo
// To stop it: StrandedWorkSweeper.unschedule();
List<Id> jobs = StrandedWorkSweeper.scheduleEvery15Minutes();
System.debug('Scheduled ' + jobs.size() + ' sweeper runs an hour: ' + jobs);
