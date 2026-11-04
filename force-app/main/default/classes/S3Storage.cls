/**
 * Amazon S3 for cloud pulls (phase 4c). Every request goes through the source's Named Credential, which points at
 * https://BUCKET.s3.REGION.amazonaws.com and signs with AWS Signature Version 4 using a read-only access key kept in
 * its External Credential, so no key is ever in code, metadata or a record.
 *
 * Uses two read-only S3 calls: ListObjectsV2 (GET /?list-type=2) for the folder, up to MAX_PAGES pages of 1,000, and
 * GetObject (GET /key) for a file. Nothing in the bucket is ever changed.
 */
public with sharing class S3Storage implements CloudStorage {
    private static final String NS = 'http://s3.amazonaws.com/doc/2006-03-01/';
    @TestVisible
    private static final Integer MAX_KEYS = 1000;
    @TestVisible
    private static final Integer MAX_PAGES = 5;
    private static final Integer TIMEOUT_MS = 60000;

    public List<CloudPullService.CloudObject> listFiles(Cloud_Source__c source) {
        List<CloudPullService.CloudObject> result = new List<CloudPullService.CloudObject>();
        String token;
        for (Integer page = 0; page < MAX_PAGES; page++) {
            String path = '/?list-type=2&max-keys=' + MAX_KEYS;
            if (String.isNotBlank(source.Folder__c)) {
                path += '&prefix=' + encode(source.Folder__c);
            }
            if (token != null) {
                path += '&continuation-token=' + encode(token);
            }
            Dom.XmlNode root = xml(send(source, path).getBody());
            for (Dom.XmlNode n : root.getChildElements()) {
                if (n.getName() == 'Contents') {
                    CloudPullService.CloudObject o = new CloudPullService.CloudObject();
                    o.key = text(n, 'Key');
                    o.etag = text(n, 'ETag') == null ? '' : text(n, 'ETag').remove('"');
                    String size = text(n, 'Size');
                    o.size = String.isBlank(size) ? 0 : Long.valueOf(size);
                    result.add(o);
                }
            }
            if (text(root, 'IsTruncated') != 'true') {
                break;
            }
            token = text(root, 'NextContinuationToken');
        }
        return result;
    }

    public Blob readFile(Cloud_Source__c source, String key) {
        return send(source, '/' + encodePath(key)).getBodyAsBlob();
    }

    private static HttpResponse send(Cloud_Source__c source, String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + source.Named_Credential__c + path);
        req.setMethod('GET');
        req.setTimeout(TIMEOUT_MS);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new CloudPullService.CloudException(describe(res));
        }
        return res;
    }

    /** S3's own error code and message, for example "S3 refused the request (403 AccessDenied): Access Denied". */
    @TestVisible
    private static String describe(HttpResponse res) {
        String code;
        String message;
        try {
            Dom.Document doc = new Dom.Document();
            doc.load(res.getBody());
            Dom.XmlNode root = doc.getRootElement();
            code = textNoNs(root, 'Code');
            message = textNoNs(root, 'Message');
        } catch (Exception e) {
            // Not an S3 error document (a proxy page, an empty body): the status code is all there is.
            code = null;
        }
        String reason = 'S3 refused the request (' + res.getStatusCode() + (code == null ? '' : ' ' + code) + ')' + (message == null ? '' : ': ' + message);
        if (res.getStatusCode() == 403) {
            reason += '. Check the access key in the Named Credential\'s External Credential, and that it may list and read this bucket.';
        } else if (res.getStatusCode() == 404) {
            reason += '. Check the bucket and region in the Named Credential\'s URL.';
        }
        return reason.abbreviate(2000);
    }

    private static Dom.XmlNode xml(String body) {
        Dom.Document doc = new Dom.Document();
        doc.load(body);
        return doc.getRootElement();
    }

    private static String text(Dom.XmlNode node, String name) {
        Dom.XmlNode child = node.getChildElement(name, NS);
        return child == null ? null : child.getText();
    }

    // S3 error documents have no namespace.
    private static String textNoNs(Dom.XmlNode node, String name) {
        Dom.XmlNode child = node.getChildElement(name, null);
        return child == null ? null : child.getText();
    }

    /** Percent-encodes a query value the way AWS expects (spaces as %20, not +). */
    @TestVisible
    private static String encode(String value) {
        return EncodingUtil.urlEncode(value, 'UTF-8').replace('+', '%20').replace('%7E', '~');
    }

    /** Encodes each part of an object key, keeping the slashes between folders. */
    @TestVisible
    private static String encodePath(String key) {
        List<String> parts = new List<String>();
        for (String part : key.split('/', -1)) {
            parts.add(encode(part));
        }
        return String.join(parts, '/');
    }
}
