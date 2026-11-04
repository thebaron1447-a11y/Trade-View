/**
 * Pulls one cloud source in the background (phase 4c). Queued by Pull now in Trade Review and by the stranded work
 * sweeper when a source is due. A queueable because listing and reading the bucket are callouts.
 */
public with sharing class CloudPullJob implements Queueable, Database.AllowsCallouts {
    private final Id sourceId;

    public CloudPullJob(Id sourceId) {
        this.sourceId = sourceId;
    }

    public void execute(QueueableContext context) {
        CloudPullService.pull(sourceId);
    }
}
