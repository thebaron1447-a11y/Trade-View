/**
 * What Trade View needs from a cloud storage provider (phase 4c): list the files in a source's folder, and read one.
 * S3Storage is the first implementation; Azure Blob and Google Cloud Storage add their own, chosen by the source's
 * Provider in CloudPullService.storageFor. Implementations make callouts only (no DML) and throw
 * CloudPullService.CloudException with a reason a person can act on.
 */
public interface CloudStorage {
    List<CloudPullService.CloudObject> listFiles(Cloud_Source__c source);
    Blob readFile(Cloud_Source__c source, String key);
}
